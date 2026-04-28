// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {NativePledgeBuilder} from "src/native/NativePledgeBuilder.sol";

contract NativePledgeBuilderTest is Test {
    NativePledgeBuilder internal builder;

    address internal borrower = address(0xB0B);

    function setUp() external {
        builder = new NativePledgeBuilder();
    }

    function test_buildPledgeIntent_derivesDeterministicCommitments() external view {
        NativePledgeBuilder.PledgeTerms memory terms = _validTerms();

        NativePledgeBuilder.PledgeIntent memory first = builder.buildPledgeIntent(terms);
        NativePledgeBuilder.PledgeIntent memory second = builder.buildPledgeIntent(terms);

        bytes32 expectedPolicy = builder.derivePolicyCommitment(
            terms.scriptKind,
            terms.minConfirmations,
            terms.enforcementDelayBlocks,
            terms.expiryTimestamp,
            terms.metadataHash
        );

        bytes32 expectedScript = builder.deriveScriptCommitment(
            terms.borrowerKeyCommitment, terms.protocolKeyCommitment, terms.recoveryKeyCommitment, expectedPolicy
        );

        bytes32 expectedIntentId =
            builder.derivePledgeIntentId(terms.positionId, terms.borrower, terms.amountSats, expectedScript);

        assertEq(first.policyCommitment, expectedPolicy);
        assertEq(first.scriptCommitment, expectedScript);
        assertEq(first.pledgeIntentId, expectedIntentId);

        assertEq(second.policyCommitment, expectedPolicy);
        assertEq(second.scriptCommitment, expectedScript);
        assertEq(second.pledgeIntentId, expectedIntentId);

        assertEq(first.policyCommitment, second.policyCommitment);
        assertEq(first.scriptCommitment, second.scriptCommitment);
        assertEq(first.pledgeIntentId, second.pledgeIntentId);
    }

    function test_buildPledgeIntent_changesWhenTermsChange() external view {
        NativePledgeBuilder.PledgeTerms memory firstTerms = _validTerms();
        NativePledgeBuilder.PledgeTerms memory secondTerms = _validTerms();

        secondTerms.amountSats = 200_000_000;

        NativePledgeBuilder.PledgeIntent memory first = builder.buildPledgeIntent(firstTerms);

        NativePledgeBuilder.PledgeIntent memory second = builder.buildPledgeIntent(secondTerms);

        assertTrue(first.pledgeIntentId != second.pledgeIntentId);
        assertEq(first.scriptCommitment, second.scriptCommitment);
    }

    function test_buildPledgeIntent_revertsOnInvalidTerms() external {
        NativePledgeBuilder.PledgeTerms memory terms = _validTerms();

        terms.amountSats = 0;
        vm.expectRevert(NativePledgeBuilder.InvalidAmount.selector);
        builder.buildPledgeIntent(terms);

        terms = _validTerms();
        terms.borrower = address(0);
        vm.expectRevert(NativePledgeBuilder.ZeroAddress.selector);
        builder.buildPledgeIntent(terms);

        terms = _validTerms();
        terms.scriptKind = NativePledgeBuilder.PledgeScriptKind.Unset;
        vm.expectRevert(NativePledgeBuilder.InvalidScriptKind.selector);
        builder.buildPledgeIntent(terms);
    }

    function _validTerms() internal view returns (NativePledgeBuilder.PledgeTerms memory) {
        return NativePledgeBuilder.PledgeTerms({
            positionId: 1,
            borrower: borrower,
            amountSats: 100_000_000,
            borrowerKeyCommitment: keccak256("borrower-key"),
            protocolKeyCommitment: keccak256("protocol-key"),
            recoveryKeyCommitment: keccak256("recovery-key"),
            minConfirmations: 6,
            enforcementDelayBlocks: 144,
            expiryTimestamp: uint64(block.timestamp + 30 days),
            metadataHash: keccak256("native-pledge-metadata"),
            scriptKind: NativePledgeBuilder.PledgeScriptKind.RecoveryTimelock
        });
    }
}
