// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParameterRegistry} from "src/core/ParameterRegistry.sol";

contract ParameterRegistryTest is Test {
    ParameterRegistry internal registry;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);

    bytes32 internal constant BTC = keccak256("BTC");
    bytes32 internal constant GLOBAL_KEY = keccak256("MAX_MARKETS");

    function setUp() external {
        registry = new ParameterRegistry(owner);
    }

    function test_setRiskParams_storesValues() external {
        ParameterRegistry.RiskParams memory params = _validParams();

        registry.setRiskParams(BTC, params);

        ParameterRegistry.RiskParams memory stored = registry.getRiskParams(BTC);

        assertEq(stored.maxBorrowLTV, params.maxBorrowLTV);
        assertEq(stored.rescueTriggerLTV, params.rescueTriggerLTV);
        assertEq(stored.liquidationLTV, params.liquidationLTV);
        assertEq(stored.targetPostRescueLTV, params.targetPostRescueLTV);
        assertEq(stored.collateralHaircutBps, params.collateralHaircutBps);
        assertEq(stored.liquidationBufferBps, params.liquidationBufferBps);
        assertEq(stored.maxRescueAttempts, params.maxRescueAttempts);
        assertEq(stored.rescueCooldown, params.rescueCooldown);
        assertEq(stored.buybackClaimDuration, params.buybackClaimDuration);
        assertEq(stored.remoteIntentFeeCapBps, params.remoteIntentFeeCapBps);
        assertEq(stored.remoteIntentMaxSize, params.remoteIntentMaxSize);
        assertEq(stored.remoteIntentExpiry, params.remoteIntentExpiry);
        assertEq(stored.remoteFillMinBps, params.remoteFillMinBps);
        assertEq(stored.remoteLiquidityStressTriggerBps, params.remoteLiquidityStressTriggerBps);
        assertEq(stored.maxRemoteDependencyBps, params.maxRemoteDependencyBps);
        assertEq(stored.maxSolverConcentrationBps, params.maxSolverConcentrationBps);
    }

    function test_setRiskParams_revertsIfNotOwner() external {
        ParameterRegistry.RiskParams memory params = _validParams();

        vm.prank(nonOwner);
        vm.expectRevert();
        registry.setRiskParams(BTC, params);
    }

    function test_setRiskParams_revertsOnZeroAssetId() external {
        vm.expectRevert(ParameterRegistry.InvalidAssetId.selector);
        registry.setRiskParams(bytes32(0), _validParams());
    }

    function test_setRiskParams_revertsOnInvalidBpsValue() external {
        ParameterRegistry.RiskParams memory params = _validParams();
        params.maxBorrowLTV = 10_001;

        vm.expectRevert(
            abi.encodeWithSelector(ParameterRegistry.InvalidBpsValue.selector, 10_001)
        );
        registry.setRiskParams(BTC, params);
    }

    function test_setRiskParams_revertsOnInvalidRiskWindow_case1() external {
        ParameterRegistry.RiskParams memory params = _validParams();
        params.maxBorrowLTV = 8_500;
        params.rescueTriggerLTV = 8_000;

        vm.expectRevert(ParameterRegistry.InvalidRiskWindow.selector);
        registry.setRiskParams(BTC, params);
    }

    function test_setRiskParams_revertsOnInvalidRiskWindow_case2() external {
        ParameterRegistry.RiskParams memory params = _validParams();
        params.rescueTriggerLTV = 8_600;
        params.liquidationLTV = 8_500;

        vm.expectRevert(ParameterRegistry.InvalidRiskWindow.selector);
        registry.setRiskParams(BTC, params);
    }

    function test_getRiskParams_revertsWhenUnset() external {
        vm.expectRevert(abi.encodeWithSelector(ParameterRegistry.AssetParamsNotFound.selector, BTC));
        registry.getRiskParams(BTC);
    }

    function test_hasRiskParams_falseWhenUnset() external {
        assertEq(registry.hasRiskParams(BTC), false);
    }

    function test_hasRiskParams_trueWhenSet() external {
        registry.setRiskParams(BTC, _validParams());
        assertEq(registry.hasRiskParams(BTC), true);
    }

    function test_setGlobalParam_storesValue() external {
        registry.setGlobalParam(GLOBAL_KEY, 42);
        assertEq(registry.getGlobalParam(GLOBAL_KEY), 42);
    }

    function test_setGlobalParam_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.setGlobalParam(GLOBAL_KEY, 42);
    }

    function test_setGlobalParam_revertsOnZeroKey() external {
        vm.expectRevert(ParameterRegistry.InvalidAssetId.selector);
        registry.setGlobalParam(bytes32(0), 42);
    }

    function _validParams() internal pure returns (ParameterRegistry.RiskParams memory params) {
        params = ParameterRegistry.RiskParams({
            maxBorrowLTV: 7_000,
            rescueTriggerLTV: 8_000,
            liquidationLTV: 8_500,
            targetPostRescueLTV: 6_500,
            collateralHaircutBps: 500,
            liquidationBufferBps: 300,
            maxRescueAttempts: 3,
            rescueCooldown: 1 hours,
            buybackClaimDuration: 7 days,
            remoteIntentFeeCapBps: 100,
            remoteIntentMaxSize: 1_000_000 ether,
            remoteIntentExpiry: 15 minutes,
            remoteFillMinBps: 8_000,
            remoteLiquidityStressTriggerBps: 9_000,
            maxRemoteDependencyBps: 3_000,
            maxSolverConcentrationBps: 2_500
        });
    }
}
