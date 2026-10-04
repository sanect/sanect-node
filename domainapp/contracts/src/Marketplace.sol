// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRegistry} from "./interfaces/IRegistry.sol";
import {BaseRegistrar} from "./BaseRegistrar.sol";
import {NameValidator} from "./util/NameValidator.sol";
import {Namehash} from "./util/Namehash.sol";
import {RevenueSplitter} from "./RevenueSplitter.sol";

/// @title Marketplace
/// @notice Secondary market for `.snct` names. Two paths:
///
///   * Fixed-price listing: seller lists at a price, anyone can hit Buy
///   * Open offer: buyer escrows ETH against a name, seller can accept
///
/// The seller must call `Registry.setApprovalForAll(marketplace, true)`
/// once before listing or accepting offers — this lets the marketplace
/// move the name on their behalf. Same approval covers all of seller's
/// names; no need to re-approve per listing.
///
/// Fee: 2.5% of every successful sale, configurable up to 10%, split
/// 50/50 burn / treasury via RevenueSplitter. Seller receives the rest.
contract Marketplace is RevenueSplitter {
    IRegistry public immutable registry;
    BaseRegistrar public immutable registrar;

    /// @notice Fee in basis points. 250 = 2.5%. Treasury-updatable up
    ///         to MAX_FEE_BPS so the take rate can never be raised
    ///         without warning above a published ceiling.
    uint16 public feeBps = 250;
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%

    struct Listing {
        address seller;
        uint256 price;
        uint64 expiresAt; // listing expiry (not name expiry)
    }
    /// labelhash -> active listing. seller == 0 means none.
    mapping(bytes32 => Listing) public listings;

    struct Offer {
        address buyer;
        uint256 amount;
        uint64 expiresAt;
        bool active;
    }
    /// labelhash -> all offers ever made (active flag flips on accept/cancel).
    mapping(bytes32 => Offer[]) public offerBook;

    event Listed(string indexed name, address indexed seller, uint256 price, uint64 expiresAt);
    event Unlisted(string indexed name, address indexed seller);
    event PriceUpdated(string indexed name, uint256 newPrice);
    event Sold(string indexed name, address indexed seller, address indexed buyer, uint256 price);
    event OfferMade(string indexed name, address indexed buyer, uint256 idx, uint256 amount, uint64 expiresAt);
    event OfferAccepted(string indexed name, address indexed seller, address indexed buyer, uint256 idx);
    event OfferCancelled(string indexed name, address indexed buyer, uint256 idx);
    event OfferExpired(string indexed name, address indexed buyer, uint256 idx);
    event FeeUpdated(uint16 newFeeBps);

    constructor(IRegistry _registry, BaseRegistrar _registrar, address _treasury)
        RevenueSplitter(_treasury)
    {
        registry = _registry;
        registrar = _registrar;
    }

    // ---------------------------------------------------------------
    // Seller side
    // ---------------------------------------------------------------

    /// @notice List `name` for `price` wei. Listing expires at
    ///         `expiresAt` (use type(uint64).max for "no expiry").
    function list(string calldata name, uint256 price, uint64 expiresAt) external {
        bytes32 label = NameValidator.labelhash(name);
        bytes32 node = Namehash.snctNode(name);
        require(registry.owner(node) == msg.sender, "Marketplace: not name owner");
        require(price > 0, "Marketplace: zero price");
        require(expiresAt > block.timestamp, "Marketplace: expiry in past");
        require(
            registry.isApprovedForAll(msg.sender, address(this)),
            "Marketplace: approve marketplace first"
        );

        listings[label] = Listing({seller: msg.sender, price: price, expiresAt: expiresAt});
        emit Listed(name, msg.sender, price, expiresAt);
    }

    function unlist(string calldata name) external {
        bytes32 label = NameValidator.labelhash(name);
        Listing memory l = listings[label];
        require(l.seller == msg.sender, "Marketplace: not your listing");
        delete listings[label];
        emit Unlisted(name, msg.sender);
    }

    function updatePrice(string calldata name, uint256 newPrice) external {
        bytes32 label = NameValidator.labelhash(name);
        Listing storage l = listings[label];
        require(l.seller == msg.sender, "Marketplace: not your listing");
        require(newPrice > 0, "Marketplace: zero price");
        l.price = newPrice;
        emit PriceUpdated(name, newPrice);
    }

    // ---------------------------------------------------------------
    // Buyer side — fixed-price purchase
    // ---------------------------------------------------------------

    function buy(string calldata name) external payable {
        bytes32 label = NameValidator.labelhash(name);
        bytes32 node = Namehash.snctNode(name);
        Listing memory l = listings[label];
        require(l.seller != address(0), "Marketplace: not listed");
        require(block.timestamp <= l.expiresAt, "Marketplace: listing expired");
        require(msg.value >= l.price, "Marketplace: underpayment");
        // Race condition: seller may have moved or sold the name through
        // some other path. Check ownership at execution time.
        require(registry.owner(node) == l.seller, "Marketplace: seller no longer owner");

        delete listings[label];
        _settleSale(name, node, l.seller, msg.sender, l.price);
        _refund(msg.value - l.price);
        emit Sold(name, l.seller, msg.sender, l.price);
    }

    // ---------------------------------------------------------------
    // Open offers
    // ---------------------------------------------------------------

    function makeOffer(string calldata name, uint64 expiresAt)
        external
        payable
        returns (uint256 idx)
    {
        require(msg.value > 0, "Marketplace: zero offer");
        require(expiresAt > block.timestamp, "Marketplace: expiry in past");
        bytes32 label = NameValidator.labelhash(name);
        // We allow offers even before a name is registered — useful for
        // reservations, and the offer is just refunded if the offerer
        // changes their mind. But the name must at least be valid.
        require(NameValidator.isValid(name), "Marketplace: invalid name");

        offerBook[label].push(Offer({
            buyer: msg.sender,
            amount: msg.value,
            expiresAt: expiresAt,
            active: true
        }));
        idx = offerBook[label].length - 1;
        emit OfferMade(name, msg.sender, idx, msg.value, expiresAt);
    }

    function acceptOffer(string calldata name, uint256 idx) external {
        bytes32 label = NameValidator.labelhash(name);
        bytes32 node = Namehash.snctNode(name);
        require(registry.owner(node) == msg.sender, "Marketplace: not name owner");
        require(
            registry.isApprovedForAll(msg.sender, address(this)),
            "Marketplace: approve marketplace first"
        );

        Offer storage o = offerBook[label][idx];
        require(o.active, "Marketplace: offer not active");
        require(block.timestamp <= o.expiresAt, "Marketplace: offer expired");

        // Clear the listing too if any, so we don't end up in a hybrid state.
        delete listings[label];

        address buyer = o.buyer;
        uint256 amount = o.amount;
        o.active = false;

        _settleSale(name, node, msg.sender, buyer, amount);
        emit OfferAccepted(name, msg.sender, buyer, idx);
    }

    function cancelOffer(string calldata name, uint256 idx) external {
        bytes32 label = NameValidator.labelhash(name);
        Offer storage o = offerBook[label][idx];
        require(o.buyer == msg.sender, "Marketplace: not your offer");
        require(o.active, "Marketplace: not active");
        o.active = false;
        uint256 amount = o.amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Marketplace: refund failed");
        emit OfferCancelled(name, msg.sender, idx);
    }

    /// @notice Anyone can call this on an expired offer to release the
    ///         buyer's escrow back to them. No incentive — the gas cost
    ///         is paid by whoever wants to clean up.
    function expireOffer(string calldata name, uint256 idx) external {
        bytes32 label = NameValidator.labelhash(name);
        Offer storage o = offerBook[label][idx];
        require(o.active, "Marketplace: not active");
        require(block.timestamp > o.expiresAt, "Marketplace: not expired");
        o.active = false;
        address buyer = o.buyer;
        uint256 amount = o.amount;
        (bool ok,) = buyer.call{value: amount}("");
        require(ok, "Marketplace: refund failed");
        emit OfferExpired(name, buyer, idx);
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    function offerCount(string calldata name) external view returns (uint256) {
        return offerBook[NameValidator.labelhash(name)].length;
    }

    function getListing(string calldata name)
        external
        view
        returns (address seller, uint256 price, uint64 expiresAt, bool active)
    {
        Listing memory l = listings[NameValidator.labelhash(name)];
        seller = l.seller;
        price = l.price;
        expiresAt = l.expiresAt;
        active = l.seller != address(0) && block.timestamp <= l.expiresAt;
    }

    function getOffer(string calldata name, uint256 idx)
        external
        view
        returns (address buyer, uint256 amount, uint64 expiresAt, bool active)
    {
        Offer memory o = offerBook[NameValidator.labelhash(name)][idx];
        buyer = o.buyer;
        amount = o.amount;
        expiresAt = o.expiresAt;
        active = o.active && block.timestamp <= o.expiresAt;
    }

    // ---------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------

    function setFeeBps(uint16 next) external {
        require(msg.sender == treasury, "Marketplace: not treasury");
        require(next <= MAX_FEE_BPS, "Marketplace: above MAX_FEE_BPS");
        feeBps = next;
        emit FeeUpdated(next);
    }

    function setTreasury(address next) external {
        require(msg.sender == treasury, "Marketplace: not treasury");
        _setTreasury(next);
    }

    // ---------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------

    /// @dev Pull the name from `from` to `to`, split fee, pay seller.
    ///      Caller must have done the bookkeeping before this (clear
    ///      listing / offer) so we don't reenter the storage we just read.
    function _settleSale(
        string calldata name,
        bytes32 node,
        address from,
        address to,
        uint256 grossPayment
    ) internal {
        // Marketplace fee → RevenueSplitter (50/50 burn + treasury).
        uint256 fee = (grossPayment * feeBps) / 10_000;
        uint256 sellerProceeds = grossPayment - fee;

        if (fee > 0) _distribute(fee);
        (bool ok,) = from.call{value: sellerProceeds}("");
        require(ok, "Marketplace: seller payment failed");

        // Transfer the name. Requires from to have approved this contract.
        registry.setOwner(node, to);
        // Use name only for the event — silence "unused" warning if any.
        name;
    }

    function _refund(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Marketplace: refund failed");
    }
}
