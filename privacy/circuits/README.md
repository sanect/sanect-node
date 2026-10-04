# Circuits — Noir 2-in/2-out spend circuit

> Status: **Phase 1 in progress** (PRIVACY.md top section is the source of truth).
> The Noir source + EVM verifier land in the next PR. This README documents the
> directory layout the rest of the codebase already expects, plus the build pipeline.

This directory holds **the Noir source** for the shielded transfer circuit and
**the generated EVM verifier** that lives on-chain. Unlike Phase 0's Railgun
plan (which required vendoring prebuilt binaries), Noir's build is fully
reproducible from source on any developer's laptop.

## Layout

```
privacy/circuits/
├── README.md                  ← you are here
├── transfer/
│   ├── Nargo.toml             ← Noir package descriptor
│   ├── src/
│   │   ├── main.nr            ← the 2-in/2-out spend circuit
│   │   ├── note.nr            ← note structure + commitment helpers
│   │   ├── merkle.nr          ← inclusion proof verifier
│   │   └── poseidon.nr        ← hash imports
│   ├── prover.toml.example    ← reference witness file for the test prover
│   └── target/                ← gitignored. nargo's build output goes here.
├── verifier/
│   └── Verifier.sol           ← EVM verifier auto-generated from the circuit's
│                                  ACIR. Treat as opaque — never hand-edit.
├── manifest.json              ← SHA-256 of Verifier.sol + the Noir source bundle
│                                  + Noir/bb toolchain versions used to build
│                                  it. Foundry tests verify on every CI run.
└── LICENSE-noir               ← Aztec's MIT license. Required because the
                                  generated verifier inherits its provenance.
```

## What the circuit proves

In ~250 lines of Noir (excluding the imported poseidon library), each shielded
transfer proof asserts all of the following at once:

1. The sender knows the spending keys for up to 2 existing notes.
2. Those notes are in the current Merkle tree (inclusion proof).
3. Their nullifiers haven't been spent (caller-side check; the proof emits
   the nullifiers so the contract can store them).
4. The sum of input note amounts equals the sum of output note amounts,
   per `asset_id`. (Conservation.)
5. Any unshielded value goes to a public recipient address claimed in the
   public inputs.
6. New note commitments are correctly formed.
7. Encrypted memos parse correctly under the recipient's viewing pubkey
   (separate per-output integrity check).

Public inputs (what the verifier contract sees):
```
inputNullifiers[0..2]      // 2 × uint256
outputCommitments[0..2]    // 2 × uint256
merkleRoot                 // uint256 (must match a recent root in the pool)
publicAmount               // int256 (>0 = shield in, <0 = unshield out, =0 = internal)
publicAssetId              // uint256 (address(0) for native, otherwise token addr)
publicRecipient            // address (for unshield, otherwise 0x0)
encryptedMemos[0..2]       // 2 × 240 bytes (32 ephPk + 96 ct + 16 mac + 96 FMD-reserved)
```

## Building

### Install Noir toolchain (~5 min)

```bash
# Install noirup (Noir's version manager). Official install URL:
curl -L https://raw.githubusercontent.com/noir-lang/noirup/main/install | bash
source ~/.bashrc

# Pin to the version we use (locks reproducibility)
noirup -v 1.0.0-beta.6
nargo --version            # expect: 1.0.0-beta.6

# Install Aztec's Barretenberg CLI for proving + verifier generation
curl -L https://raw.githubusercontent.com/AztecProtocol/aztec-packages/master/barretenberg/bbup/install | bash
source ~/.bashrc
bbup -v 0.79.0             # pin version
bb --version               # expect: 0.79.0
```

If `noirup.dev` or `bbup.dev` is referenced anywhere — that was an older
docs alias that 404s now. Use the raw GitHub URLs above.

### Compile the circuit

```bash
cd privacy/circuits/transfer
nargo compile
# outputs: target/transfer.json (ACIR + bytecode)
```

### Generate the EVM verifier

```bash
# From the ACIR, produce the on-chain verifier
bb write_solidity_verifier -b target/transfer.json -o ../verifier/Verifier.sol

# Sanity check the size — must fit in EIP-170 (24 KB)
wc -c ../verifier/Verifier.sol
```

### Regenerate the manifest

```bash
cd ../..  # back to privacy/circuits/
node ../scripts/build-manifest.js
# manifest.json now has SHA-256 of every artifact + toolchain versions
git diff manifest.json   # review before committing
```

### Run tests

```bash
cd ../test
forge test -vvv
# At least one test (TestRealProof) calls the prover with a synthesised
# witness and asserts the on-chain verifier accepts it. That's our
# end-to-end proof-of-life.
```

## Why no per-circuit ceremony

Noir uses Barretenberg's Plonk backend. Plonk has a **universal** trusted
setup — one ceremony covers all circuits up to a max size. That ceremony
was already run by Aztec (well-publicised, ~100 participants, audited
output is on IPFS). Anyone can verify the SRS, including auditors.

So unlike Railgun's Groth16 (which needs a fresh ceremony per circuit
variant), we don't run any ceremony ourselves. We download the existing
SRS via the `bb` toolchain and use it.

This is the single biggest reason we picked Noir over Railgun for sanect.

## What the ShieldedPool expects of the verifier

```solidity
function verify(bytes calldata proof, bytes32[] calldata publicInputs)
    external
    view
    returns (bool);
```

`Verifier.sol`'s generated `verify(bytes,bytes32[])` matches this exactly.
The pool just calls it; everything else (nullifier dedup, root tracking,
event emission) is the pool's responsibility.

## Until the real verifier lands

The pool falls back to `MockVerifier.sol`, which approves every proof.
**This is testnet-only.** `scripts/verify-chain.sh` will refuse to certify
a deployment whose `ShieldedPool.verifier()` still points at `MockVerifier`
(added in the Phase 2 PR).
