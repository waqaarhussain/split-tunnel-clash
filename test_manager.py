import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

import yaml
import manager as m


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.conf = self.root / 'wg-stash.conf'
        self.patches = [patch.object(m, 'STATE', self.state), patch.object(m, 'WG_CONF', self.conf),
                        patch.object(m.grp, 'getgrnam', return_value=types.SimpleNamespace(gr_gid=os.getgid()))]
        for item in self.patches:
            item.start()
        self.settings = {'endpoint': '203.0.113.8', 'server_private': 'SERVER_PRIVATE',
                         'server_public': 'SERVER_PUBLIC', 'rules_source': m.SOURCE}
        m.save('settings.json', self.settings)
        m.save('clients.json', {})
        m.save('rules.json', {'rules': m.SEED, 'updated': 'seed', 'source': 'seed'})
        m.atomic(self.state / 'domains.txt', '# Test suffixes\n')
        self.conf.write_text(m.render_wg(self.settings, {}))
        self.calls = []

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def fake_run(self, *args, data=None):
        self.calls.append(args)
        if args == ('wg', 'genkey'):
            return 'PRIVATE_' + secrets.token_hex(4)
        if args == ('wg', 'pubkey'):
            return 'PUBLIC_' + hashlib.sha256(data.encode()).hexdigest()
        if args[:2] == ('wg-quick', 'strip'):
            return self.conf.read_text()
        if args[:2] == ('wg', 'syncconf'):
            return ''
        raise AssertionError(args)

    def add(self, name):
        with patch.object(m, 'run', side_effect=self.fake_run), contextlib.redirect_stdout(io.StringIO()):
            m.add_client(name)

    def test_distinct_keys_addresses_and_tokens(self):
        self.add('AppleTV')
        self.add('iPhone')
        clients = m.load('clients.json')
        self.assertEqual({c['ip'] for c in clients.values()}, {'10.88.0.2', '10.88.0.3'})
        self.assertNotEqual(clients['AppleTV']['token'], clients['iPhone']['token'])
        self.assertNotEqual(clients['AppleTV']['private'], clients['iPhone']['private'])
        self.assertNotIn('PRIVATE_', self.conf.read_text())
        self.assertEqual(self.conf.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.state / 'clients.json').stat().st_mode & 0o777, 0o640)

    def test_names_cannot_inject_config_or_paths(self):
        for name in ('../x', 'a/b', 'a\nb', 'a"b', '', '-test', 'x' * 65):
            with self.assertRaises(ValueError):
                self.add(name)
        self.assertEqual(m.load('clients.json'), {})

    def test_duplicate_and_exhausted_pool_leave_state_unchanged(self):
        self.add('TV')
        before = self.conf.read_text()
        with self.assertRaises(ValueError):
            self.add('TV')
        self.assertEqual(before, self.conf.read_text())
        clients = {str(i): {'ip': '10.88.0.' + str(i)} for i in range(2, 255)}
        m.save('clients.json', clients)
        with self.assertRaisesRegex(ValueError, 'No free'):
            self.add('other')

    def test_failed_peer_sync_restores_config_and_client_database(self):
        before = self.conf.read_text()
        def failing(*args, data=None):
            if args[:2] == ('wg', 'syncconf'):
                raise subprocess.CalledProcessError(1, args)
            return self.fake_run(*args, data=data)
        with patch.object(m, 'run', side_effect=failing), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                m.add_client('TV')
        self.assertEqual(self.conf.read_text(), before)
        self.assertEqual(m.load('clients.json'), {})

    def test_config_uses_local_endpoint_system_dns_direct_default(self):
        self.add('TV')
        client = m.load('clients.json')['TV']
        config = m.make_config(self.settings, client)
        self.assertEqual(config['proxies'][0]['server'], '203.0.113.8')
        for option in ('nameserver', 'default-nameserver', 'proxy-server-nameserver'):
            self.assertEqual(config['dns'][option], ['system'])
        self.assertNotIn('fallback', config['dns'])
        self.assertFalse(config['dns']['follow-rule'])
        # An unavailable tunnel-local DNS sink prevents public remote defaults.
        self.assertEqual(config['proxies'][0]['dns'], ['10.88.0.1'])
        self.assertEqual(config['rules'][-1], 'MATCH,DIRECT')
        self.assertEqual(config['rule-providers']['selected-service']['interval'], 1800)
        self.assertEqual(yaml.safe_load(yaml.safe_dump(config)), config)

    def test_rule_validation_ignores_shared_ip_rules_and_rejects_injection(self):
        rules = m.parse_rules('payload:\n - DOMAIN-SUFFIX,youtube.com\n - IP-CIDR,1.0.0.0/8\n')
        self.assertEqual(rules, ['DOMAIN-SUFFIX,youtube.com'])
        for body in ('payload: []', 'payload:\n - MATCH,DIRECT',
                     'payload:\n - DOMAIN-SUFFIX,x.com,DIRECT',
                     'payload:\n - DOMAIN-SUFFIX,*', 'payload:\n - 12'):
            with self.assertRaises(ValueError):
                m.parse_rules(body)

    def test_failed_rule_download_keeps_previous_copy(self):
        before = (self.state / 'rules.json').read_text()
        with patch.object(m, 'urlopen', side_effect=OSError('network unavailable')):
            with self.assertRaises(OSError):
                m.refresh()
        self.assertEqual((self.state / 'rules.json').read_text(), before)

    def test_service_change_rolls_back_on_failed_refresh(self):
        before = copy.deepcopy(m.load('settings.json'))
        rules = copy.deepcopy(m.load('rules.json'))
        with patch.object(m, 'urlopen', side_effect=OSError('network unavailable')):
            with self.assertRaises(OSError):
                m.select_service('netflix')
        self.assertEqual(m.load('settings.json'), before)
        self.assertEqual(m.load('rules.json'), rules)

    def test_custom_service_retains_client_token_and_removes_youtube(self):
        self.add('TV')
        token = m.load('clients.json')['TV']['token']
        m.atomic(self.state / 'domains.txt', 'netflix.com\n')
        with contextlib.redirect_stdout(io.StringIO()):
            m.select_service('custom')
        self.assertEqual(m.current_rules(), ['DOMAIN-SUFFIX,netflix.com'])
        self.assertEqual(m.load('clients.json')['TV']['token'], token)

    def test_http_subscription_authentication_and_revocation(self):
        self.add('TV')
        token = m.load('clients.json')['TV']['token']
        server = m.ThreadingHTTPServer(('127.0.0.1', 0), m.Gateway)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        base = 'http://127.0.0.1:' + str(server.server_port)
        try:
            with urlopen(base + '/s/' + token + '/config.yaml') as response:
                document = yaml.safe_load(response.read())
                self.assertEqual(response.headers['Cache-Control'], 'no-store')
                self.assertEqual(document['proxies'][0]['private-key'], m.load('clients.json')['TV']['private'])
            with urlopen(base + '/s/' + token + '/rules.yaml') as response:
                self.assertIn('DOMAIN-SUFFIX,youtube.com', yaml.safe_load(response.read())['payload'])
            for path in ('/', '/settings.json', '/s/' + 'A' * 43 + '/config.yaml', '/s/' + token + '/../clients.json'):
                with self.assertRaises(HTTPError) as error:
                    urlopen(base + path)
                self.assertEqual(error.exception.code, 404)
            with patch('builtins.input', return_value='YES'), patch.object(m, 'run', side_effect=self.fake_run), contextlib.redirect_stdout(io.StringIO()):
                m.remove_client('TV')
            self.assertNotIn('[Peer]', self.conf.read_text())
            with self.assertRaises(HTTPError) as error:
                urlopen(base + '/s/' + token + '/config.yaml')
            self.assertEqual(error.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_firewall_reapply_and_cleanup_with_simulated_iptables(self):
        bindir = self.root / 'bin'
        bindir.mkdir()
        statefile = self.root / 'iptables.json'
        (bindir / 'ip').write_text('#!/bin/sh\necho "default via 192.0.2.1 dev eth0"\n')
        (bindir / 'ip').chmod(0o755)
        (bindir / 'iptables').write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['IPTABLES_SIMULATION'])
d=json.loads(p.read_text()) if p.exists() else {'filter:INPUT':[], 'filter:FORWARD':[], 'nat:POSTROUTING':[]}
a=sys.argv[1:]
if '-w' in a: a.remove('-w')
table='filter'
if '-t' in a:
    i=a.index('-t'); table=a[i+1]; del a[i:i+2]
op,chain=a[:2]; rule=a[2:]; key=table+':'+chain
if op=='-C': sys.exit(0 if rule in d.get(key,[]) else 1)
if op=='-N':
    if key in d: sys.exit(1)
    d[key]=[]
elif op=='-A': d[key].append(rule)
elif op=='-I':
    if rule and rule[0].isdigit(): rule=rule[1:]
    d[key].insert(0,rule)
elif op=='-D':
    if rule not in d.get(key,[]): sys.exit(1)
    d[key].remove(rule)
elif op=='-F':
    if key not in d: sys.exit(1)
    d[key]=[]
elif op=='-X':
    if key not in d: sys.exit(1)
    del d[key]
else: sys.exit(2)
p.write_text(json.dumps(d))
''')
        (bindir / 'iptables').chmod(0o755)
        env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'], IPTABLES_SIMULATION=str(statefile))
        firewall = str(Path(m.__file__).with_name('firewall'))
        subprocess.run(['bash', firewall, 'up'], env=env, check=True)
        first = json.loads(statefile.read_text())
        subprocess.run(['bash', firewall, 'up'], env=env, check=True)
        self.assertEqual(first, json.loads(statefile.read_text()))
        chain = first['filter:STASH_FORWARD']
        accept_index = next(i for i, r in enumerate(chain) if r[-1] == 'ACCEPT')
        for protocol in ('tcp', 'udp'):
            dns_index = next(i for i, r in enumerate(chain) if protocol in r and '--dports' in r)
            self.assertLess(dns_index, accept_index)
            self.assertEqual(chain[dns_index][-1], 'REJECT')
            self.assertIn('53,853', chain[dns_index])
        self.assertEqual(chain[-1], ['-j', 'REJECT'])
        nat = first['nat:POSTROUTING']
        self.assertEqual(len(nat), 1)
        self.assertIn('10.88.0.0/24', nat[0])
        subprocess.run(['bash', firewall, 'down'], env=env, check=True)
        for rules in json.loads(statefile.read_text()).values():
            self.assertEqual(rules, [])


if __name__ == '__main__':
    unittest.main()
