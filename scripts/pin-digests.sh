#!/usr/bin/env bash
# Resolve every `image: name:tag` in the compose files to `name:tag@sha256:<digest>`
# by asking the registry (no Docker needed). Existing digests are refreshed.
# Renovate does this automatically via PRs; this script is for bootstrap or manual bumps.
#
# Usage: ./scripts/pin-digests.sh [compose files...]   (default: all stacks + bootstrap)
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
files=("$@")
[[ ${#files[@]} -gt 0 ]] || files=(stacks/*/compose.yaml bootstrap/*.compose.yaml)

ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

resolve() { # $1 = name:tag → prints sha256:...
  local ref=$1 name=${1%:*} tag=${1##*:} registry repo token
  case $name in
    lscr.io/*)  registry=ghcr.io; repo=${name#lscr.io/} ;; # lscr.io is a front for ghcr.io
    ghcr.io/*)  registry=ghcr.io; repo=${name#ghcr.io/} ;;
    */*)        registry="registry-1.docker.io"; repo=$name ;;
    *)          registry="registry-1.docker.io"; repo=library/$name ;;
  esac
  if [[ $registry == ghcr.io ]]; then
    token=$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')
  else
    token=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')
  fi
  curl -fsSI -H "Authorization: Bearer $token" -H "Accept: $ACCEPT" \
    "https://$registry/v2/$repo/manifests/$tag" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' \
    | grep -E '^sha256:[0-9a-f]{64}$' || { echo "ERROR: could not resolve $ref" >&2; return 1; }
}

for f in "${files[@]}"; do
  echo "==> $f"
  grep -E '^[[:space:]]*image:' "$f" | sed -E 's/^[[:space:]]*image:[[:space:]]*([^@ #]+).*/\1/' | sort -u | while read -r ref; do
    digest=$(resolve "$ref")
    echo "    $ref@$digest"
    # replace "image: ref" or "image: ref@sha256:old" with the fresh pin
    REF=$ref DIGEST=$digest perl -pi -e \
      's/^(\s*image:\s*)\Q$ENV{REF}\E(\@sha256:[0-9a-f]{64})?(?=\s|$)/$1$ENV{REF}\@$ENV{DIGEST}/' "$f"
  done
done
