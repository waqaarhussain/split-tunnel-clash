# WireGuard Server Split Tunnel

**Status: baseline copy only. Split tunnelling is not implemented yet.**

This separate project was copied from [wireguard-server](https://github.com/waqaarhussain/wireguard-server). Its installer is currently identical to the original. The intended next stage is YouTube-only routing with server-managed rules for VPS `45.88.89.23`; that design still needs verification before implementation. Wait for that work before resetting the VPS for a split-tunnel test.

WireGuard VPS setup with interactive `new` and `remove` helpers. This is the original full-tunnel baseline, assembled from the nine supplied commands in their original order. The only added installer line is the Bash shebang; command bodies and helper code are preserved.

## Install

Run in a root Bash session on a fresh Debian/Ubuntu-style VPS using APT and systemd. The download command requires `curl` to be installed already.

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/wireguard-server-split-tunnel/main/install.sh -o /tmp/wireguard-server-split-tunnel-install.sh && bash /tmp/wireguard-server-split-tunnel-install.sh
```

Fresh installation only. Rerunning this script regenerates the server keys and overwrites `/etc/wireguard/wg0.conf`, including existing peer entries. It is not an update command. The installer retains the original command error handling and is not transactional.

## Helpers

| Command | Action |
| --- | --- |
| `new` | Ask for a client name, allocate the first unused IPv4 address, generate its config and PNG QR code, and add its server peer. |
| `remove` | List clients, ask for a selection and explicit `YES`, back up the server config, remove the peer, and delete the selected client's folder. |
| `wg show` | Display WireGuard's current status. |

Run helpers as root. Client files are stored at:

```text
/Wireguard/client/CLIENT_NAME/CLIENT_NAME.conf
/Wireguard/client/CLIENT_NAME/CLIENT_NAME.png
```

The QR code is saved as a PNG only. It is not printed in the terminal. Configs and QR images contain private client keys; keep them private and do not commit generated files to GitHub.

## Preserved configuration

| Setting | Value |
| --- | --- |
| Interface | `wg0` |
| Server VPN address | `10.8.0.1/24` |
| Client address pool | `10.8.0.2` through `10.8.0.254` |
| Listen port | `51820/udp` |
| Endpoint | Public IPv4 detected using `https://api.ipify.org` when `new` runs |
| Client AllowedIPs | `0.0.0.0/0, ::/0` |
| Client DNS field | Omitted |
| Persistent keepalive | `25` seconds |
| Firewall | IPv4 iptables NAT and forwarding rules; attempts a UFW port allowance if UFW is available |

Omitting the DNS field leaves DNS configuration to the client environment. It does not guarantee that DNS traffic bypasses a full tunnel.

## Known limitations of the original commands

- IPv6 forwarding is enabled and client configs include `::/0`, but the supplied setup does not assign IPv6 VPN addresses or provide IPv6 forwarding/firewall/NAT configuration. Working IPv6 internet access through this tunnel has not been established.
- `remove` requires `python3`, which the original APT command does not explicitly install.
- The original name validation permits characters that can break the Python snippet in `remove`, including quotes. Use simple client names containing letters, numbers, hyphens and underscores.
- Client creation has no allocation lock for simultaneous runs.
- Provider-level firewalls and existing host firewall policies are not managed by these commands, apart from the shown iptables rules and UFW allowance.

These points are documented rather than changed, so this repository preserves the supplied baseline. There are no YouTube split-tunnel or DNS-server integration changes in this version.

## Validation

The installer and extracted helper scripts pass `bash -n`. The Python removal snippet compiles with a representative simple client name. Installation and live VPN traffic have not been tested on a VPS as part of packaging.
