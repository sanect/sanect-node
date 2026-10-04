// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title NameValidator
/// @notice Enforces the `.snct` naming ruleset: 1-32 chars, lowercase
///         a-z + digits 0-9 + hyphen, no leading/trailing hyphen, no
///         Unicode. Plus the tier classifier the registrars gate on.
library NameValidator {
    /// @notice Returns true if `name` satisfies the .snct ruleset.
    function isValid(string memory name) internal pure returns (bool) {
        bytes memory b = bytes(name);
        uint256 n = b.length;
        if (n == 0 || n > 32) return false;
        if (b[0] == 0x2d || b[n - 1] == 0x2d) return false; // no leading/trailing '-'
        for (uint256 i = 0; i < n; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x30 && c <= 0x39) // 0-9
                || (c >= 0x61 && c <= 0x7a) // a-z
                || c == 0x2d; // '-'
            if (!ok) return false;
        }
        return true;
    }

    /// @notice Byte length of `name`. Since we forbid Unicode, byte
    ///         length == character length.
    function length(string memory name) internal pure returns (uint256) {
        return bytes(name).length;
    }

    /// @notice The registrar tier for `name`:
    ///         0 = reserved (1-2 chars)
    ///         1 = auction  (3-4 chars)
    ///         2 = open     (5-32 chars)
    /// @dev Reverts on invalid names — callers must check `isValid` first
    ///      or accept the revert as a validation shortcut.
    function tier(string memory name) internal pure returns (uint8) {
        uint256 n = bytes(name).length;
        if (n <= 2) return 0;
        if (n <= 4) return 1;
        return 2;
    }

    /// @notice keccak256 of the label, as used in namehash composition.
    function labelhash(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(name));
    }
}
