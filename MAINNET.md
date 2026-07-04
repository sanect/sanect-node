# Running a Sanect mainnet node

This guide walks you through running a full node on the sanect mainnet, optionally becoming a validator, and publishing your RPC endpoint publicly.

**Mainnet chain:** `sanect_7628-1` | **EVM chain ID:** `7628` | **Token:** SNCT

---

## Prerequisites

- **Docker** (20.10+) and **Docker Compose** (optional but convenient)
- **Hardware:**
  - CPU: 4+ cores
  - RAM: 16 GB minimum
  - Storage: NVMe SSD mandatory (minimum 200 GB, 500 GB+ recommended for archive nodes)
  - Network: 100 Mbps+
- **Operating system:** Ubuntu 22.04+ recommended (any Linux with Docker works)

NVMe is not optional. ZFS-backed storage and network-attached block storage (AWS EBS, GCP Persistent Disk) cause consensus slowdowns due to fsync contention. Use bare-metal servers or cloud instances with local NVMe drives.

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
docker run -d --name sanect-node \
  -p 8080:8080 \
  -v sanect-data:/data \
  -e JOIN_NETWORK=true \
  -e CHAIN_ID=sanect_7628-1 \
  -e EVM_CHAIN_ID=7628 \
  -e SEED_NODE_URL=https://rpc.sanect.com \
  -e MONIKER=my-sanect-node \
  sanect-node
```

**Environment variables explained:**

| Variable | Required | Description |
|---|---|---|
| `JOIN_NETWORK` | Yes | Set to `true` to join an existing chain (not build a new genesis). |
| `CHAIN_ID` | Yes | Cosmos chain ID. Mainnet: `sanect_7628-1`. |
| `EVM_CHAIN_ID` | Yes | EVM chain ID. Mainnet: `7628`. |
| `SEED_NODE_URL` | Yes | HTTP URL of an existing node to fetch genesis and sync state from. |
| `MONIKER` | Yes | A human-readable name for your node (visible to peers). |
| `SEED_PEER_HOST` | No | Explicit peer address (`host:port`). If omitted, the entrypoint derives peers from the seed node. |
| `EXTERNAL_P2P_ADDRESS` | No | Your node's publicly reachable P2P address (`host:port`). Set this if you want other nodes to connect to you via peer exchange. |
| `SNAPSHOT_MANIFEST_URL` | No | URL to a snapshot manifest for fast-start (see Step 7). |
| `EXPLORER_HEARTBEAT_URL` | No | URL to register your node on the operator dashboard. |

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

A fresh node with no snapshot typically syncs at 100-500 blocks/second. For chains with millions of blocks, use a snapshot (Step 7) to start near the tip.

---

## Step 5: Become a validator (optional)

Once your node is fully synced (`catching_up: false`), you can register as a validator.

### 5a. Get your consensus public key

From the Docker container:

```bash
docker exec sanect-node sanectd cometbft show-validator --home /data/.sanectd
```

This outputs a JSON object like:

```json
{"@type":"/cosmos.crypto.ed25519.PubKey","key":"ABC123..."}
```

### 5b. Fund your wallet

Your validator operator address needs SNCT to self-delegate. The minimum self-delegation on mainnet is **1,000 SNCT** (1,000,000,000,000,000,000,000 asnct).

### 5c. Register via the staking dApp

The easiest way is to use the staking dApp's "Register as Validator" button. Connect your wallet, paste the consensus pubkey from step 5a, set your commission rate and description, and submit.

### 5d. Register via CLI (alternative)

```bash
docker exec sanect-node sanectd tx staking create-validator \
  --amount=1000000000000000000000asnct \
  --pubkey='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"YOUR_KEY_HERE"}' \
  --moniker="my-validator" \
  --commission-rate="0.10" \
  --commission-max-rate="0.20" \
  --commission-max-change-rate="0.01" \
  --min-self-delegation="1000000000000000000000" \
  --chain-id=sanect_7628-1 \
  --from=YOUR_KEY_NAME \
  --home /data/.sanectd \
  --gas=auto \
  --gas-adjustment=1.5
```

### 5e. Verify your validator

```bash
curl -s localhost:8080/rest/cosmos/staking/v1beta1/validators?status=BOND_STATUS_BONDED | jq '.validators[] | .description.moniker'
```

---

## Step 6: Publish your RPC publicly (optional)

To let other users and operators query your node over HTTPS:

```bash
sudo bash scripts/sanect-publish-rpc.sh
```

The wizard offers two options:

1. **Use your own domain** -- handles Caddy + Let's Encrypt automatically.
2. **Get a free community subdomain** -- pick a name, get `https://YOUR-NAME.sanect.org` with no DNS or TLS setup.

Your node appears on the live operator dashboard once the heartbeat is configured.

---

## Step 7: Fast-start with snapshot (optional)

For a chain with many blocks, downloading a snapshot is much faster than syncing from genesis.

Add this environment variable when starting the container:

```bash
-e SNAPSHOT_MANIFEST_URL=https://sanect-snapshots.sanect.com/LATEST.json
```

Or specify a direct snapshot URL:

```bash
-e SNAPSHOT_URL=https://sanect-snapshots.sanect.com/sanect-500000.tar.lz4
```

The entrypoint downloads and extracts the snapshot before starting the node. If the download fails, it falls back to state sync, then to block sync from genesis.

---

## Troubleshooting

### Validator jailed for downtime

If your validator missed too many blocks (>50% in a 10,000-block window, roughly 1 hour), it gets jailed. To unjail:

- **Via dApp:** Use the "Unjail" button on the staking dApp (requires the validator operator wallet).
- **Via CLI:**
  ```bash
  docker exec sanect-node sanectd tx slashing unjail \
    --from=YOUR_KEY_NAME \
    --chain-id=sanect_7628-1 \
    --home /data/.sanectd
  ```

After unjailing, there is a 10-minute cooldown before your validator can be unjailed again.

### Double-sign from duplicated keys

Never copy a node's data volume to create a second node. Each node must run `sanectd init` on a fresh volume to generate a unique `priv_validator_key.json`. Running two nodes with the same consensus key causes CometBFT to detect a double-sign, which results in a **5% stake slash** and permanent tombstoning.

### Slow block times / consensus lag

If you observe block times consistently above 600 ms:

- Verify you are on NVMe storage, not ZFS or network-attached disks.
- Check network latency to other validators (`ping` major peers).
- Ensure no other I/O-heavy workloads share the same disk.

### Node stuck / not syncing

1. Check logs: `docker logs sanect-node --tail 100`
2. Verify the seed node is reachable: `curl -s https://rpc.sanect.com/rpc/status | jq .result.sync_info.latest_block_height`
3. If state sync is stuck, try restarting with a snapshot (Step 7).

---

## Mainnet deployed contracts

### Privacy

| Contract | Address |
|---|---|
| Poseidon2Bn254 | `0xaEE4A735027b86ccbF43042f4C31d1a856943c1C` |
| HonkVerifier | `0x580d7c1Ff04a5761D58a8Db08C37fb33c5e395f2` |
| ShieldedPool v1.4 | `0x5532Dc2B743D45Fd0121E382696521ED62DD3ecf` |

### DEX (Uniswap V2 fork)

| Contract | Address |
|---|---|
| WSNCT | `0x4f35BD61FEd919aA9933C6333e388b3B7E1108Dc` |
| UniswapV2Factory | `0xDF03522CEc5bd2a609863De38da2eEf1267EE0c8` |
| UniswapV2Router02 | `0xBf08497825CFcF04037efD852C9bBd0C9C64d175` |
| MasterChef | `0xa8264E2c8EC09b0251A789860388f70e0Ef563A7` |
| TreasuryEmitter | `0x833E69Fd81f8678C2cFc800277Fe5271fbf680bb` |

### LP incentive pools

| Pool | Pair address | Allocation |
|---|---|---|
| SNCT/USDC | `0xD15DBc1538E9f8Cd137a989DA847134F39fE7b29` | 30% |
| SNCT/USDT | `0xc9fF55Fef97185c7a37117CCef84EddC751e4538` | 30% |
| SNCT/WETH | `0x4aD57b4b3A26b16D5d323c6Cc8Fb9a5487C81562` | 20% |
| SNCT/WBTC | `0x7D2B206077a7ea0D97327e9D0202414E1F33C8fb` | 20% |

### `.snct` name service

| Contract | Address |
|---|---|
| Registry | `0xdC7bB6f4d1c217bd5729a719AFf55de4Cf3EaE23` |
| PublicResolver | `0xA0c101e04581f287836746ec2844831DAc946dff` |
| ReverseRegistrar | `0x6A5e80493281237f678F5f5c64Db42572c20458c` |
| PriceOracle | `0x19bA43C7dd508162221A1324F35c572aB8cBd02C` |
| BaseRegistrar | `0xd45357B67C82311eD3e36DE279599CD84CE15AcA` |
| SealedBidAuction | `0xdAD7EEF74725F0ee71Ef8851A37329D33764Bac0` |
| Marketplace | `0x0b6E3C4bF83097636294c076443feF7b6AC7a34D` |
| Reserved | `0x26e829e6c7d9e78b2dbB88df9Edbe0044776CE6D` |

### Hyperlane bridge

| Contract | Chain | Address |
|---|---|---|
| Mailbox | sanect | `0x2CB7861CC3dA9148763538C75DdCf5772e5c03e1` |
| SanectHypAdapter (collateral) | sanect | `0x4BAfd466B805471065a3F909E6b7acE28Dc68D75` |
| HypERC20Payable (synthetic wSNCT) | Ethereum | `0x2D4d99c44eDc3da75529401FBDcC895De28Dc12d` |

### Bridged ERC-20 assets (Ethereum to sanect)

| Asset | Sanect synthetic | Ethereum adapter |
|---|---|---|
| USDC | `0x1777479878760049ebE06f3c14bF1cc92D8dFE25` | `0x9b3888b9C720810b2E59Cb857e4142b55FE985C7` |
| USDT | `0x3EE14f9B5da94Bb11b3427BB52dC8BaE741bC7D8` | `0x580d7c1Ff04a5761D58a8Db08C37fb33c5e395f2` |
| WBTC | `0xC490A459abA82AA32c942D71d6885893B8f0806E` | `0xDF03522CEc5bd2a609863De38da2eEf1267EE0c8` |
| WETH | `0xD5C6DC458cd43E51191210a629212462a9Bb673D` | `0xa8264E2c8EC09b0251A789860388f70e0Ef563A7` |
| DAI | `0x9F5CA6e038Fa2627aDD422E1C998D9e18454c790` | `0xA0c101e04581f287836746ec2844831DAc946dff` |
| LINK | `0x8Ac3acF4d5bC9ACC2004D94E916F278e9750651e` | `0xddb33806143d1EB6774D7B9414431676Bc3a0f0d` |
| UNI | `0x2EB0C6945239D990d76586979ed65362A32Ff073` | `0x74Eb06DD02AF8052aD3fa69e4915364b3BB0fa9d` |
| AAVE | `0x8c7BDf0e740574a3e45cdA612c394fE526b2F292` | `0xDF6FE5403FD1670f9EE4206DE7FA4797ED403976` |
| MKR | `0xf8480e2287585aB0bdAd9eB77d89FC8a2A20c539` | `0x86148cB18E6A3fe57820c838cD86144850298A3a` |
| COMP | `0xDc156DB3dfDfcB2FD3Ce6574c5BAe7C6cEe0849E` | `0xA8B6f096CE9049713A1Bd82eBBd8999A738703Be` |
| LDO | `0x1fCE2D9921A79670a3BC301ff32Fc117813dC360` | `0xC504D12241ed1562a31e47A741bFFD7F066e303f` |
| SHIB | `0xd86D3290976d5d0A4ffCfbba60Ae02368B1EF5b2` | `0xA2c361924831A3ccf3b0cfb16148725A44202E77` |
| PEPE | `0xC7C502e957F7de5246354cf008C32b1b40fE4604` | `0x076e4B0d2B330351812B82CCa7f79A72bdb4Aa47` |
| CRV | `0x28603b752723665b74a6194eaB7F617be573CD0E` | `0x8df8958019caee0C904D1fA2413E5b11D1bfbD4b` |
