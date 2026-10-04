# Chain icon listing — why your icon doesn't show, and how to fix it

> **Network:** This runbook targets **mainnet** (chain id 7628). For testnet (chain id 76287) substitute the values in [`testnet-onboarding.md`](./testnet-onboarding.md) — everything else is identical.


When a user clicks "Add to wallet" on sanect.com/wallet, we send
`wallet_addEthereumChain` with an `iconUrls` field pointing at our
logo. **Most wallets ignore it.** They source network icons from
their internal databases, which are mostly seeded from
[chainlist.org](https://chainlist.org) and
[ethereum-lists/chains](https://github.com/ethereum-lists/chains).

| Wallet | `iconUrls` honored? | Where it sources icons |
|---|---|---|
| MetaMask (extension) | Sometimes | ChainList + builtin DB |
| MetaMask (mobile) | No | Builtin DB |
| Rabby | Yes | `iconUrls` first, then ChainList |
| Brave Wallet | Yes | `iconUrls` |
| Trust Wallet | No | Trust assets DB (manual review) |
| Coinbase Wallet | No | Coinbase DB |
| OKX Wallet | No | OKX DB |
| Phantom | No | Phantom DB |
| Bitget | No | Bitget DB |

So `iconUrls` covers ~30% of wallets. The other 70% need the chain
listed in `ethereum-lists/chains`, which then propagates to most
wallets within 1–4 weeks.

## Step 1 — register on `ethereum-lists/chains`

This is the upstream source nearly every wallet eventually pulls from.

1. Fork [ethereum-lists/chains](https://github.com/ethereum-lists/chains).
2. Create `_data/chains/eip155-7628.json`:
   ```json
   {
     "name": "Sanect Testnet",
     "chain": "Sanect",
     "title": "Sanect Testnet",
     "rpc": [
       { "url": "https://rpc.sanect.com/" }
     ],
     "faucets": [
       "https://faucet.sanect.com"
     ],
     "nativeCurrency": {
       "name": "Sanect",
       "symbol": "SNCT",
       "decimals": 18
     },
     "features": [{ "name": "EIP1559" }],
     "infoURL": "https://sanect.com",
     "shortName": "sanect-test",
     "chainId": 7628,
     "networkId": 7628,
     "icon": "sanect",
     "explorers": [
       {
         "name": "Sanect Scan",
         "url": "https://scan.sanect.com",
         "standard": "EIP3091"
       }
     ],
     "status": "active",
     "redFlags": [],
     "parent": {
       "type": "L1",
       "chain": "Sanect"
     }
   }
   ```
3. Add icon at `_data/icons/sanect.json`:
   ```json
   [
     {
       "url": "ipfs://<CID-of-our-PNG>",
       "width": 256,
       "height": 256,
       "format": "png"
     }
   ]
   ```
   Upload the 256×256 PNG to IPFS first (e.g. `npx ipfs-deploy` or
   pin via Pinata) — they require IPFS URLs, not HTTPS.
4. Open a PR. Their CI validates the JSON. Merges usually happen
   within a few days.
5. After merge, ChainList rebuilds within ~1 hour; MetaMask and
   downstream wallets pick it up at their next index refresh
   (typically 1–4 weeks).

## Step 2 — Trust Wallet (separate process)

Trust maintains its own asset DB. For a custom EVM testnet they
**rarely accept** listings (they prioritise mainnets). For mainnet
later: see [trust-wallet/assets](https://github.com/trustwallet/assets).
The submission needs a 256×256 PNG + `info.json` per the repo's
schema. Expect 2–6 weeks of review.

## Step 3 — Coinbase, OKX, Phantom

Each has its own opaque process. Best chance is filing a support
ticket with documentation + the ChainList listing as proof of
legitimacy. Don't expect quick wins on testnet.

## Step 4 — meanwhile, what works today

Without any listings, `iconUrls` in our `wallet_addEthereumChain`
call covers Rabby + Brave + sometimes MetaMask extension. For the
others, the network just shows a default generic icon — functionally
identical, just less branded. Acceptable for testnet; mainnet
warrants real listings.

## Logo files in this repo

- **SVG vector**: `landing/public/assets/sanect-mark.svg` (256×256 viewbox)
- **PNG raster**: needs to be exported from the SVG and placed at
  `landing/public/assets/sanect-mark.png`. Use Inkscape, Figma, or:
  ```bash
  npx svgexport landing/public/assets/sanect-mark.svg \
                landing/public/assets/sanect-mark.png 256:256
  ```

Once both exist at `https://sanect.com/assets/sanect-mark.{svg,png}`,
the iconUrls field works for the wallets that respect it.
