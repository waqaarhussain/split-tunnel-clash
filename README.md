# Split Tunnel Clash

YouTube domain rules select connections for this VPS's own WireGuard exit. Other connections use DIRECT through the device's normal network. Import one private profile URL into Clash; domain rules refresh centrally. This repository preserves the current Clash setup. The original [wireguard-server](https://github.com/waqaarhussain/wireguard-server) full-tunnel baseline is unchanged.

**Current evidence:** the VPS installation and handshake succeeded, and the user reports YouTube and explicit Control D DNS working on iPhone after reimporting the updated profile. Apple TV playback, exhaustive YouTube coverage and long-term reliability remain unverified. The system-DNS experiment did not preserve the iPhone's installed encrypted DNS profile. This setup therefore selects a fixed Control D DoH URL explicitly; it does not automatically inherit arbitrary device DNS.

## Install on a new VPS

Requires Debian/Ubuntu, APT, systemd, root and an existing `curl` command. Inbound TCP 80/8443 and UDP 51821 must be reachable through host and provider firewalls.

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/split-tunnel-clash/main/install.sh -o /tmp/split-tunnel-install.sh && bash /tmp/split-tunnel-install.sh
```

Then configure your Control D resolver:

```bash
stash dns
```

Paste your full `https://dns.controld.com/…` DoH URL. This is saved in private VPS state, never in GitHub. Keep YouTube redirect disabled in that Control D profile so it returns real destination addresses. The setting applies to this VPS's Clash subscriptions.

Create a device client:

```bash
new
```

Names can include spaces and apostrophes. Import the resulting **Clash subscription URL ending in `/mihomo.yaml`** into Clash as a remote profile, select it, and use Rule mode. Create one client per device. Never run the same peer concurrently in two apps.

[Clash App Store listing](https://apps.apple.com/gb/app/clash-rule-based-proxy/id6794257189) lists iPhone, iPad and Apple TV; actual availability on the user's Apple TV has not been confirmed.

## Existing installation

Do not rerun the installer on the working VPS. It refuses to overwrite initialized keys and clients. Renaming the GitHub repository does not change your VPS subscription URLs, peer keys, DNS setting or client names. Legacy `stash` helper names, `wg-stash`, systemd units and private state paths intentionally remain stable.

To display an existing client's URL:

```bash
stash url
```

When DNS or profile fields change, refresh the full remote profile, not only its rules. If the app retains the old source, disconnect and remove/reimport the same URL. For the fixed-DNS setup, verify that `dns.nameserver` contains the intended Control D HTTPS URL before reconnecting.

## DNS and routing

The Clash profile uses the explicit Control D DoH address for ordinary destinations, DIRECT destinations and proxy hostnames. DNS connects directly (`respect-rules: false`). Only the DoH hostname's bootstrap lookup uses Control D's documented `76.76.2.22` resolver. There is no ordinary-destination fallback to another provider. WireGuard's `remote-dns-resolve` is explicitly false.

Fake-IP mapping inside Clash associates connections with domain rules. Matching service domains use `This VPS`; the final rule is `MATCH,DIRECT`. This does not rewrite YouTube DNS answers to the SNI proxy IP, and it does not build a list of real YouTube IP routes.

`stash dns system` removes the fixed resolver override. That restores the earlier trial, not a guarantee that Apple encrypted DNS configuration profiles are inherited. No private Control D resolver ID is embedded in this repository.

## Rules and scheduling

The default source is the community-maintained [blackmatrix7 YouTube domain catalog](https://github.com/blackmatrix7/ios_rule_script/blob/master/rule/Clash/YouTube/YouTube.yaml). Only validated DOMAIN, DOMAIN-SUFFIX and DOMAIN-KEYWORD entries are accepted; shared IP ranges are excluded. A small bundled seed covers initial download failure; subsequent failures retain the last good list.

The list is not Control D's proprietary service catalog and is not guaranteed exhaustive. Shared hostnames can also be used by other Google functions; traffic to a matching hostname takes the same route regardless of which app requested it. Unknown or unclassified destinations can go direct.

| Operation | Timing |
| --- | --- |
| VPS refreshes the upstream catalog | Every hour at :00 and :30, in the VPS timezone |
| Client fetches the private rule provider | 1800 seconds, subject to app and OS scheduling |
| Server health check | Every five minutes |
| DNS or full profile changes | Refresh the full imported profile and reconnect |

Existing connections and DNS caches may persist across rule updates. The health timer recovers missing project services; it does not restart idle peers. Old handshakes are normal, and restarting the server cannot clear device caches.

Add extra domain suffixes to `/var/lib/stash-split-tunnel/domains.txt`, one per line. Each VPS uses its own detected public IPv4 as the tunnel endpoint and its own egress. Service selection never sends traffic through a hardcoded external proxy.

## Helpers

| Command | Action |
| --- | --- |
| `new` | Create a client and print its Clash URL |
| `stash list` | List clients |
| `stash url` | Select a client and show its existing URL |
| `stash remove` | Confirm removal and revoke peer and URL |
| `stash dns` | Set the private Control D DoH URL |
| `stash dns system` | Restore system-DNS trial |
| `stash rules` | Refresh the catalog now |
| `stash service youtube` | Select YouTube catalog |
| `stash service netflix` | Select Netflix catalog for a separate service experiment |
| `stash service custom` | Use only domains.txt entries |
| `stash status` | Services, DNS mode, rule age, handshakes and firewall counters |

Names may also be passed directly, for example `stash url 'Family iPad'`. Peer updates use `wg syncconf` with rollback on failure. Client operations are serialized.

## Existing SNI and WireGuard coexistence

The project uses `wg-stash`, subnet `10.88.0.0/24`, UDP 51821 and private subscription HTTPS on TCP 8443. It preserves the existing `wg0` and Nginx SNI stream on TCP 443. The installer checks port/subnet conflicts before changes.

For Nginx, a root-only configuration backup is made before adding a separate port-80 ACME challenge virtual host for the VPS IP. It syntax-checks Nginx, gracefully reloads and checks the challenge route; failures roll back that added route. The existing stream configuration is not edited. Original `wg0` and SNI file hashes and the running `wg0` public key are checked before completion.

The installer extracts Caddy from the official signed stable APT package without starting the global caddy.service. The separate stash-https service requests a trusted short-lived Let's Encrypt IP certificate. Public TCP 80 must remain reachable for renewal. Certificate checks are never disabled. Keep `/var/lib/stash-https` intact across reboots.

The dedicated tunnel firewall blocks access to the VPS itself, private destinations and forwarded DNS on ports 53/853. NAT applies only to this project's subnet. These blocks cannot establish that every HTTPS connection is free of encrypted DNS.

## Private state and diagnostics

Private state lives under `/var/lib/stash-split-tunnel`, and the server configuration is `/etc/wireguard/wg-stash.conf`. Subscription URLs contain bearer tokens and return a client private key. Keep them confidential. The backend listens on loopback, logs no token-bearing paths and exposes no admin endpoints. Removing a client revokes both its peer and subscription access.

```bash
stash status
wg show wg-stash
systemctl list-timers 'stash-*'
journalctl -u stash-https -n 50 --no-pager
journalctl -u stash-subscriptions -n 50 --no-pager
```

A different public IP requires deliberate endpoint and certificate migration; existing IP-based URLs do not follow a new VPS automatically. A failed partial installation may be resumed using its installation marker; a completed installation must not be used as an update mechanism.

## Test copies

- [split-tunnel-shadowrocket](https://github.com/waqaarhussain/split-tunnel-shadowrocket): independent baseline copy for future native Shadowrocket profile work.
- [split-tunnel-stash](https://github.com/waqaarhussain/split-tunnel-stash): independent baseline copy for the Stash DNS/transport experiment.

These repositories initially copy the Clash baseline. Creating a copy does not make the existing profile compatible with another app. Do not install multiple copies on the same VPS: they share legacy service names, ports and state paths. App-specific changes and tests come next. The old `/config.yaml` Stash experimental endpoint remains for compatibility; its fixed-DNS behavior is not implemented or validated in this Clash baseline.

## Validation

Run `python3 -m unittest -q` and `bash -n install.sh firewall`. Tests cover peer/key isolation, URL authentication and revocation, names, failed sync rollback, domain validation, last-good rules, Control D URL validation and system reset, Clash profile fields, simulated firewall idempotence and Nginx challenge routing/rollback. These are not device acceptance tests.

On each device, verify the expected Control D resolver ID, actual YouTube playback, matching connections through This VPS and unrelated browsing through DIRECT. A browser public-IP check only describes that request, not YouTube's route. Apple TV and complete domain coverage still require direct testing.
