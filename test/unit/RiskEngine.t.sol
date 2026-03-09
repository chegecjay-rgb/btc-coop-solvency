// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {OracleGuard} from "src/oracles/OracleGuard.sol";
import {ExpectedLossEngine} from "src/risk/ExpectedLossEngine.sol";
import {HealthFactorCalculator} from "src/risk/HealthFactorCalculator.sol";
import {RiskEngine} from "src/risk/RiskEngine.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";
import {StabilizationPool} from "src/vaults/StabilizationPool.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract RiskEngineTest is Test {
    ParameterRegistry internal parameterRegistry;
    PositionRegistry internal positionRegistry;
    DebtLedger internal debtLedger;
    OracleGuard internal oracleGuard;
    ExpectedLossEngine internal expectedLossEngine;
    HealthFactorCalculator internal calculator;
    LendingLiquidityVault internal lendingVault;
    StabilizationPool internal stabilizationPool;
    RiskEngine internal riskEngine;

    MockOracle internal oracle;
    MockERC20 internal stable;
    MockERC20 internal btc;

    address internal owner = address(this);
    address internal lender = address(0x1111);
    address internal stabilizer = address(0x2222);
    address internal user = address(0x3333);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        parameterRegistry = new ParameterRegistry(owner);
        positionRegistry = new PositionRegistry(owner);
        debtLedger = new DebtLedger(owner);
        oracleGuard = new OracleGuard(owner, 500, 1 hours);

        expectedLossEngine = new ExpectedLossEngine(
            owner,
            address(positionRegistry),
            address(debtLedger)
        );

        calculator = new HealthFactorCalculator(
            address(parameterRegistry),
            address(oracleGuard),
            address(expectedLossEngine),
            address(positionRegistry),
            address(debtLedger)
        );

        stable = new MockERC20("USD Coin", "USDC", 6);
        btc = new MockERC20("Wrapped BTC", "WBTC", 8);

        lendingVault = new LendingLiquidityVault(owner, address(stable), BTC);
        stabilizationPool = new StabilizationPool(owner, address(stable), address(btc));

        riskEngine = new RiskEngine(
            owner,
            address(parameterRegistry),
            address(calculator),
            address(lendingVault),
            address(stabilizationPool),
            address(expectedLossEngine),
            address(positionRegistry),
            address(debtLedger)
        );

        oracle = new MockOracle(18, 100_000 ether, block.timestamp);
        oracleGuard.setOracleConfig(BTC, address(oracle), address(0));

        parameterRegistry.setRiskParams(
            BTC,
            ParameterRegistry.RiskParams({
                maxBorrowLTVBps: 7000,
                rescueTriggerLTVBps: 8000,
                liquidationLTVBps: 8500,
                targetPostRescueLTVBps: 6500,
                collateralHaircutBps: 1000,
                liquidationBufferBps: 300,
                maxRescueAttempts: 3,
                rescueCooldown: 1 hours,
                buybackClaimDuration: 7 days
            })
        );

        parameterRegistry.setRemoteLiquidityParams(
            BTC,
            ParameterRegistry.RemoteLiquidityParams({
                minLocalLiquidityBps: 2000,
                highUtilizationBps: 8500,
                maxPendingRescueLoadBps: 4000,
                remoteIntentFeeCapBps: 100,
                remoteIntentDeadline: 15 minutes
            })
        );

        expectedLossEngine.setVolatilityBps(BTC, 3000);
        expectedLossEngine.setLiquidityStressBps(BTC, 5000);
        expectedLossEngine.setRecoveryRateBps(BTC, 6000);

        positionRegistry.setAuthorizedWriter(address(this), true);
        debtLedger.setAuthorizedWriter(address(this), true);
        lendingVault.setAuthorizedWriter(address(this), true);
        stabilizationPool.setAuthorizedWriter(address(this), true);
        stabilizationPool.setSupportedAsset(BTC, true);

        stable.mint(lender, 1_000_000e6);
        stable.mint(stabilizer, 1_000_000e6);
        btc.mint(stabilizer, 1_000_000_000);

        vm.startPrank(lender);
        stable.approve(address(lendingVault), type(uint256).max);
        lendingVault.depositLiquidity(100_000e6, lender);
        vm.stopPrank();

        vm.startPrank(stabilizer);
        stable.approve(address(stabilizationPool), type(uint256).max);
        stabilizationPool.depositStable(BTC, 200_000e6);
        vm.stopPrank();

        uint256 positionId = positionRegistry.createPosition(user, BTC, 1 ether, 70_000 ether, false);
        require(positionId == 1, "unexpected position id");
        debtLedger.initializeDebtRecord(1, 70_000 ether);
    }

    function test_availableLocalLiquidity_readsVault() external view {
        assertEq(riskEngine.availableLocalLiquidity(BTC), 100_000e6);
    }

    function test_rescueLoadRatio_zeroInitially() external view {
        assertEq(riskEngine.rescueLoadRatio(BTC), 0);
    }

    function test_rescueLoadRatio_updatesAfterDeployment() external {
        stabilizationPool.deployRescueCapital(BTC, 50_000e6);
        // active 50k / (remaining 150k + active 50k) = 25%
        assertEq(riskEngine.rescueLoadRatio(BTC), 2500);
    }

    function test_evaluateMarketStress_normal() external returns (RiskEngine.LiquidityStressState) {
        RiskEngine.LiquidityStressState state = riskEngine.evaluateMarketStress(BTC);
        assertEq(uint256(state), uint256(RiskEngine.LiquidityStressState.Normal));
        return state;
    }

    function test_evaluateMarketStress_stressedFromHighUtilization() external {
        lendingVault.allocateToBorrower(user, 90_000e6); // 90% util
        RiskEngine.LiquidityStressState state = riskEngine.evaluateMarketStress(BTC);
        assertEq(uint256(state), uint256(RiskEngine.LiquidityStressState.Stressed));
    }

    function test_evaluateMarketStress_criticalFromVeryHighUtilization() external {
        lendingVault.allocateToBorrower(user, 96_000e6); // 96% util
        RiskEngine.LiquidityStressState state = riskEngine.evaluateMarketStress(BTC);
        assertEq(uint256(state), uint256(RiskEngine.LiquidityStressState.Critical));
    }

    function test_refreshDynamicBorrowCap_reducesCapUnderStress() external {
        lendingVault.allocateToBorrower(user, 90_000e6); // stressed
        uint256 cap = riskEngine.refreshDynamicBorrowCap(BTC);
        assertEq(cap, 6000);
    }

    function test_positionRiskSnapshot_returnsExpectedFields() external view {
        RiskEngine.PositionRiskSnapshot memory snap = riskEngine.positionRiskSnapshot(1);
        assertEq(snap.adjustedCollateral, 90_000 ether);
        assertEq(snap.totalDebt, 70_000 ether);
        assertEq(snap.currentLTVBps, 7777);
        assertEq(snap.classification, 1); // AtRisk
    }

    function test_shouldOpenRemoteIntent_trueWhenAmountExceedsLocalLiquidity() external returns (bool) {
        bool shouldOpen = riskEngine.shouldOpenRemoteIntent(BTC, 200_000e6, 0);
        assertEq(shouldOpen, true);
        return shouldOpen;
    }

    function test_shouldOpenRemoteIntent_trueWhenRescueLoadHigh() external returns (bool) {
        stabilizationPool.deployRescueCapital(BTC, 120_000e6); // 60% rescue load
        bool shouldOpen = riskEngine.shouldOpenRemoteIntent(BTC, 1e6, 1);
        assertEq(shouldOpen, true);
        return shouldOpen;
    }

    function test_rescueCapitalRequired_usesSensitivityAndRescueLiquidity() external view {
        // sensitivity = average(3000+1000, 5000) = 4500
        // rescue liquidity = 200,000e6
        // required = 90,000e6
        assertEq(riskEngine.rescueCapitalRequired(BTC, 1000), 90_000e6);
    }

    function test_liquidationExposure_usesLocalLiquidityAndStress() external view {
        // liquidityStress 5000 + shock 1000 = 6000
        // local 100,000e6 -> 60,000e6
        assertEq(riskEngine.liquidationExposure(BTC, 1000), 60_000e6);
    }

    function test_solvencyRatio_usesLocalPlusRescueOverRequired() external view {
        // local 100k + rescue 200k = 300k
        // required 90k
        // ratio = 3.333... * 1e18
        assertEq(riskEngine.solvencyRatio(BTC, 1000), 3_333_333_333_333_333_333);
    }
}
