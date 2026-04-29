// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RescueController} from "src/core/RescueController.sol";
import {CollateralRail} from "src/types/CollateralRail.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockStabilizationPoolForRescue {
    mapping(bytes32 => uint256) internal _available;
    bytes32 internal _lastAssetId;
    uint256 internal _lastDeployAmount;

    function setAvailable(bytes32 assetId, uint256 amount) external {
        _available[assetId] = amount;
    }

    function availableRescueLiquidity(bytes32 assetId) external view returns (uint256) {
        return _available[assetId];
    }

    function deployRescueCapital(bytes32 assetId, uint256 amount) external {
        _lastAssetId = assetId;
        _lastDeployAmount = amount;
        _available[assetId] -= amount;
    }

    function lastAssetId() external view returns (bytes32) {
        return _lastAssetId;
    }

    function lastDeployAmount() external view returns (uint256) {
        return _lastDeployAmount;
    }
}

contract MockInsuranceReserveForRescue {
    uint256 internal _lastPositionId;
    uint256 internal _lastAmount;

    function coverTerminalDeficit(uint256 positionId, uint256 amount) external {
        _lastPositionId = positionId;
        _lastAmount = amount;
    }

    function lastPositionId() external view returns (uint256) {
        return _lastPositionId;
    }

    function lastAmount() external view returns (uint256) {
        return _lastAmount;
    }
}

contract MockRiskEngineForRescue {
    struct PositionRiskSnapshot {
        uint256 healthFactor;
        uint256 adjustedCollateral;
        uint256 totalDebt;
        uint256 currentLTVBps;
        uint8 classification;
    }

    mapping(uint256 => PositionRiskSnapshot) internal _snapshots;

    function setSnapshot(
        uint256 positionId,
        uint256 healthFactor,
        uint256 adjustedCollateral,
        uint256 totalDebt,
        uint256 currentLTVBps,
        uint8 classification
    ) external {
        _snapshots[positionId] = PositionRiskSnapshot({
            healthFactor: healthFactor,
            adjustedCollateral: adjustedCollateral,
            totalDebt: totalDebt,
            currentLTVBps: currentLTVBps,
            classification: classification
        });
    }

    function positionRiskSnapshot(uint256 positionId) external view returns (PositionRiskSnapshot memory) {
        return _snapshots[positionId];
    }
}

contract MockRemoteIntentCoordinatorForRescue {
    uint256 internal _callCount;
    uint256 internal _lastPositionId;
    uint256 internal _lastAmountNeeded;
    address internal _lastBeneficiary;
    address internal _lastSettlementAsset;
    bytes32 internal _lastIntentId;

    function requestRescueFill(uint256 positionId, uint256 amountNeeded, address beneficiary, address settlementAsset)
        external
        returns (bytes32 intentId)
    {
        _callCount += 1;
        _lastPositionId = positionId;
        _lastAmountNeeded = amountNeeded;
        _lastBeneficiary = beneficiary;
        _lastSettlementAsset = settlementAsset;
        _lastIntentId = keccak256(
            abi.encodePacked("RESCUE_INTENT", positionId, amountNeeded, beneficiary, settlementAsset, _callCount)
        );
        return _lastIntentId;
    }

    function callCount() external view returns (uint256) {
        return _callCount;
    }

    function lastPositionId() external view returns (uint256) {
        return _lastPositionId;
    }

    function lastAmountNeeded() external view returns (uint256) {
        return _lastAmountNeeded;
    }

    function lastBeneficiary() external view returns (address) {
        return _lastBeneficiary;
    }

    function lastSettlementAsset() external view returns (address) {
        return _lastSettlementAsset;
    }

    function lastIntentId() external view returns (bytes32) {
        return _lastIntentId;
    }
}

contract RescueControllerTest is Test {
    PositionRegistry internal positionRegistry;
    ParameterRegistry internal parameterRegistry;
    DebtLedger internal debtLedger;
    CollateralManager internal collateralManager;
    MockStabilizationPoolForRescue internal stabilizationPool;
    MockInsuranceReserveForRescue internal insuranceReserve;
    MockRiskEngineForRescue internal riskEngine;
    MockRemoteIntentCoordinatorForRescue internal remoteIntentCoordinator;
    MockERC20 internal stable;
    RescueController internal rescueController;

    address internal owner = address(this);
    address internal executor = address(0xABCD);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        positionRegistry = new PositionRegistry(owner);
        parameterRegistry = new ParameterRegistry(owner);
        debtLedger = new DebtLedger(owner);
        collateralManager = new CollateralManager(owner);
        stabilizationPool = new MockStabilizationPoolForRescue();
        insuranceReserve = new MockInsuranceReserveForRescue();
        riskEngine = new MockRiskEngineForRescue();
        remoteIntentCoordinator = new MockRemoteIntentCoordinatorForRescue();
        stable = new MockERC20("USD Coin", "USDC", 6);

        rescueController = new RescueController(
            owner,
            address(positionRegistry),
            address(parameterRegistry),
            address(debtLedger),
            address(collateralManager),
            address(stabilizationPool),
            address(insuranceReserve),
            address(riskEngine),
            address(remoteIntentCoordinator),
            address(stable)
        );

        rescueController.setAuthorizedSettlementHandler(address(this), true);

        positionRegistry.setAuthorizedWriter(address(rescueController), true);
        debtLedger.setAuthorizedWriter(address(rescueController), true);
        collateralManager.setAuthorizedWriter(address(rescueController), true);
        rescueController.setAuthorizedExecutor(executor, true);

        positionRegistry.createPosition(address(0x1234), BTC, 100e6, 0, false);
        debtLedger.initializeDebtRecord(1, 0);
        collateralManager.initializeCollateralRecord(1, 100e6);
        collateralManager.lockCollateral(1, 100e6);

        parameterRegistry.setRiskParams(
            BTC,
            ParameterRegistry.RiskParams({
                maxBorrowLTVBps: 7000,
                rescueTriggerLTVBps: 8000,
                liquidationLTVBps: 9000,
                targetPostRescueLTVBps: 6000,
                collateralHaircutBps: 0,
                liquidationBufferBps: 500,
                maxRescueAttempts: 3,
                rescueCooldown: 0,
                buybackClaimDuration: 1 days
            })
        );

        riskEngine.setSnapshot(1, 0, 100e6, 80e6, 8000, 2);
        stabilizationPool.setAvailable(BTC, 100e6);
    }

    function test_calculateRescueSize_returnsExpectedValue() external view {
        uint256 rescueAmount = rescueController.calculateRescueSize(1);
        assertEq(rescueAmount, 20e6);
    }

    function test_applyRescueFee_returnsExpectedValue() external view {
        uint256 fee = rescueController.applyRescueFee(1, 20e6);
        assertEq(fee, 200_000);
    }

    function test_executeRescue_marksTerminalWhenMaxAttemptsReached() external {
        parameterRegistry.setRiskParams(
            BTC,
            ParameterRegistry.RiskParams({
                maxBorrowLTVBps: 7000,
                rescueTriggerLTVBps: 8000,
                liquidationLTVBps: 9000,
                targetPostRescueLTVBps: 6000,
                collateralHaircutBps: 0,
                liquidationBufferBps: 500,
                maxRescueAttempts: 0,
                rescueCooldown: 0,
                buybackClaimDuration: 1 days
            })
        );

        vm.prank(executor);
        rescueController.executeRescue(1);

        (,,, bool terminalFlag) = rescueController.rescueByPosition(1);
        PositionRegistry.Position memory p = positionRegistry.getPosition(1);

        assertEq(terminalFlag, true);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Terminal));
    }

    function test_executeRescue_opensRemoteIntentWhenPoolInsufficient() external {
        stabilizationPool.setAvailable(BTC, 10e6);

        vm.prank(executor);
        rescueController.executeRescue(1);

        assertEq(remoteIntentCoordinator.callCount(), 1);
        assertEq(remoteIntentCoordinator.lastPositionId(), 1);
        assertEq(remoteIntentCoordinator.lastAmountNeeded(), 20e6);
        assertEq(remoteIntentCoordinator.lastBeneficiary(), address(stabilizationPool));
        assertEq(remoteIntentCoordinator.lastSettlementAsset(), address(stable));

        (,,, bool terminalFlag) = rescueController.rescueByPosition(1);
        assertEq(terminalFlag, false);

        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Healthy));
    }

    function test_executeRescue_updatesPoolDebtAndState() external {
        vm.prank(executor);
        rescueController.executeRescue(1);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(1);
        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        (uint256 totalRescued, uint256 lastRescueAmount, uint256 rescueFees, bool terminalFlag) =
            rescueController.rescueByPosition(1);

        assertEq(stabilizationPool.lastAssetId(), BTC);
        assertEq(stabilizationPool.lastDeployAmount(), 20e6);
        assertEq(d.rescueCapitalUsed, 20e6);
        assertEq(d.rescueFeesAccrued, 200_000);
        assertEq(p.rescueCount, 1);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Rescued));
        assertEq(totalRescued, 20e6);
        assertEq(lastRescueAmount, 20e6);
        assertEq(rescueFees, 200_000);
        assertEq(terminalFlag, false);
        assertEq(rescueController.localRescuedByPosition(1), 20e6);
        assertEq(rescueController.remoteRescuedByPosition(1), 0);
    }

    function test_consumeRemoteRescueSettlement_updatesAccountingAndProvenance() external {
        rescueController.consumeRemoteRescueSettlement(1, 10e6, false);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(1);
        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        (uint256 totalRescued, uint256 lastRescueAmount, uint256 rescueFees, bool terminalFlag) =
            rescueController.rescueByPosition(1);

        assertEq(d.rescueCapitalUsed, 10e6);
        assertEq(d.rescueFeesAccrued, 100_000);
        assertEq(totalRescued, 10e6);
        assertEq(lastRescueAmount, 10e6);
        assertEq(rescueFees, 100_000);
        assertEq(terminalFlag, false);
        assertEq(rescueController.localRescuedByPosition(1), 0);
        assertEq(rescueController.remoteRescuedByPosition(1), 10e6);
        assertEq(p.rescueCount, 0);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Healthy));
    }

    function test_consumeRemoteRescueSettlement_finalMarksRescued() external {
        rescueController.consumeRemoteRescueSettlement(1, 20e6, true);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(1);
        PositionRegistry.Position memory p = positionRegistry.getPosition(1);

        assertEq(d.rescueCapitalUsed, 20e6);
        assertEq(d.rescueFeesAccrued, 200_000);
        assertEq(rescueController.remoteRescuedByPosition(1), 20e6);
        assertEq(p.rescueCount, 1);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Rescued));
    }

    function test_markTerminal_updatesState() external {
        vm.prank(executor);
        rescueController.markTerminal(1);

        (,,, bool terminalFlag) = rescueController.rescueByPosition(1);
        PositionRegistry.Position memory p = positionRegistry.getPosition(1);

        assertEq(terminalFlag, true);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Terminal));
    }

    function test_routeTerminalSettlement_recordsInsuranceAndMovesCollateral() external {
        riskEngine.setSnapshot(1, 0, 60e6, 80e6, 13_333, 3);

        vm.prank(executor);
        rescueController.routeTerminalSettlement(1);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(1);
        CollateralManager.CollateralRecord memory c = collateralManager.getCollateralRecord(1);

        assertEq(insuranceReserve.lastPositionId(), 1);
        assertEq(insuranceReserve.lastAmount(), 20e6);
        assertEq(d.insuranceCapitalUsed, 20e6);
        assertEq(c.transferredToInsurance, 100e6);
        assertEq(c.lockedCollateral, 0);
    }

    function test_rail2_terminalSettlementRevertsWhenNativeAdapterMissing() external {
        uint256 positionId = positionRegistry.createPositionWithRail(
            address(0x5678), BTC, 100e6, 0, false, CollateralRail.ENFORCEABLE_NATIVE
        );

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(RescueController.NativeRailSettlementAdapterMissing.selector, positionId)
        );
        rescueController.routeTerminalSettlement(positionId);
    }
}
