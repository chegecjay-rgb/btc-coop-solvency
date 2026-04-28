// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Phase C.1 skeleton for constructing native BTC pledge commitments.
/// @dev This contract does not build or validate a real Bitcoin transaction.
///      It creates deterministic commitments that offchain BTC-side tooling can
///      use when building enforceable native BTC collateral scripts.
contract NativePledgeBuilder {
    enum PledgeScriptKind {
        Unset,
        TwoPartyEscrow,
        RecoveryTimelock
    }

    struct PledgeTerms {
        uint256 positionId;
        address borrower;
        uint64 amountSats;
        bytes32 borrowerKeyCommitment;
        bytes32 protocolKeyCommitment;
        bytes32 recoveryKeyCommitment;
        uint32 minConfirmations;
        uint32 enforcementDelayBlocks;
        uint64 expiryTimestamp;
        bytes32 metadataHash;
        PledgeScriptKind scriptKind;
    }

    struct PledgeIntent {
        uint256 positionId;
        address borrower;
        uint64 amountSats;
        uint32 minConfirmations;
        uint32 enforcementDelayBlocks;
        uint64 expiryTimestamp;
        bytes32 policyCommitment;
        bytes32 scriptCommitment;
        bytes32 pledgeIntentId;
    }

    error InvalidPositionId();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidKeyCommitment();
    error InvalidConfirmationTarget();
    error InvalidTimelock();
    error InvalidExpiry();
    error InvalidScriptKind();

    function buildPledgeIntent(PledgeTerms calldata terms) external pure returns (PledgeIntent memory intent) {
        _validateTerms(terms);

        bytes32 policyCommitment = derivePolicyCommitment(
            terms.scriptKind,
            terms.minConfirmations,
            terms.enforcementDelayBlocks,
            terms.expiryTimestamp,
            terms.metadataHash
        );

        bytes32 scriptCommitment = deriveScriptCommitment(
            terms.borrowerKeyCommitment, terms.protocolKeyCommitment, terms.recoveryKeyCommitment, policyCommitment
        );

        bytes32 pledgeIntentId =
            derivePledgeIntentId(terms.positionId, terms.borrower, terms.amountSats, scriptCommitment);

        intent = PledgeIntent({
            positionId: terms.positionId,
            borrower: terms.borrower,
            amountSats: terms.amountSats,
            minConfirmations: terms.minConfirmations,
            enforcementDelayBlocks: terms.enforcementDelayBlocks,
            expiryTimestamp: terms.expiryTimestamp,
            policyCommitment: policyCommitment,
            scriptCommitment: scriptCommitment,
            pledgeIntentId: pledgeIntentId
        });
    }

    function derivePolicyCommitment(
        PledgeScriptKind scriptKind,
        uint32 minConfirmations,
        uint32 enforcementDelayBlocks,
        uint64 expiryTimestamp,
        bytes32 metadataHash
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "LUNA_NATIVE_BTC_POLICY_V1",
                scriptKind,
                minConfirmations,
                enforcementDelayBlocks,
                expiryTimestamp,
                metadataHash
            )
        );
    }

    function deriveScriptCommitment(
        bytes32 borrowerKeyCommitment,
        bytes32 protocolKeyCommitment,
        bytes32 recoveryKeyCommitment,
        bytes32 policyCommitment
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "LUNA_NATIVE_BTC_SCRIPT_COMMITMENT_V1",
                borrowerKeyCommitment,
                protocolKeyCommitment,
                recoveryKeyCommitment,
                policyCommitment
            )
        );
    }

    function derivePledgeIntentId(uint256 positionId, address borrower, uint64 amountSats, bytes32 scriptCommitment)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked("LUNA_NATIVE_BTC_PLEDGE_INTENT_V1", positionId, borrower, amountSats, scriptCommitment)
        );
    }

    function _validateTerms(PledgeTerms calldata terms) internal pure {
        if (terms.positionId == 0) revert InvalidPositionId();
        if (terms.borrower == address(0)) revert ZeroAddress();
        if (terms.amountSats == 0) revert InvalidAmount();

        if (
            terms.borrowerKeyCommitment == bytes32(0) || terms.protocolKeyCommitment == bytes32(0)
                || terms.recoveryKeyCommitment == bytes32(0)
        ) {
            revert InvalidKeyCommitment();
        }

        if (terms.minConfirmations == 0) revert InvalidConfirmationTarget();
        if (terms.enforcementDelayBlocks == 0) revert InvalidTimelock();
        if (terms.expiryTimestamp == 0) revert InvalidExpiry();
        if (terms.scriptKind == PledgeScriptKind.Unset) revert InvalidScriptKind();
    }
}
