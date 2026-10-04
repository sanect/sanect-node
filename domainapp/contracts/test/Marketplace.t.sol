// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {PublicResolver} from "../src/PublicResolver.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {BaseRegistrar} from "../src/BaseRegistrar.sol";
import {SealedBidAuction} from "../src/SealedBidAuction.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {NameValidator} from "../src/util/NameValidator.sol";
import {Namehash} from "../src/util/Namehash.sol";

contract MarketplaceTest is Test {
    Registry registry;
    PublicResolver resolver;
    PriceOracle prices;
    BaseRegistrar baseReg;
    SealedBidAuction auction;
    Marketplace mp;

    address treasury = address(0xBEEF);
    address alice = address(0xA11CE); // seller
    address bob = address(0xB0B);     // buyer
    address carol = address(0xCA801); // other buyer
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

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

        mp = new Marketplace(registry, baseReg, treasury);

        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(carol, 10_000 ether);

        // Alice registers alice2.snct (the name to sell).
        vm.prank(alice);
        baseReg.register{value: 5 ether}("alice2", alice, 1);
    }

    function _approve(address user) internal {
        vm.prank(user);
        registry.setApprovalForAll(address(mp), true);
    }

    // ---- list / buy ----

    function test_listBuyHappyPath() public {
        _approve(alice);
        vm.prank(alice);
        mp.list("alice2", 1000 ether, uint64(block.timestamp + 30 days));

        uint256 aliceBefore = alice.balance;
        uint256 burnBefore = BURN.balance;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(bob);
        mp.buy{value: 1000 ether}("alice2");

        bytes32 node = Namehash.snctNode("alice2");
        assertEq(registry.owner(node), bob);

        // Fee = 2.5% of 1000 = 25 SNCT, split 12.5/12.5
        assertEq(BURN.balance - burnBefore, 12.5 ether);
        assertEq(treasury.balance - treasuryBefore, 12.5 ether);
        assertEq(alice.balance - aliceBefore, 975 ether);
    }

    function test_listRevertsWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Marketplace: approve marketplace first"));
        mp.list("alice2", 100 ether, uint64(block.timestamp + 1 days));
    }

    function test_buyRevertsOnExpired() public {
        _approve(alice);
        vm.prank(alice);
        mp.list("alice2", 100 ether, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        vm.expectRevert(bytes("Marketplace: listing expired"));
        mp.buy{value: 100 ether}("alice2");
    }

    function test_unlist() public {
        _approve(alice);
        vm.prank(alice);
        mp.list("alice2", 100 ether, uint64(block.timestamp + 1 days));
        vm.prank(alice);
        mp.unlist("alice2");
        (address seller,,,) = mp.getListing("alice2");
        assertEq(seller, address(0));
    }

    function test_updatePrice() public {
        _approve(alice);
        vm.prank(alice);
        mp.list("alice2", 100 ether, uint64(block.timestamp + 1 days));
        vm.prank(alice);
        mp.updatePrice("alice2", 200 ether);
        (,uint256 price,,) = mp.getListing("alice2");
        assertEq(price, 200 ether);
    }

    function test_buyRefundsExcess() public {
        _approve(alice);
        vm.prank(alice);
        mp.list("alice2", 100 ether, uint64(block.timestamp + 1 days));

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        mp.buy{value: 300 ether}("alice2");

        // Bob paid only 100, got back 200.
        assertEq(bob.balance, bobBefore - 100 ether);
    }

    // ---- offers ----

    function test_makeAndAcceptOffer() public {
        vm.prank(bob);
        uint256 idx = mp.makeOffer{value: 500 ether}("alice2", uint64(block.timestamp + 7 days));
        assertEq(idx, 0);

        _approve(alice);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        mp.acceptOffer("alice2", 0);

        assertEq(registry.owner(Namehash.snctNode("alice2")), bob);
        // 2.5% fee → seller gets 487.5
        assertEq(alice.balance - aliceBefore, 487.5 ether);
    }

    function test_cancelOfferRefunds() public {
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        mp.makeOffer{value: 500 ether}("alice2", uint64(block.timestamp + 7 days));
        assertEq(bob.balance, bobBefore - 500 ether);

        vm.prank(bob);
        mp.cancelOffer("alice2", 0);
        assertEq(bob.balance, bobBefore);
    }

    function test_expireOfferAllowsAnyoneToReleaseFunds() public {
        vm.prank(bob);
        mp.makeOffer{value: 500 ether}("alice2", uint64(block.timestamp + 7 days));

        // Time travel past the offer expiry.
        vm.warp(block.timestamp + 8 days);

        uint256 bobBefore = bob.balance;
        // Carol (a third party) cleans up the expired offer.
        vm.prank(carol);
        mp.expireOffer("alice2", 0);
        assertEq(bob.balance, bobBefore + 500 ether);
    }

    function test_acceptOfferRevertsIfNotOwner() public {
        vm.prank(bob);
        mp.makeOffer{value: 500 ether}("alice2", uint64(block.timestamp + 7 days));

        vm.prank(carol); // not the owner
        vm.expectRevert(bytes("Marketplace: not name owner"));
        mp.acceptOffer("alice2", 0);
    }

    function test_acceptOfferClearsListing() public {
        _approve(alice);
        vm.prank(alice);
        mp.list("alice2", 1000 ether, uint64(block.timestamp + 30 days));

        vm.prank(bob);
        mp.makeOffer{value: 500 ether}("alice2", uint64(block.timestamp + 7 days));

        vm.prank(alice);
        mp.acceptOffer("alice2", 0);

        (address seller,,,) = mp.getListing("alice2");
        assertEq(seller, address(0));
    }

    function test_setFeeBpsRequiresTreasury() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Marketplace: not treasury"));
        mp.setFeeBps(500);

        vm.prank(treasury);
        mp.setFeeBps(500);
        assertEq(mp.feeBps(), 500);
    }

    function test_setFeeBpsCapped() public {
        vm.prank(treasury);
        vm.expectRevert(bytes("Marketplace: above MAX_FEE_BPS"));
        mp.setFeeBps(2_000);
    }
}
