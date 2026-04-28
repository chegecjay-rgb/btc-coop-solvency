// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal kernel-facing read interface for Rail 2 native BTC pledge state.
/// @dev Return values use uint8-compatible enum values to keep downstream adapters simple.
interface INativePledgeRegistry {
    function hasPledge(uint256 positionId) external view returns (bool);
    function pledgeIdOfPosition(uint256 positionId) external view returns (bytes32);

    function isFinalized(uint256 positionId) external view returns (bool);
    function isCreditReady(uint256 positionId) external view returns (bool);
    function isEnforcementActive(uint256 positionId) external view returns (bool);

    function finalityOf(uint256 positionId)
        external
        view
        returns (uint8 finalityState, uint64 btcBlockHeight, uint32 confirmations, bytes32 finalityProofRef);

    function enforcementStateOf(uint256 positionId) external view returns (uint8);

    function proofRefsOf(uint256 positionId)
        external
        view
        returns (bytes32 pledgeProofRef, bytes32 finalityProofRef, bytes32 enforcementProofRef, bytes32 latestProofRef);
}
