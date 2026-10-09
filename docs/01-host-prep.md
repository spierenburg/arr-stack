# 1. Host preparation and Portainer bootstrap

You'll SSH into the host **once**, for the steps on this page. After that, every deployment goes through Portainer from git ([step 3](03-gitops-stacks.md)).

## Fixed IP

Give the server a DHCP reservation in the router, or a static IP. Every name under your domain will point to this address, so it must never change. This guide calls it `SERVER_IP`.

## Docker

Install Docker Engine and the Compose plugin from Docker's own apt repository by following https://docs.docker.com/engine/install/. The `docker.io` package in the distro repo is often old.

```bash
docker compose version          # must print v2.x
```

## Free port 53 (Ubuntu and some Debian setups)

On Ubuntu, `systemd-resolved` already listens on port 53, so AdGuard can't start. Check with:

```bash
sudo ss -ltnup 'sport = :53'
```

If `systemd-resolved` shows up, edit `/etc/systemd/resolved.conf`:

```ini
[Resolve]
DNSStubListener=no
# The host itself uses public DNS, NOT AdGuard. Otherwise a stopped AdGuard
# means the host can't pull images or reach GitHub to fix it.
DNS=9.9.9.9 1.1.1.1
```

```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
sudo ss -ltnup 'sport = :53'      # should print nothing now
```

## Git and your copy of the repo

You need **your own copy** of this repo on GitHub first: [README → Step 0](../README.md#step-0-make-your-own-copy-required), which is one click on *Use this template*. Then on the host:

```bash
sudo apt install -y git          # skip if `git --version` already works
git clone https://github.com/<you>/arr-stack.git && cd arr-stack
```

`<you>` is **your** GitHub account, not the template's. A private copy asks for your GitHub username and a token when cloning: use the read-only token from [docs/03](03-gitops-stacks.md#repository-setup-on-github).

## Folders and host checks

```bash
sudo ./scripts/init.sh
```

`init.sh` creates the following layout and runs a hardlink test plus port and device checks:

```
/opt/arr/config/<app>        app state (settings, databases): back this up
/srv/data
├── torrents/{movies,tv}     qBittorrent downloads here
├── usenet/…                 SABnzbd downloads here (only if you add the optional usenet stack)
└── media/{movies,tv}        Sonarr/Radarr hardlink finished files here, Jellyfin reads here
```

Use different paths or a different user if you like (`sudo PUID=... CONFIG_ROOT=... DATA_ROOT=... ./scripts/init.sh`). They must match the Portainer stack variables later.

Why one `/data`: qBittorrent, Sonarr and Radarr all mount the same `/data`, so an import is a hardlink. It's instant, takes no extra space, and seeding continues from the same bytes. If `torrents/` and `media/` are on different filesystems, every import becomes a full copy. See the [TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/).

**Check:** `init.sh` ends with `Host ready`.

## Bootstrap Portainer

These are the **only** manual `docker` commands in the whole setup:

```bash
docker network create proxy
DOMAIN=home.arpa docker compose -f bootstrap/portainer.compose.yaml up -d
```

Open `https://SERVER_IP:9443` within a few minutes. Portainer uses its own self-signed certificate, so accept the browser warning once. Portainer locks the setup wizard if nobody claims it in time. Create the admin user and pick the local Docker environment.

Portainer can't manage itself as a Git stack, because a redeploy would cut its own connection. That's why it's bootstrapped here. To update Portainer later, merge the Renovate PR for `bootstrap/`, `git pull` on the host, and re-run the second command.

## Optional: hardware transcoding

On an Intel or AMD host with an iGPU, check that `/dev/dri` exists. If it does, uncomment the `devices:` block under `jellyfin` in `stacks/media/compose.yaml` **in git** and let Portainer deploy it.
