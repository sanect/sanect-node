// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRegistry} from "./interfaces/IRegistry.sol";
import {PublicResolver} from "./PublicResolver.sol";

/// @title ReverseRegistrar
/// @notice Maps `address -> primary .snct name`. Lives under
///         `addr.reverse` per ENS convention so generic ENS-aware
///         libraries can do reverse lookups without protocol changes.
contract ReverseRegistrar {
    IRegistry public immutable registry;
    PublicResolver public immutable defaultResolver;

    /// @dev namehash("reverse") — the parent of addr.reverse.
    bytes32 internal constant REVERSE_NODE =
        keccak256(abi.encodePacked(bytes32(0), keccak256("reverse")));

    /// @notice namehash("addr.reverse") — ENS-canonical reverse root. The
    ///         deploy script transfers ownership of this node to this
    ///         contract, so `setName` writes subnodes under it.
    ///         Previously this constant was set to namehash("reverse")
    ///         which caused every setName call to revert with
    ///         "Registry: not authorised" — the contract was never the
    ///         owner of "reverse".
    bytes32 public constant ADDR_REVERSE_NODE =
        keccak256(abi.encodePacked(REVERSE_NODE, keccak256("addr")));

    event ReverseClaimed(address indexed account, bytes32 indexed node);

    constructor(IRegistry _registry, PublicResolver _resolver) {
        registry = _registry;
        defaultResolver = _resolver;
    }

    /// @notice Claim the reverse record for `msg.sender` and set their
    ///         primary `.snct` name.
    /// @dev Caller must own `name` in the forward Registry; we don't
    ///      verify it here because the forward registrar's resolver is
    ///      the source of truth — a lying reverse record just means the
    ///      explorer shows nothing.
    function setName(string calldata primaryName) external returns (bytes32) {
        bytes32 label = _sha3HexAddress(msg.sender);
        bytes32 node = keccak256(abi.encodePacked(ADDR_REVERSE_NODE, label));
        registry.setSubnodeRecord(
            ADDR_REVERSE_NODE,
            label,
            address(this),
            address(defaultResolver),
            0
        );
        defaultResolver.setName(node, primaryName);
        registry.setOwner(node, msg.sender);
        emit ReverseClaimed(msg.sender, node);
        return node;
    }

    /// @notice Returns the namehash of the reverse record for `account`.
    function nodeOf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            ADDR_REVERSE_NODE,
            _sha3HexAddress(account)
        ));
    }

    /// @dev EIP-181 style: keccak256 of the lowercase hex representation
    ///      of the address (40 hex chars, no 0x).
    function _sha3HexAddress(address addr_) internal pure returns (bytes32 ret) {
        assembly {
            let lookup := 0x3031323334353637383961626364656600000000000000000000000000000000
            for { let i := 40 } gt(i, 0) {} {
                i := sub(i, 1)
                mstore8(i, byte(and(addr_, 0xf), lookup))
                addr_ := div(addr_, 0x10)
                i := sub(i, 1)
                mstore8(i, byte(and(addr_, 0xf), lookup))
                addr_ := div(addr_, 0x10)
            }
            ret := keccak256(0, 40)
        }
    }
}
