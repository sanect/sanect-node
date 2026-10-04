// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RevenueSplitter
/// @notice Sends 50% of every received amount to the burn sink (0xdead)
///         and 50% to the treasury address. The treasury can update
///         itself; the burn share is fixed for the lifetime of the
///         contract — no admin discretion over how much is burned.
abstract contract RevenueSplitter {
    /// @notice 0x000…dEaD — the standard EVM burn sink. The funds can't
    ///         be retrieved without breaking ECDSA.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    address public treasury;

    event TreasuryUpdated(address indexed previous, address indexed next);
    event Distributed(uint256 burned, uint256 toTreasury);

    constructor(address _treasury) {
        require(_treasury != address(0), "RevenueSplitter: zero treasury");
        treasury = _treasury;
    }

    function _setTreasury(address next) internal {
        require(next != address(0), "RevenueSplitter: zero treasury");
        emit TreasuryUpdated(treasury, next);
        treasury = next;
    }

    /// @notice Split `amount` 50/50 between burn sink and treasury.
    ///         Reverts if either transfer fails (treasury better not be
    ///         a contract that rejects ETH).
    function _distribute(uint256 amount) internal {
        if (amount == 0) return;
        uint256 burnShare = amount / 2;
        uint256 treasuryShare = amount - burnShare;
        (bool ok1,) = BURN.call{value: burnShare}("");
        require(ok1, "RevenueSplitter: burn failed");
        (bool ok2,) = treasury.call{value: treasuryShare}("");
        require(ok2, "RevenueSplitter: treasury failed");
        emit Distributed(burnShare, treasuryShare);
    }
}
