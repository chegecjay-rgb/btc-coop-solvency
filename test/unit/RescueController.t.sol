// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {RescueController} from "src/core/RescueController.sol";
import {OracleGuard} from "src/oracles/OracleGuard.sol";
import {ExpectedLossEngine} from "src/risk/ExpectedLossEngine.sol";
import {HealthFactorCalculator} from "src/risk/HealthFactorCalculator.sol";
import {RiskEngine} from "src/risk/RiskEngine.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";
import {StabilizationPool} from "src/vaults/StabilizationPool.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract RescueControllerTest is Test {
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
    RiskEngine internal riskEngine;
    RescueController internal rescueController;

    MockOracle internal oracle;
    MockERC20 internal stable;
    MockERC20 internal btc;

    address internal owner = address(this);
    address internal executor = address(0xCAFE);
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

        rescueController = new RescueController(
            owner,
            address(positionRegistry),
            address(parameterRegistry),
            address(debtLedger),
            address(collateralManager),
            address(stabilizationPool),
            address(insuranceReserve),
            address(riskEngine)
        );

        rescueController.setAuthorizedExecutor(executor, true);

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
        positionRegistry.setAuthorizedWriter(address(rescueController), true);
        debtLedger.setAuthorizedWriter(address(this), true);
        debtLedger.setAuthorizedWriter(address(rescueController), true);
        collateralManager.setAuthorizedWriter(address(this), true);
        collateralManager.setAuthorizedWriter(address(rescueController), true);
        lendingVault.setAuthorizedWriter(address(this), true);
        stabilizationPool.setAuthorizedWriter(address(rescueController), true);
        stabilizationPool.setSupportedAsset(BTC, true);
        insuranceReserve.setAuthorizedWriter(address(rescueController), true);

        stable.mint(lender, 1_000_000 ether);
        stable.mint(stabilizer, 1_000_000 ether);
        stable.mint(insurer, 1_000_000 ether);

        vm.startPrank(lender);
        stable.approve(address(lendingVault), type(uint256).max);
        lendingVault.depositLiquidity(500_000 ether, lender);
        vm.stopPrank();

        vm.startPrank(stabilizer);
        stable.approve(address(stabilizationPool), type(uint256).max);
        stabilizationPool.depositStable(BTC, 200_000 ether);
        vm.stopPrank();

        vm.startPrank(insurer);
        stable.approve(address(insuranceReserve), type(uint256).max);
        insuranceReserve.depositReserve(300_000 ether);
        vm.stopPrank();

        positionRegistry.createPosition(user, BTC, 1 ether, 80_000 ether, false); // id 1
        debtLedger.initializeDebtRecord(1, 80_000 ether);
        collateralManager.initializeCollateralRecord(1, 1 ether);
        collateralManager.lockCollateral(1, 1 ether);

        positionRegistry.createPosition(user, BTC, 1 ether, 100_000 ether, false); // id 2
        debtLedger.initializeDebtRecord(2, 100_000 ether);
        collateralManager.initializeCollateralRecord(2, 1 ether);
        collateralManager.lockCollateral(2, 1 ether);
    }

    function test_calculateRescueSize_returnsExpectedValue() external view {
        assertEq(rescueController.calculateRescueSize(1), 21_500 ether);
    }

    function test_applyRescueFee_returnsExpectedValue() external view {
        assertEq(rescueController.applyRescueFee(1, 21_500 ether), 215 ether);
    }

    function test_executeRescue_updatesPoolDebtAndState() external {
        vm.prank(executor);
        rescueController.executeRescue(1);

        (
            uint256 stableLiquidity,
            ,
            uint256 activeRescueExposure,

        ) = stabilizationPool.pools(BTC);

        assertEq(stableLiquidity, 178_500 ether);
        assertEq(activeRescueExposure, 21_500 ether);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(1);
        assertEq(d.rescueCapitalUsed, 21_500 ether);
        assertEq(d.rescueFeesAccrued, 215 ether);

        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        assertEq(p.rescueCount, 1);
        assertEq(uint256(p.state), 4);

        (
            uint256 totalRescued,
            uint256 lastRescueAmount,
            uint256 rescueFees,
            bool terminalFlag
        ) = rescueController.rescueByPosition(1);

        assertEq(totalRescued, 21_500 ether);
        assertEq(lastRescueAmount, 21_500 ether);
        assertEq(rescueFees, 215 ether);
        assertEq(terminalFlag, false);
    }

    function test_executeRescue_marksTerminalWhenMaxAttemptsReached() external {
        positionRegistry.incrementRescueCount(1);
        positionRegistry.incrementRescueCount(1);
        positionRegistry.incrementRescueCount(1);

        vm.prank(executor);
        rescueController.executeRescue(1);

        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        assertEq(uint256(p.state), 6);

        (, , , bool terminalFlag) = rescueController.rescueByPosition(1);
        assertEq(terminalFlag, true);
    }

    function test_executeRescue_marksTerminalWhenPoolInsufficient() external {
        stabilizationPool.setAuthorizedWriter(address(this), true);
        stabilizationPool.deployRescueCapital(BTC, 190_000 ether);

        vm.prank(executor);
        rescueController.executeRescue(2);

        PositionRegistry.Position memory p = positionRegistry.getPosition(2);
        assertEq(uint256(p.state), 6);
    }

    function test_markTerminal_updatesState() external {
        vm.prank(executor);
        rescueController.markTerminal(1);

        PositionRegistry.Position memory p = positionRegistry.getPosition(1);
        assertEq(uint256(p.state), 6);

        (, , , bool terminalFlag) = rescueController.rescueByPosition(1);
        assertEq(terminalFlag, true);
    }

    function test_routeTerminalSettlement_recordsInsuranceAndMovesCollateral() external {
        vm.prank(executor);
        rescueController.markTerminal(2);

        vm.prank(executor);
        rescueController.routeTerminalSettlement(2);

        (
            ,
            uint256 systemDeficitCovered,
            ,
            bool active
        ) = insuranceReserve.exposureByPosition(2);

        assertEq(systemDeficitCovered, 10_000 ether);
        assertEq(active, true);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(2);
        assertEq(d.insuranceCapitalUsed, 10_000 ether);

        CollateralManager.CollateralRecord memory c = collateralManager.getCollateralRecord(2);
        assertEq(c.lockedCollateral, 0);
        assertEq(c.transferredToInsurance, 1 ether);
    }
}
