# Running a Sanect testnet node

This guide walks you through running a full node on the sanect testnet, optionally becoming a validator, and publishing your RPC endpoint publicly. Testnet tokens have no real value.

**Testnet chain:** `sanect_76287-1` | **EVM chain ID:** `76287` | **Token:** SNCT (testnet)

---

## Prerequisites

- **Docker** (20.10+) and **Docker Compose** (optional but convenient)
- **Hardware:**
  - CPU: 4+ cores
  - RAM: 16 GB minimum (8 GB may work for testnet-only use)
  - Storage: NVMe SSD recommended (100 GB minimum)
  - Network: 100 Mbps+
- **Operating system:** Ubuntu 22.04+ recommended (any Linux with Docker works)

Testnet is more forgiving than mainnet on hardware -- you can run on ZFS or cloud block storage, but block times may be higher than the ~400 ms target.

---

## Step 1: Clone the repo

```bash
git clone https://github.com/sanect/sanect-node.git
cd sanect-node
```

---

## Step 2: Build the Docker image

```bash
docker build -t sanect-node docker/
```

This builds the `sanectd` binary by forking [cosmos/evm](https://github.com/cosmos/evm) v0.4.1 and patching it with sanect's chain identifiers. The build takes 5-10 minutes on first run.

---

## Step 3: Run a full node

```bash
docker run -d --name sanect-testnet \
  -p 8080:8080 \
  -v sanect-testnet-data:/data \
  -e JOIN_NETWORK=true \
  -e CHAIN_ID=sanect_76287-1 \
  -e EVM_CHAIN_ID=76287 \
  -e SEED_NODE_URL=https://rpc.testnet.sanect.com \
  -e SEED_PEER_HOST=p2p.testnet.sanect.com:46430 \
  -e MONIKER=my-testnet-node \
  -e SNAPSHOT_MANIFEST_URL=https://sanect-snapshots.testnet.sanect.com/LATEST.json \
  sanect-node
```

**Environment variables explained:**

| Variable | Required | Description |
|---|---|---|
| `JOIN_NETWORK` | Yes | Set to `true` to join an existing chain (not build a new genesis). |
| `CHAIN_ID` | Yes | Cosmos chain ID. Testnet: `sanect_76287-1`. |
| `EVM_CHAIN_ID` | Yes | EVM chain ID. Testnet: `76287`. |
| `SEED_NODE_URL` | Yes | HTTP URL of an existing node to fetch genesis and sync state from. |
| `SEED_PEER_HOST` | Recommended | Explicit peer address. Testnet: `p2p.testnet.sanect.com:46430`. |
| `MONIKER` | Yes | A human-readable name for your node (visible to peers). |
| `SNAPSHOT_MANIFEST_URL` | Recommended | URL to a snapshot manifest for fast-start. Testnet: `https://sanect-snapshots.testnet.sanect.com/LATEST.json`. |
| `EXTERNAL_P2P_ADDRESS` | No | Your node's publicly reachable P2P address (`host:port`). Set this if you want other nodes to discover you via peer exchange. |
| `EXPLORER_HEARTBEAT_URL` | No | URL to register your node on the testnet operator dashboard. Set to `https://scan.testnet.sanect.com/api/network/heartbeat`. |

**Port 8080** is a Caddy reverse proxy that serves all endpoints:

| Path | Protocol | Description |
|---|---|---|
| `/` | EVM JSON-RPC | What MetaMask and ethers.js connect to. |
| `/rpc` | CometBFT RPC | Cosmos-side RPC (status, validators, tx search). |
| `/rest` | Cosmos REST | REST queries (staking, bank, gov, distribution). |
| `/ws` | WebSocket | EVM subscription endpoint. |

---

## Step 4: Verify sync status

```bash
curl -s localhost:8080/rpc/status | jq .result.sync_info
```

Key fields:
- `catching_up`: `true` while syncing, `false` when at chain tip.
- `latest_block_height`: current block your node has processed.
- `latest_block_time`: timestamp of the latest block.

With the snapshot URL set, the node downloads a recent state snapshot and only needs to sync the last few thousand blocks, which typically takes 1-5 minutes.

---

## Step 5: Get testnet SNCT

The staking dApp includes a faucet that drips **100 SNCT per address every 24 hours**. Connect your MetaMask wallet to the staking dApp and click the faucet button.

You can also request testnet SNCT from the team on Telegram (`@sanectnetwork`) or Discord.

---

## Step 6: Become a validator (optional)

Once your node is fully synced (`catching_up: false`), you can register as a validator.

### 6a. Get your consensus public key

```bash
docker exec sanect-testnet sanectd cometbft show-validator --home /data/.sanectd
```

This outputs a JSON object like:

```json
{"@type":"/cosmos.crypto.ed25519.PubKey","key":"ABC123..."}
```

### 6b. Fund your wallet

The minimum self-delegation on testnet is **100 SNCT** (100,000,000,000,000,000,000 asnct). Use the faucet to get your first 100 SNCT if needed.

### 6c. Register via the staking dApp

The easiest way is to use the staking dApp's "Register as Validator" button. Connect your wallet, paste the consensus pubkey from step 6a, set your commission rate and description, and submit.

### 6d. Register via CLI (alternative)

```bash
docker exec sanect-testnet sanectd tx staking create-validator \
  --amount=100000000000000000000asnct \
  --pubkey='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"YOUR_KEY_HERE"}' \
  --moniker="my-testnet-validator" \
  --commission-rate="0.10" \
  --commission-max-rate="0.20" \
  --commission-max-change-rate="0.01" \
  --min-self-delegation="100000000000000000000" \
  --chain-id=sanect_76287-1 \
  --from=YOUR_KEY_NAME \
  --home /data/.sanectd \
  --gas=auto \
  --gas-adjustment=1.5
```

---

## Step 7: Publish your RPC publicly (optional)

To let other users and operators query your node over HTTPS:

```bash
sudo bash scripts/sanect-publish-rpc.sh
```

The wizard offers two options:

1. **Use your own domain** -- handles Caddy + Let's Encrypt automatically.
2. **Get a free community subdomain** -- pick a name, get `https://YOUR-NAME.testnet.sanect.org` with no DNS or TLS setup on your end.

Your node appears on the live operator dashboard at:
[scan.testnet.sanect.com/network/nodes](https://scan.testnet.sanect.com/network/nodes)

---

## Troubleshooting

### Validator jailed for downtime

If your validator missed too many blocks (>50% in a 10,000-block window, roughly 1 hour), it gets jailed. To unjail:

- **Via dApp:** Use the "Unjail" button on the staking dApp (requires the validator operator wallet).
- **Via CLI:**
  ```bash
  docker exec sanect-testnet sanectd tx slashing unjail \
    --from=YOUR_KEY_NAME \
    --chain-id=sanect_76287-1 \
    --home /data/.sanectd
  ```

After unjailing, there is a 10-minute cooldown before your validator can be unjailed again.

### Double-sign from duplicated keys

Never copy a node's data volume to create a second node. Each node must run `sanectd init` on a fresh volume to generate a unique `priv_validator_key.json`. Running two nodes with the same consensus key causes CometBFT to detect a double-sign, resulting in a 5% stake slash.

### Node not finding peers

Verify the seed peer is reachable:

```bash
nc -zv p2p.testnet.sanect.com 46430
```

If it cannot connect, check:
- Your firewall allows outbound TCP on port 46430.
- DNS resolves correctly (`dig p2p.testnet.sanect.com`).

### Snapshot download fails

If the snapshot URL is unreachable or the download is interrupted, the entrypoint automatically falls back to state sync, then to block sync from genesis. No manual intervention is needed -- just wait longer for the sync to complete.

---

## Testnet deployed contracts

### Privacy

| Contract | Address |
|---|---|
| Poseidon2Bn254 | `0xE4AdD1a1aA6E9df2037b4285D0E8b052fdB6bB04` |
| HonkVerifier | `0x8fDd518356e570D72f426Bc4d1485d46c60b74Cd` |
| ShieldedPool v1.4 | `0x0571969a9C0554D908387255a30DE5c392AA4b8e` |

### DEX (Uniswap V2 fork)

| Contract | Address |
|---|---|
| WSNCT | `0xC09473C15BE5A4B9D1a587a45dC8EF46F6872935` |
| UniswapV2Factory | `0x5740B613CC08a8ED765a898E82AA62E49137b5F8` |
| UniswapV2Router02 | `0x0F5575BC344f6F0b595A7B3a0bDEdE9a90859c6f` |
| MasterChef | `0x59A0b9c948D23c91e6313562603bC7586dA64B29` |
| TreasuryEmitter | `0x850320963ee99EA635bf6Fb7C4D345410bfEe44B` |

### `.snct` name service

| Contract | Address |
|---|---|
| Registry | `0xF8c4AbD2d2573eBDA51cc886A9b6882E435C80A2` |
| PublicResolver | `0x3CEaEA15a13dB070d6EE41f374B033d77cc89104` |
| ReverseRegistrar | `0xb1B3bd91bC919C5e29e420f841360D9D3Df399A8` |
| PriceOracle | `0xA4F9381317159e415B4Ad8d2D5cBb749834CE686` |
| BaseRegistrar | `0xb34293056E208aC1FDcD4F9C9e1f6Ffe1440c1dB` |
| SealedBidAuction | `0x483fC2ef9a8bF01a9532c415806bF20A5AE26844` |
| Marketplace | `0x232C6633c0b72C8715321300F6e0221a7Bbb97DD` |

### Hyperlane bridge (sanect to Sepolia)

| Contract | Chain | Address |
|---|---|---|
| Mailbox | sanect testnet | `0x17Af7329E8BB9DB890628F501786cF24c9f2Db1a` |
| SanectHypAdapter | sanect testnet | `0x6FEc13AbD70674eD3A2d01752E7f9Da0fe1DC900` |
| HypERC20Payable (synthetic wSNCT) | Sepolia | `0x22E2D99BE12eA2837726E744eE7a32bC05c5e9dC` |

### Test ERC-20 tokens

Testnet includes mintable test tokens for the DEX UI. Each has a public `mint(address, uint256)` function.

| Token | Decimals | Address |
|---|---|---|
| TUSD | 6 | `0x2EFF1A121d8f407C57Ad290c1E87ab28c5Eda89E` |
| TUSDC | 6 | `0x9628552AB51DfE3843e08E44C89104702de1615D` |
| TWBTC | 8 | `0x8E9953129857155C3946585C86771ce53B0025e1` |
| TWETH | 18 | `0x07973e5Ed46b28E542a81F4D85a727b97f07DC9A` |

---

## Add testnet to MetaMask

```
Network name:    sanect testnet
RPC URL:         https://rpc.testnet.sanect.com/
Chain ID:        76287
Symbol:          SNCT
Block explorer:  https://scan.testnet.sanect.com
```

The staking dApp calls `wallet_addEthereumChain` automatically when your wallet does not know the chain.

---

## Useful links

- Testnet explorer: [scan.testnet.sanect.com](https://scan.testnet.sanect.com)
- Staking dApp (with faucet): [app.testnet.sanect.com](https://app.testnet.sanect.com)
- DEX: [swap.testnet.sanect.com](https://swap.testnet.sanect.com)
- `.snct` names: [domain.testnet.sanect.com](https://domain.testnet.sanect.com)
- Operator dashboard: [scan.testnet.sanect.com/network/nodes](https://scan.testnet.sanect.com/network/nodes)
- Documentation: [docs.sanect.com](https://docs.sanect.com)
