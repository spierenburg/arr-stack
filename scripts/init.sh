#!/usr/bin/env bash
# One-time host preparation: folders, ownership, hardlink test, host checks.
# Changes only CONFIG_ROOT / DATA_ROOT. Deploys nothing (that's Portainer's job).
#
# Usage: sudo ./scripts/init.sh
#   Override defaults with env vars, which must match the Portainer stack env:
#   sudo PUID=1000 PGID=1000 CONFIG_ROOT=/opt/arr/config DATA_ROOT=/srv/data ./scripts/init.sh
set -euo pipefail

PUID=${PUID:-1000}
PGID=${PGID:-1000}
CONFIG_ROOT=${CONFIG_ROOT:-/opt/arr/config}
DATA_ROOT=${DATA_ROOT:-/srv/data}

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo." >&2; exit 1; }
echo "Using PUID=$PUID PGID=$PGID CONFIG_ROOT=$CONFIG_ROOT DATA_ROOT=$DATA_ROOT"

echo "==> Config folders in $CONFIG_ROOT"
for app in adguard/work adguard/conf gluetun qbittorrent prowlarr sonarr radarr bazarr jellyfin seerr sabnzbd; do
  mkdir -p "$CONFIG_ROOT/$app"
done
chown -R "$PUID:$PGID" "$CONFIG_ROOT"
# Seerr runs as the image's built-in `node` user (UID 1000), not PUID
chown -R 1000:1000 "$CONFIG_ROOT/seerr"

echo "==> Data folders in $DATA_ROOT (TRaSH Guides layout)"
mkdir -p \
  "$DATA_ROOT/torrents/movies" "$DATA_ROOT/torrents/tv" \
  "$DATA_ROOT/usenet/incomplete" "$DATA_ROOT/usenet/complete/movies" "$DATA_ROOT/usenet/complete/tv" \
  "$DATA_ROOT/media/movies" "$DATA_ROOT/media/tv"
chown -R "$PUID:$PGID" "$DATA_ROOT"
chmod -R a=,a+rX,u+w,g+w "$DATA_ROOT"

fail=0
echo "==> Hardlink test"
# usenet/ too: SABnzbd imports are moves, which are only instant on one filesystem
for src in torrents usenet; do
  probe="$DATA_ROOT/$src/.hardlink-probe"
  link="$DATA_ROOT/media/.hardlink-probe"
  echo probe > "$probe"
  if ln "$probe" "$link" 2>/dev/null && [[ "$(stat -c %i "$probe")" == "$(stat -c %i "$link")" ]]; then
    echo "    [ok]   $src/ and media/ are on one filesystem"
  else
    echo "    [FAIL] hardlinks don't work between $src/ and media/: every import would be a full copy"
    fail=1
  fi
  rm -f "$probe" "$link"
done

echo "==> Host checks"
for p in 53 80 3000 9443; do
  holder=$(ss -Hltnup "sport = :$p" 2>/dev/null | head -1)
  if [[ -z $holder ]]; then echo "    [ok]   port $p free"
  elif grep -q -e docker -e portainer <<<"$holder"; then echo "    [ok]   port $p held by docker"
  else echo "    [FAIL] port $p in use: $holder"; fail=1
       [[ $p == 53 ]] && echo "           -> systemd-resolved? See docs/01-host-prep.md"
  fi
done
if [[ -c /dev/net/tun ]]; then echo "    [ok]   /dev/net/tun present"; else echo "    [FAIL] /dev/net/tun missing (Gluetun needs it)"; fail=1; fi
if docker network inspect proxy >/dev/null 2>&1; then echo "    [ok]   docker network 'proxy' exists"
else echo "    [todo] docker network 'proxy' missing: create it in the bootstrap step"; fi

echo
if [[ $fail -eq 0 ]]; then echo "Host ready. Next: bootstrap Portainer (docs/01-host-prep.md)."
else echo "Fix the FAIL items above, then re-run."; exit 1; fi
