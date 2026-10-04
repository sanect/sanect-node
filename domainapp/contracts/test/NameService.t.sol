// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {PublicResolver} from "../src/PublicResolver.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {BaseRegistrar} from "../src/BaseRegistrar.sol";
import {SealedBidAuction} from "../src/SealedBidAuction.sol";
import {NameValidator} from "../src/util/NameValidator.sol";
import {Namehash} from "../src/util/Namehash.sol";

contract NameServiceTest is Test {
    Registry registry;
    PublicResolver resolver;
    PriceOracle prices;
    BaseRegistrar baseReg;
    SealedBidAuction auction;
    address treasury = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA801);

    function setUp() public {
        registry = new Registry();
        resolver = new PublicResolver(registry);
        prices = new PriceOracle(100 ether, 50 ether, 5 ether);
        bytes32 snctLabel = NameValidator.labelhash("snct");
        registry.setSubnodeOwner(bytes32(0), snctLabel, address(this));
        baseReg = new BaseRegistrar(registry, prices, Namehash.SNCT_NODE, treasury);
        auction = new SealedBidAuction(baseReg, treasury);
        baseReg.setSealedBidAuction(address(auction));
        registry.setOwner(Namehash.SNCT_NODE, address(baseReg));

        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(carol, 10_000 ether);
    }

    // -------- NameValidator --------

    function test_validNames() public {
        assertTrue(NameValidator.isValid("a"));
        assertTrue(NameValidator.isValid("alice2"));
        assertTrue(NameValidator.isValid("a-b-c"));
        assertTrue(NameValidator.isValid("0x1234"));
        assertFalse(NameValidator.isValid(""));
        assertFalse(NameValidator.isValid("-alice2"));
        assertFalse(NameValidator.isValid("alice2-"));
        assertFalse(NameValidator.isValid("alice2!"));
        assertFalse(NameValidator.isValid("Alice2"));
        assertFalse(NameValidator.isValid("alice2.eth"));
    }

    function test_tiers() public {
        assertEq(NameValidator.tier("a"), 0);
        assertEq(NameValidator.tier("ab"), 0);
        assertEq(NameValidator.tier("abc"), 1);
        assertEq(NameValidator.tier("abcd"), 1);
        assertEq(NameValidator.tier("abcde"), 2);
        assertEq(NameValidator.tier("verylongname32characterslimitxxx"), 2);
    }

    // -------- BaseRegistrar (open 5-32 char) --------

    function test_openRegistration() public {
        uint256 burnBefore = address(0x000000000000000000000000000000000000dEaD).balance;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        baseReg.register{value: 5 ether}("alice", alice, 1);

        bytes32 node = Namehash.snctNode("alice");
        assertEq(registry.owner(node), alice);
        assertEq(baseReg.expirations(NameValidator.labelhash("alice")),
            block.timestamp + baseReg.YEAR());

        // 50/50 burn + treasury.
        assertEq(address(0x000000000000000000000000000000000000dEaD).balance - burnBefore, 2.5 ether);
        assertEq(treasury.balance - treasuryBefore, 2.5 ether);
    }

    function test_renewalExtendsFromExpiry() public {
        vm.prank(alice);
        baseReg.register{value: 5 ether}("alice", alice, 1);
        uint256 firstExpiry = baseReg.expirations(NameValidator.labelhash("alice"));

        vm.prank(bob);
        baseReg.renew{value: 5 ether}("alice", 1);

        assertEq(
            baseReg.expirations(NameValidator.labelhash("alice")),
            firstExpiry + baseReg.YEAR()
        );
        // Name owner unchanged — anyone can renew anyone's name.
        assertEq(registry.owner(Namehash.snctNode("alice")), alice);
    }

    function test_reregisterAfterGracePeriod() public {
        vm.prank(alice);
        baseReg.register{value: 5 ether}("alice", alice, 1);

        vm.warp(block.timestamp + baseReg.YEAR() + baseReg.GRACE_PERIOD() + 1);

        vm.prank(bob);
        baseReg.register{value: 5 ether}("alice", bob, 1);
        assertEq(registry.owner(Namehash.snctNode("alice")), bob);
    }

    function test_revertOnWrongTierForOpenReg() public {
        vm.prank(alice);
        vm.expectRevert(bytes("BaseRegistrar: wrong tier"));
        baseReg.register{value: 100 ether}("ab", alice, 1);

        vm.prank(alice);
        vm.expectRevert(bytes("BaseRegistrar: wrong tier"));
        baseReg.register{value: 100 ether}("abc", alice, 1);
    }

    // -------- SealedBidAuction (3-4 char) --------

    function test_auctionHappyPath() public {
        // Alice and Bob both bid; Alice wins, pays Vickrey-2nd.
        bytes32 salt1 = keccak256("alice-secret");
        bytes32 salt2 = keccak256("bob-secret");
        uint256 aliceBid = 300 ether;
        uint256 bobBid = 200 ether;

        auction.start("abc");
        bytes32 commitA = auction.commitmentOf(aliceBid, salt1, alice);
        bytes32 commitB = auction.commitmentOf(bobBid, salt2, bob);

        vm.prank(alice);
        auction.commit{value: aliceBid}("abc", commitA);
        vm.prank(bob);
        auction.commit{value: bobBid}("abc", commitB);

        vm.warp(block.timestamp + auction.COMMIT_PHASE() + 1);

        vm.prank(alice);
        auction.reveal("abc", aliceBid, salt1);
        vm.prank(bob);
        auction.reveal("abc", bobBid, salt2);

        vm.warp(block.timestamp + auction.REVEAL_PHASE() + 1);

        uint256 treasuryBefore = treasury.balance;
        uint256 aliceBefore = alice.balance;

        auction.finalise("abc");

        // Alice paid the 2nd-highest bid (200), got back deposit-200 = 100.
        assertEq(alice.balance, aliceBefore + (aliceBid - bobBid));
        // Treasury got half of 200 = 100.
        assertEq(treasury.balance - treasuryBefore, 100 ether);
        // Alice owns abc.snct.
        assertEq(registry.owner(Namehash.snctNode("abc")), alice);

        // Bob withdraws his unused deposit.
        vm.prank(bob);
        auction.withdraw("abc");
        assertEq(bob.balance, 10_000 ether);
    }

    function test_auctionSingleBidderPaysReserve() public {
        bytes32 salt = keccak256("only-bidder");
        uint256 bid = 500 ether;
        auction.start("xyzz");
        bytes32 commit = auction.commitmentOf(bid, salt, alice);

        vm.prank(alice);
        auction.commit{value: bid}("xyzz", commit);

        vm.warp(block.timestamp + auction.COMMIT_PHASE() + 1);
        vm.prank(alice);
        auction.reveal("xyzz", bid, salt);
        vm.warp(block.timestamp + auction.REVEAL_PHASE() + 1);

        uint256 aliceBefore = alice.balance;
        uint256 treasuryBefore = treasury.balance;
        auction.finalise("xyzz");

        // Alice paid the RESERVE only (100), got back 400.
        assertEq(alice.balance, aliceBefore + (bid - auction.RESERVE()));
        assertEq(treasury.balance - treasuryBefore, auction.RESERVE() / 2);
        assertEq(registry.owner(Namehash.snctNode("xyzz")), alice);
    }

    function test_auctionNoBidInitiatorCanClaim() public {
        vm.prank(alice);
        auction.start("hot");
        vm.warp(block.timestamp + auction.COMMIT_PHASE() + auction.REVEAL_PHASE() + 1);

        auction.finalise("hot"); // closes out with no reveals
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        auction.claimUnbid{value: 100 ether}("hot");

        assertEq(registry.owner(Namehash.snctNode("hot")), alice);
        assertEq(treasury.balance - treasuryBefore, 50 ether);
    }

    function test_auctionNonRevealerForfeitsDeposit() public {
        bytes32 salt = keccak256("griefer");
        uint256 bid = 300 ether;

        auction.start("grif");
        bytes32 commit = auction.commitmentOf(bid, salt, bob);

        vm.prank(bob);
        auction.commit{value: bid}("grif", commit);

        // Bob never reveals.
        vm.warp(block.timestamp + auction.COMMIT_PHASE() + auction.REVEAL_PHASE() + 1);
        auction.finalise("grif");

        uint256 burnBefore = address(0x000000000000000000000000000000000000dEaD).balance;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(bob);
        auction.withdraw("grif");

        // Bob's deposit was confiscated 50/50.
        assertEq(address(0x000000000000000000000000000000000000dEaD).balance - burnBefore, 150 ether);
        assertEq(treasury.balance - treasuryBefore, 150 ether);
    }
}
