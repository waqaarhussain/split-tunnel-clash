# Stash Split Tunnel

**Status: preparation stage. The existing installer is still the original full-tunnel WireGuard baseline. Stash URL generation and split routing are not implemented yet.**

A project for Stash on Apple TV, iPhone and iPad, using a subscription URL imported once and centrally maintained domain rules. The original [wireguard-server](https://github.com/waqaarhussain/wireguard-server) repository remains separate.

## Intended behavior

- Send YouTube traffic through the selected VPS, using that VPS's own internet connection.
- Send unmatched traffic directly through the device's normal ISP connection.
- Detect each VPS's endpoint during setup rather than hardcoding a public IP into the installer.
- Provide a private Stash subscription URL for each client, rather than requiring manual configuration-file editing.
- Keep domain rules on the VPS and allow Stash to fetch updates periodically. The proposed server refresh schedule is at the hour and half hour; client fetching is a separate interval and is not guaranteed to occur at those exact clock times.
- Use the DNS resolver already supplied by the device/network, without adding a public resolver or fallback. This is a required acceptance criterion, not a validated capability of the current implementation.

Stash replaces the standard WireGuard client app in this design. WireGuard may still serve as the transport between Stash and the VPS; changing client apps does not itself require replacing the server protocol.

## DNS acceptance requirement

Stash documents `system` as an upstream DNS choice, but also has its own DNS handling and protocol-specific resolution. We have not verified that its WireGuard and proxied UDP paths can satisfy strict device-DNS-only operation. Do not describe the project as meeting that requirement until an Apple TV test confirms it.

## Installation status

Do not reset a VPS for a Stash split-tunnel test yet. This command currently installs only the preserved full-tunnel baseline; it does not generate Stash subscription URLs:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/stash-split-tunnel/main/install.sh -o /tmp/stash-split-tunnel-install.sh && bash /tmp/stash-split-tunnel-install.sh
```

For baseline installation only: run in a root Bash session on a fresh Debian/Ubuntu-style VPS with APT, systemd and `curl` available.

Rerunning the existing installer regenerates the server keys and overwrites `/etc/wireguard/wg0.conf`, including existing peer entries. It is not an update command. The installer retains the original command error handling and is not transactional.

## Current baseline reference

The sections below describe the preserved installer, not the planned Stash interface.

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

These points describe the unchanged baseline. Stash subscription hosting, domain-rule updates and strict DNS behavior still require implementation and validation.

## Validation

The installer and extracted helper scripts pass `bash -n`. The Python removal snippet compiles with a representative simple client name. Installation and live VPN traffic have not been tested on a VPS as part of packaging.
