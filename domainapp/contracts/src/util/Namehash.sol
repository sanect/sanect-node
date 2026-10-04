// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Namehash
/// @notice ENS-compatible namehash algorithm. Used so any ENS-aware
///         library / wallet that knows the algorithm can resolve
///         `.snct` names against our Registry without modification.
library Namehash {
    /// @notice The root node — namehash of the empty string.
    bytes32 internal constant ROOT = bytes32(0);

    /// @notice The TLD node — namehash of "snct".
    /// keccak256(bytes32(0), keccak256("snct"))
    bytes32 internal constant SNCT_NODE =
        keccak256(abi.encodePacked(bytes32(0), keccak256(bytes("snct"))));

    /// @notice Compute the namehash of `label.snct`.
    function snctNode(string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SNCT_NODE, keccak256(bytes(label))));
    }

    /// @notice Compute the namehash of `child.<parent>` where parent is
    ///         already-namehashed.
    function subnode(bytes32 parent, string memory child) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, keccak256(bytes(child))));
    }
}
