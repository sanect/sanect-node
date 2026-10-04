// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier} from "./IVerifier.sol";

/// @title MockVerifier — always returns true. PHASE 0 ONLY.
/// @notice This is a stub so the ShieldedPool can be developed and tested
///         before the real Noir-generated verifier exists. Deploying this
///         to a real network would let an attacker spend any note by
///         submitting an empty proof.
///
/// @custom:security DO NOT use on mainnet. `scripts/verify-chain.sh`
///                  refuses to certify a deploy whose pool points here.
contract MockVerifier is IVerifier {
    function verify(bytes calldata, bytes32[] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}
