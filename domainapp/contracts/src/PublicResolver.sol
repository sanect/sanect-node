// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRegistry} from "./interfaces/IRegistry.sol";

/// @title PublicResolver
/// @notice Stores the data records associated with each `.snct` name.
///         Subset of the ENS PublicResolver — enough to make the names
///         useful (addr, text, contenthash, name) without bloating the
///         v1 contract surface.
contract PublicResolver {
    IRegistry public immutable registry;

    /// @notice node => coin type => address bytes (EIP-2304).
    /// Coin type 60 = Ethereum-style EVM address; we use 60 for Sanect
    /// since the EVM signing scheme is identical.
    mapping(bytes32 => mapping(uint256 => bytes)) internal _addresses;
    mapping(bytes32 => mapping(string => string)) internal _text;
    mapping(bytes32 => bytes) internal _contenthash;
    mapping(bytes32 => string) internal _names;

    event AddrChanged(bytes32 indexed node, address newAddress);
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress);
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value);
    event ContenthashChanged(bytes32 indexed node, bytes hash);
    event NameChanged(bytes32 indexed node, string name);

    modifier authorised(bytes32 node) {
        address nodeOwner = registry.owner(node);
        require(
            nodeOwner == msg.sender || registry.isApprovedForAll(nodeOwner, msg.sender),
            "Resolver: not authorised"
        );
        _;
    }

    constructor(IRegistry _registry) {
        registry = _registry;
    }

    // -------- address records --------

    function setAddr(bytes32 node, address a) external authorised(node) {
        _addresses[node][60] = abi.encodePacked(a);
        emit AddrChanged(node, a);
        emit AddressChanged(node, 60, abi.encodePacked(a));
    }

    function addr(bytes32 node) external view returns (address payable) {
        bytes memory raw = _addresses[node][60];
        if (raw.length != 20) return payable(address(0));
        address out;
        assembly {
            out := mload(add(raw, 20))
        }
        return payable(out);
    }

    function setAddr(bytes32 node, uint256 coinType, bytes calldata a) external authorised(node) {
        _addresses[node][coinType] = a;
        emit AddressChanged(node, coinType, a);
        if (coinType == 60 && a.length == 20) {
            emit AddrChanged(node, _bytesToAddress(a));
        }
    }

    function addr(bytes32 node, uint256 coinType) external view returns (bytes memory) {
        return _addresses[node][coinType];
    }

    // -------- text records --------

    function setText(
        bytes32 node,
        string calldata key,
        string calldata value
    ) external authorised(node) {
        _text[node][key] = value;
        emit TextChanged(node, key, key, value);
    }

    function text(bytes32 node, string calldata key) external view returns (string memory) {
        return _text[node][key];
    }

    // -------- contenthash (IPFS / Swarm) --------

    function setContenthash(bytes32 node, bytes calldata hash) external authorised(node) {
        _contenthash[node] = hash;
        emit ContenthashChanged(node, hash);
    }

    function contenthash(bytes32 node) external view returns (bytes memory) {
        return _contenthash[node];
    }

    // -------- name (used by ReverseRegistrar) --------

    function setName(bytes32 node, string calldata newName) external authorised(node) {
        _names[node] = newName;
        emit NameChanged(node, newName);
    }

    function name(bytes32 node) external view returns (string memory) {
        return _names[node];
    }

    function _bytesToAddress(bytes calldata b) internal pure returns (address out) {
        assembly {
            out := shr(96, calldataload(b.offset))
        }
    }
}
