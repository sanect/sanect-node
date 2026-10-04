// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier} from "./IVerifier.sol";

/// @notice Minimal ERC-20 interface (avoids dragging in openzeppelin in v1).
interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

/// @title ShieldedPool — sanect's multi-asset shielded value pool.
///
/// @notice Single contract holding shielded balances for **native SNCT** and
///         **any ERC-20**. One Noir 2-in/2-out circuit handles every flow:
///         shield, internal send, unshield. The public-amount field in the
///         circuit's public inputs determines which:
///
///             publicAmount > 0  : shield (caller sends asset INTO the pool)
///             publicAmount = 0  : internal send (no public asset movement)
///             publicAmount < 0  : unshield (pool sends |publicAmount| OUT)
///
///         The same 2-in/2-out shape lets the caller batch any pair of
///         operations on the same asset (e.g. "spend my 100 SNCT note +
///         my 50 SNCT note, send 80 to a public address, keep 70 as a
///         change note"). The circuit asserts:
///
///             Σ inputs.value == Σ outputs.value + publicAmount     (per asset)
///
///         Privacy properties:
///           - Sender anonymity: zk proof hides which two input notes were spent
///           - Amount privacy:   note values are hidden inside the commitment
///           - Receiver privacy: encrypted memo lets recipient auto-receive
///                               (no on-chain claim tx needed)
///           - Asset segregation: each asset has its own anonymity set
///
/// @dev    The Merkle tree + Poseidon hash are STUBBED in this phase
///         (the on-chain root is computed via keccak for cheap testing).
///         The real Poseidon-based incremental Merkle tree drops in alongside
///         the real verifier in PR 4. The TX ABI does NOT change at that
///         point; only the internal `_insertCommitment` switches hash function.
contract ShieldedPool {
    // ============================================================
    //                      CONFIG / OWNER
    // ============================================================

    /// @notice Address allowed to rotate the verifier (testnet only).
    /// @dev    On mainnet this becomes a timelock / governance contract.
    address public owner;

    /// @notice Current ZK proof verifier. Swappable so MockVerifier can be
    ///         replaced with the real Noir-generated verifier without
    ///         redeploying the pool.
    IVerifier public verifier;

    // ============================================================
    //                       CIRCUIT SHAPE
    // ============================================================

    /// @notice Number of input notes a single transact() consumes.
    /// @dev    Matches the Noir circuit. Larger batches happen in multiple
    ///         txs. Why 2: covers 95%+ of real flows (spend one note +
    ///         change, or merge two notes), keeps the circuit small.
    uint256 public constant INPUTS = 2;

    /// @notice Number of output notes a single transact() produces.
    /// @dev    Matches the Noir circuit. Same reasoning as INPUTS.
    uint256 public constant OUTPUTS = 2;

    /// @notice Required length of every `encryptedMemo` blob.
    /// @dev    Fixed at 240 bytes:
    ///           32  ephemeralPk
    ///         + 96  ChaCha20 ciphertext
    ///         + 16  Poly1305 MAC
    ///         + 96  FMD flag (RESERVED — all zero today)
    ///         = 240
    ///         A constant size is a privacy property: variable lengths would
    ///         let observers fingerprint memos by their byte counts. The
    ///         trailing 96-byte FMD region is reserved for Phase 4 of
    ///         PRIVACY.md (Penumbra-style fuzzy message detection). The pool
    ///         does NOT inspect the FMD bytes — it just enforces total
    ///         memo length so receivers see the format they expect and an
    ///         off-chain indexer can pre-filter on the flag once active.
    ///         The wallet's `MEMO_SIZE_BYTES` (in privacy/wallet/types.ts)
    ///         MUST agree with this value.
    uint256 public constant MEMO_SIZE = 240;

    // ============================================================
    //                  COMMITMENT TREE (STUB)
    // ============================================================

    /// @notice Tree depth — supports 2^TREE_DEPTH notes total before exhaustion.
    /// @dev    32 gives ~4.3 billion notes. The Noir merkle.nr circuit
    ///         expects this exact depth — any change requires recompiling.
    uint256 public constant TREE_DEPTH = 32;

    /// @notice Current Merkle root over the commitment tree.
    /// @dev    STUB: keccak-derived rolling root. Real version is Poseidon-
    ///         based incremental Merkle root, computed inline with each
    ///         _insertCommitment so we never hash the whole tree on chain.
    bytes32 public merkleRoot;

    /// @notice All inserted commitments in insertion order (Merkle leaves).
    bytes32[] public commitments;

    /// @notice Has this commitment been inserted before? Prevents replay /
    ///         dup commitments (which would corrupt the tree state).
    mapping(bytes32 => bool) public commitmentSeen;

    /// @notice Recent merkle roots accepted by transact proofs.
    /// @dev    Window of 32 roots so a proof built against a slightly stale
    ///         root (a few blocks old) still verifies, even if new
    ///         commitments arrived between proof generation + submit.
    uint256 public constant ROOT_HISTORY = 32;
    bytes32[ROOT_HISTORY] public recentRoots;
    uint256 public rootCursor;

    // ============================================================
    //                  NULLIFIER SET
    // ============================================================

    /// @notice Has this nullifier already been used? Nullifier == 1-1 with a
    ///         spent note, but reveals nothing about which note (zk magic).
    mapping(bytes32 => bool) public nullifierSpent;

    // ============================================================
    //                    EVENTS
    // ============================================================

    /// @notice Emitted for every new shielded note. Wallets scan these
    ///         events and trial-decrypt `encryptedMemo` with their viewing
    ///         key to detect notes addressed to them. **This is the
    ///         auto-receive channel — no on-chain claim tx ever needed.**
    event CommitmentAdded(
        uint256 indexed leafIndex,
        bytes32 commitment,
        bytes32 newMerkleRoot,
        bytes   encryptedMemo
    );

    /// @notice Emitted on each spent note. Lets wallets detect their own
    ///         spends across browsers/devices by remembering nullifiers
    ///         they generated.
    event NullifierUsed(bytes32 indexed nullifier);

    /// @notice Emitted when value flows IN from public to shielded (shield).
    ///         `asset` and `amount` are publicly visible — that's intentional;
    ///         the shielding step itself isn't hidden, only the per-account
    ///         balances after.
    event Shield(address indexed from, address indexed asset, uint256 amount);

    /// @notice Emitted when value flows OUT from shielded to public (unshield).
    event Unshield(address indexed to, address indexed asset, uint256 amount);

    /// @notice Emitted when a transact() with publicAmount == 0 happens.
    ///         No asset/amount/sender/recipient is visible — only that
    ///         a shielded-internal send took place. This is the maximum-
    ///         privacy event type.
    event InternalSend(uint256 inputCount, uint256 outputCount);

    /// @notice Verifier rotation log (testnet only).
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    // ============================================================
    //                    ERRORS
    // ============================================================

    error NotOwner();
    error ZeroAddress();
    error InvalidProof();
    error UnknownRoot();
    error NullifierAlreadyUsed();
    error CommitmentAlreadyAdded();
    error BadMemoSize();
    error BadArrayLength();
    error NativeValueWithErc20();
    error NativeValueMismatch();
    error EthTransferFailed();
    error TokenTransferFailed();
    error UnsupportedAsset();
    error PublicAmountZeroButValueSent();

    // ============================================================
    //                    REENTRANCY
    // ============================================================

    uint256 private _entered;
    modifier nonReentrant() {
        require(_entered == 0, "reentrant");
        _entered = 1;
        _;
        _entered = 0;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ============================================================
    //                    CONSTRUCTOR
    // ============================================================

    constructor(address verifier_, address owner_) {
        if (verifier_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        verifier = IVerifier(verifier_);
        owner = owner_;
    }

    // ============================================================
    //                    OWNER ACTIONS
    // ============================================================

    /// @notice Swap the verifier. MockVerifier → real Noir verifier in PR 4.
    function setVerifier(address newVerifier) external onlyOwner {
        if (newVerifier == address(0)) revert ZeroAddress();
        emit VerifierUpdated(address(verifier), newVerifier);
        verifier = IVerifier(newVerifier);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    // ============================================================
    //                    TRANSACT  (the only entry point)
    // ============================================================

    /// @notice Single entry point for shield / internal send / unshield.
    ///         Which one happens is determined by `publicAmount`:
    ///
    ///             > 0 : shield   — caller deposits |publicAmount| of `publicAsset` into pool
    ///             = 0 : internal — pool balances unchanged; only notes shuffle
    ///             < 0 : unshield — pool sends |publicAmount| of `publicAsset` to publicRecipient
    ///
    /// @param proof              Plonk proof bytes from the Noir prover.
    /// @param inputNullifiers    Exactly INPUTS nullifiers (use sentinel-zero for "no note here").
    /// @param outputCommitments  Exactly OUTPUTS new note commitments.
    /// @param encryptedMemos     Exactly OUTPUTS encrypted memos (one per commitment).
    ///                           For non-empty commitment slot: MEMO_SIZE bytes.
    ///                           For empty (sentinel-zero) commitment slot: 0 bytes.
    /// @param historicRoot       Merkle root the proof was built against (must be recent).
    /// @param publicAmount       Net public value flow. >0 = shield, <0 = unshield, =0 = internal.
    /// @param publicAsset        address(0) for native SNCT, otherwise the ERC-20 contract.
    /// @param publicRecipient    Where unshielded value goes. Ignored unless publicAmount < 0.
    ///
    /// @dev Arrays are typed dynamic (not fixed-size) because Solidity's
    ///      `bytes[N] calldata` does NOT ABI-decode reliably when the caller
    ///      passes from memory — the decoder panics before our function
    ///      body runs. Dynamic arrays work in every case; we enforce the
    ///      INPUTS/OUTPUTS length at the top of the function instead.
    function transact(
        bytes calldata proof,
        bytes32[] calldata inputNullifiers,
        bytes32[] calldata outputCommitments,
        bytes[] calldata encryptedMemos,
        bytes32 historicRoot,
        int256 publicAmount,
        address publicAsset,
        address publicRecipient
    ) external payable nonReentrant {
        // 0. Shape — every transact() has exactly INPUTS nullifiers + OUTPUTS
        //    commitments + OUTPUTS memos. The Noir circuit hardcodes the same
        //    shape; both ends must agree.
        if (inputNullifiers.length != INPUTS) revert BadArrayLength();
        if (outputCommitments.length != OUTPUTS) revert BadArrayLength();
        if (encryptedMemos.length != OUTPUTS) revert BadArrayLength();

        // 1. Validate the proof against the public inputs the circuit expects.
        //    The order here MUST match the Noir circuit's main() signature
        //    exactly — any deviation makes every proof fail to verify so the
        //    chain catches it before funds move.
        bytes32[] memory publicInputs = _packPublicInputs(
            inputNullifiers,
            outputCommitments,
            historicRoot,
            publicAmount,
            publicAsset,
            publicRecipient
        );
        if (!verifier.verify(proof, publicInputs)) revert InvalidProof();

        // 2. Root must be one of the recent ones.
        if (!_rootKnown(historicRoot)) revert UnknownRoot();

        // 3. Consume input notes (nullifiers). Sentinel-zero is allowed and
        //    means "this slot has no input note" (the circuit will have
        //    asserted that the corresponding value contribution is zero too).
        uint256 spent;
        for (uint256 i = 0; i < INPUTS; ++i) {
            bytes32 n = inputNullifiers[i];
            if (n == bytes32(0)) continue;
            if (nullifierSpent[n]) revert NullifierAlreadyUsed();
            nullifierSpent[n] = true;
            emit NullifierUsed(n);
            unchecked { ++spent; }
        }

        // 4. Insert new commitments + emit memos for auto-receive.
        uint256 emitted;
        for (uint256 i = 0; i < OUTPUTS; ++i) {
            bytes32 c = outputCommitments[i];
            if (c == bytes32(0)) {
                // empty output slot — must have a 0-length memo
                if (encryptedMemos[i].length != 0) revert BadArrayLength();
                continue;
            }
            _insertCommitment(c, encryptedMemos[i]);
            unchecked { ++emitted; }
        }

        // 5. Handle the public-side value flow.
        if (publicAmount > 0) {
            // SHIELD: caller is depositing into the pool.
            uint256 amt = uint256(publicAmount);
            if (publicAsset == address(0)) {
                if (msg.value != amt) revert NativeValueMismatch();
            } else {
                if (msg.value != 0) revert NativeValueWithErc20();
                bool ok = IERC20Minimal(publicAsset).transferFrom(msg.sender, address(this), amt);
                if (!ok) revert TokenTransferFailed();
            }
            emit Shield(msg.sender, publicAsset, amt);
        } else if (publicAmount < 0) {
            // UNSHIELD: pool pays out to publicRecipient.
            if (msg.value != 0) revert NativeValueMismatch(); // unshield must not carry value
            if (publicRecipient == address(0)) revert ZeroAddress();
            uint256 amt = uint256(-publicAmount);
            if (publicAsset == address(0)) {
                (bool ok,) = publicRecipient.call{value: amt}("");
                if (!ok) revert EthTransferFailed();
            } else {
                bool ok = IERC20Minimal(publicAsset).transfer(publicRecipient, amt);
                if (!ok) revert TokenTransferFailed();
            }
            emit Unshield(publicRecipient, publicAsset, amt);
        } else {
            // INTERNAL: no public value flow. msg.value must be zero too.
            if (msg.value != 0) revert PublicAmountZeroButValueSent();
            emit InternalSend(spent, emitted);
        }
    }

    // ============================================================
    //                    READS
    // ============================================================

    function commitmentCount() external view returns (uint256) {
        return commitments.length;
    }

    // ============================================================
    //                    INTERNAL
    // ============================================================

    /// @dev Insert a commitment and roll the root forward. PHASE-0 STUB:
    ///      naive keccak chain. The real Phase-1 version uses an incremental
    ///      Poseidon Merkle tree (matches what the Noir circuit verifies),
    ///      keeping the tree state in storage and computing root in O(depth)
    ///      per insertion. The interface this function exposes (memo emit
    ///      + recentRoots ring buffer) is identical in both versions.
    function _insertCommitment(bytes32 commitment, bytes memory encryptedMemo) internal {
        if (encryptedMemo.length != MEMO_SIZE) revert BadMemoSize();
        if (commitmentSeen[commitment]) revert CommitmentAlreadyAdded();
        commitmentSeen[commitment] = true;
        uint256 idx = commitments.length;
        commitments.push(commitment);

        bytes32 newRoot = keccak256(abi.encode(merkleRoot, commitment));
        merkleRoot = newRoot;
        recentRoots[rootCursor] = newRoot;
        rootCursor = (rootCursor + 1) % ROOT_HISTORY;

        emit CommitmentAdded(idx, commitment, newRoot, encryptedMemo);
    }

    function _rootKnown(bytes32 root) internal view returns (bool) {
        if (root == merkleRoot) return true;
        for (uint256 i = 0; i < ROOT_HISTORY; ++i) {
            if (recentRoots[i] == root) return true;
        }
        return false;
    }

    /// @dev Pack typed public inputs into the bytes32[] the verifier expects.
    ///      Field order is contract-of-truth between the Noir circuit and
    ///      this contract — any divergence breaks every proof.
    /// BN254 scalar field modulus — must match Aztec's verifier.
    /// Used to encode negative publicAmount as field-negative (p - |x|)
    /// instead of two's-complement (2^256 - |x|), which would not reduce
    /// to zero mod p and break the circuit's value-conservation check.
    uint256 internal constant BN254_P =
        0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    function _packPublicInputs(
        bytes32[] calldata inputNullifiers,
        bytes32[] calldata outputCommitments,
        bytes32 historicRoot,
        int256 publicAmount,
        address publicAsset,
        address publicRecipient
    ) internal pure returns (bytes32[] memory out) {
        // Order: [nullifiers..., commitments..., root, publicAmount,
        //         publicAsset, publicRecipient]
        // Total length: INPUTS + OUTPUTS + 4
        out = new bytes32[](INPUTS + OUTPUTS + 4);
        uint256 k;
        for (uint256 i = 0; i < INPUTS; ++i) out[k++] = inputNullifiers[i];
        for (uint256 i = 0; i < OUTPUTS; ++i) out[k++] = outputCommitments[i];
        out[k++] = historicRoot;
        // Encode signed publicAmount as a BN254 field element.
        //   positive: x (unchanged)
        //   negative: p - |x| (field-negative — matches circuit's interpretation)
        // We can't use bytes32(uint256(publicAmount)) for the negative case
        // because that's 2^256 - |x|, and 2^256 mod p ≠ 0.
        if (publicAmount >= 0) {
            out[k++] = bytes32(uint256(publicAmount));
        } else {
            out[k++] = bytes32(BN254_P - uint256(-publicAmount));
        }
        out[k++] = bytes32(uint256(uint160(publicAsset)));
        out[k++] = bytes32(uint256(uint160(publicRecipient)));
    }

    /// @notice Accept native SNCT received outside of transact() (e.g.
    ///         selfdestruct dust). Not used in normal operation.
    receive() external payable {}
}
