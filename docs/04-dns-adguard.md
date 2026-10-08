# 4. DNS with AdGuard Home

AdGuard Home becomes the only DNS server on the network. It does two jobs:
- **Ad and tracker blocking** for every device, including TVs and phones.
- **Local names:** a rewrite sends `*.DOMAIN` to `SERVER_IP`. AdGuard answers these names itself, so they keep working when the internet is down.

AdGuard is part of the `infra` stack you deployed in [step 3](03-gitops-stacks.md). What you configure in its UI, such as rewrites, upstreams and blocklists, is **app state** stored under `CONFIG_ROOT/adguard/conf`. It isn't deployment config, so it's covered by backups rather than git. The same goes for every app's own settings in [step 5](05-apps.md).

## Setup wizard

Open `http://SERVER_IP:3000` and set:
- **Admin Web Interface:** *All interfaces*, port **3000**. Keep it on 3000, not the default 80. Traefik routes `adguard.DOMAIN` to 3000, and `http://SERVER_IP:3000` stays available as a way in if DNS breaks, because then the name won't resolve.
- **DNS server:** *All interfaces*, port **53**.
- Create the admin user.

## Configure

Log in at `http://SERVER_IP:3000`.

**Settings → DNS settings**
- Upstream DNS servers (encrypted, one per line):
  ```
  https://dns.quad9.net/dns-query
  https://cloudflare-dns.com/dns-query
  ```
- Choose *Parallel requests*.
- Bootstrap DNS: `9.9.9.9` and `1.1.1.1`.

**Filters → DNS rewrites → Add**

| Domain | Answer |
|---|---|
| `*.home.arpa` | `SERVER_IP` |
| `home.arpa` | `SERVER_IP` |

**Filters → DNS blocklists:** the AdGuard default list is a sensible start. Add more later only if something is getting through. Large lists mostly cause false positives.

**Filters → Custom filtering rules:** add

```
||use-application-dns.net^$dnsrewrite=NXDOMAIN
```

This is Mozilla's canary domain. When it doesn't exist, Firefox switches off its built-in DNS-over-HTTPS on this network, so it uses AdGuard and resolves `home.arpa`. The `$dnsrewrite=NXDOMAIN` part matters because a normal block answers `0.0.0.0`, which still counts as an address and Firefox ignores it.

### Verify (before touching the router)

```bash
dig +short @SERVER_IP sonarr.home.arpa            # → SERVER_IP
dig +short @SERVER_IP doubleclick.net              # → 0.0.0.0 (blocked)
dig @SERVER_IP use-application-dns.net | grep status   # → NXDOMAIN
```

## Point the network at AdGuard

In the router's DHCP settings, set the DNS server to `SERVER_IP`.

- **Don't add a public resolver as secondary DNS.** Clients pick between DNS servers more or less at random, so ad blocking and local names would only work some of the time. If you want redundancy, add a second AdGuard instance instead (see below).
- **Check IPv6 too.** Many routers advertise their own DNS over IPv6 router advertisements, and clients then bypass AdGuard without you noticing. On a FRITZ!Box, set the local DNS server in both *Heimnetz → Netzwerk → Netzwerkeinstellungen → IPv4-Einstellungen* and the IPv6 settings.

Renew the DHCP lease on a client (reconnect Wi-Fi), then:

**Check:**
1. `http://jellyfin.home.arpa` loads.
2. AdGuard's *Query Log* shows that client's requests.
3. **Offline test:** unplug the router's WAN/fibre cable. `http://jellyfin.home.arpa` still loads and plays. Plug it back in.

## Redundancy (recommended once the house depends on it)

This host is now a single point of failure for DNS: if it reboots, nobody in the house can browse. The fix is a second AdGuard Home on a small separate device, such as a Raspberry Pi:

1. Install AdGuard Home on the Pi.
2. Run [`adguardhome-sync`](https://github.com/bakito/adguardhome-sync) to copy the configuration, rewrites included, from this instance to the Pi.
3. Set the router's DHCP to hand out **both** IPs.

**Emergency fallback** if the server dies and there's no second instance: change the router's DHCP DNS back to the router itself. Browsing works again. Local names don't until the server is back.
