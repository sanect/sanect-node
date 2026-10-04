# sanect operators / admin playbook

> ⚠ Admin-only. This directory contains operational details that should NOT
> be on the public docs site (`docs/`). It lives in the repo so operators can
> read it on GitHub, but it never gets built into the public site.

## What's here

| File | When you need it |
|---|---|
| [`multicloud-deploy.md`](./multicloud-deploy.md) | Deploying 50 validators across 6+ cloud providers in Singapore. The whole per-provider playbook (AWS, GCP, DigitalOcean, Vultr, Linode, OVH, Railway) including firewall, peering, sentry pattern. |
| [`keys-and-slashing.md`](./keys-and-slashing.md) | How NOT to lose 5% of stake to a double-sign. Key generation, backup, hot/cold, TMKMS, rotation. |
| [`runbook.md`](./runbook.md) | Day-2 ops: "validator jailed", "chain halted", "missed blocks", "provider outage", state-sync, upgrade, recovery. |

## The 3 rules you can't break

1. **One validator key = one running node.** Two nodes with the same
   `priv_validator_key.json` will both sign the same block → **5% slash +
   tombstoned forever**. Replicas are forbidden for validator services.
2. **Back up `priv_validator_key.json` once, offline.** You can rebuild
   anything else. You cannot recover this key, and losing it = retiring the
   validator + creating a new one + losing brand/uptime ranking.
3. **Never roll back the volume.** `priv_validator_state.json` tracks the
   last height your key signed at. Rolling back state to before a signed
   height = you'll sign it again at a different hash = double-sign slash.
   When recovering from a corrupted volume, you must **bring forward** the
   state file, never revert it.

## Quick checklist before going live (per validator)

- [ ] Unique Volume / persistent disk attached, mounted at `/data`
- [ ] `priv_validator_key.json` backed up to a cold location
- [ ] **`replicas = 1`** on the service (or single VM)
- [ ] `persistent_peers` config lists all the other validators
- [ ] Firewall: 26656 open to peers; 26657/1317/8545 NOT publicly exposed
      (those go through your sentry / RPC fleet instead)
- [ ] Monitoring: Prometheus scraping `:26660`, alerts wired for missed
      blocks > 10 in window, peer count < 3, disk > 80%
- [ ] Time sync: `chronyd` / `systemd-timesyncd` enabled (clock skew breaks
      CometBFT consensus signing)
- [ ] You know which key file to grab if the VM dies (see
      [`keys-and-slashing.md`](./keys-and-slashing.md))

## Public-facing docs

The public docs site (built from `docs/` in this repo, deployed to
`docs.<your-domain>`) covers end-user / developer concerns. Operator
specifics — keys, multicloud, runbooks — are deliberately not there.

If you find something in this directory that you think IS safe to publish,
move it to `docs/` and add it to the sidebar in `docs/.vitepress/config.ts`.
