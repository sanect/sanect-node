#!/usr/bin/env bash
# After a fresh deploy, run this to confirm everything is wired up correctly.
# Hits the public node's EVM RPC + REST. Pass NODE_URL=... to override.

set -u
NODE_URL="${NODE_URL:-https://privacy-layer1-production.up.railway.app}"
RPC="$NODE_URL"
REST="$NODE_URL/rest"

PVT_ADDR="0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"
STAKING_ADDR="0x0000000000000000000000000000000000000800"

fail=0
pass=0
warn=0

ok()   { printf "  \033[32m✓\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31m✗\033[0m  %s\n" "$1"; fail=$((fail+1)); }
note() { printf "  \033[33m!\033[0m  %s\n" "$1"; warn=$((warn+1)); }

eth() {
  curl -sS --max-time 15 -X POST "$RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}"
}

# Sanity-check dependencies — verbose so Windows / Git Bash users see what's missing.
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not installed (or not on PATH)"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq not installed. Install:  https://jqlang.org/download/"; exit 2; }

echo "================================================================"
echo "  sanect verification — node: $NODE_URL"
echo "================================================================"

echo
echo "▸ Connectivity"
# 15s timeout: Windows TLS handshakes can be slow over residential ISPs.
REST_BODY=$(curl -sS --max-time 15 "$REST/cosmos/base/tendermint/v1beta1/blocks/latest" 2>&1)
H=$(echo "$REST_BODY" | jq -r '.block.header.height // empty' 2>/dev/null)
if [ -n "$H" ]; then
  ok "REST reachable, latest block: $H"
else
  bad "REST not reachable. Response was: ${REST_BODY:0:200}"
  exit 1
fi
CHAINID=$(eth eth_chainId "[]" | jq -r .result)
# 76287 (testnet) → 0x129ef ; 7628 (mainnet) → 0x1dcc.
EXPECTED_CHAINID="${EXPECTED_CHAINID:-0x129ef}"
[ "$CHAINID" = "$EXPECTED_CHAINID" ] && ok "EVM chain id $CHAINID" || bad "Wrong EVM chain id: $CHAINID (expected $EXPECTED_CHAINID — override with EXPECTED_CHAINID env)"

echo
echo "▸ SNCT ERC-20 precompile @ $PVT_ADDR"
# decimals() = 0x313ce567
DEC=$(eth eth_call "[{\"to\":\"$PVT_ADDR\",\"data\":\"0x313ce567\"},\"latest\"]" | jq -r .result)
case "$DEC" in
  0x000*000012) ok "decimals() = 18" ;;
  0x|""|null) bad "decimals() returned empty — token_pairs / native_precompiles not in genesis";;
  *) bad "decimals() unexpected: $DEC" ;;
esac
# symbol() = 0x95d89b41 ; expect "SNCT" (hex: 53='S', 4E='N', 43='C', 54='T')
SYM=$(eth eth_call "[{\"to\":\"$PVT_ADDR\",\"data\":\"0x95d89b41\"},\"latest\"]" | jq -r .result)
[[ "$SYM" == *534E4354* ]] && ok "symbol() = SNCT" || bad "symbol() unexpected: ${SYM:0:80}"

echo
echo "▸ cosmos/evm static precompiles (must be in active_static_precompiles)"
for addr in $STAKING_ADDR \
            0x0000000000000000000000000000000000000801 \
            0x0000000000000000000000000000000000000804 \
            0x0000000000000000000000000000000000000805 \
            0x0000000000000000000000000000000000000806 ; do
  # invalid selector -> alive precompile reverts with "no method with id"
  R=$(eth eth_call "[{\"to\":\"$addr\",\"data\":\"0xdeadbeef\"},\"latest\"]")
  if echo "$R" | grep -q "no method with id"; then
    ok "$addr alive"
  elif echo "$R" | jq -e '.result == "0x"' >/dev/null 2>&1; then
    bad "$addr inactive (returned empty — add it to evm.params.active_static_precompiles)"
  else
    note "$addr unexpected response: $(echo "$R" | head -c 80)"
  fi
done

echo
echo "▸ Chain params"
VALS=$(curl -s "$REST/cosmos/staking/v1beta1/validators?status=BOND_STATUS_BONDED" | jq -r '.validators | length')
MAX=$(curl -s "$REST/cosmos/staking/v1beta1/params" | jq -r .params.max_validators)
EXPECTED_MAX="${EXPECTED_MAX:-50}"
[ "$MAX" = "$EXPECTED_MAX" ] && ok "max_validators = $MAX" || bad "max_validators = $MAX (expected $EXPECTED_MAX)"
ok "active validators in the bonded set: $VALS"
BOND_DENOM=$(curl -s "$REST/cosmos/staking/v1beta1/params" | jq -r .params.bond_denom)
[ "$BOND_DENOM" = "asnct" ] && ok "bond_denom = asnct" || bad "bond_denom = $BOND_DENOM"

# --- ShieldedPool / verifier sanity ---------------------------------------
# Skipped when SHIELDED_POOL is unset (chain may not have a pool deployed yet).
# When set, refuse to green-light a deploy whose pool still points at the
# Phase 0 MockVerifier — that contract approves every proof and would let
# anyone drain the pool.
if [ -n "${SHIELDED_POOL:-}" ]; then
  echo
  echo "▸ Shielded pool @ $SHIELDED_POOL"

  # verifier() selector = 0x2b7ac3f3 (no args, returns address)
  V_RAW=$(eth eth_call "[{\"to\":\"$SHIELDED_POOL\",\"data\":\"0x2b7ac3f3\"},\"latest\"]" | jq -r .result)
  if [ -z "$V_RAW" ] || [ "$V_RAW" = "null" ] || [ "$V_RAW" = "0x" ]; then
    bad "pool.verifier() call returned empty — is SHIELDED_POOL correct?"
  else
    # Last 40 hex chars of the 32-byte return == the address.
    V_ADDR="0x${V_RAW: -40}"
    ok "pool.verifier() = $V_ADDR"

    if [ -n "${EXPECTED_VERIFIER:-}" ]; then
      # Lowercase compare.
      EXP_LC=$(echo "$EXPECTED_VERIFIER" | tr 'A-F' 'a-f')
      GOT_LC=$(echo "$V_ADDR"            | tr 'A-F' 'a-f')
      [ "$EXP_LC" = "$GOT_LC" ] \
        && ok "verifier matches EXPECTED_VERIFIER" \
        || bad "verifier mismatch — expected $EXPECTED_VERIFIER, got $V_ADDR"
    fi

    if [ -n "${MOCK_VERIFIER:-}" ]; then
      MOCK_LC=$(echo "$MOCK_VERIFIER" | tr 'A-F' 'a-f')
      GOT_LC=$(echo "$V_ADDR"         | tr 'A-F' 'a-f')
      if [ "$MOCK_LC" = "$GOT_LC" ]; then
        bad "pool.verifier() is MockVerifier — DO NOT USE THIS POOL"
      else
        ok "verifier is NOT the MockVerifier"
      fi
    fi
  fi
fi
# -------------------------------------------------------------------------

echo
echo "================================================================"
echo "  pass: $pass    fail: $fail    warn: $warn"
[ $fail -eq 0 ] && echo "  CHAIN IS GOOD — go ahead and deploy / use the staking app."
[ $fail -gt 0 ] && echo "  Failures detected — fix before relying on this chain."
echo "================================================================"

exit $fail
