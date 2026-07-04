# sanect-node

Source for **sanect** -- a privacy-first EVM Layer 1.

- **Dual transfer paths:** public (EVM-native) + shielded (Noir zk-SNARKs, custom 2-in/2-out circuit on Aztec's universal Plonk SRS -- no per-circuit ceremony, multi-asset).
- **Consensus:** Cosmos SDK v0.53.4 + CometBFT v0.38.17 + cosmos/evm v0.4.1, DPoS with top-50 active validators.
- **Block time:** ~400 ms.
- **Wallet:** any EVM wallet -- MetaMask, Rabby, Frame, OKX, Coinbase Wallet, Trust, etc. No extra seed phrase, no second wallet.

[sanect.com](https://sanect.com) ·
[docs.sanect.com](https://docs.sanect.com) ·
Mainnet explorer: [scan.sanect.com](https://scan.sanect.com) ·
Testnet explorer: [scan.testnet.sanect.com](https://scan.testnet.sanect.com)

---

## What's in this repo

| Path | Purpose |
|---|---|
| `docker/` | Container that builds and runs the `sanectd` node (Dockerfile, genesis entrypoint, Caddy reverse-proxy front). |
| `scripts/` | Operator tooling -- node bootstrap, snapshot publish/restore, chain verification, public-RPC wizard. |
| `operators/` | Runbooks for validators and RPC operators (Ubuntu bare-metal, multicloud, archive nodes, key management). |
| `privacy/` | Shielded-pool Solidity contracts, Noir circuit source, Poseidon-2 hasher, and Foundry tests. |
| `domainapp/contracts/` | `.snct` name service: registry, resolver, base registrar, sealed-bid auctions, marketplace. |

The hosted explorer, staking dApp, DEX, bridge, airdrop app, docs site, and landing page are not in this repo -- they run on the public infrastructure linked above.

---

## Chain identifiers

| | Testnet | Mainnet |
|---|---|---|
| EVM chain ID | `76287` | `7628` |
| Cosmos chain ID | `sanect_76287-1` | `sanect_7628-1` |
| Bech32 prefix | `snct` | `snct` |
| Token | SNCT (`asnct`, 18 decimals) | SNCT (`asnct`, 18 decimals) |
| RPC | `https://rpc.testnet.sanect.com/` | `https://rpc.sanect.com/` |
| Explorer | `https://scan.testnet.sanect.com` | `https://scan.sanect.com` |

---

## Add to MetaMask

**Mainnet:**

```
Network name:    sanect
RPC URL:         https://rpc.sanect.com/
Chain ID:        7628
Symbol:          SNCT
Block explorer:  https://scan.sanect.com
```

**Testnet:**

```
Network name:    sanect testnet
RPC URL:         https://rpc.testnet.sanect.com/
Chain ID:        76287
Symbol:          SNCT
Block explorer:  https://scan.testnet.sanect.com
```

The staking dApp calls `wallet_addEthereumChain` automatically when your wallet does not know the chain yet -- most users never need to add it by hand.

---

## Quick start -- run a mainnet node

```bash
git clone https://github.com/sanect/sanect-node.git
cd sanect-node

# Build the image (forks cosmos/evm and patches to sanect identifiers)
docker build -t sanect-node docker/

# Run, joining the public mainnet
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

Verify sync status:

```bash
curl -s localhost:8080/rpc/status | jq .result.sync_info
```

For the full mainnet node guide (validator setup, snapshots, RPC publishing, troubleshooting), see **[MAINNET.md](MAINNET.md)**.

---

## Quick start -- run a testnet node

```bash
docker build -t sanect-node docker/

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

Testnet tokens have no real value. A faucet at the staking dApp drips 100 SNCT per address every 24 hours.

For the full testnet node guide, see **[TESTNET.md](TESTNET.md)**.

---

## Privacy module

Custom 2-in/2-out Noir circuit using Aztec's Poseidon-2 BN254 hasher and universal Plonk SRS -- no per-circuit trusted setup, multi-asset via `asset_id` in commitments. Source under `privacy/`. Browser proving is shipped -- circuit artifacts are bundled into the staking dApp.

**Mainnet contracts:**

| Contract | Address |
|---|---|
| Poseidon2Bn254 | `0xaEE4A735027b86ccbF43042f4C31d1a856943c1C` |
| HonkVerifier | `0x580d7c1Ff04a5761D58a8Db08C37fb33c5e395f2` |
| ShieldedPool v1.4 | `0x5532Dc2B743D45Fd0121E382696521ED62DD3ecf` |

**Testnet contracts:**

| Contract | Address |
|---|---|
| Poseidon2Bn254 | `0xE4AdD1a1aA6E9df2037b4285D0E8b052fdB6bB04` |
| HonkVerifier | `0x8fDd518356e570D72f426Bc4d1485d46c60b74Cd` |
| ShieldedPool v1.4 | `0x0571969a9C0554D908387255a30DE5c392AA4b8e` |

Run the Foundry tests:

```bash
cd privacy
forge test
```

External audit is underway before mainnet tokens carry significant value.

---

## DEX (Uniswap V2 fork)

A Uniswap V2 fork deployed on sanect with LP farming via MasterChef. Swap UI at [swap.sanect.com](https://swap.sanect.com).

**Mainnet contracts:**

| Contract | Address |
|---|---|
| WSNCT | `0x4f35BD61FEd919aA9933C6333e388b3B7E1108Dc` |
| UniswapV2Factory | `0xDF03522CEc5bd2a609863De38da2eEf1267EE0c8` |
| UniswapV2Router02 | `0xBf08497825CFcF04037efD852C9bBd0C9C64d175` |
| MasterChef | `0xa8264E2c8EC09b0251A789860388f70e0Ef563A7` |
| TreasuryEmitter | `0x833E69Fd81f8678C2cFc800277Fe5271fbf680bb` |

Four LP incentive pools (SNCT/USDC, SNCT/USDT, SNCT/WETH, SNCT/WBTC) are active with emission rate 0.1 SNCT/block.

---

## `.snct` name service

Public registrar with sealed-bid auctions and a peer-to-peer marketplace. Dashboard at [domain.sanect.com](https://domain.sanect.com) (mainnet) / [domain.testnet.sanect.com](https://domain.testnet.sanect.com) (testnet). Contracts under `domainapp/contracts/`.

**Mainnet contracts:**

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

**Testnet contracts:**

| Contract | Address |
|---|---|
| Registry | `0xF8c4AbD2d2573eBDA51cc886A9b6882E435C80A2` |
| PublicResolver | `0x3CEaEA15a13dB070d6EE41f374B033d77cc89104` |
| BaseRegistrar | `0xb34293056E208aC1FDcD4F9C9e1f6Ffe1440c1dB` |
| SealedBidAuction | `0x483fC2ef9a8bF01a9532c415806bF20A5AE26844` |
| Marketplace | `0x232C6633c0b72C8715321300F6e0221a7Bbb97DD` |

---

## Hyperlane bridge

Sanect is bridged to Ethereum via Hyperlane, with 14 ERC-20 assets available (USDC, USDT, WBTC, WETH, DAI, LINK, UNI, AAVE, MKR, COMP, LDO, SHIB, PEPE, CRV) plus native SNCT.

**Mainnet bridge contracts:**

| Contract | Chain | Address |
|---|---|---|
| SanectHypAdapter (collateral) | sanect | `0x4BAfd466B805471065a3F909E6b7acE28Dc68D75` |
| HypERC20Payable (synthetic wSNCT) | Ethereum | `0x2D4d99c44eDc3da75529401FBDcC895De28Dc12d` |

Each bridged asset has a single canonical synthetic on sanect regardless of source chain. See [MAINNET.md](MAINNET.md) for the full bridged asset address table.

---

## Hardware requirements

Minimum specs for running a validator or full node:

| Resource | Requirement |
|---|---|
| CPU | 4+ cores |
| RAM | 16 GB minimum |
| Storage | NVMe SSD mandatory |
| Network | 100 Mbps+ |

NVMe is not optional. ZFS-backed storage (including most cloud platforms' default volumes) and network-attached EBS cause consensus slowdowns due to fsync contention. Use bare-metal or cloud instances with local NVMe (Vultr High Frequency, Hetzner CCX/SX, etc.).

---

## Contributing

Issues and PRs welcome. For security disclosures, email `contribute@sanect.com` rather than opening a public issue.

---

## License

MIT -- see [LICENSE](LICENSE).
