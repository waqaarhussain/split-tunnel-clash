#!/usr/bin/env python3
"""Stash subscription gateway and root-only client management. Test release."""
import argparse
import contextlib
import datetime as dt
import fcntl
import grp
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

import yaml

STATE = Path('/var/lib/stash-split-tunnel')
WG_CONF = Path('/etc/wireguard/wg-stash.conf')
IFACE = 'wg-stash'
SOURCE = 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/YouTube/YouTube.yaml'
SEED = ['DOMAIN-SUFFIX,' + d for d in (
    'youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com',
    'youtube-nocookie.com', 'youtubei.googleapis.com',
    'youtube.googleapis.com', 'ggpht.com', 'yt.be')]
DOMAIN = re.compile(r'[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?', re.ASCII)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def run(*args, data=None):
    return subprocess.run(args, input=data, text=True, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()


def atomic(path, data, mode=0o640):
    """Replace a complete file; readers never see a partial credential database."""
    path = Path(path)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.pending-')
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
            if mode == 0o640 and os.geteuid() == 0:
                os.fchown(stream.fileno(), 0, grp.getgrnam('stash-split').gr_gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save(name, value):
    atomic(STATE / name, json.dumps(value, indent=2) + '\n')


def load(name):
    return json.loads((STATE / name).read_text())


@contextlib.contextmanager
def locked():
    with (STATE / 'admin.lock').open('a') as stream:
        os.chmod(stream.name, 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def parse_rules(text):
    document = yaml.safe_load(text)
    if not isinstance(document, dict) or not isinstance(document.get('payload'), list):
        raise ValueError('Expected a Clash YAML payload list')
    if len(document['payload']) > 10000:
        raise ValueError('Too many rules')
    result = []
    for value in document['payload']:
        if not isinstance(value, str):
            raise ValueError('Invalid rule type')
        parts = value.split(',')
        # Domain entries only. Do not accidentally tunnel shared IP networks.
        if parts[0] not in ('DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD'):
            continue
        if len(parts) != 2 or not DOMAIN.fullmatch(parts[1].lower()):
            raise ValueError('Invalid domain rule')
        result.append(parts[0] + ',' + parts[1].lower())
    if not result:
        raise ValueError('No valid domain rules; retaining previous rules')
    return sorted(set(result))


def current_rules():
    rules = list(load('rules.json')['rules'])
    for line in (STATE / 'domains.txt').read_text().splitlines():
        domain = line.partition('#')[0].strip().lower()
        if not domain:
            continue
        if not DOMAIN.fullmatch(domain):
            raise ValueError('Invalid custom domain: ' + domain)
        rules.append('DOMAIN-SUFFIX,' + domain)
    return sorted(set(rules))


def refresh():
    settings = load('settings.json')
    source = settings['rules_source']
    if not source:
        # An empty source means custom-domain-only service (e.g. another VPS).
        rules = []
    else:
        if urlsplit(source).scheme != 'https':
            raise ValueError('Rules source must use HTTPS')
        request = Request(source, headers={'User-Agent': 'stash-split-tunnel/0.1'})
        with urlopen(request, timeout=20) as response:
            if urlsplit(response.geturl()).scheme != 'https':
                raise ValueError('Refusing a non-HTTPS redirect')
            body = response.read(2_000_001)
        if len(body) > 2_000_000:
            raise ValueError('Rules download too large')
        rules = parse_rules(body.decode('utf-8'))
    save('rules.json', {'rules': rules, 'updated': now(), 'source': source})
    print('Rules refreshed: ' + str(len(current_rules())) + ' domain rules')


def select_service(name):
    if name not in ('youtube', 'netflix', 'custom'):
        raise ValueError('Choose youtube, netflix or custom')
    settings = load('settings.json')
    old_settings = dict(settings)
    old_rules = load('rules.json')
    if name == 'custom':
        custom = (STATE / 'domains.txt').read_text()
        if not any(line.partition('#')[0].strip() for line in custom.splitlines()):
            raise ValueError('Add your domain suffixes to ' + str(STATE / 'domains.txt') + ' first')
        settings['rules_source'] = ''
    else:
        title = {'youtube': 'YouTube', 'netflix': 'Netflix'}[name]
        settings['rules_source'] = SOURCE.replace('/YouTube/YouTube.yaml', '/' + title + '/' + title + '.yaml')
    settings['service'] = name
    save('settings.json', settings)
    try:
        refresh()
    except Exception:
        save('settings.json', old_settings)
        save('rules.json', old_rules)
        raise
    print('Service changed. Existing Stash URLs remain valid; clients fetch the new rules on their next refresh.')


def initialize(endpoint):
    address = ipaddress.ip_address(endpoint)
    if address.version != 4 or not address.is_global:
        raise ValueError('A public IPv4 address is required')
    if (STATE / 'settings.json').exists() or WG_CONF.exists():
        raise ValueError('Already initialized; existing keys will not be replaced')
    private = run('wg', 'genkey')
    public = run('wg', 'pubkey', data=private + '\n')
    save('settings.json', {'endpoint': str(address), 'wg_port': 51821,
                          'https_port': 8443, 'server_private': private,
                          'server_public': public, 'rules_source': SOURCE,
                          'created': now()})
    save('clients.json', {})
    save('rules.json', {'rules': SEED, 'updated': now(), 'source': 'bundled seed'})
    atomic(STATE / 'domains.txt', '# Extra domain suffixes, one per line.\n')
    atomic(WG_CONF, render_wg(load('settings.json'), {}), mode=0o600)


def render_wg(settings, clients):
    result = ('[Interface]\nAddress = 10.88.0.1/24\nListenPort = ' + str(settings.get('wg_port', 51821)) + '\n'
              'PrivateKey = ' + settings['server_private'] + '\n'
              'PostUp = /usr/local/lib/stash-split-tunnel/firewall up\n'
              'PostDown = /usr/local/lib/stash-split-tunnel/firewall down\n')
    for name, client in sorted(clients.items()):
        result += ('\n[Peer]\n# ' + name + '\nPublicKey = ' + client['public']
                   + '\nAllowedIPs = ' + client['ip'] + '/32\n')
    return result


def apply_clients(settings, clients):
    original = WG_CONF.read_text()
    atomic(WG_CONF, render_wg(settings, clients), mode=0o600)
    try:
        stripped = run('wg-quick', 'strip', str(WG_CONF))
        # setconf would reset live sessions; syncconf applies only differences.
        with tempfile.NamedTemporaryFile(mode='w', prefix='stash-wg-') as stream:
            os.chmod(stream.name, 0o600)
            stream.write(stripped + '\n')
            stream.flush()
            run('wg', 'syncconf', IFACE, stream.name)
        save('clients.json', clients)
    except Exception:
        atomic(WG_CONF, original, mode=0o600)
        try:
            stripped = run('wg-quick', 'strip', str(WG_CONF))
            with tempfile.NamedTemporaryFile(mode='w') as stream:
                stream.write(stripped + '\n')
                stream.flush()
                run('wg', 'syncconf', IFACE, stream.name)
        except Exception:
            print('Rollback could not resync WireGuard. Check wg-stash before continuing.', file=sys.stderr)
        raise


def add_client(name):
    name = name.strip(' ')
    if (not 1 <= len(name) <= 64 or not name.isprintable()
            or '/' in name or '\\' in name or name in ('.', '..')):
        raise ValueError('Use a name of 1-64 printable characters; no slashes or line breaks')
    clients, settings = load('clients.json'), load('settings.json')
    if name in clients:
        raise ValueError('Client already exists')
    used = {item['ip'] for item in clients.values()}
    available = next(('10.88.0.' + str(i) for i in range(2, 255)
                      if '10.88.0.' + str(i) not in used), None)
    if not available:
        raise ValueError('No free client addresses')
    private = run('wg', 'genkey')
    clients[name] = {'private': private,
                     'public': run('wg', 'pubkey', data=private + '\n'),
                     'ip': available, 'token': secrets.token_urlsafe(32), 'created': now()}
    apply_clients(settings, clients)
    print('Created: ' + name)
    show_url(name)


def show_url(name):
    clients, settings = load('clients.json'), load('settings.json')
    if name not in clients:
        raise ValueError('Unknown client')
    url = subscription_base(settings, clients[name]) + '/mihomo.yaml'
    print('Clash subscription URL (private):\n' + url)
    print('Import into Clash as a remote profile. Use Rule mode.')
    print('DNS: ' + ('explicit Control D DoH' if settings.get('mihomo_doh') else
                      'system trial; run stash dns to set Control D DoH'))
    print('Use one active app per client. Do not share private subscription URLs.')


def remove_client(name):
    clients = load('clients.json')
    if name not in clients:
        raise ValueError('Unknown client')
    if input('Remove ' + name + ' and revoke its URL? Type YES: ') != 'YES':
        raise ValueError('Cancelled')
    del clients[name]
    apply_clients(load('settings.json'), clients)
    print('Removed peer and revoked subscription URL: ' + name)


def subscription_base(settings, client):
    return ('https://' + settings['endpoint'] + ':' + str(settings.get('https_port', 8443))
            + '/s/' + client['token'])


def make_config(settings, client):
    base = subscription_base(settings, client)
    return {
        'mode': 'rule', 'log-level': 'info', 'ipv6': False,
        'dns': {'default-nameserver': ['system'], 'nameserver': ['system'],
                'proxy-server-nameserver': ['system'], 'follow-rule': False,
                'fake-ip-filter': ['*']},
        'proxies': [{'name': 'This VPS', 'type': 'wireguard',
                     'server': settings['endpoint'], 'port': settings.get('wg_port', 51821),
                     'ip': client['ip'], 'private-key': client['private'],
                     'public-key': settings['server_public'],
                     # Do not force a transport resolver. The previous local
                     # sink was observed blocking YouTube DNS on the device.
                     # Keep remote DNS firewall blocks while validating the
                     # adapter's default resolution behavior with system DNS.
                     'mtu': 1380, 'keepalive': 25}],
        'rule-providers': {'selected-service': {'behavior': 'classical',
            'format': 'yaml', 'url': base + '/rules.yaml',
            'interval': 1800}},
        'rules': ['DST-PORT,53,DIRECT', 'DST-PORT,853,DIRECT',
                  'RULE-SET,selected-service,This VPS', 'MATCH,DIRECT']}


def set_dns(value):
    """Store an opt-in Control D DoH URL in private server state."""
    settings = load('settings.json')
    if value == 'system':
        settings.pop('mihomo_doh', None)
    elif re.fullmatch(r'https://dns\.controld\.com/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)?', value):
        settings['mihomo_doh'] = value
    else:
        raise ValueError('Use your https://dns.controld.com/ resolver URL or system')
    save('settings.json', settings)
    print('Clash DNS updated. Refresh the imported profile and reconnect.')


def make_mihomo_config(settings, client):
    """Optional client trial with local resolution or explicit Control D DoH."""
    config = make_config(settings, client)
    config['dns'] = {'enable': True, 'nameserver': ['system'],
                     'default-nameserver': ['system'], 'respect-rules': False,
                     'enhanced-mode': 'fake-ip', 'fake-ip-range': '198.18.0.1/16'}
    if settings.get('mihomo_doh'):
        upstream = settings['mihomo_doh']
        config['dns'].update({'nameserver': [upstream],
            'direct-nameserver': [upstream], 'proxy-server-nameserver': [upstream],
            # Only bootstrap the DoH hostname via Control D's documented IP.
            # No system/public fallback for ordinary destination lookups.
            'default-nameserver': ['76.76.2.22']})
        config['rules'].insert(0, 'DOMAIN,dns.controld.com,DIRECT')
    proxy = config['proxies'][0]
    proxy.pop('keepalive', None)
    proxy.update({'persistent-keepalive': 25, 'remote-dns-resolve': False,
                  'udp': True, 'allowed-ips': ['0.0.0.0/0']})
    config['rule-providers']['selected-service'].update({
        'type': 'http', 'path': './rule-providers/selected-service.yaml'})
    return config


class Gateway(BaseHTTPRequestHandler):
    server_version = 'StashSubscription'

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *_):
        # Request paths contain bearer tokens: never put them in logs.
        pass

    def do_GET(self):
        try:
            path = urlsplit(self.path).path
            if path == '/health':
                return self.respond(200, 'ok\n', 'text/plain')
            match = re.fullmatch(r'/s/([A-Za-z0-9_-]{43})/(config|rules|mihomo)\.yaml', path)
            if not match:
                return self.respond(404, 'Not found\n', 'text/plain')
            token, kind = match.groups()
            client = next((c for c in load('clients.json').values()
                           if hmac.compare_digest(c['token'], token)), None)
            if client is None:
                return self.respond(404, 'Not found\n', 'text/plain')
            if kind == 'rules':
                document = {'payload': current_rules()}
            else:
                renderer = make_mihomo_config if kind == 'mihomo' else make_config
                document = renderer(load('settings.json'), client)
            self.respond(200, yaml.safe_dump(document, sort_keys=False), 'application/yaml')
        except Exception:
            self.respond(503, 'Configuration temporarily unavailable\n', 'text/plain')

    def respond(self, status, body, content_type):
        data = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type + '; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(data)


def status():
    clients = load('clients.json')
    metadata = load('rules.json')
    print('Clash split tunnel: iPhone playback reported working; Apple TV acceptance pending.')
    print('Clash DNS: ' + ('explicit Control D DoH' if load('settings.json').get('mihomo_doh') else 'system trial (not encrypted-profile inheritance)'))
    print('Endpoint: ' + load('settings.json')['endpoint'])
    print('Clients: ' + str(len(clients)))
    print('Domain rules: ' + str(len(current_rules())))
    print('Last successful rule refresh: ' + metadata['updated'])
    print('Refresh schedule: every hour at :00 and :30; Client rule fetch interval: 1800 seconds.')
    for unit in ('wg-quick@wg-stash', 'stash-subscriptions', 'stash-https', 'stash-rules.timer'):
        result = subprocess.run(['systemctl', 'is-active', unit], text=True, capture_output=True)
        print(unit + ': ' + result.stdout.strip())
    try:
        handshakes = dict(line.split('\t') for line in run('wg', 'show', IFACE, 'latest-handshakes').splitlines())
        timestamp = dt.datetime.now(dt.timezone.utc).timestamp()
        for name, client in sorted(clients.items()):
            last = int(handshakes.get(client['public'], 0))
            label = ('never' if not last else str(max(0, int(timestamp - last))) + ' seconds ago')
            print(name + ': last handshake ' + label)
    except (subprocess.CalledProcessError, ValueError):
        print('WireGuard handshake status unavailable')
    print('An old handshake is not proof of a fault. No automatic peer/server restarts.')
    print('\nDNS guard counters (rejections during playback indicate an incompatible remote DNS path):')
    result = subprocess.run(['iptables', '-w', '-nvL', 'STASH_FORWARD'], text=True, capture_output=True)
    print(result.stdout.strip() or 'Firewall counters unavailable')


def choose_client():
    names = sorted(load('clients.json'))
    if not names:
        raise ValueError('No clients exist')
    for i, name in enumerate(names, 1):
        print(str(i) + '. ' + name)
    choice = input('Client number: ').strip()
    if not choice.isdigit() or not 1 <= int(choice) <= len(names):
        raise ValueError('Invalid selection')
    return names[int(choice) - 1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['init', 'new', 'remove', 'url', 'list', 'rules', 'service', 'dns', 'status', 'serve'])
    parser.add_argument('value', nargs='?')
    args = parser.parse_args()
    if args.command == 'serve':
        return ThreadingHTTPServer(('127.0.0.1', 8765), Gateway).serve_forever()
    if os.geteuid() != 0:
        raise ValueError('Run as root')
    with locked():
        if args.command == 'init':
            initialize(args.value)
        elif args.command == 'new':
            add_client(args.value or input('Client name: ').strip())
        elif args.command == 'remove':
            remove_client(args.value or choose_client())
        elif args.command == 'url':
            show_url(args.value or choose_client())
        elif args.command == 'list':
            print('\n'.join(sorted(load('clients.json'))) or 'No clients')
        elif args.command == 'rules':
            refresh()
        elif args.command == 'dns':
            set_dns(args.value or input('Control D DoH URL (or system): ').strip())
        elif args.command == 'service':
            select_service(args.value)
        elif args.command == 'status':
            status()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, yaml.YAMLError) as error:
        # Never echo subprocess stderr: it may contain credentials/configs.
        message = ('A system command failed; check service status.'
                   if isinstance(error, subprocess.CalledProcessError) else str(error))
        print('ERROR: ' + message, file=sys.stderr)
        sys.exit(1)
