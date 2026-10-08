# 6. Remote access with Tailscale

Nothing in this stack is port-forwarded, and it should stay that way. The *arr apps were never designed to face the internet, and Traefik's `lan-only` middleware blocks non-LAN traffic anyway. Remote access goes through Tailscale, a WireGuard mesh network with nothing exposed.

## On the server

Install Tailscale with the official instructions (https://tailscale.com/download/linux). Then advertise your LAN subnet, for example `192.168.178.0/24` on a FRITZ!Box:

```bash
sudo tailscale up --advertise-routes=<your-LAN-subnet>
```

In the Tailscale admin console → Machines → this server → *Edit route settings*: **approve** the subnet route.

The subnet route is needed because AdGuard answers `*.DOMAIN` with the LAN IP. Remote devices can only reach that IP through the advertised route.

## Split DNS

Tailscale admin console → **DNS → Nameservers → Add nameserver → Custom**:
- Nameserver: `SERVER_IP`, the LAN IP
- Tick **Restrict to domain** and enter `home.arpa`

Remote devices then ask AdGuard only for your own names. Everything else uses their normal DNS.

## On clients

Install the Tailscale app and log in. Linux clients also need `sudo tailscale up --accept-routes`.

**Check:** on a phone using mobile data (Wi-Fi off) with Tailscale connected, `http://jellyfin.home.arpa` loads. The page says "Not secure", but the traffic is encrypted by Tailscale's WireGuard tunnel.

## Sharing with family elsewhere

Invite them to your tailnet, or use Tailscale's *share machine* feature to share only this server. Both are free for personal use. Use [Tailscale ACLs](https://tailscale.com/kb/1018/acls) to limit them to Jellyfin (port 80 on the server) if you don't want them seeing Sonarr and the rest.

If someone really can't run Tailscale, for example on a smart TV at another house, the only option is exposing Jellyfin publicly. That's a separate decision with its own hardening work, and this repo deliberately doesn't do it.
