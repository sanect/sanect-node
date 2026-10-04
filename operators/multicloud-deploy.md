# Multi-cloud 50-validator deployment (Singapore)

> **Network:** This runbook targets **mainnet** (chain id 7628). For testnet (chain id 76287) substitute the values in [`testnet-onboarding.md`](./testnet-onboarding.md) — everything else is identical.


The point: **no single cloud outage should be able to halt the chain.** With
50 validators and BFT `f = (n-1)/3`, the chain tolerates up to **16** down. So
spread validators so that **no one provider hosts more than 16 of them**.

This page is the concrete per-provider playbook to do that in Singapore.

## Recommended layout

| # | Provider | Region | Reasonable VM | Underlying infra |
|---|---|---|---|---|
| 1 | **AWS** | `ap-southeast-1` (Singapore) | `c6i.large` (2 vCPU / 4 GB) | own DCs |
| 2 | **GCP** | `asia-southeast1` (Singapore / Jurong West) | `n2-standard-2` | own DCs |
| 3 | **DigitalOcean** | `sgp1` | Premium Intel 2vCPU / 4 GB | leased DCs (Equinix SG1) |
| 4 | **Vultr** | `Singapore` | Regular Cloud 2vCPU / 4 GB | Equinix SG3 |
| 5 | **Linode (Akamai)** | `Singapore` | Linode 4 GB | Equinix SG1 |
| 6 | **OVHcloud** | `SGP` | Public Cloud B2-7 | own DC, Tai Seng |
| 7 | **Railway** | `asia-southeast` | (managed) | **runs on GCP `asia-southeast1`** |

> Railway's underlying infra is GCP `asia-southeast1`. Treat Railway + GCP as
> **one provider** for diversity accounting. With the layout above, GCP
> hosts 2 of 7 (val 2 + val 7). That's exactly at the BFT tolerance limit.
> If GCP Singapore drops, the chain continues with 5/7.

If you want to be safer than "exactly at tolerance" for GCP, swap Railway
out for a 7th non-GCP provider (e.g., a second DC at OVH, or **Equinix
Metal** in SG2).

## Realistic latencies (plan for these, not 1–2 ms)

| pair | typical RTT |
|---|---|
| Same provider, same AZ | <1 ms |
| AWS sgp ↔ GCP sgp (SGIX) | 1–3 ms |
| AWS sgp ↔ DO SGP1 | 1–3 ms |
| AWS/GCP ↔ Vultr / Linode sgp | 2–4 ms |
| AWS/GCP ↔ OVH SGP | 2–5 ms |
| occasional tail | up to 10–15 ms |

This is well inside a 400 ms `timeout_commit` budget. Don't optimize for
2 vs 4 ms; CometBFT's prevote/precommit/commit rounds care about the
ensemble, not a single pair.

## Resource sizing per validator

For our current params (~400 ms blocks, 150 M block gas, fresh testnet):

| | minimum | comfortable |
|---|---|---|
| vCPU | 2 | 4 |
| RAM | 4 GB | 8 GB |
| Disk (volume) | 100 GB SSD | 250 GB NVMe |
| Network | 100 Mbps | 1 Gbps |

State grows ~monotonically; budget extra disk for retention. Mainnet sizing
should be re-estimated once shielded txs are enabled (notes + nullifiers
inflate state).

## Per-provider playbook

> All providers: install Docker, attach a persistent disk mounted at
> `/data`, open inbound TCP `26656` from peer IPs only, run the same
> `sanectd` container that powers the Railway deploy.

The container we run on every host:

```bash
# Pull the chain image (we maintain it in the repo's docker/ folder).
# Build once with: docker build -t sanect-node -f docker/Dockerfile .
# Then push to a registry, or build on each host.

docker run -d --restart unless-stopped \
  --name sanect-val \
  -v /data:/data \
  -p 26656:26656 \
  -e CHAIN_ID=sanect_7628-1 \
  -e MONIKER=val-<n>-<provider> \
  -e HOMEDIR=/data/.sanect \
  -e PORT=8080 \
  -p 8080:8080 \
  sanect-node
```

(`8080` is the Caddy front for RPC/REST. Only expose it publicly if this
node is also acting as a public RPC; for validator-only, keep it bound to
localhost via firewall.)

### 1. AWS (`ap-southeast-1`)

```bash
# CLI / Terraform pseudocode
aws ec2 run-instances \
  --image-id ami-0xxxxx \                           # Ubuntu 24.04 LTS
  --instance-type c6i.large \
  --key-name my-key \
  --security-group-ids sg-sanect-val \
  --subnet-id subnet-xxxxx \
  --block-device-mappings 'DeviceName=/dev/sdb,Ebs={VolumeSize=200,VolumeType=gp3}' \
  --user-data file://cloud-init.sh

# Security group sg-sanect-val:
#   inbound  22/tcp   from your bastion IP only
#   inbound  26656/tcp from <ip of each other validator>
#   outbound any
```

Cloud-init (`cloud-init.sh`):
```bash
#!/bin/bash
set -e
apt-get update && apt-get install -y docker.io chrony jq curl
systemctl enable --now docker chrony
# mount the EBS volume
mkfs.ext4 /dev/nvme1n1 || true
mkdir -p /data
mount /dev/nvme1n1 /data
echo "/dev/nvme1n1 /data ext4 defaults,nofail 0 2" >> /etc/fstab
# (then docker run command shown above)
```

### 2. GCP (`asia-southeast1`)

```bash
gcloud compute instances create sanect-val-2 \
  --zone=asia-southeast1-a \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2404-lts --image-project=ubuntu-os-cloud \
  --create-disk=name=val-data,size=200GB,type=pd-ssd \
  --metadata-from-file=startup-script=cloud-init.sh \
  --tags=sanect-val

gcloud compute firewall-rules create sanect-p2p \
  --direction=INGRESS --action=ALLOW \
  --rules=tcp:26656 --source-ranges=<peer-ips> \
  --target-tags=sanect-val
```

### 3. DigitalOcean (`SGP1`)

```bash
doctl compute droplet create sanect-val-3 \
  --region sgp1 --image ubuntu-24-04-x64 --size s-2vcpu-4gb-intel \
  --ssh-keys <fingerprint> --user-data-file cloud-init.sh \
  --enable-monitoring --tag-name sanect-val

doctl compute volume create val3-data --region sgp1 --size 200GiB
doctl compute volume-action attach <volume-id> <droplet-id>

# Firewall
doctl compute firewall create --name sanect-val \
  --inbound-rules "protocol:tcp,ports:26656,address:<peer-ip>" \
  --tag-names sanect-val
```

### 4. Vultr (Singapore)

```bash
vultr-cli instance create \
  --region sgp --plan vc2-2c-4gb --os 1743 \         # Ubuntu 24.04
  --ssh-keys <id> --userdata "$(cat cloud-init.sh | base64)" \
  --tag sanect-val

vultr-cli block-storage create --region sgp --size 200 --label val4-data
vultr-cli instance attach-block-storage <inst> <volume>

# Firewall group with 26656/tcp from peer IPs
```

### 5. Linode / Akamai (Singapore)

```bash
linode-cli linodes create \
  --region ap-south --type g6-standard-2 \
  --image linode/ubuntu24.04 --label sanect-val-5 \
  --stackscript-id <id> \
  --root_pass "$(openssl rand -base64 16)"

linode-cli volumes create --label val5-data --size 200 --region ap-south
linode-cli volumes attach <volume> --linode_id <instance>

# Cloud Firewall: 26656 from peer IPs
```

### 6. OVHcloud (`SGP`)

```bash
# Public Cloud, with the openstack CLI configured for tenant
openstack server create sanect-val-6 \
  --image "Ubuntu 24.04" \
  --flavor b2-7 \
  --network <net> \
  --user-data cloud-init.sh \
  --key-name my-key

openstack volume create --size 200 --type classic val6-data
openstack server add volume sanect-val-6 <volume>

# Security group with 26656/tcp
```

### 7. Railway (current setup)

Already documented in `docs/guide/scaling-validators.md`. Railway abstracts
the underlying provider. Two peering paths:

**Public peering (everyone else uses this)** — the primary node exposes
P2P via a Railway TCP proxy (Settings → Networking → TCP Proxy on 26656),
which gives a `<hash>.proxy.rlwy.net:<random-port>` public endpoint. We
CNAME a custom domain at it (Cloudflare DNS-only, grey cloud — NEVER
orange-cloud, raw TCP isn't HTTPS) so the canonical peer string stays
human-friendly:

```
p2p.sanect.com:46430
```

External joiners — Railway-different-project, AWS, GCP, DO, bare metal —
all use that exact string in `SEED_PEER_HOST`. The primary node must
also set `EXTERNAL_P2P_ADDRESS=p2p.sanect.com:46430` so peer
exchange advertises a reachable address instead of `0.0.0.0:26656`.

**Internal peering (sibling Railway services only)** — Railway services
in the same project can reach each other on any port via
`<service>.railway.internal:26656`. This is a micro-optimisation; the
public path above also works between sibling services, just with one
extra hop.

## Cross-provider peering (the public-internet version)

Inside one Railway project the peering goes over private networking. Across
providers there's no private link — peering goes over **public IPs**.
Every validator's `config.toml`:

```toml
[p2p]
laddr = "tcp://0.0.0.0:26656"
external_address = "<this validator's public ip>:26656"
persistent_peers = "<id1>@<ip1>:26656,<id2>@<ip2>:26656,...,<id7>@<ip7>:26656"
addr_book_strict = false                # different provider IP ranges
allow_duplicate_ip = false
max_num_inbound_peers = 80
max_num_outbound_peers = 20
```

Get each validator's node id from a running node:

```bash
sanectd cometbft show-node-id --home /data/.sanect
# -> e.g. a0ae54bdf174183dae20b4fad79a81b4e5281454
```

Build the `persistent_peers` string once, distribute to all 7 hosts via
your config management tool. Restart each. Verify peer count:

```bash
curl -s localhost:26657/net_info | jq '.result.n_peers'
# -> 6 (the other 6 validators)
```

## Optional but recommended: sentry pattern

For each validator, run a small sentry node in **the same provider/region**.
The validator binds 26656 only to the sentry's IP; the sentry binds 26656
publicly. Benefits: validator never exposes its IP; DDoS hits the sentry,
not the signing node.

Topology:
```
   [val 1 (private)]  <--26656-->  [sentry-1 (public)]  <-->  internet / other peers
   [val 2 (private)]  <--26656-->  [sentry-2 (public)]  <-->  ...
   ...
```

Validator `config.toml`:
```toml
pex = false                              # don't gossip my IP
persistent_peers = "<sentry-id>@<sentry-internal-ip>:26656"
unconditional_peer_ids = "<sentry-id>"   # always reconnect
```

Sentry `config.toml`:
```toml
pex = true
private_peer_ids = "<validator-id>"      # never gossip the validator
persistent_peers = "<other sentries...>"
```

This costs you one extra small VM per provider but is the standard pattern
on Cosmos Hub, Osmosis, Sei, etc.

## DNS

Optional but cleaner: instead of bare IPs in `persistent_peers`, use stable
DNS records (`val1.sanect.example`, etc.) pointing at each validator. Then
if you have to rebuild a VM with a new IP, you don't have to update every
other validator's config.

## Firewall summary

| Port | Inbound from | Purpose |
|---|---|---|
| 22 | bastion only | SSH ops |
| 26656 | peer / sentry IPs only | p2p consensus |
| 26657 | localhost only | CometBFT RPC (sensitive! never public on validator) |
| 1317 | localhost only | Cosmos REST |
| 8545 | localhost only | EVM JSON-RPC |
| 26660 | monitoring net only | Prometheus scrape |

Public RPC traffic does **not** go to validators. Run a separate
**RPC fleet** (Railway service with replicas, or a few VMs behind a load
balancer) that's read-only and faces users.

## Fast-start from a published snapshot

On a chain with >100k blocks, block-syncing from genesis takes hours
even with healthy peers. The image ships two scripts that turn that
into a 1–5 minute download:

- `scripts/snapshot-upload.sh` — runs as a cron on the primary node,
  streams `tar | lz4 | rclone` to Cloudflare R2 every N hours, plus a
  `LATEST.json` manifest pointing at the newest snapshot.
- `scripts/snapshot-download.sh` — runs from the joiner's entrypoint
  on first boot, streams `curl | lz4 -d | tar -x` straight into
  `/data/.sanectd/data` before CometBFT starts.

The full chain of fast-starts the joiner tries in order:

1. Tarball download (1–5 min) — opt in via `SNAPSHOT_MANIFEST_URL`.
2. CometBFT state sync (~2–5 min) — automatic.
3. Block sync from genesis (hours+) — last resort.

### Publish snapshots from the primary

R2 setup is a one-shot:

1. Cloudflare dashboard → R2 → create bucket `sanect-snapshots`.
2. Create an R2 API token with `Object Read & Write` scoped to that
   bucket.
3. Either enable public access on the bucket, or CNAME a custom domain
   (`snapshots.sanect.com` → bucket's public hostname).

Then on the primary node service set:

```env
SNAPSHOT_UPLOAD_INTERVAL_HOURS=6
R2_ACCOUNT_ID=<32-char hex>
R2_ACCESS_KEY_ID=<token access key>
R2_SECRET_ACCESS_KEY=<token secret>
R2_BUCKET=sanect-snapshots
R2_PUBLIC_URL=https://snapshots.sanect.com
SNAPSHOT_KEEP=3
```

The entrypoint starts a cron that runs every 6h, skips upload if the
node is still catching up, and prunes older snapshots automatically.

### Fast-start a joiner

On a fresh validator / RPC node:

```env
JOIN_NETWORK=true
SEED_NODE_URL=https://rpc.sanect.com
SEED_NODE_ID=<from sanectd cometbft show-node-id on primary>
SEED_PEER_HOST=p2p.sanect.com:46430
SNAPSHOT_MANIFEST_URL=https://snapshots.sanect.com/LATEST.json
MONIKER=sanect-val-N
HOMEDIR=/data/.sanectd
```

On first boot the entrypoint:
1. Fetches genesis from `SEED_NODE_URL/rpc/genesis`.
2. Resolves the manifest, downloads the tarball, extracts into `data/`.
3. Resets `priv_validator_state.json` so this node's key doesn't
   replay any signing history from the seed.
4. Starts the node — block-syncs from snapshot height to tip
   (a few thousand blocks at most).

Each path degrades gracefully. If R2 is down: state sync. If the seed
isn't serving state snapshots: block sync. Nothing wedges the boot.

## What to do next

1. [`keys-and-slashing.md`](./keys-and-slashing.md) — secure the signing
   keys before going live.
2. [`runbook.md`](./runbook.md) — day-2 operations (upgrades, outages,
   jailed validator recovery).
