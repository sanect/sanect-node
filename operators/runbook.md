# sanect operator runbook

> **Network:** This runbook targets **mainnet** (chain id 7628). For testnet (chain id 76287) substitute the values in [`testnet-onboarding.md`](./testnet-onboarding.md) — everything else is identical.


What to do when things go wrong. Each section starts with the **symptom**
you see in monitoring or in a logs grep.

## My validator is jailed for downtime

**Symptom**: `sanectd query staking validator <valoper>` shows
`"jailed": true`, status `BOND_STATUS_UNBONDING` or `_UNBONDED`.

Cause: missed more than 50 of the last 100 blocks (`signed_blocks_window`).

Fix:
```bash
# 1. Make sure the node is actually back up and signing
curl -s localhost:26657/status | jq .result.validator_info
# voting_power should be >0 once you're unjailed and back in the active set

# 2. Wait out the downtime jail (600s = 10 min on sanect)
date            # check timestamp of jail event vs now

# 3. Unjail (from the operator key, NOT the consensus key)
sanectd tx slashing unjail \
  --from=mykey \
  --chain-id=sanect_7628-1 \
  --gas-prices=10000000apvt \
  --keyring-backend=file \
  --yes

# 4. Verify you're bonded again
sanectd query staking validator <valoper> | grep -E "jailed|status"
```

You lost `slash_fraction_downtime = 1%` of stake. That's it — keep going.

## My validator is tombstoned

**Symptom**: `sanectd query slashing signing-info <valcons>` shows
`"tombstoned": true`.

Cause: equivocation (double-sign). Two votes at the same height/round/step
from your consensus key.

There is no fix. The chain has permanently retired this validator key.

Recovery:
1. STOP the running node immediately if you haven't already.
2. Diagnose root cause **before** doing anything else. Common causes:
   - You restored a volume from a backup that had old
     `priv_validator_state.json`.
   - You ran two validator instances with the same key
     (e.g., accidentally setting `replicas > 1` on the Railway service).
   - You imported the key into a second node "just to test" and forgot to
     remove it. CometBFT signed on both.
3. Move remaining unbonded balance from the operator wallet to a fresh
   wallet. The old validator's stake is reduced 5% and locked in the
   tombstoned state.
4. Create a NEW validator (new consensus key, new operator key, new
   `valoper` address). See `docs/guide/run-a-validator.md`.
5. Beg delegators to redelegate.

If this happens on mainnet later it's a real incident — write a post-mortem,
publish it, change procedures.

## Validator missing blocks (but not jailed yet)

**Symptom**: monitoring alert "missed_blocks > 10 in window". You have
time to act before jail (need to miss > 50 of 100).

Triage:

```bash
# Is the node up?
systemctl status docker; docker ps | grep sanect-val

# Is it synced?
curl -s localhost:26657/status | jq .result.sync_info
#   catching_up should be false; latest_block_height should match peers

# Peer count
curl -s localhost:26657/net_info | jq .result.n_peers
#   < 3 is a red flag; you may be isolated

# Is the signer producing votes?
curl -s localhost:26657/consensus_state | jq .result.round_state.height_vote_set[0].prevotes
#   look for your validator's vote in the array

# CPU / RAM / disk
top -bn1 | head -20
df -h /data
```

Common causes & fixes:

| Cause | Fix |
|---|---|
| Out of disk | Add disk, prune (`sanectd start --pruning custom --pruning-keep-recent 100000`) |
| Clock skew | `chronyd -q` to force resync; check `chronyc tracking` |
| Lost peers (e.g. provider outage) | Add temporary `persistent_peers` from public seed list; check firewall hasn't reset |
| OOM kill | Bump RAM; check for memory leak in sanectd logs |
| Disk I/O saturated | Switch to NVMe; ensure no other workload sharing the volume |

## Chain is halted

**Symptom**: `latest_block_height` is the same on every validator and not
moving. CometBFT logs show repeated `consensus reached round 0 nil_vote`.

The chain needs **2/3 voting power online** (34/50 validators with equal stake).
If fewer than 34 of 50 are online, no blocks commit. This is BFT working as
designed.

Triage:

1. Identify who's down.
   ```bash
   # Run this against any working node
   curl -s https://privacy-layer1-production.up.railway.app/rpc/dump_consensus_state \
     | jq '.result.round_state.height_vote_set[0].prevotes | length'
   # vs validators
   curl -s https://.../rpc/validators | jq '.result.validators | length'
   ```
2. Contact the offline validators' operators.
3. If a provider is in an outage, you may need to spin up emergency
   replacement validators on a different provider. Be careful — see
   "Emergency new validator" below.

### Emergency new validator

If a provider is down for hours and you need to restore quorum, you can
deploy a fresh node on a different provider, fund it, and bond stake. The
new validator must have a NEW consensus key — do not import a downed
validator's key onto a new host until you've confirmed the original is dead.

Otherwise, when the original comes back online, you have two nodes with the
same key → double-sign → tombstone.

## Software upgrade

When the team ships a new sanectd version (chain restart not required, no
genesis change):

```bash
# 1. Drain rewards if you want to (optional, separate from upgrade)

# 2. Stop the validator
docker stop sanect-val

# 3. Update image
docker pull <registry>/sanect-node:new-tag

# 4. Restart
docker start sanect-val   # or `docker run` with new image

# 5. Verify
curl -s localhost:26657/status | jq .result.sync_info.latest_block_height
sanectd version
```

Coordinate downtime across validators — if 3 of 7 are upgrading at once and
1 is already offline for unrelated reasons, you've dropped to 3 active = chain
halts. Roll upgrades one at a time, verify between each.

For coordinated upgrades that require a genesis change or hardfork: that's
handled via the `x/upgrade` module governance proposal. Separate procedure;
follow the upgrade announcement.

## Migrating a validator to a different provider

You want to move val-3 from DigitalOcean to Hetzner without slashing.

The procedure:
1. Provision the new host. Don't start any sanect process yet.
2. On the OLD host, stop the validator: `docker stop sanect-val`.
3. Verify it's stopped: nothing on port 26656, no `sanectd` processes.
4. Wait one block confirmation that the chain noticed you went down
   (start of the downtime window — it's safe to be down briefly).
5. Copy the entire `/data/.sanect/` directory to the new host. This
   includes `priv_validator_key.json` AND `priv_validator_state.json`. The
   state file is critical — it tells CometBFT the last height you signed.
6. **Confirm the new host has a CURRENT `priv_validator_state.json`.**
   Cross-check that height matches what your monitoring showed for the old
   host's last block.
7. Start the validator on the new host.
8. After it's syncing/signing again, securely wipe the old host's volume
   (`shred -uvz /data/.sanect/config/priv_validator_key.json`).

If at step 4 you can't get the OLD host to a clean stop (e.g., it's
unreachable), do NOT skip ahead. The "Emergency new validator" path above
applies, with a fresh key.

## Restoring after volume corruption

If the volume is corrupted but `priv_validator_key.json` is still readable:

1. Stop the node.
2. Wipe the data directory (`/data/.sanect/data/`) but **keep**
   `/data/.sanect/config/priv_validator_key.json`.
3. State-sync from peers (much faster than full sync):
   ```toml
   # config.toml
   [statesync]
   enable = true
   rpc_servers = "https://<peer-rpc>,https://<peer-rpc>"
   trust_height = <recent_height>
   trust_hash = "<hash_at_that_height>"
   trust_period = "168h"
   ```
4. **Before starting**: set `priv_validator_state.json` to a height higher
   than the current chain tip (see `keys-and-slashing.md` →
   "A safe double-sign protection file"). This prevents signing while you
   sync.
5. Start, sync to tip.
6. Once at tip, reset `priv_validator_state.json` to
   `{"height":"0","round":0,"step":0}` and restart. The validator resumes
   signing.

Skipping step 4 is how teams accidentally double-sign during recovery.

## Routine: rotating peer info

When you add or replace a validator:

1. Get the new validator's node id (`sanectd cometbft show-node-id`) and
   public IP.
2. Update every other validator's `config.toml` `persistent_peers`.
3. Restart each (rolling, not all at once).

If you used DNS in `persistent_peers` (recommended), you only update DNS,
no restarts needed — CometBFT re-resolves on reconnect.

## When in doubt

- Read the logs. CometBFT and sanectd are extremely chatty; the actual
  failure reason is almost always there.
- Compare your node's state against a known-good public RPC (`/status`,
  `/net_info`, `/dump_consensus_state`).
- When considering ANY action that touches `priv_validator_key.json` or
  `priv_validator_state.json`: re-read `keys-and-slashing.md` first.

## Useful one-liners

```bash
# Am I in the active validator set?
sanectd query staking validator <valoper> | grep -E "status|tokens|jailed"

# What's my voting power and rank?
curl -s localhost:26657/validators | jq '.result.validators[] | {address, voting_power}'

# Blocks I've missed recently
sanectd query slashing signing-info <valcons>

# Pending rewards
sanectd query distribution rewards <delegator> <valoper>

# Force-recheck connectivity to peers
curl -s localhost:26657/net_info | jq '.result.peers[].remote_ip'
```
