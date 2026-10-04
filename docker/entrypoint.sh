#!/bin/bash
# sanect container entrypoint.
# 1. On first boot (empty volume) build genesis via scripts/localnet.sh (SETUP_ONLY).
# 2. Bind node services to localhost, enable CORS.
# 3. Start the node, then Caddy on $PORT to expose everything over one HTTP URL.
set -euo pipefail

export PATH="$PATH:/usr/local/bin"
HOMEDIR="${HOMEDIR:-/data/.sanectd}"
CHAIN_ID="${CHAIN_ID:-sanect_76287-1}"
EVM_CHAIN_ID="${EVM_CHAIN_ID:-76287}"
PORT="${PORT:-8080}"

# Defensive: Railway sometimes promotes a freshly-added TCP-proxy port as
# the service's primary $PORT (saw this when TCP proxy on 26656 was added
# to expose CometBFT P2P externally). If $PORT collides with any port the
# node itself binds, Caddy can't bind it and the container crash-loops with
# "address already in use". Force a safe default and warn loudly.
case "$PORT" in
  26656|26657|1317|8545|8546|9090)
    echo ">>> WARNING: PORT=$PORT collides with a node service. Forcing PORT=8080."
    PORT=8080
    ;;
esac
export PORT

CONFIG_TOML="$HOMEDIR/config/config.toml"
APP_TOML="$HOMEDIR/config/app.toml"

# ---- Operator escape hatch: FORCE_SNAPSHOT_RESTORE=true ----
# Wipes the existing chain data and re-runs the JOIN_NETWORK path so the
# entrypoint re-attempts snapshot fast-start. Use this when a node gets
# stuck (e.g. crashed during genesis sync, corrupted state, has fallen
# 100k+ blocks behind tip and would take forever to block-sync).
#
# Without this, a stuck node restart just resumes from the broken state
# and crashes again — operators have to remember to manually `rm -rf
# $HOMEDIR` first. This env var makes the recovery one-line.
#
# Safety:
#   - Only fires if JOIN_NETWORK=true (the genesis-builder path doesn't
#     have a remote source of truth to restore from)
#   - Preserves priv_validator_key.json (the signer identity — wiping
#     this would create a NEW validator, defeating the recovery)
#   - Preserves priv_validator_state.json (last-signed height — wiping
#     this is a DOUBLE-SIGN risk if the operator is a validator that
#     already signed at heights between the snapshot and now)
if [ "${FORCE_SNAPSHOT_RESTORE:-false}" = "true" ] && [ "${JOIN_NETWORK:-false}" = "true" ]; then
  # Confirmation gate — refuse to wipe unless the operator typed the chain
  # ID into FORCE_SNAPSHOT_RESTORE_CONFIRM. The 2026-06-14 cascade
  # happened in part because `FORCE_SNAPSHOT_RESTORE=true` was left set
  # across multiple redeploys, causing repeat data wipes. With this
  # gate, the env var alone does nothing — operator must explicitly
  # confirm by setting FORCE_SNAPSHOT_RESTORE_CONFIRM to the chain ID
  # (which proves they know what they're wiping).
  if [ "${FORCE_SNAPSHOT_RESTORE_CONFIRM:-}" != "${CHAIN_ID:-sanect_76287-1}" ]; then
    echo ">>> FORCE_SNAPSHOT_RESTORE=true but FORCE_SNAPSHOT_RESTORE_CONFIRM doesn't match CHAIN_ID."
    echo ">>> To actually wipe chain data, set FORCE_SNAPSHOT_RESTORE_CONFIRM=$CHAIN_ID"
    echo ">>> SKIPPING wipe (preserving existing data)."
  elif [ -d "$HOMEDIR/data" ] || [ -f "$HOMEDIR/config/genesis.json" ]; then
    echo ">>> FORCE_SNAPSHOT_RESTORE=true + CONFIRM matched — wiping chain data, preserving validator key"
    # Stash the validator key + last-signed state OUTSIDE the homedir
    STASH="/tmp/sanectd-key-stash.$$"
    mkdir -p "$STASH"
    [ -f "$HOMEDIR/config/priv_validator_key.json" ] && cp "$HOMEDIR/config/priv_validator_key.json" "$STASH/"
    [ -f "$HOMEDIR/data/priv_validator_state.json" ] && cp "$HOMEDIR/data/priv_validator_state.json" "$STASH/"
    [ -f "$HOMEDIR/config/node_key.json" ] && cp "$HOMEDIR/config/node_key.json" "$STASH/"
    rm -rf "$HOMEDIR"
    # Restore stashed files post-wipe so the regenerated config gets them back
    mkdir -p "$HOMEDIR/config" "$HOMEDIR/data"
    [ -f "$STASH/priv_validator_key.json" ] && cp "$STASH/priv_validator_key.json" "$HOMEDIR/config/"
    [ -f "$STASH/priv_validator_state.json" ] && cp "$STASH/priv_validator_state.json" "$HOMEDIR/data/"
    [ -f "$STASH/node_key.json" ] && cp "$STASH/node_key.json" "$HOMEDIR/config/"
    rm -rf "$STASH"
    echo ">>> Wipe complete. First-boot logic will now run and restore from snapshot."
    echo ">>> IMPORTANT: unset BOTH FORCE_SNAPSHOT_RESTORE and FORCE_SNAPSHOT_RESTORE_CONFIRM"
    echo "    after this boot so future restarts don't keep wiping."
  else
    echo ">>> FORCE_SNAPSHOT_RESTORE=true but no existing data; treating as normal first boot."
  fi
fi

# Snapshot upload cron — refuse to run on a validator node unless the
# operator explicitly opts in. The 2026-06-14 cascade started when
# `--force` snapshot upload ran on the producing validator and caused
# I/O contention that forked the chain. Default: cron disabled when
# the priv_validator_key exists. To run anyway (e.g. on a dedicated
# archive node that happens to have a key file), set
# SNAPSHOT_UPLOAD_ALLOW_ON_VALIDATOR=true.
#
# Cleaner alternative for dedicated archive nodes: set
# SNAPSHOT_PUBLISHER=true. The entrypoint then DELETES the auto-
# generated priv_validator_key.json on every boot (sanectd init
# creates one regardless of whether the node will validate), so the
# node is literally unable to sign and the safety gate stays correct
# without needing the override flag.
if [ "${SNAPSHOT_PUBLISHER:-false}" = "true" ] \
   && [ -f "$HOMEDIR/config/priv_validator_key.json" ]; then
  echo ">>> SNAPSHOT_PUBLISHER=true — removing priv_validator_key.json"
  echo "    (publisher cannot validate; uploads safe to enable)"
  rm -f "$HOMEDIR/config/priv_validator_key.json"
  rm -f "$HOMEDIR/data/priv_validator_state.json" 2>/dev/null || true
fi

if [ -f "$HOMEDIR/config/priv_validator_key.json" ] \
   && [ -n "${SNAPSHOT_UPLOAD_INTERVAL_HOURS:-}" ] \
   && [ "${SNAPSHOT_UPLOAD_ALLOW_ON_VALIDATOR:-false}" != "true" ]; then
  echo ">>> Snapshot upload cron requested but priv_validator_key.json is present."
  echo ">>> REFUSING to run snapshot uploads on a validator node — see 2026-06-14 postmortem."
  echo ">>> Set SNAPSHOT_PUBLISHER=true on a dedicated archive node (deletes the key)"
  echo ">>> or SNAPSHOT_UPLOAD_ALLOW_ON_VALIDATOR=true to bypass the gate entirely."
  unset SNAPSHOT_UPLOAD_INTERVAL_HOURS
fi

if [[ ! -f "$HOMEDIR/config/genesis.json" ]]; then
  if [[ "${JOIN_NETWORK:-false}" == "true" ]]; then
    # ------------- Join an existing chain (new validator / RPC node) -------------
    : "${SEED_NODE_URL:?JOIN_NETWORK=true requires SEED_NODE_URL (e.g. https://privacy-layer1-production.up.railway.app)}"
    : "${SEED_NODE_ID:?JOIN_NETWORK=true requires SEED_NODE_ID (CometBFT node id of a peer)}"
    : "${SEED_PEER_HOST:?JOIN_NETWORK=true requires SEED_PEER_HOST (host:port reachable from this container, e.g. privacy-layer1.railway.internal:26656)}"
    MONIKER="${MONIKER:-sanect-joiner}"
    echo ">>> First boot: JOINING existing chain $CHAIN_ID via $SEED_NODE_URL"
    # sanectd init generates a UNIQUE priv_validator_key.json — exactly what we want
    # for a new validator that must not collide with any other node's key.
    sanectd init "$MONIKER" --chain-id "$CHAIN_ID" --home "$HOMEDIR" >/dev/null
    echo ">>> Fetching live genesis from $SEED_NODE_URL/rpc/genesis"
    curl -sf "$SEED_NODE_URL/rpc/genesis" \
      | jq -r '.result.genesis' > "$HOMEDIR/config/genesis.json"
    # validate-genesis is a defense-in-depth sanity check that the genesis
    # JSON parses + every module accepts its config. It's optional — the
    # chain runs the same checks at boot during InitChain.
    #
    # cosmos/evm v0.2.0's precisebank module crashes here with a nil deref
    # because its ValidateGenesis() calls GetEVMCoinDecimals() before the
    # binary has initialised the coin config. Hitting this means the
    # joiner's pre-flight check fails even though the genesis itself is
    # fine. Make it non-fatal: if validate-genesis succeeds great, log
    # success; if it crashes, just continue and let the actual boot catch
    # real problems.
    if sanectd genesis validate-genesis --home "$HOMEDIR" 2>/dev/null; then
      echo ">>> genesis validate-genesis: OK"
    else
      echo ">>> genesis validate-genesis: skipped (cosmos/evm v0.2.0 precisebank"
      echo "    has a pre-flight nil deref; real validation runs at InitChain)"
    fi

    # ---- Fast-start path: pull a published snapshot tarball before CometBFT
    # starts, so the joiner doesn't replay from genesis on big chains. This
    # runs BEFORE state-sync config: if it succeeds, we skip state-sync; if
    # it fails, we fall through to state-sync; if THAT fails, full block sync.
    if [ -n "${SNAPSHOT_URL:-}" ] || [ -n "${SNAPSHOT_MANIFEST_URL:-}" ]; then
      echo ">>> Attempting fast-start from published snapshot"
      bash /app/scripts/snapshot-download.sh || \
        echo ">>> snapshot-download failed; falling back to state sync"
    fi

    echo ">>> Wiring peers: $SEED_NODE_ID@$SEED_PEER_HOST"
    sed -i "s|^persistent_peers = .*|persistent_peers = \"$SEED_NODE_ID@$SEED_PEER_HOST\"|" "$CONFIG_TOML"
    sed -i "s|^seeds = .*|seeds = \"$SEED_NODE_ID@$SEED_PEER_HOST\"|" "$CONFIG_TOML"
    # Match the chain's Variant A 400ms timing (see CLAUDE.md). These values
    # match scripts/localnet.sh; any change there should mirror here.
    sed -i 's/timeout_propose = "3s"/timeout_propose = "250ms"/'             "$CONFIG_TOML"
    sed -i 's/timeout_propose_delta = "500ms"/timeout_propose_delta = "50ms"/' "$CONFIG_TOML"
    sed -i 's/timeout_prevote = "1s"/timeout_prevote = "150ms"/'             "$CONFIG_TOML"
    sed -i 's/timeout_prevote_delta = "500ms"/timeout_prevote_delta = "50ms"/' "$CONFIG_TOML"
    sed -i 's/timeout_precommit = "1s"/timeout_precommit = "150ms"/'         "$CONFIG_TOML"
    sed -i 's/timeout_precommit_delta = "500ms"/timeout_precommit_delta = "50ms"/' "$CONFIG_TOML"
    sed -i 's/timeout_commit = "5s"/timeout_commit = "400ms"/'               "$CONFIG_TOML"
    # mempool.type = "flood" — CometBFT-managed mempool that gossips
    # txs and accepts broadcast_tx_* RPC submissions. Works on every
    # CometBFT 0.38.x version.
    #
    # NEITHER "app" NOR "nop" work for us:
    #   - "app" was accepted by CometBFT v0.38.17 but rejected by
    #     v0.38.18 with "unknown mempool type: app"
    #   - "nop" disables CometBFT's mempool entirely, breaking
    #     eth_sendRawTransaction with "not allowed with nop mempool"
    #
    # "flood" is the documented default. cosmos/evm's EVM legacypool
    # still runs at the app layer (proposer pulls from it during
    # PrepareProposal); CometBFT just handles gossip + broadcast.
    sed -i 's/^type = "nop"/type = "flood"/' "$CONFIG_TOML"
    sed -i 's/^type = "app"/type = "flood"/' "$CONFIG_TOML"

    # ---- State sync: skip full-syncing 1M+ blocks and fetch a recent snapshot instead ----
    # Requires the seed to be serving snapshots (snapshot-interval > 0 in app.toml).
    # The awk block lower in this script enables snapshot serving on every node, so
    # once val-1 has been redeployed once, subsequent joins find snapshots quickly.
    echo ">>> Configuring CometBFT state sync from $SEED_NODE_URL"
    CHAIN_HEIGHT=$(curl -sf "$SEED_NODE_URL/rpc/status" | jq -r '.result.sync_info.latest_block_height' 2>/dev/null || echo 0)
    if [ "$CHAIN_HEIGHT" -gt 2500 ]; then
      TRUST_HEIGHT=$(( CHAIN_HEIGHT - 2000 ))
      TRUST_HASH=$(curl -sf "$SEED_NODE_URL/rpc/block?height=$TRUST_HEIGHT" | jq -r '.result.block_id.hash')
      if [ -n "$TRUST_HASH" ] && [ "$TRUST_HASH" != "null" ]; then
        echo ">>> Trust height $TRUST_HEIGHT, hash ${TRUST_HASH:0:24}..."
        awk -v height="$TRUST_HEIGHT" -v hash="$TRUST_HASH" -v rpc="$SEED_NODE_URL/rpc,$SEED_NODE_URL/rpc" '
          /^\[/ { sec=$0 }
          sec=="[statesync]" && /^enable[[:space:]]*=/         { print "enable = true"; next }
          sec=="[statesync]" && /^rpc_servers[[:space:]]*=/    { print "rpc_servers = \"" rpc "\""; next }
          sec=="[statesync]" && /^trust_height[[:space:]]*=/   { print "trust_height = " height; next }
          sec=="[statesync]" && /^trust_hash[[:space:]]*=/     { print "trust_hash = \"" hash "\""; next }
          { print }
        ' "$CONFIG_TOML" > "$CONFIG_TOML.tmp" && mv "$CONFIG_TOML.tmp" "$CONFIG_TOML"
      else
        echo ">>> WARNING: couldn't fetch trust hash; falling back to full sync (slow!)"
      fi
    else
      echo ">>> Chain too young for state sync (height $CHAIN_HEIGHT); doing full sync"
    fi

    # Print our node id so the operator can fund + register us via CLI.
    echo ">>> This node's CometBFT id: $(sanectd cometbft show-node-id --home "$HOMEDIR")"
    echo ">>> This node's consensus pubkey: $(sanectd cometbft show-validator --home "$HOMEDIR")"
    echo ">>> The node will now sync the chain. Once 'catching_up' is false,"
    echo ">>> submit a MsgCreateValidator tx to actually become a validator."
  else
    echo ">>> First boot: generating genesis for $CHAIN_ID"

    # ---------- mainnet guard: require explicit VAL_MNEMONIC ----------
    NETWORK="${NETWORK:-testnet}"
    if [[ "$NETWORK" == "mainnet" ]] && [ -z "${VAL_MNEMONIC:-}" ]; then
      echo "!! MAINNET requires VAL_MNEMONIC env var set to a fresh secret mnemonic." >&2
      echo "!! The default testnet mnemonic is PUBLIC — refusing to build mainnet genesis with it." >&2
      exit 1
    fi

    # ---------- compute validator key allocation ----------
    # Total supply is 1B SNCT = 1000000000000000000000000000 asnct.
    # If treasury and/or foundation amounts are set, the validator key gets
    # the REMAINDER (total - treasury - foundation), NOT the full 1B.
    # Previous bug: localnet.sh allocated the full 1B to the validator key,
    # then entrypoint.sh added treasury + foundation ON TOP → 2B total.
    TOTAL_SUPPLY_ASNCT="1000000000000000000000000000"
    treasury_amount="${GENESIS_TREASURY_AMOUNT:-0}"
    foundation_amount="${FOUNDATION_AMOUNT:-0}"
    # Arbitrary-precision subtraction via jq (string math, not tonumber).
    # jq's builtin arithmetic loses precision past ~15 digits, but we can
    # shell out the subtraction to awk's printf or do string-level work.
    # Simpler: use jq only for JSON, do the math with POSIX bc fallback
    # or manual digit subtraction. Since the container has no bc/python,
    # we use awk with printf to avoid float — but awk also loses precision.
    # Safest: subtract via the shell using dc-style string math in jq's
    # --jsonargs mode, or simply hard-compute in the shell.
    #
    # Actually: for THIS specific subtraction (1e27 - 969e24 - 30e24 = 1e24)
    # we can validate the inputs are sane and do string subtraction via
    # a helper that works on decimal strings of any length.
    bigint_sub() {
      # $1 - $2, both non-negative decimal strings. Uses jq's arbitrary-
      # precision integer support (jq 1.7+ handles big ints as strings
      # via tonumber, but we avoid that). Instead: use the fact that our
      # numbers are all multiples of 10^18 and divide down.
      # Simpler approach: just use printf in awk with enough precision.
      # GNU awk's PREC= sets arbitrary precision with -M flag, but that
      # may not be available. Fallback: since all our values end in 18+
      # zeros, trim them, do normal arithmetic, then re-append.
      local a="$1" b="$2"
      # Trim trailing zeros (at least 18), do subtraction, re-append
      local suffix=""
      local i=0
      while [ $i -lt 18 ] && [[ "$a" == *0 ]] && [[ "$b" == *0 ]]; do
        a="${a%0}"; b="${b%0}"; suffix="${suffix}0"; i=$((i+1))
      done
      # Now a and b fit in bash arithmetic (max ~9.2e18)
      local result=$(( a - b ))
      echo "${result}${suffix}"
    }
    step1=$(bigint_sub "$TOTAL_SUPPLY_ASNCT" "$treasury_amount")
    val_key_amount=$(bigint_sub "$step1" "$foundation_amount")
    # Validate positive
    if [[ "$val_key_amount" == -* ]] || [ "$val_key_amount" = "0" ]; then
      echo "!! validator key allocation is non-positive: treasury=$treasury_amount + foundation=$foundation_amount >= total=$TOTAL_SUPPLY_ASNCT" >&2
      exit 1
    fi
    export VAL_KEY_GENESIS_AMOUNT="$val_key_amount"
    echo ">>> Validator key allocation: $val_key_amount asnct (total $TOTAL_SUPPLY_ASNCT - treasury $treasury_amount - foundation $foundation_amount)"

    # localnet.sh builds the v1 genesis (asnct denom, max_validators=50,
    # ~400ms tuning, slashing/distribution/inflation per Variant A, gentx).
    # VAL_KEY_GENESIS_AMOUNT overrides the default full-supply allocation.
    HOMEDIR="$HOMEDIR" CHAIN_ID="$CHAIN_ID" SETUP_ONLY=true bash /app/scripts/localnet.sh

    # ---------------- optional: add genesis accounts from env ----------------
    # Lets a Railway / single-container deploy inject vesting accounts at
    # genesis time without exec-shell wrangling. Two slots:
    #
    #   GENESIS_TREASURY_ADDR / GENESIS_TREASURY_AMOUNT
    #     — added as a regular (non-vesting) account. Amount is in asnct
    #       (1 SNCT = 10^18 asnct). Example: 970000000000000000000000000.
    #
    #   FOUNDATION_ADDR / FOUNDATION_AMOUNT / FOUNDATION_VEST_MONTHS
    #     — added as a DelayedVestingAccount. Vest ends now + N months.
    #
    # Addresses may be 0x-prefixed EVM hex OR snct1 bech32 — converted via
    # `sanectd debug addr` if hex. NOTE: `sanectd debug addr` rejects the
    # literal '0x' prefix (chokes on the 'x' character), so we strip it
    # before passing.
    addr_to_bech32() {
      local a="$1"
      if [[ "$a" =~ ^snct1[a-z0-9]+$ ]]; then
        echo "$a"
        return
      fi
      # Strip 0x prefix if present — sanectd debug addr only accepts bare hex.
      local hex="${a#0x}"
      hex="${hex#0X}"
      if [[ ! "$hex" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo ""
        return
      fi
      sanectd debug addr "$hex" 2>&1 | grep -oE 'snct1[a-z0-9]{38,}' | head -1
    }
    if [ -n "${GENESIS_TREASURY_ADDR:-}" ] && [ -n "${GENESIS_TREASURY_AMOUNT:-}" ]; then
      b=$(addr_to_bech32 "$GENESIS_TREASURY_ADDR")
      if [ -z "$b" ]; then
        echo "!! could not derive bech32 from GENESIS_TREASURY_ADDR=$GENESIS_TREASURY_ADDR" >&2
        exit 1
      fi
      echo ">>> Adding genesis-treasury: $b  ${GENESIS_TREASURY_AMOUNT} asnct (no vest)"
      sanectd genesis add-genesis-account "$b" "${GENESIS_TREASURY_AMOUNT}asnct" --home "$HOMEDIR"
    fi
    if [ -n "${FOUNDATION_ADDR:-}" ] && [ -n "${FOUNDATION_AMOUNT:-}" ]; then
      b=$(addr_to_bech32 "$FOUNDATION_ADDR")
      if [ -z "$b" ]; then
        echo "!! could not derive bech32 from FOUNDATION_ADDR=$FOUNDATION_ADDR" >&2
        exit 1
      fi
      months="${FOUNDATION_VEST_MONTHS:-48}"
      vest_end=$(date -d "+${months} months" +%s)
      echo ">>> Adding Foundation: $b  ${FOUNDATION_AMOUNT} asnct (${months}-mo vest)"
      sanectd genesis add-genesis-account "$b" "${FOUNDATION_AMOUNT}asnct" \
        --vesting-amount "${FOUNDATION_AMOUNT}asnct" \
        --vesting-end-time "$vest_end" \
        --home "$HOMEDIR"
    fi

    # Sanity-check total supply — sum all asnct balances from genesis JSON.
    # Uses jq string extraction + shell arithmetic on trimmed values (no
    # python3 in the runtime image, and jq tonumber loses precision past
    # ~15 digits). All our amounts end in 18+ zeros, so we trim 18 zeros,
    # sum in bash, then re-append.
    total="0"
    while IFS= read -r amt; do
      [ -z "$amt" ] && continue
      # Trim 18 trailing zeros for bash-safe arithmetic
      trimmed="${amt%000000000000000000}"
      total=$(( total + trimmed ))
    done < <(jq -r '.app_state.bank.balances[].coins[] | select(.denom == "asnct") | .amount' "$HOMEDIR/config/genesis.json")
    # Re-append the 18 zeros
    total="${total}000000000000000000"
    if [ "$total" != "$TOTAL_SUPPLY_ASNCT" ]; then
      echo "!! genesis bank balances total $total asnct" >&2
      echo "!! expected $TOTAL_SUPPLY_ASNCT asnct (1B SNCT)" >&2
      echo "!! refusing to start the chain with wrong supply" >&2
      exit 1
    fi
    echo ">>> ✓ genesis bank balances sum to 1B SNCT ($total asnct)"
  fi
else
  echo ">>> Existing chain data found at $HOMEDIR — reusing it"
fi

# Re-apply server config on EVERY boot so a stale volume can't keep gRPC/API
# off (gRPC must be ON or the REST gateway returns code 12 "Not Implemented").
echo ">>> Ensuring api/grpc enabled + CORS in config (idempotent)"
# CometBFT RPC CORS (Caddy also adds CORS at the edge)
sed -i 's/^cors_allowed_origins = .*/cors_allowed_origins = ["*"]/' "$CONFIG_TOML" 2>/dev/null || true

# If the operator set EXTERNAL_P2P_ADDRESS, advertise it so peers (especially
# external/cross-project ones) can dial us back. Without this CometBFT tells
# peers about its in-container 0.0.0.0:26656 which is useless from outside.
# Format: host:port — typically the Railway TCP-proxy hostname (or a CNAME
# pointing at it) plus the assigned port. Reapplied every boot so a stale
# volume can't keep an outdated value.
#
# Pre-validate DNS: CometBFT does an eager getaddrinfo() at boot and the
# node refuses to start if the hostname doesn't resolve. We'd rather come
# up without an advertised external address than crash-loop while DNS is
# being set up.
if [ -n "${EXTERNAL_P2P_ADDRESS:-}" ]; then
  EXTERNAL_HOST="${EXTERNAL_P2P_ADDRESS%:*}"
  if getent hosts "$EXTERNAL_HOST" >/dev/null 2>&1; then
    echo ">>> Advertising external P2P address: $EXTERNAL_P2P_ADDRESS"
    sed -i "s|^external_address = .*|external_address = \"$EXTERNAL_P2P_ADDRESS\"|" "$CONFIG_TOML"
  else
    echo ">>> WARN: EXTERNAL_P2P_ADDRESS=$EXTERNAL_P2P_ADDRESS but $EXTERNAL_HOST does not resolve."
    echo ">>>       Skipping external_address for this boot. Set up DNS, then redeploy."
    sed -i "s|^external_address = .*|external_address = \"\"|" "$CONFIG_TOML"
  fi
fi

# Re-apply seed/peer config on EVERY boot when SEED_NODE_ID + SEED_PEER_HOST
# are set. The JOIN_NETWORK=true block above only runs on FIRST boot (before
# genesis exists). If the operator later changes SEED_PEER_HOST — e.g. moving
# from a Railway-internal hostname to the public CNAME — a plain restart
# would otherwise NOT pick up the new value and the node would silently
# keep dialling the old address forever, showing "No addresses to dial" in
# the logs. Keeping this idempotent matches how we treat EXTERNAL_P2P_ADDRESS
# and the consensus timeouts.
if [ -n "${SEED_NODE_ID:-}" ] && [ -n "${SEED_PEER_HOST:-}" ]; then
  PEER="$SEED_NODE_ID@$SEED_PEER_HOST"
  echo ">>> Wiring persistent_peers + seeds: $PEER"
  sed -i "s|^persistent_peers = .*|persistent_peers = \"$PEER\"|" "$CONFIG_TOML"
  sed -i "s|^seeds = .*|seeds = \"$PEER\"|" "$CONFIG_TOML"
fi

# Re-apply Variant A consensus timeouts (~400ms target) on EVERY boot.
# Without this, a volume created before localnet.sh had the fast timeouts
# keeps CometBFT defaults (5s commit) forever, and block time is capped
# by the slowest committer regardless of how many other validators are
# tuned. Keep these in sync with scripts/localnet.sh.
# Consensus timeouts. timeout_propose is the budget the proposer has to
# call PrepareProposal (which iterates the EVM mempool, sorts by
# fee/nonce, packs into a block) — at 250ms with 5000 mempool depth,
# the proposer can only pack ~20 txs/block before time runs out. We
# bump it to 1s so under burst load the proposer can pack 500+ txs/
# block; under idle load CometBFT skips empty blocks so this doesn't
# slow normal operation.
sed -i 's/^timeout_propose = .*/timeout_propose = "1s"/'                  "$CONFIG_TOML"
sed -i 's/^timeout_propose_delta = .*/timeout_propose_delta = "200ms"/'   "$CONFIG_TOML"
sed -i 's/^timeout_prevote = .*/timeout_prevote = "150ms"/'                "$CONFIG_TOML"
sed -i 's/^timeout_prevote_delta = .*/timeout_prevote_delta = "50ms"/'     "$CONFIG_TOML"
sed -i 's/^timeout_precommit = .*/timeout_precommit = "150ms"/'            "$CONFIG_TOML"
sed -i 's/^timeout_precommit_delta = .*/timeout_precommit_delta = "50ms"/' "$CONFIG_TOML"
sed -i 's/^timeout_commit = .*/timeout_commit = "400ms"/'                  "$CONFIG_TOML"

# Mempool capacity — bumped well above the CometBFT defaults so a single
# burst-y client (load tester, indexer backfill, batch faucet) doesn't
# get its txs evicted before the proposer can pack them.
#
# Defaults vs ours:
#   size           5000   →  50000   (max txs sitting in mempool)
#   cache_size    10000   →  50000   (dedup window for incoming txs)
#   max_txs_bytes  1 GiB  →   1 GiB  (unchanged — already huge)
#   recheck         true  →   false  (skip re-running CheckTx every block;
#                                      saves CPU at high mempool depth)
# Section-aware rewrite via awk. CRITICAL: the previous sed-based
# version was `s/^size = 5000/.../` — that regex isn't anchored at
# end-of-line, so each redeploy of an already-patched config matched
# the prefix again and appended an extra digit. After ~40 redeploys
# the line read `size = 500000000000000000000000000000000000000000`
# and sanectd crashed at parse time. The awk pattern below always
# rewrites the line to the exact target value regardless of what's
# already there. Same lesson applies to any future sed on a value
# that could grow: anchor `$` or use awk.
awk '
  /^\[/ { sec=$0 }
  # Match both bare and auto-disabled-commented forms so the heal from
  # the earlier patch doesn'\''t leave the field permanently disabled.
  sec=="[mempool]" && /^(# auto-disabled[^:]*:[[:space:]]*)?type[[:space:]]*=/        { print "type = \"flood\""; next }
  sec=="[mempool]" && /^(# auto-disabled[^:]*:[[:space:]]*)?size[[:space:]]*=/        { print "size = 50000"; next }
  sec=="[mempool]" && /^(# auto-disabled[^:]*:[[:space:]]*)?cache_size[[:space:]]*=/  { print "cache_size = 50000"; next }
  sec=="[mempool]" && /^(# auto-disabled[^:]*:[[:space:]]*)?recheck[[:space:]]*=/     { print "recheck = false"; next }
  { print }
' "$CONFIG_TOML" > "$CONFIG_TOML.tmp" && mv "$CONFIG_TOML.tmp" "$CONFIG_TOML"

# cosmos/evm app-side mempool: -1 = unlimited (let CometBFT's size cap us).
# Default is 5000 which collides with the CometBFT cap above and double-
# counts the eviction.
sed -i 's/^max-txs = "5000"/max-txs = "-1"/'                                "$APP_TOML"

# IAVL state cache — defaults to 781,250 nodes (~100 MiB). At ~300k+
# blocks the active working set outgrows this and every commit goes to
# disk, adding 200-300ms per block on Railway's networked storage.
# 10M nodes (~1.2 GiB) balances block time vs memory. Previous 20M
# default consumed ~2.5 GiB and with fast-node enabled effectively
# doubled to ~5 GiB. Override via IAVL_CACHE_SIZE env.
IAVL_CACHE_SIZE="${IAVL_CACHE_SIZE:-10000000}"
echo ">>> Setting iavl-cache-size = ${IAVL_CACHE_SIZE} (default was 781250)"
if grep -q '^iavl-cache-size' "$APP_TOML"; then
  sed -i "s/^iavl-cache-size *=.*/iavl-cache-size = ${IAVL_CACHE_SIZE}/" "$APP_TOML"
else
  printf '\niavl-cache-size = %d\n' "${IAVL_CACHE_SIZE}" >> "$APP_TOML"
fi

# Inter-block cache — keeps the deliver-state cache populated across
# blocks instead of dropping it after EndBlock. Free win for empty
# blocks (no reads to repopulate) and for read-heavy workloads.
echo ">>> Setting inter-block-cache = true"
if grep -q '^inter-block-cache' "$APP_TOML"; then
  sed -i "s/^inter-block-cache *=.*/inter-block-cache = true/" "$APP_TOML"
else
  printf '\ninter-block-cache = true\n' >> "$APP_TOML"
fi

# IAVL fast node — fast lookup paths for the latest state version.
# Roughly doubles IAVL memory usage (separate index of all latest-version
# nodes). Disable on memory-constrained nodes via IAVL_DISABLE_FASTNODE=true.
IAVL_DISABLE_FASTNODE="${IAVL_DISABLE_FASTNODE:-false}"
echo ">>> Setting iavl-disable-fastnode = ${IAVL_DISABLE_FASTNODE}"
if grep -q '^iavl-disable-fastnode' "$APP_TOML"; then
  sed -i "s/^iavl-disable-fastnode *=.*/iavl-disable-fastnode = ${IAVL_DISABLE_FASTNODE}/" "$APP_TOML"
fi

# Per-account mempool caps: patched at binary-build time in
# scripts/fork-cosmos-evm.sh. cosmos/evm v0.4.1 hardcodes
# AccountSlots=16 + AccountQueue=64 in legacypool.DefaultConfig (no
# app.toml knob for this in v0.4.1), so we sed them to 5000/5000 in
# the fork script. The change requires a fresh sanectd binary build —
# bump the SCRIPT_VERSION in fork-cosmos-evm.sh to force Railway to
# rebuild instead of reusing a cached image.

# app.toml: force [api] enable, [grpc] enable, CORS, AND the EVM chain ID
# at runtime. The last one is a defensive belt-and-suspenders against
# the cosmos/evm v0.4.x baked-in default of 262144 — even if the binary's
# sed patches didn't catch every chain-ID constant, writing the value
# directly into app.toml forces it at every start.
echo ">>> Forcing EVM chain id = $EVM_CHAIN_ID in app.toml (runtime safety net)"
awk -v cid="$EVM_CHAIN_ID" '
  /^\[/ { sec=$0 }
  sec=="[api]"  && /^enable[[:space:]]*=/ { print "enable = true"; next }
  sec=="[api]"  && /^enabled-unsafe-cors[[:space:]]*=/ { print "enabled-unsafe-cors = false"; next }
  sec=="[grpc]" && /^enable[[:space:]]*=/ { print "enable = true"; next }
  sec=="[state-sync]" && /^snapshot-interval[[:space:]]*=/   { print "snapshot-interval = 1000"; next }
  sec=="[state-sync]" && /^snapshot-keep-recent[[:space:]]*=/ { print "snapshot-keep-recent = 5"; next }
  sec=="[evm]" && /^evm-chain-id[[:space:]]*=/ { print "evm-chain-id = " cid; next }
  sec=="[evm]" && /^eth-chain-id[[:space:]]*=/ { print "eth-chain-id = " cid; next }
  sec=="[json-rpc]" && /^evm-chain-id[[:space:]]*=/ { print "evm-chain-id = " cid; next }
  # Force JSON-RPC HTTP + WebSocket on. WSS specifically: a stale volume
  # could have ws-address commented out or pointing at the wrong port,
  # leaving eth_subscribe unreachable. Caddy reverse-proxies 127.0.0.1:8546
  # at /ws so this MUST match.
  sec=="[json-rpc]" && /^enable[[:space:]]*=/        { print "enable = true"; next }
  sec=="[json-rpc]" && /^address[[:space:]]*=/       { print "address = \"127.0.0.1:8545\""; next }
  sec=="[json-rpc]" && /^ws-address[[:space:]]*=/    { print "ws-address = \"127.0.0.1:8546\""; next }
  sec=="[json-rpc]" && /^enable-indexer[[:space:]]*=/ { print "enable-indexer = true"; next }
  sec=="[json-rpc]" && /^api[[:space:]]*=/           { print "api = \"eth,txpool,net,web3,debug\""; next }
  # Throughput tunings — defaults are conservative and fight us under load.
  sec=="[json-rpc]" && /^http-timeout[[:space:]]*=/      { print "http-timeout = \"5m\""; next }
  sec=="[json-rpc]" && /^http-idle-timeout[[:space:]]*=/ { print "http-idle-timeout = \"5m\""; next }
  sec=="[json-rpc]" && /^max-open-connections[[:space:]]*=/ { print "max-open-connections = 65535"; next }
  sec=="[json-rpc]" && /^batch-request-limit[[:space:]]*=/  { print "batch-request-limit = 500"; next }
  sec=="[json-rpc]" && /^block-range-cap[[:space:]]*=/      { print "block-range-cap = 10000"; next }
  sec=="[json-rpc]" && /^logs-cap[[:space:]]*=/             { print "logs-cap = 10000"; next }
  { print }
' "$APP_TOML" > "$APP_TOML.tmp" && mv "$APP_TOML.tmp" "$APP_TOML"
# If neither evm-chain-id nor eth-chain-id was anywhere in app.toml, append
# a short [evm] section so the value is still applied. Done in bash rather
# than an awk END block because mawk's parser chokes on comments inside END.
if ! grep -qE '^(evm|eth)-chain-id[[:space:]]*=' "$APP_TOML"; then
  {
    echo ""
    echo "[evm]"
    echo "evm-chain-id = $EVM_CHAIN_ID"
  } >> "$APP_TOML"
fi

# Self-heal: scan config + app TOML for any unquoted integer larger than
# int64 max (≈ 9.2e18). Such values came from a buggy field default in an
# earlier image and crash the new sanectd at TOML parse time with
# "strconv.ParseInt: ... value out of range". Comment those lines out;
# whatever default cosmos/evm picks is almost certainly correct.
echo ">>> Scanning TOMLs for out-of-range int values…"
for F in "$CONFIG_TOML" "$APP_TOML" "$HOMEDIR/config/client.toml"; do
  [ -f "$F" ] || continue
  # Match any line with an unquoted integer ≥ 20 digits (10^19 is past int64).
  # Pattern: KEY = NUMBER (no leading quote) where NUMBER has ≥20 digits.
  BAD_LINES=$(grep -nE '^[[:space:]]*[a-zA-Z_-]+[[:space:]]*=[[:space:]]*[0-9]{20,}[[:space:]]*(#.*)?$' "$F" || true)
  if [ -n "$BAD_LINES" ]; then
    echo "⚠ $F has out-of-range int values, commenting out:"
    echo "$BAD_LINES" | sed 's/^/   /'
    sed -i -E 's/^([[:space:]]*[a-zA-Z_-]+[[:space:]]*=[[:space:]]*)([0-9]{20,})/# auto-disabled (out of int64 range): \1\2/' "$F"
  fi
done

echo ">>> sanectd build: $(sanectd version 2>&1 | head -1)"

# Debug dump: print the genesis evm + feemarket sections AND the app.toml [evm]
# / [json-rpc] sections so we can SEE what cosmos/evm reads at runtime. If
# eth_chainId returns something other than $EVM_CHAIN_ID, this output tells
# us which field's value is being used.
echo ">>> DEBUG — genesis evm.params:"
jq '.app_state.evm.params | {evm_denom, evm_chain_id, eth_chain_id, chain_id, chain_config}' \
  "$HOMEDIR/config/genesis.json" 2>/dev/null || echo "  (genesis not parseable)"
echo ">>> DEBUG — genesis feemarket.params (chain id keys):"
jq '.app_state.feemarket.params | {evm_chain_id, base_fee, min_gas_price}' \
  "$HOMEDIR/config/genesis.json" 2>/dev/null || echo "  (genesis not parseable)"
echo ">>> DEBUG — app.toml [evm] + [json-rpc] sections:"
awk '/^\[/ { sec=$0 } sec=="[evm]" || sec=="[json-rpc]" { print }' "$APP_TOML" 2>/dev/null || echo "  (app.toml not parseable)"

echo ">>> Starting sanect node (EVM chain-id $EVM_CHAIN_ID)"

# Pin Go's scheduler to the container's actual CPU allowance. Go reads
# /proc/cpuinfo (host CPUs) rather than the cgroup limit, so on Railway
# with a 24-CPU container the runtime might over-schedule and starve
# itself. Detecting the cgroup quota and clamping GOMAXPROCS to it is
# the production pattern.
#
# CAVEAT: on Railway some containers report `max` as the cgroup CPU
# quota even on a 24-CPU plan (no hard cgroup cap; only "shares"). In
# that case our detection falls back to nproc which sees the host's
# CPUs. Setting GOMAXPROCS explicitly as an env var on the service is
# the bypass — recommended for any high-CPU plan.
if [ -z "${GOMAXPROCS:-}" ]; then
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    # cgroup v2
    read -r QUOTA PERIOD < /sys/fs/cgroup/cpu.max
    if [ "$QUOTA" != "max" ] && [ -n "$QUOTA" ] && [ -n "$PERIOD" ] && [ "$PERIOD" -gt 0 ]; then
      CGROUP_CPUS=$(( (QUOTA + PERIOD - 1) / PERIOD ))
      [ "$CGROUP_CPUS" -ge 1 ] && export GOMAXPROCS="$CGROUP_CPUS"
    fi
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    # cgroup v1
    Q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    P=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if [ "$Q" -gt 0 ] && [ "$P" -gt 0 ]; then
      export GOMAXPROCS=$(( (Q + P - 1) / P ))
    fi
  fi
  : "${GOMAXPROCS:=$(nproc 2>/dev/null || echo 4)}"
fi
echo ">>> GOMAXPROCS=$GOMAXPROCS  (cgroup-aware; explicit GOMAXPROCS env overrides)"
echo ">>>   if your Railway metrics show < 50% of plan CPU during load tests,"
echo ">>>   set GOMAXPROCS=24 (or whatever your plan is) on the service env"
echo ">>>   to force-pin the Go scheduler past the cgroup auto-detect."

# Memory soft-limit. Go's default lets the heap grow without an upper
# bound, so GC pressure is purely heuristic. Setting an explicit soft
# limit forces GC to kick in before the container gets OOM-killed.
# Default 16 GiB (67% of a 24 GiB plan) — leaves headroom for Caddy,
# OS caches, and GC overhead. Previous default of 22 GiB with GOGC=200
# caused the heap to grow to 22GB over ~7 days and trigger OOM kill.
GOMEMLIMIT_VAL="${MEMLIMIT_GIB:-16}GiB"
export GOMEMLIMIT="$GOMEMLIMIT_VAL"
# GOGC controls how aggressively Go collects garbage. Default 100 means
# GC fires when heap doubles the live set. Previous value of 200 let
# too much garbage accumulate before collection, contributing to the
# 22GB OOM. Stick with Go's default unless profiling shows GC pauses
# are a bottleneck.
export GOGC="${GOGC:-100}"
echo ">>> GOMEMLIMIT=$GOMEMLIMIT  GOGC=$GOGC  (Go runtime tuning; bump MEMLIMIT_GIB env if your plan is bigger)"

# File-descriptor ceiling. The classic 65535 ceiling kills load-tester
# throughput: each open JSON-RPC socket + each upstream HTTP keepalive
# + each peer connection eats one FD. Without lifting this, sanectd
# starts dropping incoming connections at ~50k concurrent requests with
# silent "accept: too many open files" in the logs. 1M is way past
# anything we'll actually need but costs nothing.
ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true
echo ">>> file descriptor limit: $(ulimit -n)"

# Node services bind localhost by default (8545 EVM, 8546 WS, 26657 RPC,
# 1317 REST); Caddy in this container proxies to them. Addresses are set in
# config files, not flags.
PRUNING_MODE="${PRUNING:-custom}"
PRUNING_FLAGS=( --pruning "$PRUNING_MODE" )
if [ "$PRUNING_MODE" = "custom" ]; then
  PRUNING_FLAGS+=( --pruning-keep-recent "${PRUNING_KEEP_RECENT:-100000}" --pruning-interval "${PRUNING_INTERVAL:-100}" )
fi
echo ">>> Pruning mode: $PRUNING_MODE (archive = 'nothing', default = 'custom' 100k blocks)"

sanectd start \
  --home "$HOMEDIR" \
  --chain-id "$CHAIN_ID" \
  "${PRUNING_FLAGS[@]}" \
  --minimum-gas-prices=1000000000asnct \
  --json-rpc.enable \
  --json-rpc.api eth,txpool,net,web3,debug \
  --json-rpc.address 127.0.0.1:8545 \
  --json-rpc.ws-address 127.0.0.1:8546 \
  --json-rpc.enable-indexer \
  --evm.evm-chain-id "$EVM_CHAIN_ID" \
  --api.enable \
  --grpc.enable --grpc.address 127.0.0.1:9090 \
  --log_level "${LOG_LEVEL:-info}" 2>&1 &

NODE_PID=$!

# ---- Start Caddy + health poller IMMEDIATELY ----
# Caddy must be listening BEFORE the node finishes syncing so Railway's
# healthcheck can reach /health. The /health endpoint returns 503 until
# the health poller writes /tmp/healthy (when catching_up == false).
# This gives Railway the signal to keep the OLD instance serving traffic
# until the new one is fully synced — zero-downtime redeploys.
rm -f /tmp/healthy
echo ">>> Starting Caddy on :$PORT (early — healthcheck available)"
caddy run --config /app/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Health flag poller: every 5s, ask CometBFT if catching_up is false.
(
  while true; do
    if curl -sf --max-time 3 http://127.0.0.1:26657/status \
       | jq -e '.result.sync_info.catching_up == false' >/dev/null 2>&1; then
      touch /tmp/healthy
    else
      rm -f /tmp/healthy
    fi
    sleep 5
  done
) &

# Wait for Cosmos RPC AND first committed block before fronting / self-testing
until h=$(curl -s localhost:26657/status 2>/dev/null | jq -r '.result.sync_info.latest_block_height // "0"'); [ "$h" -gt 0 ] 2>/dev/null; do
  sleep 2
  kill -0 "$NODE_PID" 2>/dev/null || { echo ">>> node process exited during startup"; exit 1; }
done
echo ">>> Node up at block $h. Running REST gateway self-test..."
# Wait up to 60s for REST API to bind AND grpc gateway to be ready
RESTOUT=""
for i in $(seq 1 30); do
  RESTOUT=$(curl -s --max-time 3 localhost:1317/cosmos/base/tendermint/v1beta1/blocks/latest 2>/dev/null || true)
  if echo "$RESTOUT" | grep -q '"block"'; then
    break
  fi
  sleep 2
done
if echo "$RESTOUT" | grep -q '"block"'; then
  echo ">>> REST SELF-TEST: OK (gRPC gateway serving — explorer will work)"
else
  echo ">>> REST SELF-TEST: FAILED -> ${RESTOUT:0:200}"
  echo ">>> (empty -> 1317 never bound; code 12 -> gRPC off; other -> see error)"
fi

# (Caddy + health poller already started above, right after NODE_PID)

# ---- Snapshot upload cron (primary / archive nodes only) ----
# Operator sets SNAPSHOT_UPLOAD_INTERVAL_HOURS (e.g. 6) and the R2_* env on
# the node they want to publish snapshots from. The cron streams a tarball
# of HOMEDIR/data straight to R2 via rclone, plus a LATEST.json manifest
# that joiners with SNAPSHOT_MANIFEST_URL follow.
if [ -n "${SNAPSHOT_UPLOAD_INTERVAL_HOURS:-}" ] && [ -n "${R2_BUCKET:-}" ]; then
  INTERVAL_H="${SNAPSHOT_UPLOAD_INTERVAL_HOURS}"
  echo ">>> Snapshot upload cron enabled: every ${INTERVAL_H}h to R2://${R2_BUCKET}"
  (
    # Wait indefinitely (not for a fixed 60 minutes) until the node reports
    # catching_up=false. Previously we capped at 120 ticks; if a slow first
    # sync exceeded that, the cron entered its main loop and every tick
    # silently skipped because catching_up was still true.
    waited=0
    while true; do
      cu=$(curl -sf --max-time 10 localhost:26657/status 2>/dev/null \
            | jq -r '(.result.sync_info.catching_up | if . == false then "false" else "true" end)' 2>/dev/null || echo "true")
      # NOTE: do NOT write `.catching_up // true` here: jq's `//` returns the
      # right side when the left is `false`, so a fully synced node (false)
      # was reported as true forever and no snapshot was ever uploaded.
      if [ "$cu" = "false" ]; then
        echo "[snapshot-cron] node is caught up after ${waited}s; first upload in 30s"
        sleep 30
        break
      fi
      # Log every 5 minutes during initial sync so the cron isn't silent.
      if [ $(( waited % 300 )) -eq 0 ]; then
        echo "[snapshot-cron] waiting for catching_up=false (currently $cu, waited ${waited}s)"
      fi
      sleep 30
      waited=$(( waited + 30 ))
    done

    tick=0
    while true; do
      tick=$(( tick + 1 ))
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      echo "[snapshot-cron] tick #${tick} at ${ts} — running snapshot-upload.sh"
      bash /app/scripts/snapshot-upload.sh \
        2>&1 | sed 's/^/[snapshot-cron] /' || true
      echo "[snapshot-cron] tick #${tick} done; next run in ${INTERVAL_H}h"
      sleep $(( INTERVAL_H * 3600 ))
    done
  ) &
fi

# Heartbeat: print height + tx counts so block production is visible in logs
(
  while true; do
    sleep 15
    s=$(curl -s localhost:26657/status 2>/dev/null) || continue
    h=$(echo "$s" | jq -r '.result.sync_info.latest_block_height // empty')
    [ -z "$h" ] && continue
    txs=$(curl -s "localhost:26657/block?height=$h" 2>/dev/null | jq -r '.result.block.data.txs | length // 0')
    mem=$(curl -s localhost:26657/num_unconfirmed_txs 2>/dev/null | jq -r '.result.total // "?"')
    echo ">>> sanect | block=$h | txs_in_block=$txs | mempool_pending=$mem"
  done
) &

# ---- Explorer heartbeat ----
# Opt-in. If EXPLORER_HEARTBEAT_URL is set, this node POSTs its identity
# + sync status to the explorer every 60 seconds. The explorer's
# /api/network/nodes dashboard discovers it without needing to be in
# KNOWN_NODES env.
#
# Privacy:
#   - public_rpc_url is sent ONLY when PUBLIC_RPC_URL is set. Operators
#     who don't want their node listed publicly just leave it unset.
#   - explorer verifies public_rpc_url by ping-back; impersonators get
#     rejected at the server.
if [ -n "${EXPLORER_HEARTBEAT_URL:-}" ]; then
  echo ">>> Explorer heartbeat enabled → ${EXPLORER_HEARTBEAT_URL}"

  (
    # Everything below runs in a backgrounded subshell so a failure
    # here (e.g. SIGPIPE in the token generator, missing config dir
    # on a stale volume) can't kill the main entrypoint and prevent
    # `exec caddy run` from binding $PORT.
    set +e

    # Generate a persistent claim-token on first boot. Stored in
    # $HOMEDIR/config/claim-token. Operators need SSH/root access to
    # read it (chmod 600). The token authenticates subdomain claims —
    # only someone who can read this file can claim subdomains for
    # this node. Reused across reboots so restarts don't invalidate
    # claims.
    #
    # Earlier version used `head -c 32 /dev/urandom | base64 | tr ... |
    # head -c 32` — the trailing `head` closed the pipe early, `tr`
    # got SIGPIPE, pipefail propagated 141, and `set -e` killed the
    # whole entrypoint on first boot. Bug surfaced as "Railway nodes
    # 2 & 3 silently dropped off the dashboard" because they redeployed
    # onto the new entrypoint and crashed before Caddy started. Rewrite
    # to a SIGPIPE-free form (24 raw bytes → ~32 base64 chars, no
    # downstream truncation).
    CLAIM_TOKEN_FILE="$HOMEDIR/config/claim-token"
    if [ ! -f "$CLAIM_TOKEN_FILE" ]; then
      mkdir -p "$HOMEDIR/config" 2>/dev/null || true
      if head -c 24 /dev/urandom 2>/dev/null | base64 2>/dev/null \
           | tr -d '/+=\n' > "$CLAIM_TOKEN_FILE.tmp" 2>/dev/null \
         && [ -s "$CLAIM_TOKEN_FILE.tmp" ]; then
        mv "$CLAIM_TOKEN_FILE.tmp" "$CLAIM_TOKEN_FILE"
        chmod 600 "$CLAIM_TOKEN_FILE" 2>/dev/null || true
        echo ">>> Generated subdomain claim_token at $CLAIM_TOKEN_FILE (chmod 600)"
      else
        rm -f "$CLAIM_TOKEN_FILE.tmp"
        echo ">>> WARNING: couldn't write claim_token; heartbeats will still flow but subdomain claims will be rejected"
      fi
    fi
    CLAIM_TOKEN=$(cat "$CLAIM_TOKEN_FILE" 2>/dev/null || echo "")

    # Small initial delay so the node is up and serving /status before
    # the first heartbeat POST.
    sleep 30
    while true; do
      STATUS=$(curl -sf --max-time 5 localhost:26657/status 2>/dev/null || echo '')
      if [ -n "$STATUS" ]; then
        HEIGHT=$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_height // "0"')
        CATCHING=$(echo "$STATUS" | jq -r '.result.sync_info.catching_up // false')
        NODE_ID=$(echo "$STATUS" | jq -r '.result.node_info.id // ""')
        VERSION=$(echo "$STATUS" | jq -r '.result.node_info.version // ""')
        REPORTED_MONIKER=$(echo "$STATUS" | jq -r '.result.node_info.moniker // ""')
        EFFECTIVE_MONIKER="${MONIKER:-$REPORTED_MONIKER}"
        if [ -n "$NODE_ID" ] && [ "$HEIGHT" != "0" ]; then
          PAYLOAD=$(jq -nc \
            --arg moniker "$EFFECTIVE_MONIKER" \
            --arg node_id "$NODE_ID" \
            --arg validator_address "${VALIDATOR_OPERATOR_ADDR:-}" \
            --arg public_rpc_url "${PUBLIC_RPC_URL:-}" \
            --argjson height "$HEIGHT" \
            --argjson catching_up "$CATCHING" \
            --arg cometbft_version "$VERSION" \
            --arg claim_token "$CLAIM_TOKEN" \
            '{
              moniker:$moniker,
              node_id:$node_id,
              validator_address: (if $validator_address=="" then null else $validator_address end),
              public_rpc_url:    (if $public_rpc_url=="" then null else $public_rpc_url end),
              height:$height,
              catching_up:$catching_up,
              cometbft_version:$cometbft_version,
              claim_token:$claim_token
            }')
          curl -sf --max-time 10 \
            -H 'content-type: application/json' \
            -d "$PAYLOAD" \
            "${EXPLORER_HEARTBEAT_URL}" >/dev/null \
            && echo "[heartbeat] sent height=$HEIGHT catching_up=$CATCHING url=${PUBLIC_RPC_URL:-<none>}" \
            || echo "[heartbeat] POST failed (will retry in 60s)"
        fi
      fi
      sleep 60
    done
  ) &
fi

# Watchdog: wait for whichever process (sanectd or Caddy) dies first,
# then exit with a non-zero status so Docker's --restart policy can
# recycle the container. CADDY_PID was set earlier (line ~603) so
# healthcheck is available during sync.
#
# Reap whichever child dies first. `wait -n` returns the exit status
# of the first to exit; we then kill the other and exit with the same
# status so the container actually terminates and Docker recycles it.
set +e
wait -n "$NODE_PID" "$CADDY_PID"
DEAD_STATUS=$?
if kill -0 "$NODE_PID" 2>/dev/null; then
  echo ">>> Caddy exited ($DEAD_STATUS) — terminating sanectd and recycling container"
  kill -TERM "$NODE_PID" 2>/dev/null
else
  echo ">>> sanectd exited ($DEAD_STATUS) — terminating Caddy and recycling container"
  echo ">>> Most common causes: OOM (check 'free -h' on host, need >= 8 GiB for"
  echo ">>>   archive RPC), consensus panic ('docker logs | grep panic'), disk full."
  kill -TERM "$CADDY_PID" 2>/dev/null
fi
wait
exit "$DEAD_STATUS"
