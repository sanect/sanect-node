#!/bin/bash
# snapshot-upload.sh — produce a node-data tarball and push it to Cloudflare R2.
#
# Invoked from cron on the primary node (configured in entrypoint.sh) when
# SNAPSHOT_UPLOAD_INTERVAL_HOURS is set and the R2 env vars are present.
#
# What it does:
#   1. tar + lz4-compress the *cold* data directories (excluding live wal files
#      that are risky to snapshot without halting the node)
#   2. upload via rclone to R2 as sanect-<height>.tar.lz4
#   3. update a stable LATEST.json manifest with the newest snapshot URL
#      so joiners can fetch without knowing the exact height
#   4. prune older snapshots, keeping the latest N (default 3)
#
# Required env (set on the primary service):
#   R2_ACCOUNT_ID         Cloudflare account id (32-char hex)
#   R2_ACCESS_KEY_ID      Access key for the R2 token
#   R2_SECRET_ACCESS_KEY  Secret for the R2 token
#   R2_BUCKET             Bucket name (e.g. sanect-snapshots)
# Optional:
#   R2_PUBLIC_URL         CDN-style public URL (e.g. https://sanect-snapshots.testnet.sanect.com)
#                         If set, the manifest links to this; otherwise it links
#                         to the S3-style endpoint (which requires auth).
#   SNAPSHOT_KEEP         How many recent snapshots to keep on R2 (default 3)

set -euo pipefail

# --force / FORCE=1 — skip the catching_up health check. Use for manual
# triggers when you know the node is healthy but CometBFT briefly reports
# catching_up=true (e.g. right after a fast-sync→consensus transition).
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
  esac
done
if [ "${FORCE_UPLOAD:-0}" = "1" ] || [ "${FORCE:-0}" = "1" ]; then FORCE=1; fi

HOMEDIR="${HOMEDIR:-/data/.sanectd}"
DATA_DIR="$HOMEDIR/data"
RCLONE_CFG="/tmp/rclone-r2.conf"
STAGING="/tmp/sanect-snapshot.$$"
KEEP="${SNAPSHOT_KEEP:-3}"
# Upload tuning. rcat streams from stdin so rclone cannot know the size: with the
# default 5Mi chunks an object is capped at 10,000 parts = 48.8 GiB and each part is
# a tiny request (slow). Bigger chunks + parallel parts are much faster and lift
# the cap (64M x 10,000 = 625 GiB). Peak extra RAM ~ chunk x concurrency.
CHUNK="${SNAPSHOT_CHUNK_SIZE:-64M}"
CONCURRENCY="${SNAPSHOT_UPLOAD_CONCURRENCY:-8}"
# Low CPU/IO priority protects a node that is also serving RPC. A dedicated
# snapshot node can set SNAPSHOT_LOW_PRIORITY=false to go full speed.
PRIO=(nice -n 19 ionice -c 3)
if [ "${SNAPSHOT_LOW_PRIORITY:-true}" = "false" ]; then PRIO=(); fi
# SNAPSHOT_FREEZE=true: SIGSTOP sanectd while tar reads the data dir, then SIGCONT.
# A live LevelDB copy can miss files that compaction creates/removes mid-read
# ("File removed before we read it") and then fail to open on restore. Freezing is
# only appropriate on a dedicated snapshot node that serves no RPC.
FREEZE="${SNAPSHOT_FREEZE:-false}"
NODE_PID=""

if [ -z "${R2_ACCOUNT_ID:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] \
   || [ -z "${R2_SECRET_ACCESS_KEY:-}" ] || [ -z "${R2_BUCKET:-}" ]; then
  echo "[snapshot-upload] R2 env not configured — skipping"
  exit 0
fi

# Pull current node status. Retry a few times — the CometBFT /status
# endpoint occasionally times out under load or during block commit, and
# a single failed curl would otherwise default jq to catching_up=true
# (fail-closed) and silently skip the entire cron tick for 6h.
STATUS=""
CATCHING_UP="true"
HEIGHT="0"
for attempt in 1 2 3 4 5; do
  STATUS=$(curl -sf --max-time 15 localhost:26657/status 2>/dev/null || echo '')
  if [ -n "$STATUS" ]; then
    CATCHING_UP=$(echo "$STATUS" | jq -r '(.result.sync_info.catching_up | if . == false then "false" else "true" end)' 2>/dev/null || echo "true")
    HEIGHT=$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null || echo "0")
    # If the response parsed and reports a real height, we're done.
    if [ -n "$HEIGHT" ] && [ "$HEIGHT" != "0" ] && [ "$HEIGHT" != "null" ]; then
      break
    fi
  fi
  echo "[snapshot-upload] status fetch attempt $attempt/5 failed (status empty or no height); retrying in 5s..."
  sleep 5
done

if [ "$HEIGHT" = "0" ] || [ -z "$HEIGHT" ] || [ "$HEIGHT" = "null" ]; then
  echo "[snapshot-upload] no height after 5 attempts — node /status unreachable. Last raw status:"
  echo "$STATUS" | head -c 500
  echo
  exit 0
fi

if [ "$CATCHING_UP" != "false" ]; then
  if [ "$FORCE" = "1" ]; then
    echo "[snapshot-upload] catching_up=$CATCHING_UP but --force given; proceeding from height $HEIGHT"
  else
    echo "[snapshot-upload] node reports catching_up=$CATCHING_UP at height $HEIGHT — skipping upload"
    echo "[snapshot-upload] (this is fine during a redeploy/restart; if the node is genuinely healthy, rerun with --force)"
    exit 0
  fi
fi

NAME="sanect-${HEIGHT}.tar.lz4"
echo "[snapshot-upload] producing $NAME from $DATA_DIR"

# rclone remote config (in-memory file, never written to disk persistently).
cat > "$RCLONE_CFG" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF

# Tar excluding live consensus WAL + WAL temps. application/blockstore/state/
# txindex are crash-consistent enough thanks to leveldb's WAL — joiner replays
# whatever's missing between snapshot height and chain tip.
mkdir -p "$STAGING"
resume_node() {
  if [ -n "$NODE_PID" ]; then
    kill -CONT "$NODE_PID" 2>/dev/null || true
    echo "[snapshot-upload] resumed sanectd (pid $NODE_PID)"
    NODE_PID=""
  fi
}
cleanup() { resume_node; rm -rf "$STAGING" "$RCLONE_CFG"; }
trap cleanup EXIT

if [ "$FREEZE" = "true" ]; then
  for d in /proc/[0-9]*; do
    if [ "$(cat "$d/comm" 2>/dev/null)" = "sanectd" ]; then NODE_PID="${d#/proc/}"; break; fi
  done
  if [ -z "$NODE_PID" ]; then
    echo "[snapshot-upload] SNAPSHOT_FREEZE=true but no sanectd process found — aborting"
    exit 1
  fi
  echo "[snapshot-upload] freezing sanectd (pid $NODE_PID) for a consistent copy"
  kill -STOP "$NODE_PID"
fi

cd "$HOMEDIR"
# Stream tar → lz4 → rclone rcat (uploads from stdin, no local staging needed).
#
# Heavy operation: tar reads every byte of LevelDB, lz4 compresses, rclone
# uploads. On a single-validator setup this competes with CometBFT for
# disk IO during block commit, pushing block time from ~430ms → 700-800ms
# during the upload window.
#
# Mitigation: run tar + lz4 at lowest IO/CPU priority so the node always
# wins scheduling contention. nice -n 19 = lowest CPU priority,
# ionice -c 3 = "idle" IO class (only runs when nothing else wants disk).
# rclone is network-bound, less impact from priority changes.
#
# tar warns "file changed as we read it" because the running node is
# continuously writing to LevelDB underneath us. That's expected and
# matches every other Cosmos chain's live-snapshot recipe — the joiner
# replays a few blocks on import to reach consistency. We:
#   - suppress the warning with --warning=no-file-changed
#   - relax pipefail just for this pipeline so a tar exit 1 (warning, not
#     error) doesn't abort the upload mid-stream
#   - check rclone's exit code explicitly because that IS what we care about
echo "[snapshot-upload] streaming tar → lz4 → R2://${R2_BUCKET}/${NAME} (low priority)"
set +e
set +o pipefail
${PRIO[@]+"${PRIO[@]}"} tar \
  --warning=no-file-changed --warning=no-file-removed \
  --exclude='data/cs.wal' \
  --exclude='data/priv_validator_state.json' \
  -cf - data \
  | ${PRIO[@]+"${PRIO[@]}"} lz4 -c1 \
  | rclone --config "$RCLONE_CFG" \
      --s3-chunk-size "$CHUNK" --s3-upload-concurrency "$CONCURRENCY" \
      rcat "r2:${R2_BUCKET}/${NAME}"
RCLONE_RC=${PIPESTATUS[2]}
set -e
set -o pipefail
resume_node   # data copy is done; let the node run again before the slow manifest/prune steps
if [ "$RCLONE_RC" -ne 0 ]; then
  echo "[snapshot-upload] rclone upload failed (rc=$RCLONE_RC) — aborting"
  exit 1
fi

# Write a stable manifest so joiners don't have to enumerate the bucket.
MANIFEST="$STAGING/LATEST.json"
PUBLIC_BASE="${R2_PUBLIC_URL:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}}"
cat > "$MANIFEST" <<EOF
{
  "height": ${HEIGHT},
  "filename": "${NAME}",
  "url": "${PUBLIC_BASE}/${NAME}",
  "size_bytes": $(rclone --config "$RCLONE_CFG" size --json "r2:${R2_BUCKET}/${NAME}" | jq .bytes),
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "chain_id": "${CHAIN_ID:-sanect_76287-1}"
}
EOF
rclone --config "$RCLONE_CFG" copy "$MANIFEST" "r2:${R2_BUCKET}/"
echo "[snapshot-upload] manifest published, height=${HEIGHT}"

# Prune oldest, keep $KEEP most recent.
LISTING=$(rclone --config "$RCLONE_CFG" lsf "r2:${R2_BUCKET}/" --include 'sanect-*.tar.lz4' | sort -V)
TOTAL=$(echo "$LISTING" | wc -l)
DELETE_COUNT=$(( TOTAL - KEEP ))
if [ "$DELETE_COUNT" -gt 0 ]; then
  echo "$LISTING" | head -n "$DELETE_COUNT" | while read -r f; do
    [ -z "$f" ] && continue
    echo "[snapshot-upload] pruning old $f"
    rclone --config "$RCLONE_CFG" delete "r2:${R2_BUCKET}/$f" || true
  done
fi

echo "[snapshot-upload] done"
