// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVerifier — ZK proof verifier interface for the sanect shielded pool.
/// @notice The ShieldedPool calls this to check every shielded transaction proof.
///
///         The signature MATCHES bb's auto-generated HonkVerifier.verify
///         exactly. We can cast a deployed HonkVerifier address to
///         IVerifier and call straight through — same 4-byte selector,
///         same calldata layout, same return type.
///
///           verify(bytes calldata proof, bytes32[] calldata publicInputs)
///               external view returns (bool);
///
///         Public-input order is locked in privacy/circuits/manifest.json
///         and must match the Noir circuit's `pub Field` declaration order
///         exactly:
///
///           [ input_nullifier_0,
///             input_nullifier_1,
///             output_commitment_0,
///             output_commitment_1,
///             merkle_root,
///             public_amount,
///             public_asset,
///             public_recipient ]
interface IVerifier {
    /// @notice Verify a zero-knowledge proof against public inputs.
    /// @param proof        Opaque proof bytes (UltraHonk format from bb).
    /// @param publicInputs Public inputs in the locked order. See above.
    /// @return ok          True if the proof verifies against publicInputs.
    function verify(bytes calldata proof, bytes32[] calldata publicInputs)
        external
        view
        returns (bool ok);
}
