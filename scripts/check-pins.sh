#!/usr/bin/env bash
# Fail if any image in the compose files is not pinned by digest. Run by CI on every PR.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
unpinned=$(grep -nE '^[[:space:]]*image:' stacks/*/compose.yaml bootstrap/*.compose.yaml | grep -vE '@sha256:[0-9a-f]{64}' || true)
if [[ -n $unpinned ]]; then
  echo "Unpinned images (run ./scripts/pin-digests.sh):"
  echo "$unpinned"
  exit 1
fi
echo "All images digest-pinned."
