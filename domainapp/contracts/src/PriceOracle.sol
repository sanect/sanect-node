// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PriceOracle
/// @notice Annual rent per name, in wei (asnct). Updatable by the owner
///         so the chain can react to SNCT price changes once mainnet
///         opens up — testnet defaults are fine for the entire testnet
///         lifetime.
contract PriceOracle {
    address public owner;

    /// @notice Rent rates per character count, in wei/year.
    /// length 3 → rent3, length 4 → rent4, length 5+ → rent5plus
    /// Lengths 1-2 don't pay rent (genesis-owned, no expiry).
    uint256 public rent3;
    uint256 public rent4;
    uint256 public rent5plus;

    event Updated(uint256 rent3, uint256 rent4, uint256 rent5plus);

    constructor(uint256 _rent3, uint256 _rent4, uint256 _rent5plus) {
        owner = msg.sender;
        rent3 = _rent3;
        rent4 = _rent4;
        rent5plus = _rent5plus;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "PriceOracle: not owner");
        _;
    }

    /// @notice Returns `length`'s annual rent in wei.
    function annualRent(uint256 nameLen) external view returns (uint256) {
        if (nameLen <= 2) return 0;
        if (nameLen == 3) return rent3;
        if (nameLen == 4) return rent4;
        return rent5plus;
    }

    function setRates(uint256 _rent3, uint256 _rent4, uint256 _rent5plus) external onlyOwner {
        rent3 = _rent3;
        rent4 = _rent4;
        rent5plus = _rent5plus;
        emit Updated(_rent3, _rent4, _rent5plus);
    }

    function transferOwnership(address next) external onlyOwner {
        owner = next;
    }
}
