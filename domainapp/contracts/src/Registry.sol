// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRegistry} from "./interfaces/IRegistry.sol";

/// @title Registry
/// @notice Core `.snct` registry. Direct port of the ENS Registry's
///         interface and storage model so any ENS-aware tooling that
///         knows the namehash algorithm can resolve our names without
///         protocol changes — only the deployment address differs.
contract Registry is IRegistry {
    struct Record {
        address owner;
        address resolver;
        uint64 ttl;
    }

    mapping(bytes32 => Record) internal _records;
    mapping(address => mapping(address => bool)) internal _operators;

    modifier authorised(bytes32 node) {
        address nodeOwner = _records[node].owner;
        require(
            nodeOwner == msg.sender || _operators[nodeOwner][msg.sender],
            "Registry: not authorised"
        );
        _;
    }

    constructor() {
        // Root node starts owned by the deployer so it can install
        // sub-registrars (BaseRegistrar, SealedBidAuction) under .snct.
        _records[bytes32(0)].owner = msg.sender;
    }

    function setRecord(
        bytes32 node,
        address newOwner,
        address newResolver,
        uint64 newTtl
    ) external authorised(node) {
        _setOwner(node, newOwner);
        _records[node].resolver = newResolver;
        _records[node].ttl = newTtl;
        emit NewResolver(node, newResolver);
        emit NewTTL(node, newTtl);
    }

    function setSubnodeRecord(
        bytes32 node,
        bytes32 label,
        address newOwner,
        address newResolver,
        uint64 newTtl
    ) external authorised(node) {
        bytes32 sub = _setSubnodeOwner(node, label, newOwner);
        _records[sub].resolver = newResolver;
        _records[sub].ttl = newTtl;
        emit NewResolver(sub, newResolver);
        emit NewTTL(sub, newTtl);
    }

    function setSubnodeOwner(
        bytes32 node,
        bytes32 label,
        address newOwner
    ) external authorised(node) returns (bytes32) {
        return _setSubnodeOwner(node, label, newOwner);
    }

    function setOwner(bytes32 node, address newOwner) external authorised(node) {
        _setOwner(node, newOwner);
    }

    function setResolver(bytes32 node, address newResolver) external authorised(node) {
        _records[node].resolver = newResolver;
        emit NewResolver(node, newResolver);
    }

    function setTTL(bytes32 node, uint64 newTtl) external authorised(node) {
        _records[node].ttl = newTtl;
        emit NewTTL(node, newTtl);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operators[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function owner(bytes32 node) external view returns (address) {
        address o = _records[node].owner;
        return o == address(this) ? address(0) : o;
    }

    function resolver(bytes32 node) external view returns (address) {
        return _records[node].resolver;
    }

    function ttl(bytes32 node) external view returns (uint64) {
        return _records[node].ttl;
    }

    function recordExists(bytes32 node) external view returns (bool) {
        return _records[node].owner != address(0);
    }

    function isApprovedForAll(address account, address operator) external view returns (bool) {
        return _operators[account][operator];
    }

    function _setOwner(bytes32 node, address newOwner) internal {
        _records[node].owner = newOwner;
        emit Transfer(node, newOwner);
    }

    function _setSubnodeOwner(
        bytes32 node,
        bytes32 label,
        address newOwner
    ) internal returns (bytes32) {
        bytes32 sub = keccak256(abi.encodePacked(node, label));
        _records[sub].owner = newOwner;
        emit NewOwner(node, label, newOwner);
        return sub;
    }
}
