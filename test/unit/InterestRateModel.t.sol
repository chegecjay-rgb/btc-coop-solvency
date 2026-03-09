// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "src/risk/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel internal model;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        model = new InterestRateModel(owner);

        model.setRateCurve(
            BTC,
            InterestRateModel.RateCurve({
                baseRateBps: 200,
                slope1Bps: 300,
                slope2Bps: 700,
                optimalUtilizationBps: 8_000,
                crisisPremiumBps: 150
            })
        );

        model.setRevenueSplit(BTC, 500, 300, 200);
    }

    function test_setRateCurve_storesValues() external view {
        (
            uint256 baseRateBps,
            uint256 slope1Bps,
            uint256 slope2Bps,
            uint256 optimalUtilizationBps,
            uint256 crisisPremiumBps
        ) = model.curveByAsset(BTC);

        assertEq(baseRateBps, 200);
        assertEq(slope1Bps, 300);
        assertEq(slope2Bps, 700);
        assertEq(optimalUtilizationBps, 8_000);
        assertEq(crisisPremiumBps, 150);
    }

    function test_setRateCurve_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        model.setRateCurve(
            BTC,
            InterestRateModel.RateCurve({
                baseRateBps: 100,
                slope1Bps: 100,
                slope2Bps: 100,
                optimalUtilizationBps: 7_000,
                crisisPremiumBps: 100
            })
        );
    }

    function test_setRateCurve_revertsOnZeroAssetId() external {
        vm.expectRevert(InterestRateModel.InvalidAssetId.selector);
        model.setRateCurve(
            bytes32(0),
            InterestRateModel.RateCurve({
                baseRateBps: 100,
                slope1Bps: 100,
                slope2Bps: 100,
                optimalUtilizationBps: 7_000,
                crisisPremiumBps: 100
            })
        );
    }

    function test_setRateCurve_revertsOnInvalidBps() external {
        vm.expectRevert(
            abi.encodeWithSelector(InterestRateModel.InvalidBpsValue.selector, 10_001)
        );
        model.setRateCurve(
            BTC,
            InterestRateModel.RateCurve({
                baseRateBps: 10_001,
                slope1Bps: 100,
                slope2Bps: 100,
                optimalUtilizationBps: 7_000,
                crisisPremiumBps: 100
            })
        );
    }

    function test_setRateCurve_revertsOnInvalidOptimalUtilization() external {
        vm.expectRevert(
            abi.encodeWithSelector(InterestRateModel.InvalidOptimalUtilization.selector, 0)
        );
        model.setRateCurve(
            BTC,
            InterestRateModel.RateCurve({
                baseRateBps: 100,
                slope1Bps: 100,
                slope2Bps: 100,
                optimalUtilizationBps: 0,
                crisisPremiumBps: 100
            })
        );
    }

    function test_setRevenueSplit_storesValues() external view {
        assertEq(model.stabilizerShareBps(BTC), 500);
        assertEq(model.insuranceShareBps(BTC), 300);
        assertEq(model.treasuryShareBps(BTC), 200);
    }

    function test_setRevenueSplit_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        model.setRevenueSplit(BTC, 100, 100, 100);
    }

    function test_setRevenueSplit_revertsOnInvalidTotal() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InvalidRevenueSplit.selector,
                5_000,
                4_000,
                2_000
            )
        );
        model.setRevenueSplit(BTC, 5_000, 4_000, 2_000);
    }

    function test_borrowRate_belowOptimalUtilization() external view {
        // base 200
        // util premium = 300 * 4000 / 8000 = 150
        // ltv premium at 6500 = 100
        // crisis premium = 0
        // total = 450
        assertEq(model.borrowRate(BTC, 4_000, 6_500), 450);
    }

    function test_borrowRate_atOptimalUtilization() external view {
        // base 200
        // util premium = 300
        // ltv premium at 7500 = 300
        // crisis premium = 0
        // total = 800
        assertEq(model.borrowRate(BTC, 8_000, 7_500), 800);
    }

    function test_borrowRate_aboveOptimalUtilization() external view {
        // utilization premium:
        // below kink = 300
        // excess = 1000, remaining range = 2000
        // above kink = 700 * 1000 / 2000 = 350
        // util total = 650
        // ltv premium at 8500 = 600
        // crisis premium = 150
        // total = 1600
        assertEq(model.borrowRate(BTC, 9_000, 8_500), 1_600);
    }

    function test_borrowRate_veryHighLTV() external view {
        // base 200
        // util premium = 300 * 2000 / 8000 = 75
        // ltv premium > 9000 = 1000
        // total = 1275
        assertEq(model.borrowRate(BTC, 2_000, 9_500), 1_275);
    }
}
