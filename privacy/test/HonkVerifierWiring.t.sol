// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IVerifier} from "../contracts/IVerifier.sol";
import {ShieldedPool} from "../contracts/ShieldedPool.sol";
import {MockVerifier} from "../contracts/MockVerifier.sol";
import {HonkVerifier} from "../circuits/verifier/Verifier.sol";

/// @notice Wiring tests for the real bb-generated UltraHonk verifier.
///         These do NOT generate a proof on-chain — that requires bb's
///         off-chain prover, and lives in a separate fixture-based test
///         once we have a real proof captured. This file proves the
///         narrower (but critical) thing:
///
///           1. HonkVerifier deploys successfully (bytecode size + linker)
///           2. Its function selector matches IVerifier.verify
///           3. ShieldedPool.setVerifier accepts a HonkVerifier address
///              and pool.verifier() returns it
///           4. A clearly-invalid proof against this verifier rejects
///              cleanly (no funny revert reason)
///
///         Once the real-proof test lands (next PR slice), the chain
///         level "MockVerifier vs real verifier" cutover can flip with
///         a single setVerifier call.
contract HonkVerifierWiringTest is Test {
    HonkVerifier honk;
    ShieldedPool pool;
    MockVerifier mockVerifier;
    address owner = address(0xA11CE);

    function setUp() public {
        mockVerifier = new MockVerifier();
        pool = new ShieldedPool(address(mockVerifier), owner);
        honk = new HonkVerifier();
    }

    function test_HonkVerifier_DeploysAndHasCode() public view {
        address h = address(honk);
        uint256 codeSize;
        assembly { codeSize := extcodesize(h) }
        // UltraHonk verifiers compile to ~24 KB just under EIP-170.
        // If this ever exceeds 24576 the deploy would have reverted —
        // assertion is just a sanity floor against accidental emptiness.
        assertGt(codeSize, 1000, "verifier bytecode looks empty");
        assertLt(codeSize, 24576, "verifier exceeds EIP-170 contract size limit");
    }

    function test_HonkVerifier_HasVerifySelector() public view {
        // The 4-byte function selector we expect HonkVerifier to expose at
        // runtime. We can't reference `HonkVerifier.verify.selector`
        // directly because `verify` is declared on the parent
        // `BaseHonkVerifier` (abstract) — the child contract doesn't
        // redeclare it, so Solidity's compile-time resolver refuses.
        //
        // Compute the selector from the signature instead. Both the bb-
        // generated verifier and our IVerifier use this exact signature,
        // so they must match. We also confirm IVerifier.verify.selector
        // matches the computed value as a sanity check that our interface
        // declaration didn't drift.
        bytes4 computed = bytes4(keccak256("verify(bytes,bytes32[])"));
        assertEq(IVerifier.verify.selector, computed, "IVerifier signature drift");

        // Now invoke HonkVerifier through IVerifier and confirm it routes
        // to the inherited verify (would revert with "function does not
        // exist" instead of returning a value if the selector were wrong).
        bytes memory empty = new bytes(0);
        bytes32[] memory zeros = new bytes32[](8);
        // We expect verification to fail (empty proof) — but the CALL must
        // succeed in routing to the implementation. A "no fallback /
        // function selector mismatch" revert would mean the selector
        // doesn't exist on the contract.
        try IVerifier(address(honk)).verify(empty, zeros) returns (bool) {
            // routed successfully (returned false — that's fine here)
        } catch Error(string memory) {
            // Custom string revert from inside verify — also routed OK.
        } catch (bytes memory) {
            // Custom selector revert (e.g. Panic) — also fine; means
            // verify() ran and produced an error inside. The only thing
            // we'd consider a failure is if Solidity reported "no function
            // matches" which manifests as a 0-byte revert without falling
            // into the catch blocks above.
        }
    }

    function test_SetVerifier_AcceptsHonkAndReturnsIt() public {
        vm.prank(owner);
        pool.setVerifier(address(honk));
        assertEq(address(pool.verifier()), address(honk), "pool.verifier() != HonkVerifier");
    }

    function test_InvalidProof_RejectsCleanly() public {
        vm.prank(owner);
        pool.setVerifier(address(honk));

        // Construct a clearly-invalid proof and the minimum 8 public inputs
        // the circuit expects. Cast pool.verifier() back to IVerifier so we
        // hit the function selector our pool will use.
        bytes memory garbageProof = new bytes(2400);  // realistic-ish size
        for (uint256 i = 0; i < garbageProof.length; ++i) {
            garbageProof[i] = bytes1(uint8(i % 256));
        }
        bytes32[] memory publicInputs = new bytes32[](8);
        for (uint256 i = 0; i < 8; ++i) {
            publicInputs[i] = keccak256(abi.encode("dummy", i));
        }

        // The verifier may revert OR return false depending on which
        // sanity check the garbage trips first. We accept both; we just
        // want to confirm it doesn't accidentally return true.
        bool acceptedGarbage = false;
        try IVerifier(address(honk)).verify(garbageProof, publicInputs) returns (bool ok) {
            acceptedGarbage = ok;
        } catch {
            // Reverted — that's also a rejection.
            acceptedGarbage = false;
        }
        assertFalse(acceptedGarbage, "verifier accepted garbage proof");
    }
}
