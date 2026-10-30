#!/bin/bash

apt update
apt install -y wireguard iptables qrencode curl

cat > /etc/sysctl.d/99-wireguard.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system

mkdir -p /Wireguard/server /Wireguard/client
chmod 700 /Wireguard

umask 077
wg genkey | tee /Wireguard/server/server_privatekey | wg pubkey > /Wireguard/server/server_publickey

SERVER_IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $(cat /Wireguard/server/server_privatekey)

# NAT for full-tunnel clients
PostUp   = iptables -t nat -A POSTROUTING -o ${SERVER_IFACE} -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_IFACE} -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF

chmod 600 /etc/wireguard/wg0.conf

ufw allow 51820/udp 2>/dev/null || true

systemctl enable --now wg-quick@wg0
wg show

cat > /usr/local/bin/new << 'EOF'
#!/bin/bash
set -euo pipefail

BASE="/Wireguard"
CLIENTS="$BASE/client"
SERVER_CONF="/etc/wireguard/wg0.conf"
SERVER_PUB="$(cat "$BASE/server/server_publickey")"
SERVER_IP="$(curl -4 -s https://api.ipify.org || true)"
SERVER_PORT="51820"

mkdir -p "$CLIENTS"

read -r -p "Client name: " NAME
NAME="$(echo "$NAME" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
if [ -z "$NAME" ]; then
  echo "Client name cannot be empty."
  exit 1
fi

# block only the truly dangerous stuff
if echo "$NAME" | grep -qE '(^\.\.$|^\.$|/|\\)'; then
  echo "Invalid name: cannot contain / or \\ or be . or .."
  exit 1
fi

DIR="$CLIENTS/$NAME"
if [ -d "$DIR" ]; then
  echo "Client already exists: $DIR"
  exit 1
fi
mkdir -p "$DIR/keys"
chmod 700 "$DIR" "$DIR/keys"

# Allocate first free IP in 10.8.0.2-254 based on server AllowedIPs entries
USED="$(grep -Eo 'AllowedIPs[[:space:]]*=[[:space:]]*10\.8\.0\.[0-9]+/32' "$SERVER_CONF" \
  | grep -Eo '10\.8\.0\.[0-9]+' \
  | awk -F. '{print $4}' | sort -n | uniq || true)"

NEXT=""
for o in $(seq 2 254); do
  if ! echo "$USED" | grep -qx "$o"; then
    NEXT="$o"
    break
  fi
done

if [ -z "$NEXT" ]; then
  echo "No available IPs left in 10.8.0.0/24."
  exit 1
fi

IP="10.8.0.$NEXT"

umask 077
PRIV="$(wg genkey)"
PUB="$(echo "$PRIV" | wg pubkey)"

CONF="$DIR/$NAME.conf"

# FULL TUNNEL, NO DNS LINE
cat > "$CONF" << EOC
[Interface]
PrivateKey = $PRIV
Address = $IP/32

[Peer]
PublicKey = $SERVER_PUB
Endpoint = ${SERVER_IP:-YOUR_SERVER_PUBLIC_IP}:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOC

# QR as PNG only (no terminal QR)
qrencode -t PNG -o "$DIR/$NAME.png" < "$CONF"
chmod 600 "$CONF" "$DIR/$NAME.png"

# Add peer to server config
cat >> "$SERVER_CONF" << EOP

[Peer]
# $NAME
PublicKey = $PUB
AllowedIPs = $IP/32
EOP
chmod 600 "$SERVER_CONF"

# Apply changes safely
if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl restart wg-quick@wg0
fi

echo "[+] Client created:"
echo "    Dir   : $DIR"
echo "    Conf  : $CONF"
echo "    QR PNG: $DIR/$NAME.png"
echo "    IP    : $IP"
EOF

chmod +x /usr/local/bin/new

cat > /usr/local/bin/remove << 'EOF'
#!/bin/bash
set -euo pipefail

CLIENTS_DIR="/Wireguard/client"
WG_CONF="/etc/wireguard/wg0.conf"

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -d "$CLIENTS_DIR" ]] || die "Missing $CLIENTS_DIR"
[[ -f "$WG_CONF" ]] || die "Missing $WG_CONF"

# List client directories
mapfile -d '' DIRS < <(find "$CLIENTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [[ ${#DIRS[@]} -eq 0 ]]; then
  die "No clients found in $CLIENTS_DIR"
fi

echo ""
echo "Clients:"
for i in "${!DIRS[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "$(basename "${DIRS[$i]}")"
done
echo ""

read -r -p "Select client number to REMOVE: " choice
[[ "$choice" =~ ^[0-9]+$ ]] || die "Not a number."
(( choice >= 1 && choice <= ${#DIRS[@]} )) || die "Out of range."

TARGET_DIR="${DIRS[$((choice-1))]}"
NAME="$(basename "$TARGET_DIR")"

echo ""
echo "Selected: $NAME"
read -r -p "Type YES to confirm: " confirm
[[ "$confirm" == "YES" ]] || die "Cancelled."

# Backup server config first
BACKUP="${WG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$WG_CONF" "$BACKUP"

# Remove the peer block that contains:
# [Peer]
# # NAME
python3 - <<PY
import pathlib

wg_conf = pathlib.Path("$WG_CONF")
name = "$NAME"

text = wg_conf.read_text(encoding="utf-8", errors="surrogateescape")
blocks = text.split("\n\n")

kept = []
removed = 0
for b in blocks:
    lines = [ln.strip() for ln in b.splitlines()]
    if "[Peer]" in lines and f"# {name}" in lines:
        removed += 1
        continue
    kept.append(b)

wg_conf.write_text("\n\n".join(kept).rstrip() + "\n", encoding="utf-8", errors="surrogateescape")
print(f"Removed peer blocks: {removed}")
PY

# Apply changes to running wg0
if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
else
  systemctl restart wg-quick@wg0 || true
fi

# Delete client directory
rm -rf -- "$TARGET_DIR"

echo ""
echo "DONE."
echo "Removed client : $NAME"
echo "Deleted folder : $TARGET_DIR"
echo "Config backup  : $BACKUP"
EOF

chmod +x /usr/local/bin/remove
