// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParameterRegistry} from "src/core/ParameterRegistry.sol";

contract ParameterRegistryTest is Test {
    ParameterRegistry internal registry;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        registry = new ParameterRegistry(owner);
    }

    function test_setRiskParams_storesValues() external {
        ParameterRegistry.RiskParams memory params_ = _validRiskParams();

        registry.setRiskParams(BTC, params_);

        ParameterRegistry.RiskParams memory stored = registry.getRiskParams(BTC);

        assertEq(stored.maxBorrowLTVBps, params_.maxBorrowLTVBps);
        assertEq(stored.rescueTriggerLTVBps, params_.rescueTriggerLTVBps);
        assertEq(stored.liquidationLTVBps, params_.liquidationLTVBps);
        assertEq(stored.targetPostRescueLTVBps, params_.targetPostRescueLTVBps);
        assertEq(stored.collateralHaircutBps, params_.collateralHaircutBps);
        assertEq(stored.liquidationBufferBps, params_.liquidationBufferBps);
        assertEq(stored.maxRescueAttempts, params_.maxRescueAttempts);
        assertEq(stored.rescueCooldown, params_.rescueCooldown);
        assertEq(stored.buybackClaimDuration, params_.buybackClaimDuration);
    }

    function test_setRiskParams_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.setRiskParams(BTC, _validRiskParams());
    }

    function test_setRiskParams_revertsOnZeroAssetId() external {
        vm.expectRevert(ParameterRegistry.InvalidAssetId.selector);
        registry.setRiskParams(bytes32(0), _validRiskParams());
    }

    function test_setRiskParams_revertsOnInvalidBpsValue() external {
        ParameterRegistry.RiskParams memory params_ = _validRiskParams();
        params_.maxBorrowLTVBps = 10_001;

        vm.expectRevert(
            abi.encodeWithSelector(ParameterRegistry.InvalidBpsValue.selector, 10_001)
        );
        registry.setRiskParams(BTC, params_);
    }

    function test_setRiskParams_revertsOnInvalidRiskWindow_case1() external {
        ParameterRegistry.RiskParams memory params_ = _validRiskParams();
        params_.maxBorrowLTVBps = 8_500;
        params_.rescueTriggerLTVBps = 8_000;

        vm.expectRevert(ParameterRegistry.InvalidRiskWindow.selector);
        registry.setRiskParams(BTC, params_);
    }

    function test_setRiskParams_revertsOnInvalidRiskWindow_case2() external {
        ParameterRegistry.RiskParams memory params_ = _validRiskParams();
        params_.rescueTriggerLTVBps = 8_600;
        params_.liquidationLTVBps = 8_500;

        vm.expectRevert(ParameterRegistry.InvalidRiskWindow.selector);
        registry.setRiskParams(BTC, params_);
    }

    function test_getRiskParams_revertsWhenUnset() external {
        vm.expectRevert(abi.encodeWithSelector(ParameterRegistry.ParamsNotFound.selector, BTC));
        registry.getRiskParams(BTC);
    }

    function test_hasRiskParams_falseWhenUnset() external {
        assertEq(registry.hasRiskParams(BTC), false);
    }

    function test_hasRiskParams_trueWhenSet() external {
        registry.setRiskParams(BTC, _validRiskParams());
        assertEq(registry.hasRiskParams(BTC), true);
    }

    function test_setInsuranceParams_storesValues() external {
        ParameterRegistry.InsuranceParams memory params_ = _validInsuranceParams();

        registry.setInsuranceParams(BTC, params_);

        ParameterRegistry.InsuranceParams memory stored = registry.getInsuranceParams(BTC);

        assertEq(stored.baseSystemInsuranceRateBps, params_.baseSystemInsuranceRateBps);
        assertEq(stored.baseOptionalCoverRateBps, params_.baseOptionalCoverRateBps);
        assertEq(stored.maxCoverageBps, params_.maxCoverageBps);
    }

    function test_setInsuranceParams_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.setInsuranceParams(BTC, _validInsuranceParams());
    }

    function test_setInsuranceParams_revertsOnInvalidBpsValue() external {
        ParameterRegistry.InsuranceParams memory params_ = _validInsuranceParams();
        params_.maxCoverageBps = 10_001;

        vm.expectRevert(
            abi.encodeWithSelector(ParameterRegistry.InvalidBpsValue.selector, 10_001)
        );
        registry.setInsuranceParams(BTC, params_);
    }

    function test_getInsuranceParams_revertsWhenUnset() external {
        vm.expectRevert(abi.encodeWithSelector(ParameterRegistry.ParamsNotFound.selector, BTC));
        registry.getInsuranceParams(BTC);
    }

    function test_hasInsuranceParams_trueWhenSet() external {
        registry.setInsuranceParams(BTC, _validInsuranceParams());
        assertEq(registry.hasInsuranceParams(BTC), true);
    }

    function test_setRemoteLiquidityParams_storesValues() external {
        ParameterRegistry.RemoteLiquidityParams memory params_ = _validRemoteParams();

        registry.setRemoteLiquidityParams(BTC, params_);

        ParameterRegistry.RemoteLiquidityParams memory stored =
            registry.getRemoteLiquidityParams(BTC);

        assertEq(stored.minLocalLiquidityBps, params_.minLocalLiquidityBps);
        assertEq(stored.highUtilizationBps, params_.highUtilizationBps);
        assertEq(stored.maxPendingRescueLoadBps, params_.maxPendingRescueLoadBps);
        assertEq(stored.remoteIntentFeeCapBps, params_.remoteIntentFeeCapBps);
        assertEq(stored.remoteIntentDeadline, params_.remoteIntentDeadline);
    }

    function test_setRemoteLiquidityParams_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.setRemoteLiquidityParams(BTC, _validRemoteParams());
    }

    function test_setRemoteLiquidityParams_revertsOnInvalidBpsValue() external {
        ParameterRegistry.RemoteLiquidityParams memory params_ = _validRemoteParams();
        params_.remoteIntentFeeCapBps = 10_001;

        vm.expectRevert(
            abi.encodeWithSelector(ParameterRegistry.InvalidBpsValue.selector, 10_001)
        );
        registry.setRemoteLiquidityParams(BTC, params_);
    }

    function test_getRemoteLiquidityParams_revertsWhenUnset() external {
        vm.expectRevert(abi.encodeWithSelector(ParameterRegistry.ParamsNotFound.selector, BTC));
        registry.getRemoteLiquidityParams(BTC);
    }

    function test_hasRemoteLiquidityParams_trueWhenSet() external {
        registry.setRemoteLiquidityParams(BTC, _validRemoteParams());
        assertEq(registry.hasRemoteLiquidityParams(BTC), true);
    }

    function _validRiskParams()
        internal
        pure
        returns (ParameterRegistry.RiskParams memory params_)
    {
        params_ = ParameterRegistry.RiskParams({
            maxBorrowLTVBps: 7000,
            rescueTriggerLTVBps: 8000,
            liquidationLTVBps: 8500,
            targetPostRescueLTVBps: 6500,
            collateralHaircutBps: 500,
            liquidationBufferBps: 300,
            maxRescueAttempts: 3,
            rescueCooldown: 1 hours,
            buybackClaimDuration: 7 days
        });
    }

    function _validInsuranceParams()
        internal
        pure
        returns (ParameterRegistry.InsuranceParams memory params_)
    {
        params_ = ParameterRegistry.InsuranceParams({
            baseSystemInsuranceRateBps: 120,
            baseOptionalCoverRateBps: 250,
            maxCoverageBps: 8000
        });
    }

    function _validRemoteParams()
        internal
        pure
        returns (ParameterRegistry.RemoteLiquidityParams memory params_)
    {
        params_ = ParameterRegistry.RemoteLiquidityParams({
            minLocalLiquidityBps: 2000,
            highUtilizationBps: 8500,
            maxPendingRescueLoadBps: 4000,
            remoteIntentFeeCapBps: 100,
            remoteIntentDeadline: 15 minutes
        });
    }
}
