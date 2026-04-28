// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {NativePledgeRegistry} from "src/native/NativePledgeRegistry.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {CollateralRail} from "src/types/CollateralRail.sol";

contract NativePledgeRegistryTest is Test {
    PositionRegistry internal positions;
    NativePledgeRegistry internal pledges;

    address internal writer = address(0xA11CE);
    address internal stranger = address(0xBEEF);
    address internal borrower = address(0xB0B);

    bytes32 internal constant BTC_ASSET = bytes32("BTC");
    bytes32 internal constant BTC_TX_ID = keccak256("btc-tx-1");
    uint32 internal constant VOUT = 1;
    uint64 internal constant AMOUNT_SATS = 100_000_000;
    bytes32 internal constant SCRIPT_COMMITMENT = keccak256("native-pledge-script-v1");
    bytes32 internal constant PROOF_REF = keccak256("proof-ref-1");

    function setUp() external {
        positions = new PositionRegistry(address(this));
        pledges = new NativePledgeRegistry(address(this), address(positions));

        pledges.setAuthorizedWriter(writer, true);
    }

    function test_constructor_revertsOnZeroOwner() external {
        vm.expectRevert(NativePledgeRegistry.ZeroAddress.selector);
        new NativePledgeRegistry(address(0), address(positions));
    }

    function test_constructor_revertsOnZeroPositionRegistry() external {
        vm.expectRevert(NativePledgeRegistry.ZeroAddress.selector);
        new NativePledgeRegistry(address(this), address(0));
    }

    function test_registerPledge_rejectsRail1Position() external {
        uint256 positionId = positions.createPosition(borrower, BTC_ASSET, 1 ether, 30_000e6, false);

        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativePledgeRegistry.NotNativeRail.selector, positionId, CollateralRail.PROTOCOL_ESCROW
            )
        );
        pledges.registerPledge(positionId, BTC_TX_ID, VOUT, AMOUNT_SATS, SCRIPT_COMMITMENT, PROOF_REF);
    }

    function test_registerPledge_storesNativeIdentityAndInitialStates() external {
        uint256 positionId = _createNativePosition();

        vm.prank(writer);
        bytes32 pledgeId =
            pledges.registerPledge(positionId, BTC_TX_ID, VOUT, AMOUNT_SATS, SCRIPT_COMMITMENT, PROOF_REF);

        NativePledgeRegistry.NativePledge memory pledge = pledges.getPledge(positionId);

        assertTrue(pledges.hasPledge(positionId));
        assertEq(pledge.positionId, positionId);
        assertEq(pledge.positionOwner, borrower);
        assertEq(pledge.pledgeId, pledgeId);
        assertEq(pledge.btcTxId, BTC_TX_ID);
        assertEq(pledge.vout, VOUT);
        assertEq(pledge.amountSats, AMOUNT_SATS);
        assertEq(pledge.scriptCommitment, SCRIPT_COMMITMENT);
        assertEq(pledge.proofRef, PROOF_REF);
        assertEq(pledge.btcBlockHeight, 0);
        assertEq(pledge.confirmations, 0);
        assertEq(uint256(pledge.enforcementState), uint256(NativePledgeRegistry.EnforcementState.Pledged));
        assertEq(uint256(pledge.finalityState), uint256(NativePledgeRegistry.FinalityState.Unconfirmed));
        assertEq(pledges.positionIdOfPledge(pledgeId), positionId);
        assertEq(pledges.pledgeIdOfPosition(positionId), pledgeId);
    }

    function test_registerPledge_onlyAuthorizedWriter() external {
        uint256 positionId = _createNativePosition();

        vm.prank(stranger);
        vm.expectRevert(NativePledgeRegistry.NotAuthorized.selector);
        pledges.registerPledge(positionId, BTC_TX_ID, VOUT, AMOUNT_SATS, SCRIPT_COMMITMENT, PROOF_REF);
    }

    function test_registerPledge_rejectsDuplicatePosition() external {
        uint256 positionId = _createNativePosition();

        vm.prank(writer);
        pledges.registerPledge(positionId, BTC_TX_ID, VOUT, AMOUNT_SATS, SCRIPT_COMMITMENT, PROOF_REF);

        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(NativePledgeRegistry.PledgeAlreadyRegistered.selector, positionId));
        pledges.registerPledge(
            positionId, keccak256("btc-tx-2"), VOUT, AMOUNT_SATS, SCRIPT_COMMITMENT, keccak256("proof-ref-2")
        );
    }

    function test_recordFinality_updatesProofAndFinalitySeparatelyFromEnforcement() external {
        uint256 positionId = _registerNativePledge();
        bytes32 finalityProof = keccak256("finality-proof");

        vm.prank(writer);
        pledges.recordFinality(positionId, NativePledgeRegistry.FinalityState.Finalized, 840_000, 6, finalityProof);

        NativePledgeRegistry.NativePledge memory pledge = pledges.getPledge(positionId);

        assertEq(uint256(pledge.finalityState), uint256(NativePledgeRegistry.FinalityState.Finalized));
        assertEq(pledge.btcBlockHeight, 840_000);
        assertEq(pledge.confirmations, 6);
        assertEq(pledge.proofRef, finalityProof);
        assertEq(uint256(pledge.enforcementState), uint256(NativePledgeRegistry.EnforcementState.Pledged));
    }

    function test_updateEnforcementState_tracksWorkflowWithoutChangingFinality() external {
        uint256 positionId = _registerNativePledge();

        vm.prank(writer);
        pledges.updateEnforcementState(positionId, NativePledgeRegistry.EnforcementState.Enforceable, bytes32(0));

        bytes32 enforcementProof = keccak256("enforcement-request-proof");

        vm.prank(writer);
        pledges.updateEnforcementState(
            positionId, NativePledgeRegistry.EnforcementState.EnforcementRequested, enforcementProof
        );

        NativePledgeRegistry.NativePledge memory pledge = pledges.getPledge(positionId);

        assertEq(uint256(pledge.enforcementState), uint256(NativePledgeRegistry.EnforcementState.EnforcementRequested));
        assertEq(uint256(pledge.finalityState), uint256(NativePledgeRegistry.FinalityState.Unconfirmed));
        assertEq(pledge.proofRef, enforcementProof);
    }

    function test_updateEnforcementState_rejectsInvalidBackwardTransition() external {
        uint256 positionId = _registerNativePledge();

        vm.prank(writer);
        pledges.updateEnforcementState(positionId, NativePledgeRegistry.EnforcementState.Enforceable, bytes32(0));

        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativePledgeRegistry.InvalidTransition.selector,
                NativePledgeRegistry.EnforcementState.Enforceable,
                NativePledgeRegistry.EnforcementState.Pledged
            )
        );
        pledges.updateEnforcementState(positionId, NativePledgeRegistry.EnforcementState.Pledged, bytes32(0));
    }

    function test_getPledge_revertsWhenMissing() external {
        vm.expectRevert(abi.encodeWithSelector(NativePledgeRegistry.PledgeNotRegistered.selector, 999));
        pledges.getPledge(999);
    }

    function _createNativePosition() internal returns (uint256 positionId) {
        positionId = positions.createPositionWithRail(
            borrower, BTC_ASSET, 1 ether, 30_000e6, false, CollateralRail.ENFORCEABLE_NATIVE
        );
    }

    function _registerNativePledge() internal returns (uint256 positionId) {
        positionId = _createNativePosition();

        vm.prank(writer);
        pledges.registerPledge(positionId, BTC_TX_ID, VOUT, AMOUNT_SATS, SCRIPT_COMMITMENT, PROOF_REF);
    }

    function test_markEnforceable_revertsBeforeFinality() external {
        uint256 positionId = _registerNativePledge();
        bytes32 enforceableProof = keccak256("enforceable-proof");

        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativePledgeRegistry.PledgeNotFinalized.selector,
                positionId,
                NativePledgeRegistry.FinalityState.Unconfirmed
            )
        );
        pledges.markEnforceable(positionId, enforceableProof);
    }

    function test_markEnforceable_afterFinalityMakesCreditReady() external {
        uint256 positionId = _registerNativePledge();

        bytes32 finalityProof = keccak256("finality-proof-b2");
        bytes32 enforceableProof = keccak256("enforceable-proof-b2");

        vm.prank(writer);
        pledges.recordFinality(positionId, NativePledgeRegistry.FinalityState.Finalized, 840_001, 7, finalityProof);

        vm.prank(writer);
        pledges.markEnforceable(positionId, enforceableProof);

        assertTrue(pledges.isFinalized(positionId));
        assertTrue(pledges.isCreditReady(positionId));
        assertFalse(pledges.isEnforcementActive(positionId));

        assertEq(
            uint256(pledges.enforcementStateOf(positionId)), uint256(NativePledgeRegistry.EnforcementState.Enforceable)
        );

        (
            NativePledgeRegistry.FinalityState finalityState,
            uint64 btcBlockHeight,
            uint32 confirmations,
            bytes32 storedFinalityProof
        ) = pledges.finalityOf(positionId);

        assertEq(uint256(finalityState), uint256(NativePledgeRegistry.FinalityState.Finalized));
        assertEq(btcBlockHeight, 840_001);
        assertEq(confirmations, 7);
        assertEq(storedFinalityProof, finalityProof);

        (bytes32 pledgeProofRef, bytes32 finalityProofRef, bytes32 enforcementProofRef, bytes32 latestProofRef) =
            pledges.proofRefsOf(positionId);

        assertEq(pledgeProofRef, PROOF_REF);
        assertEq(finalityProofRef, finalityProof);
        assertEq(enforcementProofRef, enforceableProof);
        assertEq(latestProofRef, enforceableProof);
    }

    function test_requestEnforcement_revertsUntilPledgeIsEnforceable() external {
        uint256 positionId = _registerNativePledge();
        bytes32 finalityProof = keccak256("finality-proof-before-request");
        bytes32 requestProof = keccak256("request-proof-before-enforceable");

        vm.prank(writer);
        pledges.recordFinality(positionId, NativePledgeRegistry.FinalityState.Finalized, 840_002, 8, finalityProof);

        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativePledgeRegistry.PledgeNotEnforceable.selector,
                positionId,
                NativePledgeRegistry.EnforcementState.Pledged
            )
        );
        pledges.requestEnforcement(positionId, requestProof);
    }

    function test_requestEnforcement_marksNativePledgeAsActive() external {
        uint256 positionId = _registerNativePledge();

        bytes32 finalityProof = keccak256("finality-proof-before-active");
        bytes32 enforceableProof = keccak256("enforceable-proof-before-active");
        bytes32 requestProof = keccak256("request-proof-active");

        vm.prank(writer);
        pledges.recordFinality(positionId, NativePledgeRegistry.FinalityState.Finalized, 840_003, 9, finalityProof);

        vm.prank(writer);
        pledges.markEnforceable(positionId, enforceableProof);

        vm.prank(writer);
        pledges.requestEnforcement(positionId, requestProof);

        assertFalse(pledges.isCreditReady(positionId));
        assertTrue(pledges.isEnforcementActive(positionId));

        assertEq(
            uint256(pledges.enforcementStateOf(positionId)),
            uint256(NativePledgeRegistry.EnforcementState.EnforcementRequested)
        );

        (, bytes32 finalityProofRef, bytes32 enforcementProofRef, bytes32 latestProofRef) =
            pledges.proofRefsOf(positionId);

        assertEq(finalityProofRef, finalityProof);
        assertEq(enforcementProofRef, requestProof);
        assertEq(latestProofRef, requestProof);
    }
}
