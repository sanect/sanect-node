// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {BaseRegistrar} from "../src/BaseRegistrar.sol";
import {Reserved} from "../src/Reserved.sol";
import {NameValidator} from "../src/util/NameValidator.sol";
import {Namehash} from "../src/util/Namehash.sol";

contract ReservedTest is Test {
    Registry registry;
    PriceOracle prices;
    BaseRegistrar baseReg;
    Reserved reserved;

    address treasury = address(0xBEEF);
    address genesis = address(0xFEED);
    address alice = address(0xA11CE);

    function setUp() public {
        registry = new Registry();
        prices = new PriceOracle(100 ether, 50 ether, 5 ether);
        bytes32 snctLabel = NameValidator.labelhash("snct");
        registry.setSubnodeOwner(bytes32(0), snctLabel, address(this));
        baseReg = new BaseRegistrar(registry, prices, Namehash.SNCT_NODE, treasury);
        registry.setOwner(Namehash.SNCT_NODE, address(baseReg));

        reserved = new Reserved(registry, Namehash.SNCT_NODE, genesis);
        baseReg.setReservedRegistrar(address(reserved));
    }

    function test_genesisCanMintOneChar() public {
        vm.prank(genesis);
        reserved.mint("r", alice);
        assertEq(registry.owner(Namehash.snctNode("r")), alice);
    }

    function test_genesisCanMintTwoChar() public {
        vm.prank(genesis);
        reserved.mint("ab", alice);
        assertEq(registry.owner(Namehash.snctNode("ab")), alice);
    }

    function test_revertsOnNonGenesis() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Reserved: not genesis"));
        reserved.mint("r", alice);
    }

    function test_revertsOnLongerName() public {
        vm.prank(genesis);
        vm.expectRevert(bytes("Reserved: not reserved tier"));
        reserved.mint("abc", alice);
    }

    function test_revertsOnInvalidName() public {
        vm.prank(genesis);
        vm.expectRevert(bytes("Reserved: invalid label"));
        reserved.mint("A", alice);
        vm.prank(genesis);
        vm.expectRevert(bytes("Reserved: invalid label"));
        reserved.mint("-", alice);
    }

    function test_batchMint() public {
        string[] memory labels = new string[](3);
        labels[0] = "r";
        labels[1] = "a";
        labels[2] = "ab";
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = treasury;
        recipients[2] = alice;

        vm.prank(genesis);
        reserved.mintBatch(labels, recipients);

        assertEq(registry.owner(Namehash.snctNode("r")), alice);
        assertEq(registry.owner(Namehash.snctNode("a")), treasury);
        assertEq(registry.owner(Namehash.snctNode("ab")), alice);
    }

    function test_transferGenesis() public {
        vm.prank(genesis);
        reserved.transferGenesis(alice);
        assertEq(reserved.genesis(), alice);

        // Old genesis can no longer mint.
        vm.prank(genesis);
        vm.expectRevert(bytes("Reserved: not genesis"));
        reserved.mint("r", alice);

        // New genesis can.
        vm.prank(alice);
        reserved.mint("r", alice);
        assertEq(registry.owner(Namehash.snctNode("r")), alice);
    }

    function test_setReservedRegistrarOnlyOnce() public {
        vm.expectRevert(bytes("BaseRegistrar: already set"));
        baseReg.setReservedRegistrar(address(0xdead));
    }
}
