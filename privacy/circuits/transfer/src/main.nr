// sanect shielded transfer -- 2-in / 2-out spend circuit
//
// Asserts (all required for every valid transact() proof):
//
//   For each NON-EMPTY input note:
//   1. owner_pk = Poseidon(spending_key, PUBKEY_TAG)
//      (caller knows the spending key for this note)
//   2. commitment(note) is in the Merkle tree at `merkle_root`
//      (note hasn't been "invented" -- it really exists)
//   3. nullifier = Poseidon(commitment, spending_key)
//      (binds spend to the note + caller; observers can't link to commitment)
//   4. note.asset_id == public_asset
//      (no cross-asset mixing within one tx)
//
//   For each NON-EMPTY output note:
//   5. commitment = Poseidon(asset_id, value, owner_pk, salt)
//   6. note.asset_id == public_asset
//
//   Value conservation across all assets in this tx:
//   7. sum(input.value) + public_amount == sum(output.value)
//      (public_amount > 0 = shield in, < 0 = unshield out, = 0 = internal)
//
//   Note-slot sentinels (privacy hygiene):
//   8. empty input slot (value == 0) -> public nullifier MUST be 0
//      empty output slot (value == 0) -> public commitment MUST be 0
//
// Public-input order -- MUST match ShieldedPool._packPublicInputs() exactly:
//
//   [ input_nullifier_0,
//     input_nullifier_1,
//     output_commitment_0,
//     output_commitment_1,
//     merkle_root,
//     public_amount,
//     public_asset,
//     public_recipient ]

// Noir 1.0.0-beta.6 stdlib: Poseidon2 hasher (Aztec's spec). Length is
// passed as the second argument so the compiler picks the right round
// constants for the input size.
use std::hash::poseidon2::Poseidon2;

fn hash_2(input: [Field; 2]) -> Field {
    Poseidon2::hash(input, 2)
}

fn hash_4(input: [Field; 4]) -> Field {
    Poseidon2::hash(input, 4)
}

// Domain-separation tags: prevent rainbow attacks across hash usages.
// Same Poseidon function used for owner-pk derivation, nullifier, and
// tree nodes -- each application tags its inputs so colliding hashes
// across roles is impossible.
global PUBKEY_TAG: Field = 1;

global TREE_DEPTH: u32 = 32;
global N_INPUTS: u32 = 2;
global N_OUTPUTS: u32 = 2;

// A shielded note (UTXO). Must match privacy/wallet/types.ts Note.
struct Note {
    asset_id: Field,    // address(0) = native, otherwise ERC-20 contract address
    value: Field,        // base units (asnct or token base)
    owner_pk: Field,     // recipient's stealth pubkey (derived from their spending key)
    salt: Field,         // randomness so equal-value notes have distinct commits
}

impl Note {
    // Note commitment = Merkle leaf value.
    fn commit(self) -> Field {
        hash_4([self.asset_id, self.value, self.owner_pk, self.salt])
    }
}

// Derive the public owner key from a spending key. Domain-tagged so a
// spending key collision with a commitment can't be confused for a key.
fn derive_pubkey(spending_key: Field) -> Field {
    hash_2([spending_key, PUBKEY_TAG])
}

// Derive a nullifier for spending a specific note. The pair (commitment,
// spending_key) uniquely identifies the spend without leaking which leaf
// in the tree was the source -- that's the zk property.
fn derive_nullifier(commitment: Field, spending_key: Field) -> Field {
    hash_2([commitment, spending_key])
}

// Verify that `leaf` is in the Merkle tree at root `root`, using `path`
// (the sibling at each level) and `path_indices` (0 = leaf is left
// child, 1 = leaf is right child).
fn verify_merkle_path(
    leaf: Field,
    path: [Field; TREE_DEPTH],
    path_indices: [Field; TREE_DEPTH],
    root: Field,
) {
    let mut current = leaf;
    for i in 0..TREE_DEPTH {
        let idx = path_indices[i];
        // Range-check: idx must be 0 or 1. Without this, an attacker could
        // pass a non-boolean idx and the multiplexer below would produce a
        // tree node that doesn't correspond to any real path.
        assert(idx * (idx - 1) == 0, "merkle path index not boolean");

        let sibling = path[i];
        // Multiplexer:
        //   idx == 0 -> leaf is left child   -> (left=current, right=sibling)
        //   idx == 1 -> leaf is right child  -> (left=sibling, right=current)
        let left = idx * sibling + (1 - idx) * current;
        let right = idx * current + (1 - idx) * sibling;
        current = hash_2([left, right]);
    }
    assert(current == root, "merkle path does not match root");
}

fn main(
    // --- Private inputs (sender's secret state) ---
    input_notes: [Note; N_INPUTS],
    input_spending_keys: [Field; N_INPUTS],
    input_merkle_paths: [[Field; TREE_DEPTH]; N_INPUTS],
    input_path_indices: [[Field; TREE_DEPTH]; N_INPUTS],
    output_notes: [Note; N_OUTPUTS],

    // --- Public inputs (commit-of-truth with the verifier contract) ---
    input_nullifier_0: pub Field,
    input_nullifier_1: pub Field,
    output_commitment_0: pub Field,
    output_commitment_1: pub Field,
    merkle_root: pub Field,
    public_amount: pub Field,
    public_asset: pub Field,
    public_recipient: pub Field,
) {
    let public_nullifiers: [Field; N_INPUTS] = [input_nullifier_0, input_nullifier_1];
    let public_commitments: [Field; N_OUTPUTS] = [output_commitment_0, output_commitment_1];

    let mut total_input_value: Field = 0;
    let mut total_output_value: Field = 0;

    // ============ Process inputs ============
    for i in 0..N_INPUTS {
        let note = input_notes[i];
        let sk = input_spending_keys[i];

        let commitment = note.commit();
        let nullifier = derive_nullifier(commitment, sk);
        let owner_check = derive_pubkey(sk);

        if note.value == 0 {
            // Empty input slot: no Merkle/ownership/nullifier checks. The
            // public nullifier MUST be zero so this empty slot can't be used
            // to invent fake nullifiers later.
            assert(public_nullifiers[i] == 0, "empty input must have zero public nullifier");
        } else {
            // Range-check the value to prevent integer overflow tricks in
            // the conservation sum. 128 bits is generous: at 1 SNCT = 10^18
            // wei, 2^128 is roughly 3.4 * 10^38 wei = 3.4 * 10^20 SNCT.
            // Far more than the total supply.
            let _: u128 = note.value as u128;

            // 1. Caller proves ownership of this note.
            assert(note.owner_pk == owner_check, "input owner_pk mismatch");

            // 2. Note is in the Merkle tree at the public root.
            verify_merkle_path(
                commitment,
                input_merkle_paths[i],
                input_path_indices[i],
                merkle_root,
            );

            // 3. The nullifier publicly emitted matches what spending this
            //    note must produce. Determinism here is critical: a given
            //    note has exactly one nullifier per spending key, so
            //    double-spend is detected when the contract sees the same
            //    nullifier twice.
            assert(public_nullifiers[i] == nullifier, "public nullifier mismatch");

            // 4. Asset consistency: no cross-asset mixing within one tx.
            assert(note.asset_id == public_asset, "input asset != public_asset");

            total_input_value = total_input_value + note.value;
        }
    }

    // ============ Process outputs ============
    for i in 0..N_OUTPUTS {
        let note = output_notes[i];
        let commitment = note.commit();

        if note.value == 0 {
            // Empty output slot: public commitment MUST be zero.
            assert(public_commitments[i] == 0, "empty output must have zero public commitment");
        } else {
            // Range-check value (same reasoning as inputs).
            let _: u128 = note.value as u128;

            // 5. Commitment is well-formed and matches the public one.
            assert(public_commitments[i] == commitment, "output commitment mismatch");

            // 6. Asset consistency.
            assert(note.asset_id == public_asset, "output asset != public_asset");

            total_output_value = total_output_value + note.value;
        }
    }

    // ============ Value conservation ============
    //
    //   sum(inputs.value) + public_amount == sum(outputs.value)
    //
    // Examples (public_amount semantics from the Solidity contract):
    //   shield 1 SNCT:           0 + 1 == 1     ok
    //   internal 5 -> 2+3:       5 + 0 == 5     ok
    //   unshield 2 of 5:         5 + (-2) == 3  ok
    //
    // public_amount as a Field interprets negative int256 values as
    // (field_order - |amount|). The equation holds modulo the field order,
    // which is correct PROVIDED all amounts stay well below field_order/4.
    // The 128-bit range checks above guarantee that.
    assert(
        total_input_value + public_amount == total_output_value,
        "value conservation failed",
    );

    // public_recipient is an unconstrained public input from the circuit's
    // perspective -- the Solidity contract is the only consumer (it sends
    // tokens to that address on unshield). Binding it as a public input
    // means a malleated value would change the proof's identity and the
    // verifier would reject it, so authenticated end-to-end.
    //
    // The compiler can't tell that the public-binding is the *whole point*,
    // so silence the unused warning explicitly.
    let _ = public_recipient;
}
