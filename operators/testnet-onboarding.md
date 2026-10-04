# Testnet onboarding — env-var deltas

The runbooks in this directory (`archive-node.md`, `runbook.md`,
`ubuntu-bare-metal.md`, `multicloud-deploy.md`, `chain-icon-listing.md`)
default to **mainnet** values now that mainnet is live.

To join **testnet** instead, swap the values below into whichever
runbook you're following. Everything else (Docker image, ports,
entrypoint behavior, dashboard registration) is identical.

---

## Chain identity

| Mainnet (runbook default) | Testnet (substitute) |
|---|---|
| `CHAIN_ID=sanect_7628-1`  | `CHAIN_ID=sanect_76287-1` |
| `EVM_CHAIN_ID=7628`        | `EVM_CHAIN_ID=76287` |
| `TARGET_EVM_CHAIN_ID=7628` (Docker build arg) | `TARGET_EVM_CHAIN_ID=76287` |

## Public endpoints

| Mainnet | Testnet |
|---|---|
| `rpc.sanect.com`            | `rpc.testnet.sanect.com` |
| `p2p.sanect.com:<port>`     | `p2p.testnet.sanect.com:46430` |
| `scan.sanect.com`           | `scan.testnet.sanect.com` |
| `app.sanect.com`            | `app.testnet.sanect.com` |
| `archive.sanect.com`        | `archive.testnet.sanect.com` |
| `snapshots.sanect.com`      | `sanect-snapshots.testnet.sanect.com` |
| *(no mainnet faucet)*       | `faucet.testnet.sanect.com` |

## Free operator subdomain

| Mainnet | Testnet |
|---|---|
| `sanect.org` (per-operator alias) | `testnet.sanect.org` (per-operator alias) |

Subdomain claim flow (`scripts/sanect-publish-rpc.sh`) reads the
`NETWORK` env var to pick the right parent zone — no change to the
script invocation.

---

## Joining testnet — quick recap

Once you've swapped the values above into the runbook you're using:

```env
NETWORK=testnet
CHAIN_ID=sanect_76287-1
EVM_CHAIN_ID=76287
HOMEDIR=/data/.sanectd

JOIN_NETWORK=true
SEED_NODE_URL=https://rpc.testnet.sanect.com
SEED_NODE_ID=<from: curl -s https://rpc.testnet.sanect.com/rpc/status | jq -r .result.node_info.id>
SEED_PEER_HOST=p2p.testnet.sanect.com:46430
SNAPSHOT_MANIFEST_URL=https://sanect-snapshots.testnet.sanect.com/LATEST.json

EXPLORER_HEARTBEAT_URL=https://scan.testnet.sanect.com/api/network/heartbeat
```

Docker build (only required if rebuilding the image yourself):

```bash
docker build --build-arg TARGET_EVM_CHAIN_ID=76287 -t sanectd:testnet docker/
```

If you're using the prebuilt mainnet image, you DO need to rebuild —
the EVM chain id is baked at compile time by
`scripts/fork-cosmos-evm.sh`. Same Dockerfile, just override the
`TARGET_EVM_CHAIN_ID` build arg.

---

## Chain-icon listing

For `ethereum-lists/chains` PRs, replace `eip155-7628.json` with
`eip155-76287.json` and use the testnet endpoint set above
(rpc/explorer/faucet URLs). Keep the file under `_data/chains/` either
way.

---

## When in doubt

`CLAUDE.md` is the source of truth for both networks' live contract
addresses, validator topology, and current ops state. Read its top
section first if anything in these runbooks looks stale.
