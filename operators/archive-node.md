# Archive node setup (Sanect)

> **Network:** This runbook targets **mainnet** (chain id 7628). For testnet (chain id 76287) substitute the values in [`testnet-onboarding.md`](./testnet-onboarding.md) — everything else is identical.


A standard sanectd validator/RPC node prunes state after 100,000 blocks
(~11 hours at 400ms blocks), which means `debug_traceTransaction`,
`debug_traceCall`, and `eth_call` against historical state only work for
the last 11 hours. For full historical tracing (block 0 to tip), you
need a dedicated archive node.

## Cost vs benefit

| Resource | Validator / RPC | Archive |
|---|---|---|
| Disk after 1 year | ~30 GB | ~500 GB – 2 TB |
| RAM | 4 GB | 16+ GB |
| CPU | 2 vCPU | 4+ vCPU |
| Catch-up sync from genesis | Hours | Days (no state pruning) |

Run an archive node when you need:

- Historical `debug_traceTransaction` from any block
- Stateful `eth_call` against a past block height
- Tracing tools (Tenderly, Phalcon, internal audits)

Skip it if you only need recent traces — the explorer's existing
`--pruning-keep-recent 100000` covers recent activity.

## Railway deployment

The same container image runs in archive mode by overriding two env
vars. Create a new Railway service in the same project:

```env
JOIN_NETWORK=true
CHAIN_ID=sanect_7628-1
EVM_CHAIN_ID=7628
HOMEDIR=/data/.sanectd
MONIKER=sanect-archive

# Peering — identical to a normal joiner
SEED_NODE_URL=https://rpc.sanect.com
SEED_NODE_ID=<from /rpc/status>
SEED_PEER_HOST=p2p.sanect.com:46430
SNAPSHOT_MANIFEST_URL=https://snapshots.sanect.com/LATEST.json

# Archive-specific:
PRUNING=nothing
PRUNING_KEEP_RECENT=
PRUNING_INTERVAL=

PORT=8080
```

`PRUNING=nothing` keeps every state root forever. The entrypoint passes
this through to `sanectd start --pruning $PRUNING`.

Mount a **persistent disk ≥ 500 GB** at `/data`. Railway's default
volume size is small — bump it explicitly in the service settings
before first deploy.

Public custom domain: `archive.sanect.com` → Railway URL.

## Wire the explorer at the archive node

After the archive is synced, point the explorer backend at it for
tracing requests. Add to the explorer-backend Railway service:

```env
NODE_URL=https://archive.sanect.com
```

The existing `provider` in `explorer/backend/src/indexer.ts` and the
trace module will then hit the archive node for every `debug_*` call.
Indexing keeps working because it only uses `eth_getBlockByNumber` and
`eth_getTransactionReceipt`, which work on both pruning and archive
nodes — the archive node just makes the older blocks queryable.

## Bare-metal alternative

If you'd rather self-host:

```bash
# Same Docker image, different start flags:
docker run -d \
  --name sanect-archive \
  --restart unless-stopped \
  -v /data-archive:/data \
  -p 26656:26656 \
  -p 127.0.0.1:8080:8080 \
  -e CHAIN_ID=sanect_7628-1 \
  -e EVM_CHAIN_ID=7628 \
  -e HOMEDIR=/data/.sanectd \
  -e JOIN_NETWORK=true \
  -e SEED_NODE_URL=https://rpc.sanect.com \
  -e SEED_NODE_ID=<id> \
  -e SEED_PEER_HOST=p2p.sanect.com:46430 \
  -e SNAPSHOT_MANIFEST_URL=https://snapshots.sanect.com/LATEST.json \
  -e PRUNING=nothing \
  -e MONIKER=archive-1 \
  sanect-node
```

Tested on Ubuntu 22.04, ext4. NVMe strongly preferred — random-read I/O
during trace replay is the main bottleneck.

## Verifying it works

From any shell, hit the archive's RPC for an old tx:

```bash
curl -s -X POST https://archive.sanect.com/ \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"debug_traceTransaction","params":["<old-tx-hash>",{"tracer":"callTracer"}],"id":1}'
```

A pruning node would return `block not found` or empty result for
anything older than 11h. The archive returns the full call tree.
