# 2. Local names, no domain, no certificates

Every app gets a name like `http://jellyfin.home.arpa`. No domain purchase, no DNS provider account, no certificates.

- **`home.arpa`** is reserved for home networks ([RFC 8375](https://www.rfc-editor.org/rfc/rfc8375)). It can never clash with a real website, and public DNS never answers for it.
- **AdGuard Home** answers `*.home.arpa` with the server's IP ([step 4](04-dns-adguard.md)), so the names work on every device that uses the house DNS, including when the internet is down.
- **Traefik** routes each name to the right container over plain HTTP on port 80.
- **Remote access** goes through Tailscale ([step 6](06-remote-access.md)), which encrypts everything end to end. Nothing is reachable from the internet.

## Picking your home domain

The docs use `home.arpa` throughout. You can pick your own: the installer asks for it, or you set `DOMAIN` in both Portainer stacks. Then use your name wherever the docs say `home.arpa`, including the AdGuard rewrite.

| Pick | Verdict |
|---|---|
| `home.arpa`, `smith.home.arpa` | Best. Reserved for home networks (RFC 8375) |
| `internal`, `media.internal` | Good. Reserved by ICANN for private use, so `jellyfin.internal` is short |
| `lan`, `home` | Common and works today, but not officially reserved. The installer warns and asks you to confirm |
| `local` | **Never.** It belongs to mDNS/Bonjour (printers, Chromecast, AirPlay), and lookups break unpredictably. The installer refuses it |
| Anything that's a real public suffix (`.nl`, `.media`, …) | **No.** AdGuard would hide the real websites under that name |

Changing it later means changing `DOMAIN` in both Portainer stacks, redeploying, and updating the AdGuard rewrite. Then re-enter any URLs you typed into the apps. Containers talk to each other by container name, so those links don't change.

## The trade-off you're accepting

Traffic **inside the house** is unencrypted. Someone on your Wi-Fi who sniffs traffic could read logins for the apps, which matters because Sonarr and Radarr API keys can delete media. Keep that in mind if the Wi-Fi is shared with guests or untrusted devices: put them on a guest network. Browsers will label the pages "Not secure". That's cosmetic for a LAN-only setup.

Everything else is unaffected: Jellyfin apps on TVs and phones, Seerr, and the *arr apps all work fine over HTTP.

## Browser quirks

- **Type `http://`** the first time. Some browsers guess `https://` for unknown names. Chrome's *Always use secure connections* shows a warning page you can click through.
- **Firefox with DNS-over-HTTPS** sends lookups to Cloudflare or NextDNS, which don't know `home.arpa`. The AdGuard step blocks Mozilla's canary domain so Firefox turns that off automatically on your network.
- **Android "Private DNS"** set to a provider bypasses AdGuard the same way. Set it to *Automatic* or *Off* on household phones.

## Upgrading to HTTPS later

If he ever buys a domain, real certificates take about 15 lines in `stacks/infra/compose.yaml`:

- add a `websecure` entrypoint on 443
- add a Let's Encrypt resolver using the DNS-01 challenge with his registrar's DNS provider ([list of supported providers](https://doc.traefik.io/traefik/https/acme/#providers))
- redirect `web` to `websecure`

Then change `DOMAIN` and the AdGuard rewrite. No public DNS records and no port forwarding are needed for that either.
