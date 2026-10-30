# Stash Split Tunnel

**Experimental test release. The installer and subscription service are implemented. Live VPS installation, certificate issuance, Stash parsing, Apple TV playback and strict device-DNS behavior have not been verified on real devices.**

Import a private URL into Stash once. Matching YouTube domains use that VPS's WireGuard connection; unmatched connections use `DIRECT` through the device's normal network. Stash is the client app; WireGuard remains the server transport. The original [wireguard-server](https://github.com/waqaarhussain/wireguard-server) repository is separate and unchanged.

## Install alongside an existing SNI proxy

Requires Debian/Ubuntu with APT, systemd and a public IPv4 address. Inbound TCP 80/8443 and UDP 51821 must be reachable, including in any provider firewall. Existing Nginx/SNI on TCP 443 and an existing `wg0` on UDP 51820 can remain running. Stash uses its own `wg-stash` interface, subnet and HTTPS service. The installer stops if one of its new ports or its VPN subnet is already occupied.

Run as root. `curl` must already be installed:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/stash-split-tunnel/main/install.sh -o /tmp/stash-split-tunnel-install.sh && bash /tmp/stash-split-tunnel-install.sh
```

The installer detects this VPS's public IPv4 and configures `wg-stash` on `10.88.0.1/24`, UDP 51821. It extracts a Caddy binary from the signed official stable package without installing or starting the global `caddy.service`. The separate `stash-https` service serves subscription URLs on TCP 8443 and requests a publicly trusted short-lived Let's Encrypt IP certificate. No purchased domain name is required. The detected IP is written into this server's state and client subscriptions, rather than hardcoded in the installer.

For an active Nginx installation, it saves a root-only backup of `/etc/nginx`, then adds only `/etc/nginx/conf.d/stash-acme.conf`. This HTTP virtual host matches requests addressed to the VPS IP on port 80. It forwards `/.well-known/acme-challenge/` to Caddy on port 9080; other HTTP requests addressed directly to that IP return 404. Existing hostname-based HTTP virtual hosts continue using their own rules. The existing SNI stream configuration and TCP 443 listener are not edited. Nginx is syntax-checked before a graceful reload, and the new route is removed if validation fails. An unsupported Nginx include/layout or a conflicting IP virtual host causes the installer to stop for inspection. A server without Nginx gets a minimal HTTP challenge route.

The installer records the hashes of the existing `wg0.conf` and SNI stream file plus the running `wg0` public key, then compares them before reporting readiness. It does not restart `wg0` or the global Caddy service. A pre-existing `/usr/local/bin/new` is backed up to `/var/lib/stash-split-tunnel/new-helper-backup` before Stash installs its own `new` helper.

Certificate issuance and automatic renewals require the server to stay reachable. Certificate failures are reported; TLS verification is never disabled. If an installation fails midway, rerun the installer to resume using its incomplete-install marker. Existing initialized keys and clients are preserved. Completed installations refuse to run again; this is not an update command.

After the installer reports HTTPS ready:

```bash
new
```

Enter a simple client name, such as `iPhone`, `iPad` or `AppleTV`. The helper prints its private HTTPS subscription URL and a `stash://install-config` import link. In Stash, use **Configuration > Download from URL**, select the imported profile, and use **Rule** mode. You do not need to edit or transfer a local YAML file. The URL downloads a Stash configuration; it is not a VPN provider subscription or a paid service.

Use one client per device. URLs contain bearer tokens and the configuration includes that client's private key. Anyone who obtains a URL can use that client's access. Keep URLs out of public posts, screenshots and GitHub. The subscription backend listens only on loopback behind HTTPS, has no administration endpoints, and does not log request paths. Removing a client revokes both its server peer and URL; a previously downloaded profile then cannot authenticate to the server.

## Device DNS is a required test, not a verified promise

The generated profile uses `system` for its main, bootstrap and proxy-endpoint DNS choices, with no public upstream or fallback. Queries use direct routing, and the profile requests real answers with `fake-ip-filter: ['*']`. Stash still handles DNS and maintains a cache; this is not bypassing Stash's DNS engine.

Stash's documentation also describes DNS resolution inside proxy protocols, including for UDP. To avoid silently falling back to a public resolver, the WireGuard node is deliberately pointed at the unavailable tunnel-local DNS address `10.88.0.1`. There is no DNS listener there. The VPS rejects traffic from the tunnel to the server itself, and forwarded DNS on TCP/UDP ports 53 and 853. This blocks those remote DNS paths rather than providing a replacement resolver.

**This guard may prevent YouTube from working if Stash requires remote resolution. If that happens, this release does not satisfy the requested combination. Do not disable the guard or switch DNS providers and call it fixed.** Firewall counters cannot prove that an app never uses its own DNS-over-HTTPS, which is indistinguishable from other HTTPS here. Application-specific DNS and OS-managed encrypted DNS also require device testing.

The test profile is IPv4-only in Stash. It does not configure IPv6 forwarding or NAT on the VPS. This setting affects Stash's IPv6 resolution/connection behavior; it does not change which upstream resolver `system` selects. IPv6 parity remains future work.

## Rules and refresh schedule

The server fetches the community-maintained [blackmatrix7 YouTube domain list](https://github.com/blackmatrix7/ios_rule_script/blob/master/rule/Clash/YouTube/YouTube.yaml). It accepts validated `DOMAIN`, `DOMAIN-SUFFIX` and `DOMAIN-KEYWORD` entries only. Shared IP ranges are excluded. A small bundled YouTube domain seed is retained if the first download fails. Later download or validation failures preserve the last good list.

This refreshes a maintained domain catalog, not an automatically discovered exhaustive list of YouTube hosts. Some catalog domains are shared with other Google services; matching traffic to those domains also uses the VPS. Unknown hosts or connections for which Stash has no matching domain can go direct. Complete YouTube coverage requires inspecting actual Apple TV requests and maintaining the list.

| Operation | Timing |
| --- | --- |
| VPS checks the upstream domain list | On the hour and half hour, in the VPS's timezone |
| Stash fetches the server's rule set | Every `1800` seconds while its engine runs, subject to app/OS scheduling |
| Server health check | Every five minutes |
| Client config changes other than rule contents | Refresh the remote profile in Stash |

Server and client refreshes are separate, so an upstream change can wait for both intervals. A fresh rule set applies to new connections; existing streams and DNS caches may persist. No peer restarts are used to apply rule updates.

Add extra domain suffixes, one per line, to:

```text
/var/lib/stash-split-tunnel/domains.txt
```

These are merged into the authenticated rule URL when Stash fetches it. To use a different service on another VPS:

```bash
stash service netflix
```

To return to YouTube:

```bash
stash service youtube
```

For only your custom domain list, first populate `domains.txt`, then run:

```bash
stash service custom
```

The service selection changes the domain catalog, not the exit server. Each VPS always supplies its own exit connection. A failed service switch restores the previous source and rules. Existing client URLs remain valid. Custom entries are additive unless custom-only mode is selected. Changing domains alone does not guarantee another streaming service will accept a datacenter IP or work correctly with local DNS.

## Helpers

`new` creates a Stash client for any supported device. `stash new` remains available as an equivalent command.

Run as root:

| Command | Action |
| --- | --- |
| `new` | Ask for a name and create a client, keys and private URL |
| `stash list` | List client names |
| `stash url` | Select a client and display its existing URLs |
| `stash remove` | Select a client; type `YES` to revoke its peer and URL |
| `stash rules` | Refresh the upstream domain list immediately |
| `stash service youtube` | Select YouTube rules |
| `stash service netflix` | Select Netflix rules |
| `stash service custom` | Use only the custom domain list |
| `stash status` | Show services, rule age, handshake age and DNS rejection counters |

`new iPhone` and `stash url iPhone` also accept names directly. Client operations are serialized to avoid address allocation races, and peer changes use `wg syncconf` to avoid restarting unrelated sessions. Failed peer updates attempt to restore the previous server configuration.

The health timer restarts a missing WireGuard interface or starts an inactive Stash subscription/HTTPS service. It does not interpret idle handshakes as a failure or periodically reboot the VPN. WireGuard handles key renegotiation itself. Restarting a VPS cannot flush caches on an Apple TV.

## First device acceptance test

1. Run `stash status` and note DNS rejection counters.
2. Import the private URL into Stash on Apple TV. Select Rule mode and start it.
3. Fully close and reopen YouTube. Confirm thumbnails, sign-in and video playback work. Check Stash's connection log for matching domains using `This VPS`; check WireGuard byte counters with `wg show wg-stash`.
4. Check Stash's DNS inspection and, where available, query logs on your existing resolver. Confirm it uses the device/network resolver. Compare `stash status` rejection counters during playback. Increasing DNS rejections or failed resolution means the remote-DNS path is incompatible, not that the device needs a different DNS provider.
5. Test an unrelated app/site and confirm its connections show `DIRECT`. An iPhone using its own client URL can also compare normal and Stash-enabled public IP and DNS results in a browser. That does not replace the Apple TV check.
6. Add a harmless test suffix to `domains.txt`, refresh the rule provider and confirm it appears without reimporting the profile.
7. Test removal with a disposable client. The URL should return 404 and its saved credentials should stop working.

Do not call the strict DNS requirement or all-YouTube routing confirmed until these device checks pass. No Apple TV or user VPS is accessible from this development environment.

## Diagnostics and recovery

```bash
stash status
systemctl list-timers 'stash-*'
journalctl -u stash-https -n 50 --no-pager
journalctl -u stash-subscriptions -n 50 --no-pager
journalctl -u stash-rules -n 50 --no-pager
wg show wg-stash
```

Keep `/var/lib/stash-https` intact across reboots so it can reuse and renew certificates. Keep `/var/lib/stash-split-tunnel` and `/etc/wireguard/wg-stash.conf` private and backed up. Moving to a different public IP requires deliberate endpoint, certificate and subscription migration; IP detection at install time does not make old IP-based URLs follow a new server automatically.

## Validation performed

`python3 -m unittest -v test_manager` checks address/key isolation, invalid names, pool exhaustion, failed peer-update rollback, generated system-DNS/direct-default configuration, malicious/invalid rule rejection, last-good rules, service-switch rollback, custom service switching, authenticated HTTP downloads, URL revocation, firewall reapply/cleanup through simulated iptables, and Nginx challenge-route success/config-error/route-error handling through simulated commands. The Nginx tests verify the SNI stream fixture stays byte-identical and no stop/restart action is used. `bash -n` checks the installer and firewall. The systemd calendar expression is checked using `systemd-analyze calendar`.

These are local automated checks. Real kernel WireGuard/firewall behavior, a complete fresh-VPS install, Caddy ACME issuance and Stash/Apple TV behavior remain untested. The installer validates Caddy's configuration and checks HTTPS trust on the target VPS before reporting the URLs ready for a test.

## References

- [Stash remote URL import](https://stash.wiki/en/get-started)
- [Stash DNS behavior](https://stash.wiki/en/features/dns-server)
- [Stash WireGuard and protocol DNS behavior](https://stash.wiki/en/proxy-protocols/proxy-types)
- [Stash remotely updated rule sets](https://stash.wiki/en/rules/rule-set)
- [Official Caddy packages](https://caddyserver.com/docs/install)
- [Let's Encrypt IP certificates](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)
