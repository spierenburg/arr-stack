# 7. Operations

## Updates (Renovate → PR → merge)

Every Saturday morning Renovate opens up to three PRs that bump image digests: `infra`, `media` and `portainer`.

1. Read the PR and the linked release notes. Watch for breaking changes or database migrations.
2. CI `validate` must pass.
3. Merge. Portainer polls `main` and redeploys within about 5 minutes. Only services whose image changed are recreated.
4. Verify: `docker inspect --format '{{.Config.Image}}' <container>` shows the new digest, and the app works.

Merge the **infra** PR at a quiet moment. Recreating AdGuard briefly takes DNS away for the whole house. Media PRs are low-risk.

## Rollback

```bash
git revert <merge-commit> && git push      # or revert the PR in the GitHub UI
```

Portainer deploys the previous digests. That restores the old **image**, not old **data**. If the bad version migrated a database, also restore that app's state from a backup (below).

## Backups

**What matters:** `CONFIG_ROOT` holds every app's settings, databases and API keys. Media can be downloaded again. Configuration takes hours to rebuild. The deployment itself is already backed up, because it's the git repo. Store the Portainer stack variables, which hold your secrets, in a password manager.

```bash
sudo ./scripts/backup.sh /mnt/backup-disk/arr
```

The script only reads and never touches containers. Sonarr, Radarr, Prowlarr and Bazarr write consistent backup zips to `<app>/Backups` on a schedule. The archive contains those zips plus the live files. Run it weekly from root's crontab (`sudo crontab -e`):

```cron
0 4 * * 0  /home/<you>/arr-stack/scripts/backup.sh /mnt/backup-disk/arr >> /var/log/arr-backup.log 2>&1
```

Copy the archives **off this machine** too, for example to a NAS or cloud storage. Delete old archives now and then.

**Restore** (state only; images come from git):
1. Portainer → Stacks → `media` (or `infra`) → **Stop this stack**.
2. `sudo tar -xzf arr-config-YYYYMMDD-HHMMSS.tar.gz -C /opt/arr/config ./sonarr` restores one app. Leave off `./sonarr` to restore everything.
3. Portainer → **Start this stack**.

For a single *arr app it's often easier to use the app's own *System → Backup → Restore*.

## What happens when…

| Situation | Effect | What to do |
|---|---|---|
| **Internet down** | Local names, Jellyfin playback and logins all keep working. Downloads, metadata and GitOps polling pause. | Nothing. Everything resumes on its own. |
| **Server down / rebooting** | **Nobody in the house can browse**, because AdGuard is the only DNS. | Short-term: set the router's DHCP DNS back to the router. Long-term: second AdGuard instance ([docs/04](04-dns-adguard.md#redundancy-recommended-once-the-house-depends-on-it)). |
| **VPN down** | qBittorrent has no network at all, by design. Nothing leaks. | Gluetun logs. Usually a provider issue. Change `VPN_SERVER_COUNTRIES` in the stack variables or wait. |
| **GitHub unreachable** | Running containers are unaffected. New merges just don't deploy yet. | Nothing. |
| **Disk full** | Downloads stall and imports fail. | Check whether hardlinks work (docs/05 end-to-end check). Copies double the usage. |

## Troubleshooting

Look first: Portainer → Containers → *container* → **Logs**, or `docker logs <container>`. Then change things **in git**.

| Symptom | Likely cause | Check |
|---|---|---|
| Merge didn't deploy | Portainer can't pull the repo (token expired or revoked) | Portainer → Stacks → *stack*: git error shown at top. Renew the token, then **Pull and redeploy** |
| Browser tries `https://` and fails | Browser guessed HTTPS for an unknown name | Type `http://` explicitly ([docs/02](02-local-names.md#browser-quirks)) |
| Name works on one device but not another | That device bypasses AdGuard (Firefox DoH, Android Private DNS) | [docs/02](02-local-names.md#browser-quirks) |
| `403 Forbidden` from every app | `lan-only` rejects the client's source IP | Client not on LAN or Tailscale? If your LAN uses an unusual range, extend the `ipallowlist.sourcerange` label in `stacks/infra/compose.yaml` |
| `404 page not found` | Container not running, or label typo | Portainer stack view. Router labels in the compose file |
| `Bad Gateway` on qBittorrent | Gluetun unhealthy, so qBittorrent is down too | `gluetun` logs |
| SABnzbd: `Access denied - Hostname verification failed` | No login set yet, so SABnzbd only accepts its IP and own hostname | Open `http://SERVER_IP:8080`, set a login under Config → General ([docs/05](05-apps.md#51b-sabnzbd-only-with-the-optional-usenet-stack)) |
| Name doesn't resolve | Client not using AdGuard (IPv6 DNS, cached lease, hard-coded DNS on device) | `nslookup sonarr.DOMAIN` on the client and look at which server answered |
| Sonarr/Radarr "path does not exist" on import | Mismatched mounts | Every app must see `/data/...`, never `/downloads` or `/tv` |
| Seerr crash-loops with permission errors | Config folder not owned by UID 1000 | `sudo chown -R 1000:1000 /opt/arr/config/seerr` |
| AdGuard won't start: `address already in use` | `systemd-resolved` on port 53 | [docs/01](01-host-prep.md#free-port-53-ubuntu-and-some-debian-setups) |
| Can't reach `adguard.DOMAIN` | DNS itself is broken | Use `http://SERVER_IP:3000` directly |
| Can't reach any `*.DOMAIN` | Traefik down | Portainer still works on `https://SERVER_IP:9443` (self-signed) |
