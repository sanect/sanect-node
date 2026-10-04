#!/bin/bash
# snapshot-download.sh — pre-populate a fresh node's data dir from a published
# tarball snapshot, so a cold join doesn't have to block-sync from genesis.
#
# Called from entrypoint.sh on first boot when SNAPSHOT_URL is set (or when
# the manifest at $SNAPSHOT_MANIFEST_URL resolves to a recent enough snapshot).
#
# Required env (set on joiners that want fast-start):
#   SNAPSHOT_URL or SNAPSHOT_MANIFEST_URL
#
# If both are set, SNAPSHOT_URL wins (operator's explicit choice).
# If only SNAPSHOT_MANIFEST_URL is set, we fetch the manifest and follow
# its `url` field.
#
# The script extracts into $HOMEDIR/data. Genesis + node keys must already
# exist (entrypoint.sh fetches genesis from SEED_NODE_URL before calling us).

set -euo pipefail

HOMEDIR="${HOMEDIR:-/data/.sanectd}"
DATA_DIR="$HOMEDIR/data"

URL=""
if [ -n "${SNAPSHOT_URL:-}" ]; then
  URL="$SNAPSHOT_URL"
elif [ -n "${SNAPSHOT_MANIFEST_URL:-}" ]; then
  echo "[snapshot-download] fetching manifest from $SNAPSHOT_MANIFEST_URL"
  MANIFEST=$(curl -sf --max-time 15 "$SNAPSHOT_MANIFEST_URL") || {
    echo "[snapshot-download] manifest fetch failed; will fall back to state sync"
    exit 0
  }
  URL=$(echo "$MANIFEST" | jq -r '.url // empty')
  HEIGHT=$(echo "$MANIFEST" | jq -r '.height // empty')
  if [ -z "$URL" ]; then
    echo "[snapshot-download] manifest has no url field; falling back"
    exit 0
  fi
  echo "[snapshot-download] manifest points to height=${HEIGHT} url=${URL}"
fi

if [ -z "$URL" ]; then
  echo "[snapshot-download] no snapshot URL configured; skipping"
  exit 0
fi

# If a previous attempt already populated data/, skip.
if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null | grep -v priv_validator_state.json | wc -l)" -gt 0 ]; then
  echo "[snapshot-download] data/ already populated; skipping"
  exit 0
fi

echo "[snapshot-download] downloading + extracting $URL → $HOMEDIR"
mkdir -p "$DATA_DIR"
# Stream download → lz4 -d → tar -x straight into HOMEDIR. The tarball
# is created with `data/` as its top-level dir.
if ! curl -fL --retry 3 --retry-delay 5 --max-time 1800 "$URL" \
     | lz4 -d - \
     | tar -xf - -C "$HOMEDIR" data; then
  echo "[snapshot-download] FAILED — entrypoint will fall back to state sync / block sync"
  # Don't fail the whole boot; leave data/ partial and let CometBFT decide.
  rm -rf "$DATA_DIR"/* 2>/dev/null || true
  exit 0
fi

# Reset priv_validator_state to height 0 so this node won't replay any of
# the seed's signing history (which it must NEVER do — it has its own key).
echo '{"height":"0","round":0,"step":0}' > "$DATA_DIR/priv_validator_state.json"

echo "[snapshot-download] done — node will start from the snapshot height"
