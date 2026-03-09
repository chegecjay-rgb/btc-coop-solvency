// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {ExpectedLossEngine} from "src/risk/ExpectedLossEngine.sol";

contract ExpectedLossEngineTest is Test {
    PositionRegistry internal positionRegistry;
    DebtLedger internal debtLedger;
    ExpectedLossEngine internal engine;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonOwner = address(0xBEEF);
    address internal user = address(0x1234);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        positionRegistry = new PositionRegistry(owner);
        debtLedger = new DebtLedger(owner);

        engine = new ExpectedLossEngine(
            owner,
            address(positionRegistry),
            address(debtLedger)
        );

        positionRegistry.setAuthorizedWriter(address(this), true);
        debtLedger.setAuthorizedWriter(address(this), true);

        uint256 positionId = positionRegistry.createPosition(user, BTC, 10 ether, 5 ether, false);
        require(positionId == 1, "unexpected position id");

        debtLedger.initializeDebtRecord(1, 5 ether);

        engine.setVolatilityBps(BTC, 3000);
        engine.setLiquidityStressBps(BTC, 5000);
        engine.setRecoveryRateBps(BTC, 6000);
    }

    function test_setVolatilityBps_updatesValue() external {
        engine.setVolatilityBps(BTC, 3500);
        assertEq(engine.volatilityBpsByAsset(BTC), 3500);
    }

    function test_setLiquidityStressBps_updatesValue() external {
        engine.setLiquidityStressBps(BTC, 5500);
        assertEq(engine.liquidityStressBpsByAsset(BTC), 5500);
    }

    function test_setRecoveryRateBps_updatesValue() external {
        engine.setRecoveryRateBps(BTC, 6500);
        assertEq(engine.recoveryRateBpsByAsset(BTC), 6500);
    }

    function test_setters_revertIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        engine.setVolatilityBps(BTC, 3000);

        vm.prank(nonOwner);
        vm.expectRevert();
        engine.setLiquidityStressBps(BTC, 3000);

        vm.prank(nonOwner);
        vm.expectRevert();
        engine.setRecoveryRateBps(BTC, 3000);
    }

    function test_setters_revertOnInvalidAssetId() external {
        vm.expectRevert(ExpectedLossEngine.InvalidAssetId.selector);
        engine.setVolatilityBps(bytes32(0), 3000);

        vm.expectRevert(ExpectedLossEngine.InvalidAssetId.selector);
        engine.setLiquidityStressBps(bytes32(0), 3000);

        vm.expectRevert(ExpectedLossEngine.InvalidAssetId.selector);
        engine.setRecoveryRateBps(bytes32(0), 3000);
    }

    function test_setters_revertOnInvalidBps() external {
        vm.expectRevert(
            abi.encodeWithSelector(ExpectedLossEngine.InvalidBpsValue.selector, 10_001)
        );
        engine.setVolatilityBps(BTC, 10_001);

        vm.expectRevert(
            abi.encodeWithSelector(ExpectedLossEngine.InvalidBpsValue.selector, 10_001)
        );
        engine.setLiquidityStressBps(BTC, 10_001);

        vm.expectRevert(
            abi.encodeWithSelector(ExpectedLossEngine.InvalidBpsValue.selector, 10_001)
        );
        engine.setRecoveryRateBps(BTC, 10_001);
    }

    function test_rescueProbability_returnsAverageOfVolatilityAndStress() external view {
        assertEq(engine.rescueProbability(1), 4000);
    }

    function test_expectedLoss_usesDebtProbabilityAndRecovery() external {
        // debt = 5 ether
        // rescue probability = 4000 bps
        // recovery = 6000 bps => LGF = 4000 bps
        // expected loss = 5 * 0.4 * 0.4 = 0.8 ether
        assertEq(engine.expectedLoss(1), 0.8 ether);
    }

    function test_expectedTerminalLoss_usesLiquidityStressAndRecovery() external {
        // debt = 5 ether
        // liquidity stress = 5000 bps
        // recovery = 6000 bps => LGF = 4000 bps
        // ETL = 5 * 0.5 * 0.4 = 1 ether
        assertEq(engine.expectedTerminalLoss(1), 1 ether);
    }

    function test_expectedLoss_includesAllDebtComponents() external {
        debtLedger.accrueInterest(1, 1 ether);
        debtLedger.recordRescueUsage(1, 2 ether, 0.5 ether);
        debtLedger.recordInsuranceUsage(1, 1 ether, 0.25 ether);
        debtLedger.recordSettlementCost(1, 0.25 ether);

        // total debt = 5 + 1 + 2 + 0.5 + 1 + 0.25 + 0.25 = 10 ether
        // rescue prob = 0.4, LGF = 0.4 => 1.6 ether
        assertEq(engine.expectedLoss(1), 1.6 ether);
    }

    function test_expectedTerminalLoss_includesAllDebtComponents() external {
        debtLedger.accrueInterest(1, 1 ether);
        debtLedger.recordRescueUsage(1, 2 ether, 0.5 ether);
        debtLedger.recordInsuranceUsage(1, 1 ether, 0.25 ether);
        debtLedger.recordSettlementCost(1, 0.25 ether);

        // total debt = 10 ether
        // stress = 0.5, LGF = 0.4 => 2 ether
        assertEq(engine.expectedTerminalLoss(1), 2 ether);
    }

    function test_rescueSensitivity_addsShockAndCapsAt10000() external {
        // vol 3000 + shock 9000 = 12000
        // avg with liq 5000 = 8500
        assertEq(engine.rescueSensitivity(BTC, 9000), 8500);

        engine.setVolatilityBps(BTC, 9000);
        engine.setLiquidityStressBps(BTC, 9000);

        // shocked vol = 19000, avg with 9000 = 14000, cap => 10000
        assertEq(engine.rescueSensitivity(BTC, 10_000), 10_000);
    }

    function test_rescueSensitivity_revertsOnZeroAssetId() external {
        vm.expectRevert(ExpectedLossEngine.InvalidAssetId.selector);
        engine.rescueSensitivity(bytes32(0), 1000);
    }
}
