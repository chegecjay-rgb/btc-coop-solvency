// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Verifier interface for Rail 2 native BTC pledge proofs.
/// @dev Phase B defines the onchain gate. Phase C can plug in the real
///      watcher, proof-pack, light-client, or committee-backed verifier.
interface INativePledgeProofVerifier {
    function verifyPledge(
        uint256 positionId,
        address positionOwner,
        bytes32 btcTxId,
        uint32 vout,
        uint64 amountSats,
        bytes32 scriptCommitment,
        bytes32 proofRef
    ) external view returns (bool);
}
