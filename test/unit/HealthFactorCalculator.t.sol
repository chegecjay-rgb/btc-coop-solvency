// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {OracleGuard} from "src/oracles/OracleGuard.sol";
import {ExpectedLossEngine} from "src/risk/ExpectedLossEngine.sol";
import {HealthFactorCalculator} from "src/risk/HealthFactorCalculator.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";

contract HealthFactorCalculatorTest is Test {
    ParameterRegistry internal parameterRegistry;
    PositionRegistry internal positionRegistry;
    DebtLedger internal debtLedger;
    OracleGuard internal oracleGuard;
    ExpectedLossEngine internal expectedLossEngine;
    HealthFactorCalculator internal calculator;
    MockOracle internal oracle;

    address internal owner = address(this);
    address internal user = address(0x1234);

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

        positionRegistry.setAuthorizedWriter(address(this), true);
        debtLedger.setAuthorizedWriter(address(this), true);

        uint256 positionId = positionRegistry.createPosition(
            user,
            BTC,
            1 ether,
            70_000 ether,
            false
        );
        require(positionId == 1, "unexpected position id");

        debtLedger.initializeDebtRecord(1, 70_000 ether);

        expectedLossEngine.setVolatilityBps(BTC, 3000);
        expectedLossEngine.setLiquidityStressBps(BTC, 5000);
        expectedLossEngine.setRecoveryRateBps(BTC, 6000);
    }

    function test_riskAdjustedCollateral_appliesOraclePriceAndHaircut() external view {
        assertEq(calculator.riskAdjustedCollateral(1), 90_000 ether);
    }

    function test_expectedRescueCapital_readsExpectedLossEngine() external view {
        assertEq(calculator.expectedRescueCapital(1), 11_200 ether);
    }

    function test_expectedRescueFee_usesRescueProbability() external view {
        assertEq(calculator.expectedRescueFee(1), 4_480 ether);
    }

    function test_liquidationExecutionBuffer_usesDebtAndBufferBps() external view {
        assertEq(calculator.liquidationExecutionBuffer(1), 2_100 ether);
    }

    function test_healthFactor_returnsExpectedValue() external view {
        assertEq(calculator.healthFactor(1), 1_031_714_285_714_285_714);
    }

    function test_classify_returnsAtRisk() external view {
        assertEq(
            uint256(calculator.classify(1)),
            uint256(HealthFactorCalculator.HealthClassification.AtRisk)
        );
    }

    function test_classify_returnsHealthy() external {
        uint256 positionId = positionRegistry.createPosition(
            user,
            BTC,
            1 ether,
            60_000 ether,
            false
        );
        debtLedger.initializeDebtRecord(positionId, 60_000 ether);

        assertEq(
            uint256(calculator.classify(positionId)),
            uint256(HealthFactorCalculator.HealthClassification.Healthy)
        );
    }

    function test_classify_returnsRescueEligible() external {
        uint256 positionId = positionRegistry.createPosition(
            user,
            BTC,
            1 ether,
            75_000 ether,
            false
        );
        debtLedger.initializeDebtRecord(positionId, 75_000 ether);

        assertEq(
            uint256(calculator.classify(positionId)),
            uint256(HealthFactorCalculator.HealthClassification.RescueEligible)
        );
    }

    function test_classify_returnsLiquidatable() external {
        uint256 positionId = positionRegistry.createPosition(
            user,
            BTC,
            1 ether,
            80_000 ether,
            false
        );
        debtLedger.initializeDebtRecord(positionId, 80_000 ether);
        debtLedger.increaseDebt(positionId, 10_000 ether);

        assertEq(
            uint256(calculator.classify(positionId)),
            uint256(HealthFactorCalculator.HealthClassification.Liquidatable)
        );
    }

    function test_healthFactor_returnsMaxWhenDebtIsZero() external {
        uint256 positionId = positionRegistry.createPosition(
            user,
            BTC,
            1 ether,
            0,
            false
        );
        debtLedger.initializeDebtRecord(positionId, 0);

        assertEq(calculator.healthFactor(positionId), type(uint256).max);
    }

    function test_healthFactor_returnsZeroWhenAdjustmentsConsumeCollateral() external {
        uint256 positionId = positionRegistry.createPosition(
            user,
            BTC,
            1 ether,
            89_000 ether,
            false
        );
        debtLedger.initializeDebtRecord(positionId, 89_000 ether);

        expectedLossEngine.setVolatilityBps(BTC, 9000);
        expectedLossEngine.setLiquidityStressBps(BTC, 9000);
        expectedLossEngine.setRecoveryRateBps(BTC, 0);

        assertEq(calculator.healthFactor(positionId), 0);
    }
}
