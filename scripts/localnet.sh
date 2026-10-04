#!/bin/bash
# Sanect v1 testnet genesis builder.
#
# Stack: Cosmos SDK v0.54 + CometBFT v0.39 + cosmos/evm (forked → sanectd).
#
# This script builds genesis for the sanect testnet — chain ID 76287, bech32
# prefix `snct`, 50-validator active set, 100 SNCT min-self-delegation, 1B
# SNCT total supply. Genesis allocates the entire supply to ONE address;
# all other distribution happens post-genesis via the in-app faucet
# (100 SNCT / address / 24h) and on-chain delegations.
#
# Requires: a `sanectd` binary on PATH built from our fork of cosmos/evm.
#           See FORK-COSMOS-EVM.md for the (one-time) build steps.
#           Plus `jq`.
set -euo pipefail

# ----------------------------- Network identity --------------------------
# Testnet defaults. Set NETWORK=mainnet (with VAL_MNEMONIC and CHAIN_ID
# overrides) to build a mainnet genesis instead.
NETWORK="${NETWORK:-testnet}"
if [[ "$NETWORK" == "mainnet" ]]; then
  CHAINID="${CHAIN_ID:-sanect_7628-1}"
  EVM_CHAIN_ID_DEFAULT=7628
  MONIKER="${MONIKER:-sanect-mainnet-node0}"
else
  CHAINID="${CHAIN_ID:-sanect_76287-1}"
  EVM_CHAIN_ID_DEFAULT=76287
  MONIKER="${MONIKER:-sanect-testnet-node0}"
fi

KEYRING="test"
KEYALGO="eth_secp256k1"
LOGLEVEL="${LOGLEVEL:-info}"
HOMEDIR="${HOMEDIR:-$HOME/.sanectd}"

# Token: base denom is 18-decimal (atto) for EVM compatibility.
DENOM="${DENOM:-asnct}"        # base (atto) denom used for gas/stake
DISPLAY="${DISPLAY:-snct}"     # human-facing denom (1 snct = 1e18 asnct)

# Fee market — sanect runs a real fee market with a Cosmos-grade floor of
# 1 gwei (1,000,000,000 asnct per gas). Zero-gas was rejected for v1
# because (a) it leaves no spam protection, (b) gives validators nothing
# to prioritize under load, (c) the UX diverges from mainnet. 1 gwei is
# essentially free for users (a 21k-gas transfer costs ~0.000021 SNCT)
# while spam costs the spammer real coin. To change later, set
# MIN_GAS_PRICE (and BASE_FEE) env vars; mainnet may want 10-100 gwei.
BASEFEE="${BASEFEE:-1000000000}"               # 1 gwei per gas — for gentx and node CLI
BASE_FEE="${BASE_FEE:-1000000000.000000000000000000}"      # 1 gwei — EIP-1559 base fee
MIN_GAS_PRICE="${MIN_GAS_PRICE:-1000000000.000000000000000000}"  # 1 gwei — chain min

# DPoS / performance / safety params (Variant A from the design discussion)
MAX_VALIDATORS=50                              # top-50 by stake become active
MIN_SELF_DELEGATION_BASE="100000000000000000000"  # 100 SNCT in base (100 * 1e18)
TOTAL_SUPPLY_BASE="1000000000000000000000000000" # 1,000,000,000 SNCT in base (1e9 * 1e18)
BLOCK_MAX_GAS=150000000                        # ~2-5k tx/block headroom

# Slashing (tuned for a 50-validator set; downtime less catastrophic per node)
SIGNED_BLOCKS_WINDOW=10000                     # ~1h window at ~400ms blocks
MIN_SIGNED_PER_WINDOW="0.5"
SLASH_FRACTION_DOWNTIME="0.0001"               # 0.01% — Cosmos Hub style
SLASH_FRACTION_DOUBLESIGN="0.05"               # 5% — punish equivocation hard
DOWNTIME_JAIL_DURATION="600s"

# Distribution (incentivize proposers to wait for a complete commit set)
COMMUNITY_TAX="0.02"
BASE_PROPOSER_REWARD="0.01"
BONUS_PROPOSER_REWARD="0.04"

# Mint inflation (Cosmos Hub curve — auto-adjusts to keep bonded ratio at ~67%)
INFLATION_MAX="0.20"
INFLATION_MIN="0.07"
INFLATION_RATE_CHANGE="0.13"
GOAL_BONDED="0.67"
# blocks_per_year MUST match the actual block production rate or annual
# inflation is mis-scaled. Cosmos default (6,311,520) assumes 5s blocks;
# sanect's Variant A target is 400ms, so blocks/year = 31,557,600 / 0.4
# = 78,894,000. Bump this if timeout_commit changes.
BLOCKS_PER_YEAR="78894000"

# Consensus timings — Variant A targets ~400ms blocks at 50 globally-distributed validators.
TIMEOUT_PROPOSE="250ms"
TIMEOUT_PROPOSE_DELTA="50ms"
TIMEOUT_PREVOTE="150ms"
TIMEOUT_PREVOTE_DELTA="50ms"
TIMEOUT_PRECOMMIT="150ms"
TIMEOUT_PRECOMMIT_DELTA="50ms"
TIMEOUT_COMMIT="400ms"

CONFIG_TOML="$HOMEDIR/config/config.toml"
APP_TOML="$HOMEDIR/config/app.toml"
GENESIS="$HOMEDIR/config/genesis.json"
TMP="$HOMEDIR/config/tmp_genesis.json"

command -v sanectd >/dev/null || { echo "sanectd not on PATH — build it via ./scripts/fork-cosmos-evm.sh first (see FORK-COSMOS-EVM.md)"; exit 1; }
command -v jq      >/dev/null || { echo "jq not installed"; exit 1; }

VAL_KEY="validator"

if [ -z "${VAL_MNEMONIC:-}" ]; then
  echo "!! VAL_MNEMONIC env var is required." >&2
  echo "!! Generate a fresh mnemonic offline and set it before running this script." >&2
  echo "!! Example: VAL_MNEMONIC=\"word1 word2 ... word24\" bash scripts/localnet.sh" >&2
  exit 1
fi

echo ">>> Building sanect $NETWORK genesis (chain-id $CHAINID, EVM chain-id $EVM_CHAIN_ID_DEFAULT)"
echo ">>> Resetting chain home at $HOMEDIR"
rm -rf "$HOMEDIR"

sanectd config set client chain-id "$CHAINID" --home "$HOMEDIR"
sanectd config set client keyring-backend "$KEYRING" --home "$HOMEDIR"

echo ">>> Importing genesis address"
echo "$VAL_MNEMONIC" | sanectd keys add "$VAL_KEY" --recover --keyring-backend "$KEYRING" --algo "$KEYALGO" --home "$HOMEDIR"

echo ">>> init"
echo "$VAL_MNEMONIC" | sanectd init "$MONIKER" -o --chain-id "$CHAINID" --home "$HOMEDIR" --recover

# ----------------------------- Genesis params -----------------------------
echo ">>> Staking params: max_validators=$MAX_VALIDATORS, bond_denom=$DENOM, min_self_delegation default applied per-validator at gentx time"
jq --arg d "$DENOM"  '.app_state.staking.params.bond_denom=$d'                "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --argjson n "$MAX_VALIDATORS" '.app_state.staking.params.max_validators=$n' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

echo ">>> Slashing params: window=$SIGNED_BLOCKS_WINDOW, downtime=$SLASH_FRACTION_DOWNTIME, doublesign=$SLASH_FRACTION_DOUBLESIGN"
jq --argjson w "$SIGNED_BLOCKS_WINDOW"          '.app_state.slashing.params.signed_blocks_window=($w|tostring)' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg     m "$MIN_SIGNED_PER_WINDOW"         '.app_state.slashing.params.min_signed_per_window=$m'            "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg     f "$SLASH_FRACTION_DOWNTIME"       '.app_state.slashing.params.slash_fraction_downtime=$f'          "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg     f "$SLASH_FRACTION_DOUBLESIGN"     '.app_state.slashing.params.slash_fraction_double_sign=$f'       "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg     d "$DOWNTIME_JAIL_DURATION"        '.app_state.slashing.params.downtime_jail_duration=$d'           "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

echo ">>> Fee market: base_fee=$BASE_FEE, min_gas_price=$MIN_GAS_PRICE (1 gwei)"
jq --arg v "$BASE_FEE"      '.app_state.feemarket.params.base_fee=$v'      "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg v "$MIN_GAS_PRICE" '.app_state.feemarket.params.min_gas_price=$v' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

echo ">>> Distribution params: community_tax=$COMMUNITY_TAX, base_proposer_reward=$BASE_PROPOSER_REWARD"
jq --arg t "$COMMUNITY_TAX"          '.app_state.distribution.params.community_tax=$t'         "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg t "$BASE_PROPOSER_REWARD"   '.app_state.distribution.params.base_proposer_reward=$t'  "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg t "$BONUS_PROPOSER_REWARD"  '.app_state.distribution.params.bonus_proposer_reward=$t' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

echo ">>> Mint inflation curve: ${INFLATION_MIN}–${INFLATION_MAX}, target bonded=$GOAL_BONDED"
jq --arg d "$DENOM"                  '.app_state.mint.params.mint_denom=$d'                "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg v "$INFLATION_MAX"          '.app_state.mint.params.inflation_max=$v'             "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg v "$INFLATION_MIN"          '.app_state.mint.params.inflation_min=$v'             "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg v "$INFLATION_RATE_CHANGE"  '.app_state.mint.params.inflation_rate_change=$v'     "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg v "$GOAL_BONDED"            '.app_state.mint.params.goal_bonded=$v'               "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg v "$BLOCKS_PER_YEAR"        '.app_state.mint.params.blocks_per_year=$v'           "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

echo ">>> Gov / evm denoms = $DENOM"
jq --arg d "$DENOM" '.app_state.gov.params.min_deposit[0].denom=$d'           "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg d "$DENOM" '.app_state.gov.params.expedited_min_deposit[0].denom=$d' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq --arg d "$DENOM" '.app_state.evm.params.evm_denom=$d'                      "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

# NOTE: cosmos/evm v0.4.1's evm module Params struct has NO chain_id /
# evm_chain_id / eth_chain_id fields. Adding any of them to genesis causes
# the chain to panic at InitChain with "unknown field in types.Params".
# The EVM chain ID is therefore NOT in genesis — it lives in app.toml
# (`evm-chain-id` under `[evm]`) and the binary reads it from there at
# startup. docker/entrypoint.sh writes it on every boot.

jq --arg d "$DENOM" --arg disp "$DISPLAY" \
  '.app_state.bank.denom_metadata=[{"description":"Sanect privacy-first L1 staking and gas token","denom_units":[{"denom":$d,"exponent":0},{"denom":$disp,"exponent":18}],"base":$d,"display":$disp,"name":"Sanect","symbol":($disp|ascii_upcase)}]' \
  "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

# Register SNCT as a native ERC-20 at the canonical 0xEeee... address.
echo ">>> Registering SNCT as native ERC-20 at the canonical address"
jq --arg d "$DENOM" '.app_state.erc20.token_pairs=[{"contract_owner":1,"erc20_address":"0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE","denom":$d,"enabled":true}]' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
jq '.app_state.erc20.native_precompiles=["0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"]' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

# Activate cosmos/evm static precompiles so staking/distribution/gov/etc. calls work.
echo ">>> Activating static precompiles"
jq '.app_state.evm.params.active_static_precompiles=[
  "0x0000000000000000000000000000000000000100",
  "0x0000000000000000000000000000000000000400",
  "0x0000000000000000000000000000000000000800",
  "0x0000000000000000000000000000000000000801",
  "0x0000000000000000000000000000000000000802",
  "0x0000000000000000000000000000000000000803",
  "0x0000000000000000000000000000000000000804",
  "0x0000000000000000000000000000000000000805",
  "0x0000000000000000000000000000000000000806",
  "0x0000000000000000000000000000000000000807"
]' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

echo ">>> block max_gas=$BLOCK_MAX_GAS"
jq --arg g "$BLOCK_MAX_GAS" '.consensus.params.block.max_gas=$g' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"

# Governance periods and deposits.
# The SDK defaults are 2d voting / 2d deposit / 10,000,000 base units — sized
# for 6-decimal tokens. With 18-decimal asnct that deposit is ~1e-11 SNCT, so
# mainnet MUST set explicit values (the 2026-06-22 genesis missed this; fixed
# on chain via MsgUpdateParams — see scripts/mainnet/gov-params-update.md).
if [[ "$NETWORK" == "mainnet" ]]; then
  jq '.app_state.gov.params.max_deposit_period="1209600s"'                     "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"   # 14 days
  jq '.app_state.gov.params.voting_period="1209600s"'                          "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"   # 14 days
  jq '.app_state.gov.params.expedited_voting_period="86400s"'                  "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"   # 1 day
  jq '.app_state.gov.params.min_deposit[0].amount="10000000000000000000000"'   "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"   # 10,000 SNCT
  jq '.app_state.gov.params.expedited_min_deposit[0].amount="50000000000000000000000"' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"   # 50,000 SNCT
else
  # Faster governance for testnet.
  jq '.app_state.gov.params.max_deposit_period="30s"'     "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
  jq '.app_state.gov.params.voting_period="60s"'          "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
  jq '.app_state.gov.params.expedited_voting_period="30s"' "$GENESIS" >"$TMP" && mv "$TMP" "$GENESIS"
fi

# ----------------------------- Fund the genesis address ------------------
# VAL_KEY_GENESIS_AMOUNT (set by entrypoint.sh) is the validator key's share
# after subtracting treasury + foundation. Falls back to full supply for
# standalone localnet.sh usage (no treasury/foundation split).
VAL_GENESIS="${VAL_KEY_GENESIS_AMOUNT:-$TOTAL_SUPPLY_BASE}"
echo ">>> Funding genesis address with $VAL_GENESIS $DENOM"
sanectd genesis add-genesis-account "$VAL_KEY" "${VAL_GENESIS}${DENOM}" --keyring-backend "$KEYRING" --home "$HOMEDIR"

# ----------------------------- Consensus timing --------------------------
echo ">>> Tuning CometBFT for ~400ms blocks (Variant A: 50 validators globally)"
sed -i.bak "s/timeout_propose = \"3s\"/timeout_propose = \"$TIMEOUT_PROPOSE\"/g"                       "$CONFIG_TOML"
sed -i.bak "s/timeout_propose_delta = \"500ms\"/timeout_propose_delta = \"$TIMEOUT_PROPOSE_DELTA\"/g" "$CONFIG_TOML"
sed -i.bak "s/timeout_prevote = \"1s\"/timeout_prevote = \"$TIMEOUT_PREVOTE\"/g"                     "$CONFIG_TOML"
sed -i.bak "s/timeout_prevote_delta = \"500ms\"/timeout_prevote_delta = \"$TIMEOUT_PREVOTE_DELTA\"/g" "$CONFIG_TOML"
sed -i.bak "s/timeout_precommit = \"1s\"/timeout_precommit = \"$TIMEOUT_PRECOMMIT\"/g"               "$CONFIG_TOML"
sed -i.bak "s/timeout_precommit_delta = \"500ms\"/timeout_precommit_delta = \"$TIMEOUT_PRECOMMIT_DELTA\"/g" "$CONFIG_TOML"
sed -i.bak "s/timeout_commit = \"5s\"/timeout_commit = \"$TIMEOUT_COMMIT\"/g"                        "$CONFIG_TOML"

# mempool.type = "flood" — see entrypoint.sh for rationale. Default
# CometBFT mempool: gossips, accepts broadcast_tx, works on every
# 0.38.x version. cosmos/evm's EVM legacypool runs at the app layer
# in PrepareProposal; CometBFT just handles gossip + RPC submissions.
sed -i.bak 's/^type = "nop"/type = "flood"/' "$CONFIG_TOML"
sed -i.bak 's/^type = "app"/type = "flood"/' "$CONFIG_TOML"

# Prometheus + APIs
sed -i.bak 's/prometheus = false/prometheus = true/' "$CONFIG_TOML"
sed -i.bak 's/^enable = false/enable = true/g' "$APP_TOML"
sed -i.bak 's/^enabled = false/enabled = true/g' "$APP_TOML"

# ----------------------------- Gentx (genesis self-delegation) -----------
# 1000 SNCT self-bond. The single genesis address bonds 1000 to itself so the
# chain has a starting validator; you'll register the other 6 seed validators
# right after launch by distributing some of the genesis balance.
GENTX_AMOUNT="1000000000000000000000"   # 1000 SNCT
echo ">>> Creating genesis validator (self-bond $GENTX_AMOUNT $DENOM, min-self-delegation $MIN_SELF_DELEGATION_BASE)"
sanectd genesis gentx "$VAL_KEY" "${GENTX_AMOUNT}${DENOM}" \
  --moniker "$MONIKER" \
  --min-self-delegation "$MIN_SELF_DELEGATION_BASE" \
  --gas-prices "${BASEFEE}${DENOM}" \
  --keyring-backend "$KEYRING" \
  --chain-id "$CHAINID" \
  --home "$HOMEDIR"
sanectd genesis collect-gentxs --home "$HOMEDIR"
sanectd genesis validate-genesis --home "$HOMEDIR"

if [[ "${SETUP_ONLY:-false}" == "true" ]]; then
  echo ">>> SETUP_ONLY=true — genesis ready at $HOMEDIR, not starting node."
  exit 0
fi

echo ">>> Starting node (EVM JSON-RPC on :8545, Cosmos RPC on :26657)"
sanectd start \
  --pruning nothing \
  --log_level "$LOGLEVEL" \
  --minimum-gas-prices="${BASEFEE}${DENOM}" \
  --json-rpc.api eth,txpool,personal,net,debug,web3 \
  --home "$HOMEDIR" \
  --chain-id "$CHAINID"
