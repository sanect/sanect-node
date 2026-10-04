// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ShieldedPool} from "../contracts/ShieldedPool.sol";
import {MockVerifier} from "../contracts/MockVerifier.sol";

/// @notice Minimal ERC-20 for the multi-asset shielding tests.
contract MockERC20 {
    string public name = "MockUSD";
    string public symbol = "MUSD";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

/// @notice Integration tests for the multi-asset transact() API.
/// MockVerifier approves every proof, so these tests cover storage / events
/// / access control / value flow. Circuit-level invariants come in PR 4.
///
/// IMPORTANT test-writing rules (the v1 version of this file violated both):
///   1. Cache pool.merkleRoot() into a local BEFORE vm.prank. An inline
///      external read consumes the prank for the wrong call.
///   2. Args to pool.transact() must use bytes32[] / bytes[] (dynamic) not
///      bytes32[N] / bytes[N] (fixed-size). The latter fails to ABI-decode
///      when passed from memory, causing transact to revert before our
///      body runs and Forge reports "did not revert as expected".
contract ShieldedPoolTest is Test {
    ShieldedPool pool;
    MockVerifier mockVerifier;
    MockERC20 token;

    address owner = address(0xA11CE);
    address alice = address(0xBABE);
    address bob   = address(0xCAFE);
    address carol = address(0xD00D);

    function setUp() public {
        mockVerifier = new MockVerifier();
        pool = new ShieldedPool(address(mockVerifier), owner);
        token = new MockERC20();
        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
        token.mint(alice, 1_000_000e6);
        token.mint(bob,   1_000_000e6);
    }

    // ------------------------- helpers ------------------------------

    function _memo(bytes1 fill) internal view returns (bytes memory out) {
        uint256 n = pool.MEMO_SIZE();
        out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) out[i] = fill;
    }

    /// @dev One-output shield args. Dynamic arrays so calldata ABI-decode
    ///      works from memory call sites.
    function _shieldArgs(bytes32 commitment, bytes memory memo)
        internal pure
        returns (
            bytes32[] memory nullifiers,
            bytes32[] memory commitments,
            bytes[] memory memos
        )
    {
        nullifiers = new bytes32[](2);
        commitments = new bytes32[](2);
        memos = new bytes[](2);
        commitments[0] = commitment;
        memos[0] = memo;
        memos[1] = new bytes(0);
    }

    function _proof() internal pure returns (bytes memory) {
        return hex"deadbeef";
    }

    // ============================================================
    //                     SHIELD (publicAmount > 0)
    // ============================================================

    function test_ShieldNative_AddsCommitment_EmitsShield() public {
        bytes32 commitment = keccak256("alice-note-1");
        (bytes32[] memory n, bytes32[] memory c, bytes[] memory m) =
            _shieldArgs(commitment, _memo(0xab));
        bytes32 root = pool.merkleRoot();   // cached BEFORE prank

        vm.expectEmit(true, true, false, true);
        emit ShieldedPool.Shield(alice, address(0), 1 ether);

        vm.prank(alice);
        pool.transact{value: 1 ether}(
            _proof(), n, c, m,
            root,
            int256(1 ether),
            address(0),
            address(0)
        );

        assertEq(pool.commitmentCount(), 1);
        assertTrue(pool.commitmentSeen(commitment));
        assertEq(address(pool).balance, 1 ether);
    }

    function test_ShieldERC20_TransfersFromCaller() public {
        bytes32 commitment = keccak256("alice-usdc-1");
        (bytes32[] memory n, bytes32[] memory c, bytes[] memory m) =
            _shieldArgs(commitment, _memo(0x11));
        bytes32 root = pool.merkleRoot();

        vm.prank(alice);
        token.approve(address(pool), 1000e6);

        vm.expectEmit(true, true, false, true);
        emit ShieldedPool.Shield(alice, address(token), 1000e6);

        vm.prank(alice);
        pool.transact(
            _proof(), n, c, m,
            root,
            int256(1000e6),
            address(token),
            address(0)
        );

        assertEq(token.balanceOf(address(pool)), 1000e6);
    }

    function test_ShieldNative_RejectsMismatchedValue() public {
        (bytes32[] memory n, bytes32[] memory c, bytes[] memory m) =
            _shieldArgs(keccak256("x"), _memo(0x00));
        bytes32 root = pool.merkleRoot();

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NativeValueMismatch.selector);
        pool.transact{value: 0.5 ether}(
            _proof(), n, c, m,
            root,
            int256(1 ether),
            address(0),
            address(0)
        );
    }

    function test_ShieldERC20_RejectsNativeValueAttached() public {
        (bytes32[] memory n, bytes32[] memory c, bytes[] memory m) =
            _shieldArgs(keccak256("x"), _memo(0x00));
        bytes32 root = pool.merkleRoot();

        vm.prank(alice);
        token.approve(address(pool), 100e6);

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NativeValueWithErc20.selector);
        pool.transact{value: 1 ether}(
            _proof(), n, c, m,
            root,
            int256(100e6),
            address(token),
            address(0)
        );
    }

    // ============================================================
    //                INTERNAL SEND (publicAmount == 0)
    // ============================================================

    function test_InternalSend_NoValueFlow_EmitsInternal() public {
        _seedShield(alice, 5 ether, address(0));
        bytes32 root = pool.merkleRoot();

        bytes32[] memory n = new bytes32[](2);
        n[0] = keccak256("alice-spent");
        bytes32[] memory c = new bytes32[](2);
        c[0] = keccak256("bob-receive");
        c[1] = keccak256("alice-change");
        bytes[] memory m = new bytes[](2);
        m[0] = _memo(0xb0);
        m[1] = _memo(0xc0);

        vm.expectEmit(false, false, false, true);
        emit ShieldedPool.InternalSend(1, 2);

        vm.prank(alice);
        pool.transact(_proof(), n, c, m, root, int256(0), address(0), address(0));

        assertEq(pool.commitmentCount(), 3); // 1 seed + 2 new
        assertTrue(pool.nullifierSpent(n[0]));
        assertEq(address(pool).balance, 5 ether); // unchanged
    }

    function test_InternalSend_RejectsNativeValueAttached() public {
        _seedShield(alice, 5 ether, address(0));
        bytes32 root = pool.merkleRoot();

        bytes32[] memory n = new bytes32[](2);
        n[0] = keccak256("alice-spent-int");
        bytes32[] memory c = new bytes32[](2);
        c[0] = keccak256("internal-c1");
        bytes[] memory m = new bytes[](2);
        m[0] = _memo(0x77);
        m[1] = new bytes(0);

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.PublicAmountZeroButValueSent.selector);
        pool.transact{value: 1 wei}(
            _proof(), n, c, m,
            root,
            int256(0),
            address(0),
            address(0)
        );
    }

    // ============================================================
    //                  UNSHIELD (publicAmount < 0)
    // ============================================================

    function test_UnshieldNative_PaysRecipient_EmitsUnshield() public {
        _seedShield(alice, 5 ether, address(0));
        bytes32 root = pool.merkleRoot();

        uint256 carolBefore = carol.balance;
        bytes32[] memory n = new bytes32[](2);
        n[0] = keccak256("alice-spent-unshield");
        bytes32[] memory c = new bytes32[](2);
        c[0] = keccak256("alice-change-unshield");
        bytes[] memory m = new bytes[](2);
        m[0] = _memo(0xee);
        m[1] = new bytes(0);

        vm.expectEmit(true, true, false, true);
        emit ShieldedPool.Unshield(carol, address(0), 2 ether);

        vm.prank(alice);
        pool.transact(
            _proof(), n, c, m,
            root,
            -int256(2 ether),
            address(0),
            carol
        );

        assertEq(carol.balance - carolBefore, 2 ether);
        assertEq(address(pool).balance, 3 ether);
    }

    function test_UnshieldERC20_PaysRecipient() public {
        _seedShield(alice, 1000e6, address(token));
        bytes32 root = pool.merkleRoot();

        bytes32[] memory n = new bytes32[](2);
        n[0] = keccak256("alice-spent-usdc-unshield");
        bytes32[] memory c = new bytes32[](2);
        c[0] = keccak256("alice-change-usdc");
        bytes[] memory m = new bytes[](2);
        m[0] = _memo(0x21);
        m[1] = new bytes(0);

        uint256 carolBefore = token.balanceOf(carol);

        vm.prank(alice);
        pool.transact(
            _proof(), n, c, m,
            root,
            -int256(400e6),
            address(token),
            carol
        );

        assertEq(token.balanceOf(carol) - carolBefore, 400e6);
        assertEq(token.balanceOf(address(pool)), 600e6);
    }

    function test_Unshield_RejectsZeroRecipient() public {
        _seedShield(alice, 5 ether, address(0));
        bytes32 root = pool.merkleRoot();

        bytes32[] memory n = new bytes32[](2);
        n[0] = keccak256("alice-spent-zr");
        bytes32[] memory c = new bytes32[](2);
        bytes[] memory m = new bytes[](2);
        m[0] = new bytes(0);
        m[1] = new bytes(0);

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.ZeroAddress.selector);
        pool.transact(
            _proof(), n, c, m,
            root,
            -int256(1 ether),
            address(0),
            address(0)
        );
    }

    function test_Unshield_RejectsValueAttached() public {
        _seedShield(alice, 5 ether, address(0));
        bytes32 root = pool.merkleRoot();

        bytes32[] memory n = new bytes32[](2);
        n[0] = keccak256("alice-spent-va");
        bytes32[] memory c = new bytes32[](2);
        bytes[] memory m = new bytes[](2);
        m[0] = new bytes(0);
        m[1] = new bytes(0);

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NativeValueMismatch.selector);
        pool.transact{value: 1}(
            _proof(), n, c, m,
            root,
            -int256(1 ether),
            address(0),
            carol
        );
    }

    // ============================================================
    //                     STORAGE INVARIANTS
    // ============================================================

    function test_RejectsDuplicateCommitment() public {
        bytes32 commitment = keccak256("dup");
        (bytes32[] memory n, bytes32[] memory c, bytes[] memory m) =
            _shieldArgs(commitment, _memo(0x01));
        bytes32 root1 = pool.merkleRoot();

        vm.prank(alice);
        pool.transact{value: 1 ether}(
            _proof(), n, c, m,
            root1,
            int256(1 ether),
            address(0),
            address(0)
        );

        bytes32 root2 = pool.merkleRoot();
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.CommitmentAlreadyAdded.selector);
        pool.transact{value: 1 ether}(
            _proof(), n, c, m,
            root2,
            int256(1 ether),
            address(0),
            address(0)
        );
    }

    function test_RejectsReusedNullifier() public {
        _seedShield(alice, 5 ether, address(0));
        bytes32 root1 = pool.merkleRoot();

        bytes32[] memory n = new bytes32[](2);
        n[0] = keccak256("dup-nullifier");
        bytes32[] memory c = new bytes32[](2);
        c[0] = keccak256("dup-null-c1");
        bytes[] memory m = new bytes[](2);
        m[0] = _memo(0x33);
        m[1] = new bytes(0);

        vm.prank(alice);
        pool.transact(
            _proof(), n, c, m,
            root1,
            int256(0),
            address(0),
            address(0)
        );

        // Second send reusing the same nullifier must revert.
        bytes32 root2 = pool.merkleRoot();
        bytes32[] memory c2 = new bytes32[](2);
        c2[0] = keccak256("dup-null-c2");
        bytes[] memory m2 = new bytes[](2);
        m2[0] = _memo(0x44);
        m2[1] = new bytes(0);
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NullifierAlreadyUsed.selector);
        pool.transact(
            _proof(), n, c2, m2,
            root2,
            int256(0),
            address(0),
            address(0)
        );
    }

    function test_RejectsUnknownRoot() public {
        bytes32[] memory n = new bytes32[](2); n[0] = keccak256("a");
        bytes32[] memory c = new bytes32[](2); c[0] = keccak256("b");
        bytes[] memory m = new bytes[](2); m[0] = _memo(0xaa); m[1] = new bytes(0);

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.UnknownRoot.selector);
        pool.transact(
            _proof(), n, c, m,
            keccak256("fake-root"),
            int256(0),
            address(0),
            address(0)
        );
    }

    function test_RejectsBadMemoSize() public {
        bytes32[] memory n = new bytes32[](2);
        bytes32[] memory c = new bytes32[](2); c[0] = keccak256("bad-memo");
        bytes[] memory m = new bytes[](2); m[0] = hex"1234"; m[1] = new bytes(0);
        bytes32 root = pool.merkleRoot();

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.BadMemoSize.selector);
        pool.transact{value: 1 ether}(
            _proof(), n, c, m,
            root,
            int256(1 ether),
            address(0),
            address(0)
        );
    }

    function test_AllowsZeroCommitmentSlot_WithZeroMemo() public {
        bytes32[] memory n = new bytes32[](2);
        bytes32[] memory c = new bytes32[](2); c[0] = keccak256("only-output");
        bytes[] memory m = new bytes[](2); m[0] = _memo(0xa1); m[1] = new bytes(0);
        bytes32 root = pool.merkleRoot();

        vm.prank(alice);
        pool.transact{value: 1 ether}(
            _proof(), n, c, m,
            root,
            int256(1 ether),
            address(0),
            address(0)
        );
        assertEq(pool.commitmentCount(), 1);
    }

    function test_RejectsEmptyCommitmentSlot_WithNonEmptyMemo() public {
        bytes32[] memory n = new bytes32[](2);
        bytes32[] memory c = new bytes32[](2); c[0] = keccak256("only-output-bad");
        bytes[] memory m = new bytes[](2); m[0] = _memo(0xa1); m[1] = _memo(0xb1);
        bytes32 root = pool.merkleRoot();

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.BadArrayLength.selector);
        pool.transact{value: 1 ether}(
            _proof(), n, c, m,
            root,
            int256(1 ether),
            address(0),
            address(0)
        );
    }

    function test_RejectsWrongArrayLengths() public {
        bytes32[] memory n = new bytes32[](1);   // wrong length
        bytes32[] memory c = new bytes32[](2);
        bytes[] memory m = new bytes[](2);
        bytes32 root = pool.merkleRoot();

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.BadArrayLength.selector);
        pool.transact(_proof(), n, c, m, root, int256(0), address(0), address(0));
    }

    // ============================================================
    //                       OWNERSHIP
    // ============================================================

    function test_SetVerifier_OnlyOwner() public {
        MockVerifier other = new MockVerifier();
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NotOwner.selector);
        pool.setVerifier(address(other));

        vm.prank(owner);
        pool.setVerifier(address(other));
        assertEq(address(pool.verifier()), address(other));
    }

    function test_TransferOwnership() public {
        vm.prank(owner);
        pool.transferOwnership(alice);
        assertEq(pool.owner(), alice);
    }

    // ------------------------- internal helpers ------------------------

    function _seedShield(address from, uint256 amount, address asset) internal {
        bytes32 commitment = keccak256(abi.encode("seed", from, amount, asset, block.timestamp));
        (bytes32[] memory n, bytes32[] memory c, bytes[] memory m) =
            _shieldArgs(commitment, _memo(0x99));
        bytes32 root = pool.merkleRoot();   // cached BEFORE prank

        if (asset == address(0)) {
            vm.prank(from);
            pool.transact{value: amount}(
                _proof(), n, c, m,
                root,
                int256(amount),
                address(0),
                address(0)
            );
        } else {
            vm.prank(from);
            MockERC20(asset).approve(address(pool), amount);
            vm.prank(from);
            pool.transact(
                _proof(), n, c, m,
                root,
                int256(amount),
                asset,
                address(0)
            );
        }
    }
}
