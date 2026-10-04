// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NameValidator} from "./util/NameValidator.sol";
import {BaseRegistrar} from "./BaseRegistrar.sol";
import {RevenueSplitter} from "./RevenueSplitter.sol";

/// @title SealedBidAuction
/// @notice Vickrey-style sealed-bid auction for 3-4 character `.snct`
///         names. 7-day commit phase, 2-day reveal phase. Winner pays
///         max(2nd highest bid, RESERVE). All proceeds split 50/50
///         burn / treasury via RevenueSplitter.
///
///         Single-bidder & no-bid cases:
///           - 0 reveals: initiator can call `claimUnbid` and pay RESERVE
///           - 1 reveal:  that bidder pays RESERVE (not their own bid)
///           - 2+ reveals: highest wins, pays max(2nd, RESERVE)
contract SealedBidAuction is RevenueSplitter {
    BaseRegistrar public immutable registrar;

    uint256 public constant COMMIT_PHASE = 7 days;
    uint256 public constant REVEAL_PHASE = 2 days;
    uint256 public constant RESERVE = 100 ether; // 100 SNCT

    enum Phase {
        None,
        Commit,
        Reveal,
        Finalised
    }

    struct Auction {
        Phase phase;
        uint64 commitDeadline;
        uint64 revealDeadline;
        address initiator;
        // Highest revealed bid so far.
        uint256 highestBid;
        address highestBidder;
        // Second-highest revealed bid (used for payment).
        uint256 secondBid;
        // Count of reveals so we can distinguish 0/1/many.
        uint32 reveals;
    }

    /// labelhash -> auction state
    mapping(bytes32 => Auction) public auctions;
    /// labelhash -> bidder -> commitment hash
    mapping(bytes32 => mapping(address => bytes32)) public commitments;
    /// labelhash -> bidder -> deposit in wei
    mapping(bytes32 => mapping(address => uint256)) public deposits;
    /// labelhash -> bidder -> already-revealed flag
    mapping(bytes32 => mapping(address => bool)) public revealed;

    event AuctionStarted(string indexed name, address indexed initiator, uint64 revealStart);
    event BidCommitted(string indexed name, address indexed bidder);
    event BidRevealed(string indexed name, address indexed bidder, uint256 amount);
    event AuctionFinalised(string indexed name, address indexed winner, uint256 payment);
    event ClaimedUnbid(string indexed name, address indexed claimer);
    event DepositRefunded(string indexed name, address indexed bidder, uint256 amount);
    event DepositForfeited(string indexed name, address indexed bidder, uint256 amount);

    constructor(BaseRegistrar _registrar, address _treasury) RevenueSplitter(_treasury) {
        registrar = _registrar;
    }

    /// @notice Open a 7-day commit phase for `name`.
    function start(string calldata name) external {
        require(NameValidator.isValid(name), "Auction: invalid name");
        require(NameValidator.tier(name) == 1, "Auction: not auction tier");
        bytes32 label = NameValidator.labelhash(name);
        require(auctions[label].phase == Phase.None, "Auction: already exists");
        require(registrar.available(label), "Auction: name not available");

        auctions[label] = Auction({
            phase: Phase.Commit,
            commitDeadline: uint64(block.timestamp + COMMIT_PHASE),
            revealDeadline: uint64(block.timestamp + COMMIT_PHASE + REVEAL_PHASE),
            initiator: msg.sender,
            highestBid: 0,
            highestBidder: address(0),
            secondBid: 0,
            reveals: 0
        });
        emit AuctionStarted(
            name,
            msg.sender,
            uint64(block.timestamp + COMMIT_PHASE)
        );
    }

    /// @notice Commit a bid for `name`. `commitment` must be
    ///         `keccak256(abi.encode(bidAmount, salt, msg.sender))`.
    ///         The `msg.value` is the deposit and must be >= bidAmount
    ///         at reveal time, so commit deposits ≥ your max bid.
    function commit(string calldata name, bytes32 commitment) external payable {
        require(msg.value >= RESERVE, "Auction: below reserve");
        bytes32 label = NameValidator.labelhash(name);
        Auction storage a = auctions[label];
        require(a.phase == Phase.Commit, "Auction: not commit phase");
        require(block.timestamp <= a.commitDeadline, "Auction: commit ended");
        require(commitments[label][msg.sender] == bytes32(0), "Auction: already committed");
        require(commitment != bytes32(0), "Auction: empty commitment");

        commitments[label][msg.sender] = commitment;
        deposits[label][msg.sender] = msg.value;
        emit BidCommitted(name, msg.sender);
    }

    /// @notice Reveal a previously-committed bid.
    function reveal(string calldata name, uint256 bidAmount, bytes32 salt) external {
        bytes32 label = NameValidator.labelhash(name);
        Auction storage a = auctions[label];
        require(
            block.timestamp > a.commitDeadline && block.timestamp <= a.revealDeadline,
            "Auction: not reveal window"
        );
        require(!revealed[label][msg.sender], "Auction: already revealed");
        bytes32 expected = keccak256(abi.encode(bidAmount, salt, msg.sender));
        require(commitments[label][msg.sender] == expected, "Auction: bad reveal");
        require(deposits[label][msg.sender] >= bidAmount, "Auction: deposit < bid");
        require(bidAmount >= RESERVE, "Auction: bid below reserve");

        revealed[label][msg.sender] = true;
        a.reveals += 1;
        if (a.phase == Phase.Commit) a.phase = Phase.Reveal;

        if (bidAmount > a.highestBid) {
            a.secondBid = a.highestBid;
            a.highestBid = bidAmount;
            a.highestBidder = msg.sender;
        } else if (bidAmount > a.secondBid) {
            a.secondBid = bidAmount;
        }
        emit BidRevealed(name, msg.sender, bidAmount);
    }

    /// @notice Close out the auction after the reveal window.
    function finalise(string calldata name) external {
        bytes32 label = NameValidator.labelhash(name);
        Auction storage a = auctions[label];
        require(a.phase == Phase.Commit || a.phase == Phase.Reveal, "Auction: bad phase");
        require(block.timestamp > a.revealDeadline, "Auction: still revealable");

        if (a.reveals == 0) {
            // No reveals — auction is dead. Initiator must use claimUnbid.
            a.phase = Phase.Finalised;
            emit AuctionFinalised(name, address(0), 0);
            return;
        }

        a.phase = Phase.Finalised;
        address winner = a.highestBidder;

        // Vickrey: winner pays the higher of the second-highest bid and
        // the reserve. If only one revealer, secondBid stays 0 → pays
        // reserve. RESERVE is the auction's floor either way.
        uint256 payment = a.secondBid > RESERVE ? a.secondBid : RESERVE;
        uint256 depositW = deposits[label][winner];
        require(depositW >= payment, "Auction: winner deposit < payment");
        deposits[label][winner] = 0;

        _distribute(payment);
        // Refund the winner the excess of their deposit.
        if (depositW > payment) {
            (bool ok,) = winner.call{value: depositW - payment}("");
            require(ok, "Auction: refund failed");
            emit DepositRefunded(name, winner, depositW - payment);
        }

        registrar.registerForAuctionWinner(name, winner);
        emit AuctionFinalised(name, winner, payment);
    }

    /// @notice If nobody else committed, the initiator can claim the
    ///         name at the reserve price after the reveal window.
    function claimUnbid(string calldata name) external payable {
        bytes32 label = NameValidator.labelhash(name);
        Auction storage a = auctions[label];
        require(a.phase == Phase.Finalised, "Auction: finalise first");
        require(a.reveals == 0, "Auction: someone bid");
        require(msg.sender == a.initiator, "Auction: only initiator");
        require(msg.value >= RESERVE, "Auction: below reserve");
        require(registrar.available(label), "Auction: not available");

        _distribute(RESERVE);
        if (msg.value > RESERVE) {
            (bool ok,) = msg.sender.call{value: msg.value - RESERVE}("");
            require(ok, "Auction: refund failed");
        }
        registrar.registerForAuctionWinner(name, msg.sender);
        emit ClaimedUnbid(name, msg.sender);
    }

    /// @notice Reclaim a deposit after the auction is finalised.
    ///         If the caller committed but never revealed, their
    ///         deposit is forfeited 50/50 burn/treasury (anti-grief).
    function withdraw(string calldata name) external {
        bytes32 label = NameValidator.labelhash(name);
        Auction storage a = auctions[label];
        require(a.phase == Phase.Finalised, "Auction: not finalised");
        uint256 amount = deposits[label][msg.sender];
        require(amount > 0, "Auction: nothing to withdraw");
        deposits[label][msg.sender] = 0;

        bool committed_ = commitments[label][msg.sender] != bytes32(0);
        bool revealed_ = revealed[label][msg.sender];

        if (committed_ && !revealed_) {
            _distribute(amount);
            emit DepositForfeited(name, msg.sender, amount);
        } else {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "Auction: refund failed");
            emit DepositRefunded(name, msg.sender, amount);
        }
    }

    /// @notice Helper for clients building commitments.
    function commitmentOf(
        uint256 bidAmount,
        bytes32 salt,
        address bidder
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(bidAmount, salt, bidder));
    }

    function setTreasury(address next) external {
        require(msg.sender == treasury, "Auction: not treasury");
        _setTreasury(next);
    }
}
