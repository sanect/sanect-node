# Run a sanect node on a fresh Ubuntu server

> **Network:** This runbook targets **mainnet** (chain id 7628). For testnet (chain id 76287) substitute the values in [`testnet-onboarding.md`](./testnet-onboarding.md) — everything else is identical.


This walks through bringing up a sanect testnet node on any Ubuntu 22.04 /
24.04 box with root access — VPS, dedicated server, lab machine, doesn't
matter. The same container image we run on Railway runs anywhere Docker
runs, so this is mostly "install Docker + mount a volume + set the env".

The default below builds a **validator** (signs blocks). The same recipe
without the registration step at the end gives you a **read-only RPC
node** — useful for hosting your own RPC endpoint, an indexer, or a
relayer.

## What you need

- Ubuntu 22.04 or 24.04 LTS, root or sudo
- 2 vCPU, 4 GB RAM, 100 GB SSD (more disk if you plan to run for months)
- A public IP, or NAT with TCP 26656 forwarded inbound
- About 15 minutes

## 1. System prep

```bash
# Update + install Docker, jq, ntp
apt-get update
apt-get install -y docker.io docker-compose-plugin chrony jq curl ufw

# Start everything
systemctl enable --now docker chrony

# Confirm clock is in sync — CometBFT will reject blocks with skewed time
chronyc tracking | grep 'System time'
```

## 2. Persistent volume

The container writes chain state to `/data/.sanectd`. Make sure that's a
real disk you control, not the ephemeral root partition:

```bash
# If you have a separate disk (recommended), e.g. /dev/sdb:
mkfs.ext4 /dev/sdb
mkdir -p /data
echo '/dev/sdb /data ext4 defaults,noatime 0 0' >> /etc/fstab
mount /data

# Otherwise just create the dir on the root disk:
mkdir -p /data
```

Confirm with `df -h /data` — you want at least 50 GB free.

## 3. Firewall

CometBFT P2P uses TCP `26656`. Everything else is internal.

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp             # SSH (consider restricting to your IP)
ufw allow 26656/tcp          # CometBFT P2P
ufw --force enable
ufw status
```

**Do not open** 26657, 1317, 8545 publicly. Those are the chain RPCs;
exposing them on a validator gives a free DoS vector. Keep them
localhost-only. If you want a public RPC, run a separate read-only RPC
node and put it behind a reverse proxy.

## 4. Get the image

Two options.

### Option A: build from the repo (recommended)

```bash
apt-get install -y git
cd /opt
git clone https://github.com/sanect/sanect-node.git sanect
cd sanect
docker build --build-arg TARGET_EVM_CHAIN_ID=7628 -t sanect-node -f docker/Dockerfile .
```

The build takes 5–10 minutes (it compiles `sanectd` from cosmos/evm). The
result is a single `sanect-node` image with everything bundled.

### Option B: pull a prebuilt image (when one is published)

```bash
# Once we publish images to a registry — TBD:
# docker pull ghcr.io/sanect/sanect-node:testnet
# docker tag ghcr.io/sanect/sanect-node:testnet sanect-node
```

## 5. Configure env

Drop your join config in `/etc/sanect/node.env`:

```bash
mkdir -p /etc/sanect
cat > /etc/sanect/node.env <<'EOF'
JOIN_NETWORK=true
CHAIN_ID=sanect_7628-1
EVM_CHAIN_ID=7628
HOMEDIR=/data/.sanectd

# Pick anything — shows up on the explorer
MONIKER=sanect-val-myhostname

# Peering — the canonical public TCP endpoint. The port belongs to a Railway
# TCP proxy; take the live value from:
#   curl -s https://rpc.sanect.com/rpc/status | jq -r .result.node_info.listen_addr
# (35998 as of 2026-10-04)
SEED_NODE_URL=https://rpc.sanect.com
SEED_PEER_HOST=p2p.sanect.com:35998

# Get the actual node id from a fresh shell:
#   curl -s https://rpc.sanect.com/rpc/status | jq -r .result.node_info.id
SEED_NODE_ID=<paste here>

# Fast-start: download the latest tarball snapshot from R2 instead of
# block-syncing from genesis. Saves hours when the chain has 100k+ blocks.
SNAPSHOT_MANIFEST_URL=https://snapshots.sanect.com/LATEST.json

# Tell peers your reachable public address so they can dial back.
# Replace <YOUR_PUBLIC_IP> with this server's real public IP.
# Use a DNS name if you have one (validator-3.example.com:26656 is fine).
EXTERNAL_P2P_ADDRESS=<YOUR_PUBLIC_IP>:26656

# Don't change this — what Caddy binds inside the container.
PORT=8080
EOF
chmod 600 /etc/sanect/node.env
```

Confirm the seed node id:

```bash
curl -s https://rpc.sanect.com/rpc/status | jq -r .result.node_info.id
```

Paste that string into the `SEED_NODE_ID=` line.

## 6. Run

```bash
docker run -d \
  --name sanect-node \
  --restart unless-stopped \
  --env-file /etc/sanect/node.env \
  -v /data:/data \
  -p 26656:26656 \
  -p 127.0.0.1:8080:8080 \
  sanect-node
```

What that does:

- `--restart unless-stopped` — survives reboots
- `-v /data:/data` — chain data lives on your disk, not in the container
- `-p 26656:26656` — exposes P2P publicly (required, that's how peers reach you)
- `-p 127.0.0.1:8080:8080` — RPC bound to localhost only (safe; access via
  `curl localhost:8080/rpc/status` from the host)

Watch it come up:

```bash
docker logs -f sanect-node
```

You should see in order:

1. `>>> First boot: JOINING existing chain sanect_7628-1`
2. `>>> Attempting fast-start from published snapshot` →
   `[snapshot-download] downloading + extracting …`
3. `>>> Wiring peers: <node-id>@p2p.sanect.com:46430`
4. `>>> Advertising external P2P address: <YOUR_IP>:26656`
5. `>>> This node's CometBFT id: <your-id>`
6. `>>> This node's consensus pubkey: {…}` ← **copy this for step 8**
7. `>>> Starting sanect node`
8. `committed state height=…` rolling in

If you see `numOutPeers=0` for more than a minute, jump to **Troubleshooting** below.

## 7. Test from the host

```bash
# Catching up? Should drop to false within a minute or two of fast-start.
curl -s localhost:8080/rpc/status | jq '.result.sync_info'

# Block height
curl -s localhost:8080/rpc/status | jq -r '.result.sync_info.latest_block_height'

# How many peers we're connected to (should be ≥1)
curl -s localhost:8080/rpc/net_info | jq -r '.result.n_peers'

# EVM JSON-RPC
curl -s -X POST localhost:8080/ \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## 8. Register as a validator (optional)

Skip this section if you only want an RPC node.

a. Grab your consensus pubkey:

```bash
docker exec sanect-node sanectd cometbft show-validator --home /data/.sanectd
```

Output is a JSON blob like `{"@type":"/cosmos.crypto.ed25519.PubKey","key":"…"}`.

b. Fund the validator's signing key with at least 100 SNCT (mainnet:
1,000 SNCT). You can use the faucet for testnet:

- The validator wallet address (what holds the stake) is a separate
  account. Generate one with MetaMask, import its private key into the
  node via `sanectd keys add` — or use a different wallet entirely; you
  only need to sign the `MsgCreateValidator` tx from it.

c. Open the staking dApp (`https://app.sanect.com`), click
**Register as validator**, paste:

- Moniker (free text — what you set in env)
- Commission rate (e.g. `0.10` for 10%)
- Consensus pubkey (the JSON blob from step a)
- Self-delegation amount (testnet minimum: 100 SNCT)

Sign with MetaMask, watch the tx land, refresh the validators list. Once
you're in the top 50 by stake you start receiving block proposals.

## 9. Updates

```bash
cd /opt/sanect
git pull
docker build --build-arg TARGET_EVM_CHAIN_ID=7628 -t sanect-node -f docker/Dockerfile .
docker stop sanect-node && docker rm sanect-node
# Re-run the docker run command from step 6
```

Volume isn't touched — chain state survives.

## 10. Recovery — node stuck, way behind, or panicking on restart

If a node gets into a bad state (genesis-sync crash, corrupted DB,
fallen 100k+ blocks behind because it was offline for hours), normal
restart won't help — it just resumes from the broken state.

The entrypoint supports a one-shot escape hatch: set
`FORCE_SNAPSHOT_RESTORE=true` in `/etc/sanect/node.env` and restart.
That wipes the chain data, preserves the validator key
(`priv_validator_key.json`) + last-signed state, and re-runs the
first-boot flow which downloads the latest snapshot and resumes.
It also requires `FORCE_SNAPSHOT_RESTORE_CONFIRM=<your CHAIN_ID>`
(`sanect_7628-1` on mainnet); with only the first variable the entrypoint
refuses to wipe.

```bash
# Add BOTH env flags
echo 'FORCE_SNAPSHOT_RESTORE=true' >> /etc/sanect/node.env
echo 'FORCE_SNAPSHOT_RESTORE_CONFIRM=sanect_7628-1' >> /etc/sanect/node.env

# Restart the container — it now re-uses the same env file
docker stop sanect-node && docker rm sanect-node
docker run -d \
  --name sanect-node \
  --restart unless-stopped \
  --env-file /etc/sanect/node.env \
  -v /data:/data \
  -p 26656:26656 \
  -p 127.0.0.1:8080:8080 \
  sanect-node

# Watch the snapshot download + extraction
docker logs -f sanect-node

# After it's caught up to tip, remove BOTH flags so future restarts
# don't wipe again
sed -i '/^FORCE_SNAPSHOT_RESTORE/d' /etc/sanect/node.env
```

**Safety:** the wipe preserves `priv_validator_key.json` (the signer
identity) and `priv_validator_state.json` (the last-signed height,
crucial for avoiding double-signs after recovery). Only the
replicable chain state is wiped.

## 11. Register your node on the explorer dashboard

The easiest way: run the interactive wizard from the repo.

```bash
cd /opt/sanect
git pull origin main
sudo bash scripts/sanect-publish-rpc.sh
```

The wizard asks two questions:

**1. Use your own domain, OR a free community subdomain?**

- **Own domain** (e.g. `rpc.myvalidator.com`): the script walks you
  through DNS, installs Caddy, gets a Let's Encrypt cert, configures
  reverse proxy, and updates your node env. Final URL is
  `https://your-domain.com`.
- **Free subdomain** (e.g. `alice.sanect.org`): the script
  checks availability, claims the name with the explorer, and points
  it at your node. No DNS or TLS setup needed — the explorer
  proxies the traffic.

**2. (only for own-domain) Enter your domain. The script:**

  - Shows you the `A` record to add at your DNS registrar
  - Polls DNS until it resolves to your VPS's IP
  - Installs Caddy + opens firewall ports 80/443
  - Writes the Caddyfile reverse-proxy block
  - Reloads Caddy (Let's Encrypt cert issues automatically)
  - Updates `/etc/sanect/node.env` with `PUBLIC_RPC_URL=https://<yours>`
  - Restarts the container
  - Waits for the explorer to verify the heartbeat
  - Prints the final URL

Re-runnable: if you've already configured something, the script
detects the existing state and updates it cleanly.

---

If you want to configure manually instead of using the wizard, add
these env vars to `/etc/sanect/node.env`:

```env
EXPLORER_HEARTBEAT_URL=https://scan.sanect.com/api/network/heartbeat

# OPTIONAL: only set if you want your RPC publicly listed on the
# explorer's /network/nodes dashboard.
#PUBLIC_RPC_URL=https://my-validator.example.com:8080
```

Restart the container (`docker stop … && docker run …`). Within
~60 seconds the explorer's `/network/nodes` page lists your node.

If you set `PUBLIC_RPC_URL`, the explorer pings it back to verify the
node-id matches before listing it publicly. If your URL isn't
reachable from the internet, the heartbeat still registers your node
but the public URL is silently dropped.

To expose your RPC publicly (needed for `PUBLIC_RPC_URL` to verify):

```bash
# 1. Change the docker run port binding from 127.0.0.1:8080:8080 to 8080:8080
# 2. Open the port in ufw
ufw allow 8080/tcp
```

⚠ **Don't expose validators that hold significant stake without
rate-limiting**. Public RPC opens you to DoS amplification.
On mainnet, run a separate sentry node with public RPC and keep
the validator firewall-restricted to the sentry's IP.

## Troubleshooting

### `numOutPeers=0`, "No addresses to dial"

```bash
# DNS + TCP path from the host:
nc -zv p2p.sanect.com 46430

# Inside the container, verify config picked up the right values:
docker exec sanect-node grep -E '^(persistent_peers|seeds|external_address) ' \
  /data/.sanectd/config/config.toml
```

If `persistent_peers` is empty, the env wasn't propagated — check
`docker inspect sanect-node | grep SEED_`. If TCP can't connect, the
primary node is probably down or its Railway TCP proxy was reset; check
`https://rpc.sanect.com/rpc/status`.

### Disk filling up

The container prunes by default (`pruning custom --pruning-keep-recent 100000`).
A few months in, expect 30–100 GB. Resize the disk or migrate to a
bigger one — chain data is portable, just stop the container, copy
`/data` to the new disk, start the container again.

### Node got jailed

If you missed too many blocks (downtime jail), the slashing precompile's
`unjail` button lives in the staking dApp. Click it from the same wallet
that registered the validator. The 600 s cooldown applies.

### "address already in use" on 26656

Something else on the host is bound to 26656. Find it with
`ss -tlnp 'sport = 26656'` and stop it, or pick a different host port
with `-p 26657:26656` (joiners would then need to point at that
different port).

## What this gets you

A sovereign sanect node, no Railway dependency, the same code path the
official testnet primary runs. You can:

- Sign blocks (after step 8)
- Serve your own RPC traffic
- Run your own explorer indexer against `localhost:8080`
- Publish your own snapshots — set the same `R2_*` + `SNAPSHOT_UPLOAD_INTERVAL_HOURS`
  env on this node and your tarball will land in your bucket every N hours
