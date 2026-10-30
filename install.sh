#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
command -v apt-get >/dev/null || { echo 'Requires Debian/Ubuntu with APT.' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'Requires systemd.' >&2; exit 1; }
STASH_STATE=/var/lib/stash-split-tunnel
if [[ ! -e "$STASH_STATE/.installing" ]] && [[ -e /etc/wireguard/wg-stash.conf || -e "$STASH_STATE/settings.json" ]]; then
    echo 'Already installed. Existing server keys and clients will not be overwritten.' >&2
    echo 'Use new, stash status, stash url or stash rules.' >&2
    exit 1
fi
if [[ ! -e "$STASH_STATE/.installing" ]]; then
    if ss -H -lntu | awk '{print $5}' | grep -Eq ':(8443|8765|9080|51821)$'; then
        echo 'A Stash port (TCP 8443/8765/9080 or UDP 51821) is already occupied. No services changed.' >&2
        exit 1
    fi
    if [[ -n "$(ip -4 route show exact 10.88.0.0/24)" ]]; then
        echo 'The Stash VPN subnet 10.88.0.0/24 is already in use. No services changed.' >&2
        exit 1
    fi
    if [[ -e /usr/local/bin/new && ! -e "$STASH_STATE/new-helper-backup" ]]; then
        install -d -m 750 "$STASH_STATE"
        cp -a /usr/local/bin/new "$STASH_STATE/new-helper-backup"
        chmod 600 "$STASH_STATE/new-helper-backup"
    fi
fi
install -d -m 750 "$STASH_STATE"
touch "$STASH_STATE/.installing"
echo 'Stash Split Tunnel: experimental Stash device test release.'
echo 'Uses device system DNS upstream; strict DNS and playback acceptance need device testing.'
echo 'Uses TCP 8443 for Stash URLs and UDP 51821 for its separate tunnel.'
echo 'TCP 80 is used only for certificate validation. Existing TCP 443 and wg0 are preserved.'
STASH_WG0_HASH="$(sha256sum /etc/wireguard/wg0.conf 2>/dev/null || true)"
STASH_WG0_PUBLIC="$(wg show wg0 public-key 2>/dev/null || true)"
STASH_SNI_HASH="$(sha256sum /etc/nginx/stream.conf 2>/dev/null || true)"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
apt-get update
apt-get install -y wireguard iptables curl ca-certificates python3 python3-yaml gnupg debian-keyring debian-archive-keyring apt-transport-https

STASH_TMP="$(mktemp -d)"
trap 'rm -rf -- "$STASH_TMP"' EXIT
STASH_SOURCE='https://raw.githubusercontent.com/waqaarhussain/stash-split-tunnel/main'
# Digests are updated together with the release files. Never execute a partial
# or mismatched download after a failed/mid-update fetch.
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/manager.py" -o "$STASH_TMP/manager.py"
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 "$STASH_SOURCE/firewall" -o "$STASH_TMP/firewall"
echo '2e54c262130f14126261dd8ebf3ca902f331fc503364403056e09687116a2daf  '"$STASH_TMP/manager.py" | sha256sum -c -
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

# Extract a binary from the signed official package without installing or
# starting its global caddy.service, which would otherwise try to bind port 80.
curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$STASH_TMP/caddy.key"
gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$STASH_TMP/caddy.key"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o /etc/apt/sources.list.d/caddy-stable.list
chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
apt-get update
(cd "$STASH_TMP" && apt-get download caddy)
dpkg-deb -x "$STASH_TMP"/caddy_*.deb "$STASH_TMP/caddy-package"

id stash-split >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin stash-split
install -d -m 755 /usr/local/lib/stash-split-tunnel
install -d -m 755 /etc/stash-split-tunnel
install -m 755 "$STASH_TMP/caddy-package/usr/bin/caddy" /usr/local/lib/stash-split-tunnel/caddy
install -d -m 750 -o root -g stash-split /var/lib/stash-split-tunnel
install -d -m 700 /etc/wireguard
install -m 755 "$STASH_TMP/manager.py" /usr/local/lib/stash-split-tunnel/manager.py
install -m 755 "$STASH_TMP/firewall" /usr/local/lib/stash-split-tunnel/firewall
cat > /usr/local/bin/stash <<'EOF'
#!/bin/bash
exec /usr/bin/python3 /usr/local/lib/stash-split-tunnel/manager.py "$@"
EOF
chmod 755 /usr/local/bin/stash
cat > /usr/local/bin/new <<'EOF'
#!/bin/bash
exec /usr/local/bin/stash new "$@"
EOF
chmod 755 /usr/local/bin/new
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
for unit in stash-subscriptions stash-https; do
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
cat > /etc/stash-split-tunnel/Caddyfile <<EOF
{
    admin off
    http_port 9080
    https_port 8443
    default_sni $STASH_IP
    auto_https disable_redirects
}
https://$STASH_IP:8443 {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
            profile shortlived
            disable_tlsalpn_challenge
            alt_http_port 9080
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
chmod 644 /etc/stash-split-tunnel/Caddyfile
/usr/local/lib/stash-split-tunnel/caddy adapt --config /etc/stash-split-tunnel/Caddyfile --adapter caddyfile --validate >/dev/null

cat > /etc/systemd/system/stash-https.service <<'EOF'
[Unit]
Description=Isolated Stash HTTPS service on port 8443
Wants=network-online.target
After=network-online.target stash-subscriptions.service
[Service]
User=stash-split
Group=stash-split
StateDirectory=stash-https
StateDirectoryMode=0700
Environment=HOME=/var/lib/stash-https
Environment=XDG_DATA_HOME=/var/lib/stash-https/data
Environment=XDG_CONFIG_HOME=/var/lib/stash-https/config
ExecStart=/usr/local/lib/stash-split-tunnel/caddy run --config /etc/stash-split-tunnel/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/stash-https
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
EOF

STASH_NGINX_FILE=/etc/nginx/conf.d/stash-acme.conf
if command -v nginx >/dev/null && systemctl is-active --quiet nginx; then
    install -d -m 700 "$STASH_STATE/backups"
    if [[ ! -f "$STASH_STATE/backups/nginx-before.tar" ]]; then
        tar -C /etc -cf "$STASH_STATE/backups/nginx-before.tar" nginx
        chmod 600 "$STASH_STATE/backups/nginx-before.tar"
    fi
    if [[ -e "$STASH_NGINX_FILE" ]] && ! grep -q '^# Managed by stash-split-tunnel$' "$STASH_NGINX_FILE"; then
        echo 'Existing stash-acme.conf is not ours. Refusing to overwrite it.' >&2
        exit 1
    fi
    cat > "$STASH_NGINX_FILE" <<EOF
# Managed by stash-split-tunnel
server {
    listen 80;
    server_name $STASH_IP;
    access_log off;
    location = /.well-known/acme-challenge/stash-route-check {
        default_type text/plain;
        return 200 "stash-acme-route-ok";
    }
    location ^~ /.well-known/acme-challenge/ {
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:9080;
    }
    location / { return 404; }
}
EOF
    chmod 644 "$STASH_NGINX_FILE"
    if ! nginx -T >"$STASH_TMP/nginx-test.txt" 2>&1 || \
       ! grep -Fq "# configuration file $STASH_NGINX_FILE:" "$STASH_TMP/nginx-test.txt" || \
       grep -q 'conflicting server name' "$STASH_TMP/nginx-test.txt"; then
        rm -f "$STASH_NGINX_FILE"
        echo 'Nginx challenge route could not be validated. No Nginx reload was attempted.' >&2
        cat "$STASH_TMP/nginx-test.txt" >&2
        exit 1
    fi
    if ! systemctl reload nginx; then
        rm -f "$STASH_NGINX_FILE"
        nginx -t && systemctl reload nginx
        echo 'Challenge route reload failed and was rolled back.' >&2
        exit 1
    fi
    if [[ "$(curl --noproxy '*' -fsS --max-time 5 -H "Host: $STASH_IP" http://127.0.0.1/.well-known/acme-challenge/stash-route-check)" != 'stash-acme-route-ok' ]]; then
        rm -f "$STASH_NGINX_FILE"
        nginx -t && systemctl reload nginx
        echo 'Challenge route check failed; route removed. SNI configuration was not edited.' >&2
        exit 1
    fi
else
    if ss -H -lnt | awk '{print $4}' | grep -Eq ':80$'; then
        echo 'Port 80 is occupied by an unsupported service. No existing listener will be stopped.' >&2
        exit 1
    fi
    # A fresh server can route only certificate validation to Caddy as well.
    apt-get install -y nginx
    cat > /etc/nginx/conf.d/stash-acme.conf <<EOF
# Managed by stash-split-tunnel
server {
    listen 80;
    server_name $STASH_IP;
    access_log off;
    location ^~ /.well-known/acme-challenge/ {
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:9080;
    }
    location / { return 404; }
}
EOF
    chmod 644 /etc/nginx/conf.d/stash-acme.conf
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
fi

if command -v ufw >/dev/null && ufw status | head -n 1 | grep -q 'Status: active'; then
    ufw allow 80/tcp
    ufw allow 8443/tcp
    ufw allow 51821/udp
fi
# Allow the services even on hosts with an INPUT policy of DROP.
for STASH_PORT in 80 8443; do
    iptables -w -C INPUT -p tcp --dport "$STASH_PORT" -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -p tcp --dport "$STASH_PORT" -j ACCEPT
done
iptables -w -C INPUT -p udp --dport 51821 -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -p udp --dport 51821 -j ACCEPT

systemctl daemon-reload
systemctl enable --now wg-quick@wg-stash stash-subscriptions stash-https stash-rules.timer stash-health.timer
[[ "$STASH_WG0_HASH" == "$(sha256sum /etc/wireguard/wg0.conf 2>/dev/null || true)" ]] || { echo 'Existing wg0 config changed unexpectedly. Stop and inspect it.' >&2; exit 1; }
[[ "$STASH_SNI_HASH" == "$(sha256sum /etc/nginx/stream.conf 2>/dev/null || true)" ]] || { echo 'Existing SNI config changed unexpectedly. Stop and inspect it.' >&2; exit 1; }
if [[ -n "$STASH_WG0_PUBLIC" ]]; then
    [[ "$STASH_WG0_PUBLIC" == "$(wg show wg0 public-key 2>/dev/null || true)" ]] || { echo 'Existing wg0 interface changed unexpectedly. Stop and inspect it.' >&2; exit 1; }
fi

echo 'Waiting up to one minute for a trusted HTTPS IP certificate...'
STASH_TLS_OK=0
for STASH_ATTEMPT in $(seq 1 15); do
    # 404 is expected at /; curl succeeds only if TLS trust/hostname checks pass.
    if curl --noproxy '*' -sS --connect-timeout 2 --max-time 3 "https://$STASH_IP:8443/" -o /dev/null 2>/dev/null; then
        STASH_TLS_OK=1
        break
    fi
    sleep 1
done
echo
stash status
if [[ "$STASH_TLS_OK" -ne 1 ]]; then
    echo 'HTTPS is not ready. Check inbound TCP 80/8443 and journalctl -u stash-https.' >&2
    echo 'Do not import a URL until its HTTPS certificate validates. Do not bypass certificate verification.' >&2
    exit 1
fi
rm -f "$STASH_STATE/.installing"
echo
echo 'Installed TEST RELEASE. Create a client for any device: new'
echo 'Then paste its private subscription URL into Stash > Download from URL.'
echo 'Verify device DNS and YouTube playback. This release is not yet device-validated.'
