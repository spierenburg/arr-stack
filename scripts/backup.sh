#!/usr/bin/env bash
# Archive all app state (not media). Read-only toward the stack: it never stops,
# restarts or redeploys containers. Lifecycle belongs to Portainer.
#
# Consistency: Sonarr/Radarr/Prowlarr/Bazarr write their own consistent backup
# zips to <app>/Backups on a schedule, and those are inside this archive. The
# live SQLite files are copied as-is and are a best-effort second copy.
#
# Usage: sudo CONFIG_ROOT=/opt/arr/config ./scripts/backup.sh <destination-dir>
set -euo pipefail

CONFIG_ROOT=${CONFIG_ROOT:-/opt/arr/config}
dest=${1:?usage: backup.sh <destination-dir>}
mkdir -p "$dest"
archive="$dest/arr-config-$(date +%Y%m%d-%H%M%S).tar.gz"

# Jellyfin's metadata cache is large and regenerates itself
tar --exclude='jellyfin/data/metadata' --exclude='jellyfin/cache' \
    -czf "$archive" -C "$CONFIG_ROOT" .
chmod 600 "$archive"
echo "==> Wrote $archive ($(du -h "$archive" | cut -f1))"
