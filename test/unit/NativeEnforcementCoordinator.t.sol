// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {NativeEnforcementCoordinator} from "src/native/NativeEnforcementCoordinator.sol";

contract MockNativePledgeRegistryForCoordinator {
    bool public pledgeExists;
    bool public creditReady;

    mapping(uint256 => bool) public enforcementActiveByPosition;
    mapping(uint256 => bytes32) public pledgeIdByPosition;

    uint256 public lastRequestedPositionId;
    bytes32 public lastRequestedProofRef;

    uint256 public lastUpdatedPositionId;
    uint8 public lastUpdatedState;
    bytes32 public lastUpdatedProofRef;

    function setPledge(uint256 positionId, bytes32 pledgeId, bool exists, bool ready) external {
        pledgeExists = exists;
        creditReady = ready;
        pledgeIdByPosition[positionId] = pledgeId;
    }

    function setEnforcementActive(uint256 positionId, bool active) external {
        enforcementActiveByPosition[positionId] = active;
    }

    function hasPledge(uint256) external view returns (bool) {
        return pledgeExists;
    }

    function pledgeIdOfPosition(uint256 positionId) external view returns (bytes32) {
        return pledgeIdByPosition[positionId];
    }

    function isCreditReady(uint256) external view returns (bool) {
        return creditReady;
    }

    function isEnforcementActive(uint256 positionId) external view returns (bool) {
        return enforcementActiveByPosition[positionId];
    }

    function requestEnforcement(uint256 positionId, bytes32 proofRef) external {
        lastRequestedPositionId = positionId;
        lastRequestedProofRef = proofRef;
        enforcementActiveByPosition[positionId] = true;
    }

    function updateEnforcementState(uint256 positionId, uint8 nextState, bytes32 proofRef) external {
        lastUpdatedPositionId = positionId;
        lastUpdatedState = nextState;
        lastUpdatedProofRef = proofRef;

        enforcementActiveByPosition[positionId] = nextState == 3 || nextState == 4 || nextState == 5;
    }
}

contract NativeEnforcementCoordinatorTest is Test {
    NativeEnforcementCoordinator internal coordinator;
    MockNativePledgeRegistryForCoordinator internal registry;

    address internal owner = address(0xA11CE);
    address internal actor = address(0xB0B);
    address internal stranger = address(0xBAD);

    uint256 internal constant POSITION_ID = 1;
    bytes32 internal constant PLEDGE_ID = keccak256("pledge-id");
    bytes32 internal constant REQUEST_PROOF = keccak256("request-proof");
    bytes32 internal constant EXECUTION_PROOF = keccak256("execution-proof");
    bytes32 internal constant RECOVERY_PROOF = keccak256("recovery-proof");
    bytes32 internal constant SETTLEMENT_PROOF = keccak256("settlement-proof");

    function setUp() external {
        vm.warp(1_000_000);

        registry = new MockNativePledgeRegistryForCoordinator();
        registry.setPledge(POSITION_ID, PLEDGE_ID, true, true);

        coordinator = new NativeEnforcementCoordinator(owner, address(registry));

        vm.prank(owner);
        coordinator.setAuthorizedActor(actor, true);
    }

    function test_startEnforcement_recordsCaseAndRequestsRegistryEnforcement() external {
        vm.prank(actor);
        coordinator.startEnforcement(POSITION_ID, REQUEST_PROOF);

        NativeEnforcementCoordinator.EnforcementCase memory enforcementCase = coordinator.getCase(POSITION_ID);

        assertTrue(coordinator.hasCase(POSITION_ID));

        assertEq(enforcementCase.positionId, POSITION_ID);
        assertEq(enforcementCase.pledgeId, PLEDGE_ID);
        assertEq(uint256(enforcementCase.phase), uint256(NativeEnforcementCoordinator.EnforcementPhase.Requested));
        assertEq(enforcementCase.requestProofRef, REQUEST_PROOF);
        assertEq(enforcementCase.requestedAt, uint64(block.timestamp));
        assertEq(enforcementCase.updatedAt, uint64(block.timestamp));

        assertEq(registry.lastRequestedPositionId(), POSITION_ID);
        assertEq(registry.lastRequestedProofRef(), REQUEST_PROOF);
        assertTrue(registry.enforcementActiveByPosition(POSITION_ID));
    }

    function test_startEnforcement_rejectsUnauthorizedActor() external {
        vm.prank(stranger);
        vm.expectRevert(NativeEnforcementCoordinator.NotAuthorized.selector);
        coordinator.startEnforcement(POSITION_ID, REQUEST_PROOF);
    }

    function test_startEnforcement_rejectsPledgeThatIsNotCreditReady() external {
        registry.setPledge(POSITION_ID, PLEDGE_ID, true, false);

        vm.prank(actor);
        vm.expectRevert(
            abi.encodeWithSelector(NativeEnforcementCoordinator.NativePledgeNotCreditReady.selector, POSITION_ID)
        );
        coordinator.startEnforcement(POSITION_ID, REQUEST_PROOF);
    }

    function test_startEnforcement_rejectsAlreadyActiveNativeEnforcement() external {
        registry.setEnforcementActive(POSITION_ID, true);

        vm.prank(actor);
        vm.expectRevert(
            abi.encodeWithSelector(NativeEnforcementCoordinator.NativeEnforcementAlreadyActive.selector, POSITION_ID)
        );
        coordinator.startEnforcement(POSITION_ID, REQUEST_PROOF);
    }

    function test_canMarkEnforcementProgressWithoutFinalizingLunaAccounting() external {
        vm.prank(actor);
        coordinator.startEnforcement(POSITION_ID, REQUEST_PROOF);

        vm.prank(actor);
        coordinator.markEnforcementInProgress(POSITION_ID, EXECUTION_PROOF);

        NativeEnforcementCoordinator.EnforcementCase memory enforcementCase = coordinator.getCase(POSITION_ID);

        assertEq(uint256(enforcementCase.phase), uint256(NativeEnforcementCoordinator.EnforcementPhase.InProgress));
        assertEq(enforcementCase.executionProofRef, EXECUTION_PROOF);
        assertEq(enforcementCase.settlementProofRef, bytes32(0));

        assertEq(registry.lastUpdatedPositionId(), POSITION_ID);
        assertEq(registry.lastUpdatedState(), 4);
        assertEq(registry.lastUpdatedProofRef(), EXECUTION_PROOF);

        (bool finalizeSuccess,) = address(coordinator)
            .call(abi.encodeWithSignature("finalizeNativeSettlement(uint256,bytes32)", POSITION_ID, SETTLEMENT_PROOF));

        (bool settleSuccess,) = address(coordinator)
            .call(abi.encodeWithSignature("settleNativePosition(uint256,bytes32)", POSITION_ID, SETTLEMENT_PROOF));

        assertFalse(finalizeSuccess);
        assertFalse(settleSuccess);

        NativeEnforcementCoordinator.EnforcementCase memory afterAttempt = coordinator.getCase(POSITION_ID);

        assertEq(uint256(afterAttempt.phase), uint256(NativeEnforcementCoordinator.EnforcementPhase.InProgress));
        assertEq(afterAttempt.settlementProofRef, bytes32(0));
    }

    function test_canRecordRecoveryObservedAfterEnforcementProgress() external {
        vm.prank(actor);
        coordinator.startEnforcement(POSITION_ID, REQUEST_PROOF);

        vm.prank(actor);
        coordinator.markEnforcementInProgress(POSITION_ID, EXECUTION_PROOF);

        vm.prank(actor);
        coordinator.recordRecoveryObserved(POSITION_ID, RECOVERY_PROOF);

        NativeEnforcementCoordinator.EnforcementCase memory enforcementCase = coordinator.getCase(POSITION_ID);

        assertEq(
            uint256(enforcementCase.phase), uint256(NativeEnforcementCoordinator.EnforcementPhase.RecoveryObserved)
        );
        assertEq(enforcementCase.recoveryProofRef, RECOVERY_PROOF);

        assertEq(registry.lastUpdatedPositionId(), POSITION_ID);
        assertEq(registry.lastUpdatedState(), 5);
        assertEq(registry.lastUpdatedProofRef(), RECOVERY_PROOF);
    }

    function test_recordRecoveryObserved_rejectsBeforeInProgress() external {
        vm.prank(actor);
        coordinator.startEnforcement(POSITION_ID, REQUEST_PROOF);

        vm.prank(actor);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativeEnforcementCoordinator.InvalidPhase.selector,
                NativeEnforcementCoordinator.EnforcementPhase.Requested,
                NativeEnforcementCoordinator.EnforcementPhase.InProgress
            )
        );
        coordinator.recordRecoveryObserved(POSITION_ID, RECOVERY_PROOF);
    }
}
