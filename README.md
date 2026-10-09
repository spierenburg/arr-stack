# arr-stack

A self-hosted media stack on one Docker host, deployed **only** through Portainer GitOps with immutable, digest-pinned images. It also gives you network-wide ad blocking, torrent traffic that only goes through a VPN, and local names like `http://jellyfin.home.arpa` that keep working when the internet is down. You don't need to own a domain.

```
 GitHub repo (main)  ──PR + CI validate──▶  merge
        │
        │  Portainer polls every 5 min, deploys the exact digests in git
        ▼
┌──────────────────────── one Docker host ──────────────────────────────┐
│ Portainer :9443  (bootstrapped once by hand, manages the two stacks)  │
│                                                                       │
│ stack "infra"                                                         │
│   AdGuard Home :53   DNS + ad blocking, *.home.arpa → this host       │
│   Traefik :80        routes <app>.home.arpa to the right container    │
│                                                                       │
│ stack "media"                                                         │
│   jellyfin.home.arpa  requests.home.arpa (Seerr)                      │
│   sonarr / radarr / bazarr / prowlarr .home.arpa                      │
│   qbittorrent.home.arpa ─▶ Gluetun ─▶ VPN only                        │
│                                                                       │
│ /srv/data ── torrents/ ──hardlink──▶ media/   (one filesystem)        │
└───────────────────────────────────────────────────────────────────────┘
```

## Principles

- **Git is the only source of truth.** `main` is what runs. No `docker compose up`, no Portainer web-editor edits, no manual changes on the host.
- **Immutable images.** Every image is `name:tag@sha256:…`, so the same commit always deploys the same bytes. CI rejects unpinned images. Renovate proposes digest bumps as PRs.
- **No config files on the host.** Traefik is configured with flags and labels in the compose file. The host only holds app **state** and **media**.
- **Secrets only in Portainer stack variables.** `stack.env.example` in each stack folder documents the names.
- **Rollback = `git revert`.**

## What's in it

| Service | Stack | URL | Role |
|---|---|---|---|
| Traefik | infra | `traefik.home.arpa` | Reverse proxy: one name per app |
| AdGuard Home | infra | `adguard.home.arpa` | DNS for the whole house: ad blocking + local names |
| Gluetun | media | — | VPN tunnel. qBittorrent has no other network path |
| qBittorrent | media | `qbittorrent.home.arpa` | Download client |
| Prowlarr | media | `prowlarr.home.arpa` | Indexer manager |
| Sonarr / Radarr | media | `sonarr.home.arpa` / `radarr.home.arpa` | TV / movie automation |
| Bazarr | media | `bazarr.home.arpa` | Subtitles |
| Jellyfin | media | `jellyfin.home.arpa` | Media server. Local logins, so it works offline |
| Seerr | media | `requests.home.arpa` | Request UI for the household |
| SABnzbd *(optional)* | usenet | `sabnzbd.home.arpa` | Usenet downloads. Only with a paid Usenet provider + NZB indexer |
| Portainer | bootstrap | `https://SERVER_IP:9443` | Deploys the stacks from git |

## Deliberately not included

- **No domain, no certificates, no local CA.** The apps are served over plain HTTP inside the house. Remote access goes through Tailscale, which encrypts it. You accept unencrypted logins on your own Wi-Fi ([docs/02](docs/02-local-names.md) explains the trade-off and the upgrade path to HTTPS).
- **No BIND9.** AdGuard Home's DNS rewrites handle local names.
- **No Watchtower.** It updates images outside git, which breaks immutability. Renovate PRs replace it.
- **Nothing exposed to the internet.** Use Tailscale for remote access, and GitOps polling instead of an inbound webhook.

## Requirements

- A Linux host (Debian/Ubuntu) with Docker Engine, the Compose plugin, `git`, and a fixed LAN IP
- A free GitHub account
- A VPN provider with WireGuard support (ideally with port forwarding, e.g. ProtonVPN)
- One filesystem with room for downloads + media

## Step 0: make your own copy (required)

**Don't deploy from this repo directly.** Portainer runs whatever is on the `main` branch of the repo you point it at. If that's this repo, every change its owner pushes lands on your server within 5 minutes, and you can't merge your own update PRs. You need a copy that only you control.

1. Log in to GitHub, open this repo and click **Use this template → Create a new repository**.
2. Owner: your account. Name: `arr-stack`. Public or private both work. A private copy makes the installer ask for a read-only token ([docs/03](docs/03-gitops-stacks.md#repository-setup-on-github)).
3. Click **Create repository**. You now have `https://github.com/<you>/arr-stack`, a clean copy with its own history, and nothing flows back from this repo.

No git knowledge needed for this step. From here on, "the repo" means **your copy**, and the installer refuses to deploy from the template itself.

## Fast path: the installer

On the Docker host:

```bash
sudo apt install -y git                                    # if `git --version` fails
git clone https://github.com/<you>/arr-stack.git && cd arr-stack   # YOUR copy from step 0
./install.sh --check          # read-only preflight
sudo ./install.sh             # interactive; or --config install.env [--yes]
```

The installer does steps 1 and 3 below:
- checks the host
- frees port 53 if `systemd-resolved` holds it (asks first)
- creates the folders and runs the hardlink test
- bootstraps Portainer and creates its admin user
- creates the `infra` and `media` **Git stacks** through the Portainer API, plus `usenet` (SABnzbd) if you say yes

Before changing anything, it checks the settings, checks that the repo is readable, and checks that every image is digest-pinned. **It never runs `docker compose up` on the stacks.** Portainer deploys them from git, so the result is identical to the manual route. It's safe to re-run: finished steps are skipped and existing stacks are never touched. Secrets are typed in hidden. They're never written to disk or passed as command-line arguments, and they end up only in Portainer's stack variables.

When it finishes, it prints the remaining manual steps: the AdGuard wizard, the router's DHCP setting, wiring the apps together, and GitHub branch protection plus Renovate.

## Setup, in order (manual route, and what the installer does under the hood)

Each guide ends with a check that it worked.

1. [Host preparation & Portainer bootstrap](docs/01-host-prep.md): the only time you use the shell to set things up
2. [Local names](docs/02-local-names.md): `home.arpa`, why there's no HTTPS, browser quirks
3. [GitOps: deploying the stacks](docs/03-gitops-stacks.md): repo settings, Renovate, Portainer Git stacks
4. [DNS with AdGuard Home](docs/04-dns-adguard.md): local names, router DHCP
5. [Wiring the apps together](docs/05-apps.md): qBittorrent (and optionally SABnzbd) → Prowlarr → Sonarr/Radarr → Jellyfin → Seerr
6. [Remote access](docs/06-remote-access.md): Tailscale
7. [Operations](docs/07-operations.md): updates, rollback, backups, troubleshooting

## Repo layout

```
install.sh                         CLI installer: host prep + Portainer bootstrap + Git stacks via API
install.env.example                answers file for unattended installs (copy, chmod 600, delete after)
stacks/infra/compose.yaml          Traefik + AdGuard        (Portainer stack "infra")
stacks/infra/stack.env.example     variable names for that stack
stacks/media/compose.yaml          VPN, downloads, *arr, Jellyfin, Seerr  (stack "media")
stacks/media/stack.env.example
stacks/usenet/compose.yaml         SABnzbd, optional          (stack "usenet")
bootstrap/portainer.compose.yaml   Portainer itself, started once by hand
renovate.json                      weekly digest-bump PRs, grouped per stack
.github/workflows/validate.yml     CI gate: digest pins, compose syntax, shellcheck
scripts/init.sh                    one-time host prep: folders, ownership, hardlink + port checks
scripts/pin-digests.sh             resolve tags → digests from the registries (bootstrap/manual)
scripts/check-pins.sh              fail on any unpinned image (used by CI)
scripts/backup.sh                  archive app state, never touches containers
```
