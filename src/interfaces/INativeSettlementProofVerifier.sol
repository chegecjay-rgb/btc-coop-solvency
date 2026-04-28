// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal verifier interface for native-BTC settlement proof packs.
/// @dev This does not execute Bitcoin settlement. It only answers whether a submitted
/// proof reference is acceptable for Luna accounting consumption.
interface INativeSettlementProofVerifier {
    function verifyNativeSettlement(
        uint256 positionId,
        bytes32 proofPackRef,
        uint256 recoveredAmount,
        uint256 settlementCost,
        uint8 settlementKind
    ) external view returns (bool);
}
