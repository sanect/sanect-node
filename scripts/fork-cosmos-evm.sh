#!/usr/bin/env bash
# Fork cosmos/evm and build the `sanectd` binary with sanect's bech32 prefix
# and default chain IDs.
#
# SCRIPT_VERSION 2026-06-09-v5 — bump this anytime you change patches, so
# Docker layer caching invalidates and Railway forces a fresh sanectd
# build instead of reusing a cached one with stale patches.
#
# This is the one-time bootstrap step before genesis. Run it once on your
# laptop (or in the Docker build of docker/Dockerfile, which calls it).
# Output: a `sanectd` binary placed at $OUT (default /usr/local/bin/sanectd).
#
# The fork is intentionally a sed-patch of upstream rather than a real Git
# fork, so we don't have to maintain a long-lived divergent codebase: we
# pin to an upstream commit, patch ~10 lines, build, and move on. If the
# user wants to bump the upstream version, they bump COSMOS_EVM_REF and
# rerun.

set -euo pipefail

# ----------------------------- Pinned versions ---------------------------
COSMOS_EVM_REPO="${COSMOS_EVM_REPO:-https://github.com/cosmos/evm}"
COSMOS_EVM_REF="${COSMOS_EVM_REF:-v0.4.1}"   # bump when upgrading SDK / cosmos-evm

# Where the binary lands.
OUT="${OUT:-/usr/local/bin/sanectd}"

# Working directory for the clone + build. Throwaway.
WORK="${WORK:-$(mktemp -d -t sanectd-build-XXXX)}"

echo ">>> Building sanectd from ${COSMOS_EVM_REPO}@${COSMOS_EVM_REF}"
echo ">>> Working in: $WORK"

command -v go   >/dev/null || { echo "ERROR: Go toolchain not installed (need >=1.25)"; exit 1; }
command -v git  >/dev/null || { echo "ERROR: git not installed"; exit 1; }
command -v make >/dev/null || { echo "ERROR: make not installed"; exit 1; }

git clone --depth 1 --branch "$COSMOS_EVM_REF" "$COSMOS_EVM_REPO" "$WORK"
cd "$WORK"

# ============================================================
#                  PRE-PATCH DIAGNOSTIC
# ============================================================
# Before we patch, print every place 262144 (and the hex form 0x40000)
# appears in the source. The post-patch audit on the OUTPUT side has
# missed the actual constant declaration for two rounds; printing the
# input side proves where to target.
echo ""
echo ">>> PRE-PATCH DIAGNOSTIC — every reference to 262144 in cosmos/evm source"
echo ">>> (non-test, non-vendor Go files; first 50 lines)"
echo "----------------------------------------------------------------"
grep -RIn '262144\|0x40000' --include='*.go' . 2>/dev/null \
  | grep -v '/vendor/' | grep -v '_test.go' | head -50 \
  || echo "  (no 262144 references found — surprising; binary may be using a different default)"
echo "----------------------------------------------------------------"
echo ""

# ============================================================
#                       PATCH PHASE
# ============================================================
# Three categories of cosmos/evm defaults need to be overridden in the
# binary. Each missed category causes a specific runtime error:
#   1. Bech32 prefix     "cosmos"  -> "snct"
#      (would show wrong-prefix addresses everywhere)
#   2. Base denom        "atest"   -> "asnct"
#      (would reject fees: "expected only native token atest")
#   3. EVM chain ID      9001/262144 -> 76287
#      (would reject signatures: "invalid chain id for signer:
#       have 76287 want 262144")
# ============================================================

# --- 1. Bech32 prefix ----------------------------------------------------
echo ">>> Patching bech32 prefix: cosmos -> snct"
find . -type f -name "*.go" -not -path "./vendor/*" -print0 \
  | xargs -0 -r sed -i.bak \
      -e 's/"cosmos"/"snct"/g' \
      -e 's/"cosmospub"/"snctpub"/g' \
      -e 's/"cosmosvaloper"/"snctvaloper"/g' \
      -e 's/"cosmosvaloperpub"/"snctvaloperpub"/g' \
      -e 's/"cosmosvalcons"/"snctvalcons"/g' \
      -e 's/"cosmosvalconspub"/"snctvalconspub"/g'
find . -name '*.bak' -delete 2>/dev/null || true

# --- 2. Base denom -------------------------------------------------------
echo ">>> Patching default base denom: atest -> asnct"
find . -type f -name "*.go" -not -path "./vendor/*" -print0 \
  | xargs -0 -r sed -i.bak \
      -e 's/"atest"/"asnct"/g' \
      -e 's/`atest`/`asnct`/g'
find . -name '*.bak' -delete 2>/dev/null || true

# --- 3. EVM chain ID (all known declaration patterns) --------------------
# TARGET_EVM_CHAIN_ID is a build-time arg:
#   - testnet build → 76287 (default for backwards compat)
#   - mainnet build → 7628  (set TARGET_EVM_CHAIN_ID=7628 in Dockerfile ARG)
# cosmos/evm bakes the chain ID into MANY constants in Go source. The
# entrypoint's runtime --evm.evm-chain-id flag does NOT reach all of them
# (real-world bug discovered 2026-06-22 on mainnet primary deploy: app.toml
# said 7628 but eth_chainId still returned 76287). Compile-time substitution
# is the only reliable fix.
TARGET_EVM_CHAIN_ID="${TARGET_EVM_CHAIN_ID:-76287}"
echo ">>> Patching default EVM chain ID: 9001 + 262144 (cosmos/evm defaults) -> $TARGET_EVM_CHAIN_ID"
#
# cosmos/evm has had two defaults across versions:
#   v0.x:   9001
#   v0.4.x: 262144 (= 2^18)
#
# Both can appear in many syntactic forms. We cover every form we've seen.
# IMPORTANT: 262144 is also 2^18 used elsewhere (buffer sizes, etc.), so
# we ONLY replace it inside patterns that are unambiguously chain-ID:
#   - String form: "cosmos_<id>-1"
#   - Struct literal: EVMChainID: <id>
#   - big.Int constructor: big.NewInt(<id>) and variants
#   - Typed integer literal: uint64(<id>) / int64(<id>)
# A bare numeric occurrence is left alone.
find . -type f -name "*.go" -not -path "./vendor/*" -print0 \
  | xargs -0 -r sed -i.bak \
      -e "s/cosmos_9001-1/sanect_${TARGET_EVM_CHAIN_ID}-1/g" \
      -e "s/cosmos_262144-1/sanect_${TARGET_EVM_CHAIN_ID}-1/g" \
      -e "s/EVMChainID:[[:space:]]*9001/EVMChainID: ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/EVMChainID:[[:space:]]*262144/EVMChainID: ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/big\\.NewInt(9001)/big.NewInt(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/big\\.NewInt(262144)/big.NewInt(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/big\\.NewInt(int64(9001))/big.NewInt(int64(${TARGET_EVM_CHAIN_ID}))/g" \
      -e "s/big\\.NewInt(int64(262144))/big.NewInt(int64(${TARGET_EVM_CHAIN_ID}))/g" \
      -e "s/SetInt64(9001)/SetInt64(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/SetInt64(262144)/SetInt64(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/SetUint64(9001)/SetUint64(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/SetUint64(262144)/SetUint64(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/uint64(9001)/uint64(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/uint64(262144)/uint64(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/int64(9001)/int64(${TARGET_EVM_CHAIN_ID})/g" \
      -e "s/int64(262144)/int64(${TARGET_EVM_CHAIN_ID})/g" \
      \
      -e "s/EVMChainID[[:space:]]*=[[:space:]]*9001/EVMChainID = ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/EVMChainID[[:space:]]*=[[:space:]]*262144/EVMChainID = ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/CosmosChainID[[:space:]]*=[[:space:]]*9001/CosmosChainID = ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/CosmosChainID[[:space:]]*=[[:space:]]*262144/CosmosChainID = ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/DefaultEVMChainID[[:space:]]*=[[:space:]]*9001/DefaultEVMChainID = ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/DefaultEVMChainID[[:space:]]*=[[:space:]]*262144/DefaultEVMChainID = ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/testChainID[[:space:]]*uint64[[:space:]]*=[[:space:]]*9001/testChainID uint64 = ${TARGET_EVM_CHAIN_ID}/g" \
      -e "s/testChainID[[:space:]]*uint64[[:space:]]*=[[:space:]]*262144/testChainID uint64 = ${TARGET_EVM_CHAIN_ID}/g"
find . -name '*.bak' -delete 2>/dev/null || true

# ============================================================
#                      AUDIT PHASE
# ============================================================
# Show any remaining references to defaults that the patches above target.
# A WARNING here means an unknown syntactic form slipped through and the
# resulting binary may still misbehave at runtime.
# ============================================================

LEFTOVERS=0

audit_remaining() {
  local label="$1"
  local pattern="$2"
  local lines
  lines=$(grep -RIn "$pattern" --include='*.go' . 2>/dev/null \
          | grep -v '/vendor/' | grep -v '_test.go' | head -10 || true)
  if [[ -n "$lines" ]]; then
    LEFTOVERS=$((LEFTOVERS + 1))
    echo ""
    echo "⚠ WARNING — $label still appears in non-test, non-vendor Go files:"
    echo "$lines" | sed 's/^/    /'
  fi
}

echo ""
echo ">>> Post-patch audit (any output below is a problem):"

audit_remaining "\"atest\" base denom" '"atest"'
audit_remaining "\`atest\` backtick base denom" '`atest`'
audit_remaining "cosmos_262144 chain ID string" 'cosmos_262144'
audit_remaining "cosmos_9001 chain ID string"   'cosmos_9001'
audit_remaining "big.NewInt(262144) chain ID"   'big\.NewInt(262144)'
audit_remaining "big.NewInt(9001) chain ID"     'big\.NewInt(9001)'
audit_remaining "EVMChainID: 262144 struct lit" 'EVMChainID:[[:space:]]*262144'
audit_remaining "EVMChainID: 9001 struct lit"   'EVMChainID:[[:space:]]*9001'
audit_remaining "SetInt64(262144) constructor"  'SetInt64(262144)'
audit_remaining "SetUint64(262144) constructor" 'SetUint64(262144)'
audit_remaining "uint64(262144) cast"           'uint64(262144)'
audit_remaining "int64(262144) cast"            'int64(262144)'

# The "= 262144" forms that bit us in build #5. These were missed by the
# colon-based EVMChainID pattern because cosmos/evm uses `=` not `:`.
audit_remaining "EVMChainID = 262144 (assignment)"      'EVMChainID[[:space:]]*=[[:space:]]*262144'
audit_remaining "CosmosChainID = 262144 (assignment)"   'CosmosChainID[[:space:]]*=[[:space:]]*262144'
audit_remaining "DefaultEVMChainID = 262144 (assign)"   'DefaultEVMChainID[[:space:]]*=[[:space:]]*262144'
audit_remaining "testChainID uint64 = 262144 (const)"   'testChainID[[:space:]]*uint64[[:space:]]*=[[:space:]]*262144'

# Bech32 sanity. "cosmos" alone is broad, but inside quotes it's almost
# always a bech32 prefix or a chain identifier — both of which we patch.
audit_remaining "leftover \"cosmos\" string" '"cosmos"'

if [[ "$LEFTOVERS" -gt 0 ]]; then
  echo ""
  echo "⚠ $LEFTOVERS audit warning(s) above. The binary will still build,"
  echo "  but the chain may misbehave at runtime. Inspect the lines, add"
  echo "  new sed patterns to scripts/fork-cosmos-evm.sh if the pattern is"
  echo "  unambiguously chain-ID context, and rebuild."
else
  echo ""
  echo "✓ No suspicious chain-ID, bech32, or denom references remain."
fi
echo ""

# ============================================================
#         EVM mempool per-account caps (5k bursts OK)
# ============================================================
# cosmos/evm v0.4.1 constructs its EVM mempool with legacypool.DefaultConfig
# unchanged (mempool/mempool.go:106). That config inherits go-ethereum's
# defaults: AccountSlots=16, AccountQueue=64, GlobalSlots=5120, GlobalQueue=1024.
# A single sender pushing > 64 above its current nonce hits the AccountQueue
# cap and the rest get silently dropped at admit time — eth_sendRawTransaction
# returns a hash but nothing is stored.
#
# These values aren't exposed via app.toml in v0.4.1 (no PR yet), so we sed
# the constants in the legacypool defaults to something usable for a
# burst-y load tester (~5k per account, ~50k global).

LEGACYPOOL="mempool/txpool/legacypool/legacypool.go"
if [[ -f "$LEGACYPOOL" ]]; then
  echo ">>> Hiking EVM mempool per-account caps in $LEGACYPOOL"
  sed -i.bak 's/AccountSlots: *16,/AccountSlots: 5000,/'      "$LEGACYPOOL"
  sed -i.bak 's/AccountQueue: *64,/AccountQueue: 5000,/'      "$LEGACYPOOL"
  sed -i.bak 's/GlobalSlots: *5120,/GlobalSlots: 50000,/'     "$LEGACYPOOL"
  sed -i.bak 's/GlobalQueue: *1024,/GlobalQueue: 50000,/'     "$LEGACYPOOL"
  echo ">>> Verifying patch took effect:"
  grep -E "AccountSlots|AccountQueue|GlobalSlots|GlobalQueue" "$LEGACYPOOL" | head -6
else
  echo "⚠ $LEGACYPOOL not found — cosmos/evm may have restructured the mempool"
  echo "  package. Per-account caps stay at the 16/64 default; burst loads"
  echo "  >64 txs/account will get silently dropped."
fi

# ============================================================
#         EVM mempool GetBlock panic patch (initial sync)
# ============================================================
# cosmos/evm's mempool blockchain.go panics on GetBlock(N) calls under the
# assumption that Cosmos has instant finality and reorgs are impossible.
# That assumption holds at the consensus layer but NOT during legacypool's
# initial reset — which happens on every fresh boot. A node syncing from
# genesis (or from a snapshot before reaching tip) hits this panic at
# block ~1000 and crashes hard.
#
# The panic message in v0.2.0/v0.4.x is verbatim:
#   "GetBlock should never be called on a Cosmos chain due to instant
#    finality - this indicates a reorg is being attempted"
#
# Replace the panic with a "return nil" so the legacypool gracefully
# treats this as "block not found" and moves on. This matches what the
# Ethereum legacypool expects when GetBlock returns nil.
echo ">>> Patching mempool GetBlock panic in blockchain.go"
# Search across both module roots (the mempool may be a sub-module pinned
# at a different version than the parent).
for BC in \
    mempool/blockchain.go \
    mempool/txpool/legacypool/blockchain.go \
    ; do
  if [[ -f "$BC" ]]; then
    if grep -q "GetBlock should never be called" "$BC"; then
      echo "    found in $BC — replacing panic with return nil"
      python3 - "$BC" <<'PY'
import sys, re
p = sys.argv[1]
src = open(p).read()
# Match the GetBlock method body that contains the panic; replace the
# panic statement with a graceful return. The function signature returns
# (*types.Block, error) or similar — returning nil for both is the
# documented "not found" contract for go-ethereum legacypool.
new = re.sub(
    r'panic\("GetBlock should never be called on a Cosmos chain.*?"\)',
    'return nil',
    src,
    flags=re.DOTALL,
)
if new == src:
    print("    WARN: panic line not matched — pattern may have changed")
else:
    open(p, 'w').write(new)
    print("    patched")
PY
    fi
  fi
done
# Same patch via sed as a fallback for boxes without python3 (e.g. some
# minimal Ubuntu Docker stages). The sed version is less precise but
# catches the common case.
for BC in \
    mempool/blockchain.go \
    mempool/txpool/legacypool/blockchain.go \
    ; do
  if [[ -f "$BC" ]] && grep -q "GetBlock should never be called" "$BC"; then
    sed -i.bak 's/panic("GetBlock should never be called.*")/return nil/' "$BC"
  fi
done

# ============================================================
#                      BUILD PHASE
# ============================================================

echo ">>> Compiling (this takes a few minutes the first time)..."
# Try the most common Makefile target first; fall back to `install` if the
# project only ships that target.
if ! make build 2>/dev/null; then
  echo ">>> 'make build' not available, trying 'make install'"
  make install
fi

# The binary's name is `evmd`. It can land in any of several places
# depending on Makefile target and cosmos/evm version. Check the lot.
BIN_SRC=""
GOBIN_DIR="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin"
for candidate in \
    build/evmd \
    build/evmd-linux-amd64 \
    build/evmd-darwin-arm64 \
    "$GOBIN_DIR/evmd" \
    "$HOME/go/bin/evmd" \
    cmd/evmd/evmd \
    evmd/evmd; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then BIN_SRC="$candidate"; break; fi
done
if [[ -z "$BIN_SRC" ]]; then
  echo "ERROR: couldn't find a built evmd binary."
  echo "       Searched: build/evmd, $GOBIN_DIR/evmd, $HOME/go/bin/evmd, cmd/evmd/evmd, evmd/evmd"
  echo "       Inspect $WORK manually:  find $WORK -name evmd -type f -executable"
  exit 1
fi

echo ">>> Installing as $OUT"
install -m 0755 "$BIN_SRC" "$OUT"

echo ">>> Verifying"
"$OUT" version 2>&1 | head -1

echo ">>> Done."
echo
echo "Next: run scripts/localnet.sh to build genesis with sanectd."
