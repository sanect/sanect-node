// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRegistry} from "./interfaces/IRegistry.sol";
import {NameValidator} from "./util/NameValidator.sol";
import {Namehash} from "./util/Namehash.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {RevenueSplitter} from "./RevenueSplitter.sol";

/// @title BaseRegistrar
/// @notice Open registration for 5-32 char `.snct` names. Annual rent,
///         90-day grace period after expiry before a name can be
///         re-registered.
contract BaseRegistrar is RevenueSplitter {
    IRegistry public immutable registry;
    PriceOracle public priceOracle;
    bytes32 public immutable rootNode;

    /// @notice The auction contract — only it can register 3-4 char
    ///         names through `registerForAuctionWinner`.
    address public sealedBidAuction;

    /// @notice The Reserved contract — only it can register 1-2 char
    ///         names. Set once at deploy time and immutable thereafter
    ///         (well, locked behind the same one-shot setter).
    address public reservedRegistrar;

    /// @notice 365.25 days. Slightly off-by-a-quarter-day but matches
    ///         civil convention and avoids leap-year edge cases.
    uint256 public constant YEAR = 365.25 days;
    uint256 public constant GRACE_PERIOD = 90 days;

    /// @dev labelhash -> unix expiry timestamp. 0 = never registered.
    mapping(bytes32 => uint256) public expirations;

    event Registered(string indexed name, address indexed owner, uint256 expiresAt);
    event Renewed(string indexed name, uint256 expiresAt);
    event Reclaimed(string indexed name, address indexed newOwner);

    constructor(
        IRegistry _registry,
        PriceOracle _priceOracle,
        bytes32 _rootNode,
        address _treasury
    ) RevenueSplitter(_treasury) {
        registry = _registry;
        priceOracle = _priceOracle;
        rootNode = _rootNode;
    }

    /// @notice One-time wiring of the auction contract. Can only be set
    ///         once — auction permanently owns the 3-4 char tier after.
    function setSealedBidAuction(address auction) external {
        require(sealedBidAuction == address(0), "BaseRegistrar: already set");
        require(msg.sender == treasury || msg.sender == registry.owner(rootNode),
            "BaseRegistrar: not authorised");
        sealedBidAuction = auction;
    }

    /// @notice One-time wiring of the Reserved contract. Reserved is the
    ///         only path to mint 1-2 char names — held by the genesis
    ///         multisig. After this call, Reserved is approved as a
    ///         Registry operator for every node owned by this registrar,
    ///         so it can mint subnodes directly.
    function setReservedRegistrar(address reserved_) external {
        require(reservedRegistrar == address(0), "BaseRegistrar: already set");
        require(msg.sender == treasury || msg.sender == registry.owner(rootNode),
            "BaseRegistrar: not authorised");
        reservedRegistrar = reserved_;
        // Grants Reserved authority to call registry.setSubnodeOwner on
        // any subnode of rootNode (which we own). One-time, no per-name
        // approval needed for each reserved mint.
        registry.setApprovalForAll(reserved_, true);
    }

    /// @notice Open registration for 5-32 char names.
    function register(
        string calldata name,
        address newOwner,
        uint256 years_
    ) external payable {
        require(NameValidator.isValid(name), "BaseRegistrar: invalid name");
        require(NameValidator.tier(name) == 2, "BaseRegistrar: wrong tier");
        bytes32 label = NameValidator.labelhash(name);
        require(available(label), "BaseRegistrar: taken");
        require(years_ > 0, "BaseRegistrar: zero years");

        uint256 fee = priceOracle.annualRent(bytes(name).length) * years_;
        require(msg.value >= fee, "BaseRegistrar: insufficient payment");

        uint256 expiresAt = block.timestamp + years_ * YEAR;
        expirations[label] = expiresAt;
        registry.setSubnodeOwner(rootNode, label, newOwner);

        _distribute(fee);
        _refund(msg.value - fee);
        emit Registered(name, newOwner, expiresAt);
    }

    /// @notice Called by SealedBidAuction when a 3-4 char auction
    ///         finalises. The auction has already collected payment.
    function registerForAuctionWinner(
        string calldata name,
        address winner
    ) external returns (uint256 expiresAt) {
        require(msg.sender == sealedBidAuction, "BaseRegistrar: not auction");
        require(NameValidator.isValid(name), "BaseRegistrar: invalid name");
        require(NameValidator.tier(name) == 1, "BaseRegistrar: not auction tier");
        bytes32 label = NameValidator.labelhash(name);
        require(available(label), "BaseRegistrar: taken");

        expiresAt = block.timestamp + YEAR;
        expirations[label] = expiresAt;
        registry.setSubnodeOwner(rootNode, label, winner);
        emit Registered(name, winner, expiresAt);
    }

    /// @notice Renew any name (3-32 char) for `years_` more years.
    ///         Anyone can pay rent for any name — useful for orgs and
    ///         users with multiple wallets.
    function renew(string calldata name, uint256 years_) external payable {
        require(years_ > 0, "BaseRegistrar: zero years");
        bytes32 label = NameValidator.labelhash(name);
        uint256 current = expirations[label];
        require(current > 0, "BaseRegistrar: not registered");
        require(
            block.timestamp <= current + GRACE_PERIOD,
            "BaseRegistrar: past grace period"
        );

        uint256 fee = priceOracle.annualRent(bytes(name).length) * years_;
        require(msg.value >= fee, "BaseRegistrar: insufficient payment");

        // Extend from the later of (current expiry, now) so a renewal
        // during grace doesn't credit the grace days for free.
        uint256 base = current > block.timestamp ? current : block.timestamp;
        uint256 expiresAt = base + years_ * YEAR;
        expirations[label] = expiresAt;

        _distribute(fee);
        _refund(msg.value - fee);
        emit Renewed(name, expiresAt);
    }

    function available(bytes32 label) public view returns (bool) {
        uint256 expiresAt = expirations[label];
        return expiresAt == 0 || block.timestamp > expiresAt + GRACE_PERIOD;
    }

    function availableByName(string calldata name) external view returns (bool) {
        return available(NameValidator.labelhash(name));
    }

    function setTreasury(address next) external {
        require(msg.sender == treasury, "BaseRegistrar: not treasury");
        _setTreasury(next);
    }

    function setPriceOracle(PriceOracle next) external {
        require(msg.sender == treasury, "BaseRegistrar: not treasury");
        priceOracle = next;
    }

    function _refund(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "BaseRegistrar: refund failed");
    }
}
