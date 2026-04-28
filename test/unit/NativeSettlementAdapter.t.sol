// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {NativeSettlementAdapter} from "src/native/NativeSettlementAdapter.sol";
import {INativeSettlementProofVerifier} from "src/interfaces/INativeSettlementProofVerifier.sol";

contract MockNativePositionRegistry {
    mapping(uint256 => uint8) internal rails;

    function setPositionRail(uint256 positionId, uint8 rail) external {
        rails[positionId] = rail;
    }

    function getPositionRail(uint256 positionId) external view returns (uint8) {
        return rails[positionId];
    }
}

contract MockNativeDebtLedger {
    mapping(uint256 => uint256) public settlementCostByPosition;

    function recordSettlementCost(uint256 positionId, uint256 amount) external {
        settlementCostByPosition[positionId] += amount;
    }
}

contract MockNativeRecapitalizationEngine {
    mapping(uint256 => uint256) public recoveryByPosition;

    function recordRecovery(uint256 positionId, uint256 amount) external {
        recoveryByPosition[positionId] += amount;
    }
}

contract MockNativeProofPackRegistry {
    mapping(bytes32 => bool) public proofPackExistsByRef;

    function setProofPack(bytes32 proofPackRef, bool exists_) external {
        proofPackExistsByRef[proofPackRef] = exists_;
    }

    function hasProofPack(bytes32 proofPackRef) external view returns (bool) {
        return proofPackExistsByRef[proofPackRef];
    }
}

contract MockNativeEnforcementCoordinator {
    mapping(uint256 => mapping(bytes32 => bool)) public observed;

    function setObserved(uint256 positionId, bytes32 proofPackRef, bool observed_) external {
        observed[positionId][proofPackRef] = observed_;
    }

    function hasObservedRecovery(uint256 positionId, bytes32 proofPackRef) external view returns (bool) {
        return observed[positionId][proofPackRef];
    }
}

contract MockNativeSettlementProofVerifier is INativeSettlementProofVerifier {
    bool public shouldVerify = true;

    function setShouldVerify(bool value) external {
        shouldVerify = value;
    }

    function verifyNativeSettlement(uint256, bytes32, uint256, uint256, uint8) external view returns (bool) {
        return shouldVerify;
    }
}

contract NativeSettlementAdapterTest is Test {
    NativeSettlementAdapter internal adapter;
    MockNativePositionRegistry internal positionRegistry;
    MockNativeDebtLedger internal debtLedger;
    MockNativeRecapitalizationEngine internal recapitalizationEngine;
    MockNativeProofPackRegistry internal proofPackRegistry;
    MockNativeEnforcementCoordinator internal enforcementCoordinator;
    MockNativeSettlementProofVerifier internal proofVerifier;

    address internal owner = address(this);
    address internal finalizer = address(0xF1A1);
    address internal stranger = address(0xBEEF);

    uint256 internal constant POSITION_ID = 1;
    bytes32 internal constant PROOF_PACK_REF = keccak256("native-proof-pack-1");

    function setUp() external {
        positionRegistry = new MockNativePositionRegistry();
        debtLedger = new MockNativeDebtLedger();
        recapitalizationEngine = new MockNativeRecapitalizationEngine();
        proofPackRegistry = new MockNativeProofPackRegistry();
        enforcementCoordinator = new MockNativeEnforcementCoordinator();
        proofVerifier = new MockNativeSettlementProofVerifier();

        adapter = new NativeSettlementAdapter(
            owner,
            address(positionRegistry),
            address(debtLedger),
            address(recapitalizationEngine),
            address(proofPackRegistry),
            address(enforcementCoordinator),
            address(proofVerifier)
        );

        adapter.setAuthorizedFinalizer(finalizer, true);

        positionRegistry.setPositionRail(POSITION_ID, adapter.RAIL_NATIVE_BTC());
        proofPackRegistry.setProofPack(PROOF_PACK_REF, true);
        enforcementCoordinator.setObserved(POSITION_ID, PROOF_PACK_REF, true);
    }

    function test_finalizeNativeLiquidation_recordsRecoveryAndSettlementCost() external {
        vm.prank(finalizer);
        adapter.finalizeNativeLiquidation(POSITION_ID, PROOF_PACK_REF, 100e8, 2e8);

        (
            uint256 storedPositionId,
            NativeSettlementAdapter.SettlementKind kind,
            bytes32 storedProofPackRef,
            uint256 recoveredAmount,
            uint256 settlementCost,
            address finalizedBy,
            bool finalized
        ) = adapter.settlementByPosition(POSITION_ID);

        assertEq(storedPositionId, POSITION_ID);
        assertEq(uint256(kind), uint256(NativeSettlementAdapter.SettlementKind.Liquidation));
        assertEq(storedProofPackRef, PROOF_PACK_REF);
        assertEq(recoveredAmount, 100e8);
        assertEq(settlementCost, 2e8);
        assertEq(finalizedBy, finalizer);
        assertEq(finalized, true);

        assertEq(debtLedger.settlementCostByPosition(POSITION_ID), 2e8);
        assertEq(recapitalizationEngine.recoveryByPosition(POSITION_ID), 100e8);
        assertEq(adapter.consumedProofPack(PROOF_PACK_REF), true);
    }

    function test_finalizeNativeTerminalSettlement_recordsTerminalKind() external {
        bytes32 terminalProofPackRef = keccak256("native-terminal-proof-pack");

        proofPackRegistry.setProofPack(terminalProofPackRef, true);
        enforcementCoordinator.setObserved(POSITION_ID, terminalProofPackRef, true);

        vm.prank(finalizer);
        adapter.finalizeNativeTerminalSettlement(POSITION_ID, terminalProofPackRef, 90e8, 1e8);

        (
            ,
            NativeSettlementAdapter.SettlementKind kind,
            bytes32 storedProofPackRef,
            uint256 recoveredAmount,
            uint256 settlementCost,,
            bool finalized
        ) = adapter.settlementByPosition(POSITION_ID);

        assertEq(uint256(kind), uint256(NativeSettlementAdapter.SettlementKind.TerminalSettlement));
        assertEq(storedProofPackRef, terminalProofPackRef);
        assertEq(recoveredAmount, 90e8);
        assertEq(settlementCost, 1e8);
        assertEq(finalized, true);
    }

    function test_finalizeNativeSettlement_revertsForUnauthorizedFinalizer() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NativeSettlementAdapter.NotAuthorizedFinalizer.selector, stranger));
        adapter.finalizeNativeLiquidation(POSITION_ID, PROOF_PACK_REF, 100e8, 2e8);
    }

    function test_finalizeNativeSettlement_revertsForRail1Position() external {
        positionRegistry.setPositionRail(POSITION_ID, 0);

        vm.prank(finalizer);
        vm.expectRevert(
            abi.encodeWithSelector(NativeSettlementAdapter.PositionIsNotNativeRail.selector, POSITION_ID, 0)
        );
        adapter.finalizeNativeLiquidation(POSITION_ID, PROOF_PACK_REF, 100e8, 2e8);
    }

    function test_finalizeNativeSettlement_revertsForMissingProofPack() external {
        bytes32 missingProofPackRef = keccak256("missing-proof-pack");

        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(NativeSettlementAdapter.ProofPackNotFound.selector, missingProofPackRef));
        adapter.finalizeNativeLiquidation(POSITION_ID, missingProofPackRef, 100e8, 2e8);
    }

    function test_finalizeNativeSettlement_revertsWhenRecoveryNotObserved() external {
        bytes32 unobservedProofPackRef = keccak256("unobserved-proof-pack");

        proofPackRegistry.setProofPack(unobservedProofPackRef, true);

        vm.prank(finalizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativeSettlementAdapter.RecoveryNotObserved.selector, POSITION_ID, unobservedProofPackRef
            )
        );
        adapter.finalizeNativeLiquidation(POSITION_ID, unobservedProofPackRef, 100e8, 2e8);
    }

    function test_finalizeNativeSettlement_revertsWhenVerifierRejects() external {
        proofVerifier.setShouldVerify(false);

        vm.prank(finalizer);
        vm.expectRevert(
            abi.encodeWithSelector(NativeSettlementAdapter.ProofVerificationFailed.selector, PROOF_PACK_REF)
        );
        adapter.finalizeNativeLiquidation(POSITION_ID, PROOF_PACK_REF, 100e8, 2e8);
    }

    function test_finalizeNativeSettlement_revertsOnProofPackReplay() external {
        vm.prank(finalizer);
        adapter.finalizeNativeLiquidation(POSITION_ID, PROOF_PACK_REF, 100e8, 2e8);

        uint256 secondPosition = 2;
        positionRegistry.setPositionRail(secondPosition, adapter.RAIL_NATIVE_BTC());
        enforcementCoordinator.setObserved(secondPosition, PROOF_PACK_REF, true);

        vm.prank(finalizer);
        vm.expectRevert(
            abi.encodeWithSelector(NativeSettlementAdapter.ProofPackAlreadyConsumed.selector, PROOF_PACK_REF)
        );
        adapter.finalizeNativeLiquidation(secondPosition, PROOF_PACK_REF, 100e8, 2e8);
    }

    function test_finalizeNativeSettlement_revertsOnPositionReplay() external {
        vm.prank(finalizer);
        adapter.finalizeNativeLiquidation(POSITION_ID, PROOF_PACK_REF, 100e8, 2e8);

        bytes32 secondProofPackRef = keccak256("second-proof-pack");
        proofPackRegistry.setProofPack(secondProofPackRef, true);
        enforcementCoordinator.setObserved(POSITION_ID, secondProofPackRef, true);

        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(NativeSettlementAdapter.PositionAlreadySettled.selector, POSITION_ID));
        adapter.finalizeNativeTerminalSettlement(POSITION_ID, secondProofPackRef, 100e8, 2e8);
    }

    function test_finalizeNativeSettlement_revertsOnZeroRecoveredAmount() external {
        vm.prank(finalizer);
        vm.expectRevert(NativeSettlementAdapter.InvalidAmount.selector);
        adapter.finalizeNativeLiquidation(POSITION_ID, PROOF_PACK_REF, 0, 2e8);
    }
}
