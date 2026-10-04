// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Registry} from "../src/Registry.sol";
import {PublicResolver} from "../src/PublicResolver.sol";
import {ReverseRegistrar} from "../src/ReverseRegistrar.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {BaseRegistrar} from "../src/BaseRegistrar.sol";
import {SealedBidAuction} from "../src/SealedBidAuction.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {Reserved} from "../src/Reserved.sol";
import {NameValidator} from "../src/util/NameValidator.sol";
import {Namehash} from "../src/util/Namehash.sol";

/// @title Deploy
/// @notice Bootstraps the .snct name service end-to-end. Run once per
///         chain (testnet, then mainnet). After this script, .snct
///         registration is open for 5-32 char names, auctions are
///         available for 3-4 char names, and 1-2 char names sit in the
///         genesis multisig waiting for distribution.
contract Deploy is Script {
    // -------- Replace before running --------
    address constant GENESIS = 0x0000000000000000000000000000000000000001;
    address constant TREASURY = 0x0000000000000000000000000000000000000002;
    // 1-2 char names locked at deploy time. The genesis address can then
    // transfer them individually using the Registry's setOwner.
    // (Doing all 36 + 1296 = 1332 sets in a single deploy script would
    // hit the gas limit; we lock the parent `snct` node to GENESIS so
    // they can mint subnodes on demand. See README "Genesis" section.)
    // ----------------------------------------

    function run() external {
        vm.startBroadcast();

        Registry registry = new Registry();
        PublicResolver resolver = new PublicResolver(registry);
        ReverseRegistrar reverseReg = new ReverseRegistrar(registry, resolver);

        // 100 SNCT/year for 3-char, 50 for 4-char, 5 for 5+. Update via
        // PriceOracle.setRates if needed later.
        PriceOracle prices = new PriceOracle(
            100 ether,
            50 ether,
            5 ether
        );

        // Claim .snct under the root. Deployer ends up owning it until
        // we hand it to BaseRegistrar.
        bytes32 snctLabel = NameValidator.labelhash("snct");
        registry.setSubnodeOwner(bytes32(0), snctLabel, msg.sender);

        // Stand up the registrars now that we own .snct.
        BaseRegistrar baseReg = new BaseRegistrar(
            registry,
            prices,
            Namehash.SNCT_NODE,
            TREASURY
        );
        SealedBidAuction auction = new SealedBidAuction(baseReg, TREASURY);
        baseReg.setSealedBidAuction(address(auction));
        Marketplace marketplace = new Marketplace(registry, baseReg, TREASURY);

        // .snct itself goes to BaseRegistrar so it can mint subnodes.
        registry.setOwner(Namehash.SNCT_NODE, address(baseReg));

        // Reserved (1-2 char) registrar — owned by the genesis multisig.
        // BaseRegistrar approves it as an operator so it can mint subnodes
        // under .snct directly.
        Reserved reserved = new Reserved(registry, Namehash.SNCT_NODE, GENESIS);
        baseReg.setReservedRegistrar(address(reserved));

        // Reverse root claim: addr.reverse goes to ReverseRegistrar.
        registry.setSubnodeOwner(
            bytes32(0),
            keccak256("reverse"),
            msg.sender
        );
        registry.setSubnodeOwner(
            keccak256(abi.encodePacked(bytes32(0), keccak256("reverse"))),
            keccak256("addr"),
            address(reverseReg)
        );

        // Genesis takes ownership of 1-2 char subnode authority via a
        // dedicated child of .snct. This is a placeholder hook — the
        // production deploy will replace this with a Reserved contract
        // that exposes per-name transfers; for v1 the genesis address
        // simply holds them as `Registry.setSubnodeOwner` admin via the
        // BaseRegistrar's `treasury` mechanism (see followups).
        // For now: emit the addresses so the team can wire UIs.
        console2.log("Registry          :", address(registry));
        console2.log("PublicResolver    :", address(resolver));
        console2.log("ReverseRegistrar  :", address(reverseReg));
        console2.log("PriceOracle       :", address(prices));
        console2.log("BaseRegistrar     :", address(baseReg));
        console2.log("SealedBidAuction  :", address(auction));
        console2.log("Marketplace       :", address(marketplace));
        console2.log("Reserved          :", address(reserved));
        console2.log("SNCT node         :");
        console2.logBytes32(Namehash.SNCT_NODE);
        console2.log("Genesis (1-2 char):", GENESIS);
        console2.log("Treasury          :", TREASURY);

        vm.stopBroadcast();
    }
}
