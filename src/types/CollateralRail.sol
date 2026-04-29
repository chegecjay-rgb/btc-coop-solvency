// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Canonical collateral-rail identifiers for Luna's two-rail credit architecture.
/// @dev Keep these as raw uint8 constants so modules can remain ABI-compatible while
///      the protocol kernel becomes rail-aware.
library CollateralRail {
    uint8 internal constant PROTOCOL_ESCROW = 0;
    uint8 internal constant ENFORCEABLE_NATIVE = 1;

    function isValid(uint8 rail) internal pure returns (bool) {
        return rail == PROTOCOL_ESCROW || rail == ENFORCEABLE_NATIVE;
    }
}
