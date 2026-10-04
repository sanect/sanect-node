// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRegistry} from "./interfaces/IRegistry.sol";
import {NameValidator} from "./util/NameValidator.sol";

/// @title Reserved
/// @notice Mints 1-2 character `.snct` names. Only the genesis multisig
///         (set at deploy time) can call `mint`. Once minted, names
///         become regular `.snct` records and can be transferred,
///         resolved, listed on the marketplace, etc. like any other.
///
///         No expiry on reserved names — they're permanent. No rent
///         either. The tradeoff for getting one is that you can only
///         get it if the genesis multisig grants it to you.
///
///         Setup: after deploy, BaseRegistrar.setReservedRegistrar(this)
///         is called once. That approves Reserved as a Registry operator
///         for every node BaseRegistrar owns (including `.snct`), so
///         this contract can write subnodes directly.
contract Reserved {
    IRegistry public immutable registry;
    bytes32 public immutable rootNode;
    address public genesis;

    event Minted(string indexed label, address indexed owner);
    event GenesisTransferred(address indexed previous, address indexed next);

    modifier onlyGenesis() {
        require(msg.sender == genesis, "Reserved: not genesis");
        _;
    }

    constructor(IRegistry _registry, bytes32 _rootNode, address _genesis) {
        require(_genesis != address(0), "Reserved: zero genesis");
        registry = _registry;
        rootNode = _rootNode;
        genesis = _genesis;
    }

    /// @notice Mint a 1-2 char `label.snct` and assign ownership to `to`.
    ///         The recipient can then set records, transfer, list, etc.
    ///         just like any other name.
    function mint(string calldata label, address to) external onlyGenesis {
        require(NameValidator.isValid(label), "Reserved: invalid label");
        require(NameValidator.tier(label) == 0, "Reserved: not reserved tier");
        require(to != address(0), "Reserved: zero recipient");
        bytes32 labelhash_ = NameValidator.labelhash(label);
        registry.setSubnodeOwner(rootNode, labelhash_, to);
        emit Minted(label, to);
    }

    /// @notice Mint many reserved names in one tx — useful for bulk
    ///         grants (e.g. seeding a treasury wallet with the full
    ///         1-char set, or distributing 2-char names to early users).
    function mintBatch(string[] calldata labels, address[] calldata recipients)
        external
        onlyGenesis
    {
        require(labels.length == recipients.length, "Reserved: length mismatch");
        for (uint256 i = 0; i < labels.length; i++) {
            string calldata label = labels[i];
            address to = recipients[i];
            require(NameValidator.isValid(label), "Reserved: invalid label");
            require(NameValidator.tier(label) == 0, "Reserved: not reserved tier");
            require(to != address(0), "Reserved: zero recipient");
            registry.setSubnodeOwner(rootNode, NameValidator.labelhash(label), to);
            emit Minted(label, to);
        }
    }

    /// @notice Move the genesis seat. Used when the project rotates from
    ///         a single deploy wallet to a real multisig, or when the
    ///         multisig itself changes signers.
    function transferGenesis(address next) external onlyGenesis {
        require(next != address(0), "Reserved: zero next");
        emit GenesisTransferred(genesis, next);
        genesis = next;
    }
}
