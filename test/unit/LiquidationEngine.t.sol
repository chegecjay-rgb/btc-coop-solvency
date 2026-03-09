// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {RecapitalizationEngine} from "src/core/RecapitalizationEngine.sol";
import {LiquidationEngine} from "src/core/LiquidationEngine.sol";
import {OracleGuard} from "src/oracles/OracleGuard.sol";
import {ExpectedLossEngine} from "src/risk/ExpectedLossEngine.sol";
import {HealthFactorCalculator} from "src/risk/HealthFactorCalculator.sol";
import {RiskEngine} from "src/risk/RiskEngine.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";
import {StabilizationPool} from "src/vaults/StabilizationPool.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
import {TreasuryVault} from "src/vaults/TreasuryVault.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LiquidationEngineTest is Test {
    ParameterRegistry internal parameterRegistry;
    PositionRegistry internal positionRegistry;
    CollateralManager internal collateralManager;
    DebtLedger internal debtLedger;
    OracleGuard internal oracleGuard;
    ExpectedLossEngine internal expectedLossEngine;
    HealthFactorCalculator internal healthFactorCalculator;
    LendingLiquidityVault internal lendingVault;
    StabilizationPool internal stabilizationPool;
    InsuranceReserve internal insuranceReserve;
    TreasuryVault internal treasuryVault;
    RiskEngine internal riskEngine;
    RecapitalizationEngine internal recapitalizationEngine;
    LiquidationEngine internal liquidationEngine;

    MockOracle internal oracle;
    MockERC20 internal stable;
    MockERC20 internal btc;

    address internal owner = address(this);
    address internal liquidator = address(0xCAFE);
    address internal lender = address(0x1111);
    address internal stabilizer = address(0x2222);
    address internal insurer = address(0x3333);
    address internal user = address(0x4444);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        parameterRegistry = new ParameterRegistry(owner);
        positionRegistry = new PositionRegistry(owner);
        collateralManager = new CollateralManager(owner);
        debtLedger = new DebtLedger(owner);
        oracleGuard = new OracleGuard(owner, 500, 1 hours);

        expectedLossEngine = new ExpectedLossEngine(
            owner,
            address(positionRegistry),
            address(debtLedger)
        );

        healthFactorCalculator = new HealthFactorCalculator(
            address(parameterRegistry),
            address(oracleGuard),
            address(expectedLossEngine),
            address(positionRegistry),
            address(debtLedger)
        );

        stable = new MockERC20("USD Coin", "USDC", 18);
        btc = new MockERC20("Wrapped BTC", "WBTC", 18);

        lendingVault = new LendingLiquidityVault(owner, address(stable), BTC);
        stabilizationPool = new StabilizationPool(owner, address(stable), address(btc));
        insuranceReserve = new InsuranceReserve(owner, address(stable));
        treasuryVault = new TreasuryVault(owner, address(stable), address(btc));

        riskEngine = new RiskEngine(
            owner,
            address(parameterRegistry),
            address(healthFactorCalculator),
            address(lendingVault),
            address(stabilizationPool),
            address(expectedLossEngine),
            address(positionRegistry),
            address(debtLedger)
        );

        recapitalizationEngine = new RecapitalizationEngine(
            owner,
            address(stabilizationPool),
            address(insuranceReserve),
            address(treasuryVault),
            address(positionRegistry),
            address(stable)
        );

        liquidationEngine = new LiquidationEngine(
            owner,
            address(positionRegistry),
            address(collateralManager),
            address(debtLedger),
            address(riskEngine),
            address(recapitalizationEngine),
            500,
            3 days
        );

        liquidationEngine.setAuthorizedLiquidator(liquidator, true);

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
        positionRegistry.setAuthorizedWriter(address(liquidationEngine), true);
        debtLedger.setAuthorizedWriter(address(this), true);
        debtLedger.setAuthorizedWriter(address(liquidationEngine), true);
        collateralManager.setAuthorizedWriter(address(this), true);
        collateralManager.setAuthorizedWriter(address(liquidationEngine), true);
        lendingVault.setAuthorizedWriter(address(this), true);
        stabilizationPool.setAuthorizedWriter(address(recapitalizationEngine), true);
        stabilizationPool.setAuthorizedWriter(address(liquidationEngine), true);
        stabilizationPool.setSupportedAsset(BTC, true);
        insuranceReserve.setAuthorizedWriter(address(recapitalizationEngine), true);
        recapitalizationEngine.setAuthorizedWriter(address(liquidationEngine), true);

        stable.mint(lender, 1_000_000 ether);
        stable.mint(stabilizer, 1_000_000 ether);
        stable.mint(insurer, 1_000_000 ether);
        stable.mint(address(recapitalizationEngine), 1_000_000 ether);

        vm.startPrank(lender);
        stable.approve(address(lendingVault), type(uint256).max);
        lendingVault.depositLiquidity(500_000 ether, lender);
        vm.stopPrank();

        vm.startPrank(stabilizer);
        stable.approve(address(stabilizationPool), type(uint256).max);
        stabilizationPool.depositStable(BTC, 100_000 ether);
        vm.stopPrank();

        vm.startPrank(insurer);
        stable.approve(address(insuranceReserve), type(uint256).max);
        insuranceReserve.depositReserve(100_000 ether);
        vm.stopPrank();

        // Position 1: deep distress, should be liquidatable by risk classification
        positionRegistry.createPosition(user, BTC, 1 ether, 100_000 ether, false); // id 1
        debtLedger.initializeDebtRecord(1, 100_000 ether);
        collateralManager.initializeCollateralRecord(1, 1 ether);
        collateralManager.lockCollateral(1, 1 ether);
    }

    function test_isLiquidatable_returnsTrueForDistressedPosition() external view {
        assertEq(liquidationEngine.isLiquidatable(1), true);
    }

    function test_executeLiquidation_movesCollateralAndRecordsRecovery() external {
        vm.prank(liquidator);
        liquidationEngine.executeLiquidation(1);

        CollateralManager.CollateralRecord memory c = collateralManager.getCollateralRecord(1);
        assertEq(c.lockedCollateral, 0);
        assertEq(c.transferredToStabilization, 1 ether);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(1);
        assertEq(d.settlementCosts, 5_000 ether); // 5% of 100,000

        assertEq(liquidationEngine.liquidatedPosition(1), true);
        assertEq(liquidationEngine.liquidationRecoveryByPosition(1), 100_000 ether);

        assertEq(recapitalizationEngine.recoveryByPosition(1), 100_000 ether);

        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        assertEq(uint256(p.state), 7);
    }

    function test_executeLiquidation_revertsIfNotLiquidatable() external {
        positionRegistry.createPosition(user, BTC, 5 ether, 10_000 ether, false); // id 2
        debtLedger.initializeDebtRecord(2, 10_000 ether);
        collateralManager.initializeCollateralRecord(2, 5 ether);
        collateralManager.lockCollateral(2, 5 ether);

        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationEngine.PositionNotLiquidatable.selector, 2)
        );
        liquidationEngine.executeLiquidation(2);
    }

    function test_settlePostLiquidation_closesPosition() external {
        vm.prank(liquidator);
        liquidationEngine.executeLiquidation(1);

        vm.prank(liquidator);
        liquidationEngine.settlePostLiquidation(1);

        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        assertEq(p.collateralAmount, 0);
        assertEq(p.debtPrincipal, 0);
        assertEq(uint256(p.state), 8);

        assertEq(liquidationEngine.liquidatedPosition(1), true);
    }
}
