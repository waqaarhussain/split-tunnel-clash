#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
command -v apt-get >/dev/null || { echo 'Requires Debian/Ubuntu with APT.' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'Requires systemd.' >&2; exit 1; }
STASH_STATE=/var/lib/stash-split-tunnel
if [[ ! -e "$STASH_STATE/.installing" ]] && [[ -e /etc/wireguard/wg-stash.conf || -e "$STASH_STATE/settings.json" ]]; then
    echo 'Already installed. Existing server keys and clients will not be overwritten.' >&2
    echo 'Use stash status, stash new, stash url or stash rules.' >&2
    exit 1
fi
if [[ ! -e "$STASH_STATE/.installing" ]] && { [[ -e /etc/wireguard/wg0.conf ]] || command -v caddy >/dev/null; }; then
    echo 'Use a fresh VPS. Existing WireGuard/Caddy configuration detected.' >&2
    exit 1
fi
install -d -m 750 "$STASH_STATE"
touch "$STASH_STATE/.installing"
echo 'Stash Split Tunnel: experimental Apple TV test release.'
echo 'Uses device system DNS upstream; strict DNS and playback acceptance need device testing.'
echo 'Requires inbound TCP 80/443 and UDP 51820, including provider firewalls.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wireguard iptables curl ca-certificates python3 python3-yaml gnupg debian-keyring debian-archive-keyring apt-transport-https

STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
STASH_SOURCE='https://raw.githubusercontent.com/waqaarhussain/stash-split-tunnel/main'
# Digests are updated together with the release files. Never execute a partial
# or mismatched download after a failed/mid-update fetch.
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/manager.py" -o "$STASH_TMP/manager.py"
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/firewall" -o "$STASH_TMP/firewall"
echo '148cbd9d1d24bf52bd035bcc2436e9be9797ecffff251d06a177fcc6381c1409  '"$STASH_TMP/manager.py" | sha256sum -c -
echo '2222a6647e6f7e919e48865cd706a635dd1ca9d9aa9bf99dea3d992d28b13fe3  '"$STASH_TMP/firewall" | sha256sum -c -
python3 -m py_compile "$STASH_TMP/manager.py"
bash -n "$STASH_TMP/firewall"

STASH_IP="$(curl --proto '=https' --tlsv1.2 -4fsS --connect-timeout 10 --max-time 20 https://api.ipify.org)"
python3 - "$STASH_IP" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
if ip.version != 4 or not ip.is_global:
    raise SystemExit('Could not detect a public IPv4 address')
PY

# Official Caddy stable package repository, with its scoped signing key.
curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$STASH_TMP/caddy.key"
gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$STASH_TMP/caddy.key"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o /etc/apt/sources.list.d/caddy-stable.list
chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

id stash-split >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin stash-split
install -d -m 755 /usr/local/lib/stash-split-tunnel
install -d -m 750 -o root -g stash-split /var/lib/stash-split-tunnel
install -d -m 700 /etc/wireguard
install -m 755 "$STASH_TMP/manager.py" /usr/local/lib/stash-split-tunnel/manager.py
install -m 755 "$STASH_TMP/firewall" /usr/local/lib/stash-split-tunnel/firewall
cat > /usr/local/bin/stash <<'EOF'
#!/bin/bash
exec /usr/bin/python3 /usr/local/lib/stash-split-tunnel/manager.py "$@"
EOF
chmod 755 /usr/local/bin/stash
if [[ -e "$STASH_STATE/settings.json" ]]; then
    for STASH_EXISTING in clients.json rules.json domains.txt; do
        [[ -f "$STASH_STATE/$STASH_EXISTING" ]] || { echo 'Incomplete initialization. Preserve the state directory and inspect it before retrying.' >&2; exit 1; }
    done
    [[ -f /etc/wireguard/wg-stash.conf ]] || { echo 'Server config missing. Preserve existing keys before attempting recovery.' >&2; exit 1; }
    # Resume a failed installation without changing existing keys or URLs.
    STASH_IP="$(python3 -c 'import json; print(json.load(open("/var/lib/stash-split-tunnel/settings.json"))["endpoint"])')"
else
    stash init "$STASH_IP"
fi
if ! stash rules; then
    echo 'Rules source unavailable. Bundled seed retained; the timer will retry.' >&2
fi

cat > /etc/sysctl.d/99-stash-split-tunnel.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-stash-split-tunnel.conf

cat > /etc/systemd/system/stash-subscriptions.service <<'EOF'
[Unit]
Description=Private Stash subscription URL service
After=network.target
[Service]
User=stash-split
Group=stash-split
ExecStart=/usr/local/bin/stash serve
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/stash-rules.service <<'EOF'
[Unit]
Description=Refresh Stash service domain list, keeping last good copy on failure
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/stash rules
TimeoutStartSec=60
EOF
cat > /etc/systemd/system/stash-rules.timer <<'EOF'
[Unit]
Description=Refresh domain list on the hour and half hour
[Timer]
OnCalendar=*-*-* *:00,30:00
Persistent=true
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF

cat > /usr/local/lib/stash-split-tunnel/health <<'EOF'
#!/bin/bash
set -euo pipefail
# Restart only an absent interface or failed service, never an idle peer.
if ! wg show wg-stash >/dev/null 2>&1; then
    systemctl restart wg-quick@wg-stash
fi
for unit in stash-subscriptions caddy; do
    if ! systemctl is-active --quiet "$unit"; then
        systemctl start "$unit"
    fi
done
EOF
chmod 755 /usr/local/lib/stash-split-tunnel/health
cat > /etc/systemd/system/stash-health.service <<'EOF'
[Unit]
Description=Recover missing Stash services without restarting idle peers
[Service]
Type=oneshot
ExecStart=/usr/local/lib/stash-split-tunnel/health
TimeoutStartSec=60
EOF
cat > /etc/systemd/system/stash-health.timer <<'EOF'
[Unit]
Description=Check Stash services every five minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF

# A public IP certificate avoids requiring a DNS name. Explicit ACME issuer
# prevents Caddy from choosing its local/self-signed CA for this address.
cat > /etc/caddy/Caddyfile <<EOF
{
    default_sni $STASH_IP
    auto_https disable_redirects
}
https://$STASH_IP {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
            profile shortlived
        }
    }
    @subscriptions path /s/*
    handle @subscriptions {
        reverse_proxy 127.0.0.1:8765
    }
    handle {
        respond "Not found" 404
    }
}
EOF
chmod 644 /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile

if command -v ufw >/dev/null && ufw status | head -n 1 | grep -q 'Status: active'; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 51820/udp
fi
# Allow the services even on hosts with an INPUT policy of DROP.
for STASH_PORT in 80 443; do
    iptables -w -C INPUT -p tcp --dport "$STASH_PORT" -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -p tcp --dport "$STASH_PORT" -j ACCEPT
done
iptables -w -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -p udp --dport 51820 -j ACCEPT

systemctl daemon-reload
systemctl enable --now wg-quick@wg-stash stash-subscriptions stash-rules.timer stash-health.timer
systemctl enable caddy
systemctl restart caddy

echo 'Waiting up to one minute for a trusted HTTPS IP certificate...'
STASH_TLS_OK=0
for STASH_ATTEMPT in $(seq 1 15); do
    # 404 is expected at /; curl succeeds only if TLS trust/hostname checks pass.
    if curl --noproxy '*' -sS --connect-timeout 2 --max-time 3 "https://$STASH_IP/" -o /dev/null 2>/dev/null; then
        STASH_TLS_OK=1
        break
    fi
    sleep 1
done
echo
stash status
if [[ "$STASH_TLS_OK" -ne 1 ]]; then
    echo 'HTTPS is not ready. Check inbound TCP 80/443 and journalctl -u caddy.' >&2
    echo 'Do not import a URL until its HTTPS certificate validates. Do not bypass certificate verification.' >&2
    exit 1
fi
rm -f "$STASH_STATE/.installing"
echo
echo 'Installed TEST RELEASE. Create a device: stash new'
echo 'Then paste its private subscription URL into Stash > Download from URL.'
echo 'Verify device DNS and YouTube playback. This release is not yet device-validated.'
