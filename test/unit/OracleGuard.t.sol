// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleGuard} from "src/oracles/OracleGuard.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";

contract OracleGuardTest is Test {
    OracleGuard internal guard;
    MockOracle internal primary;
    MockOracle internal secondary;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        guard = new OracleGuard(owner, 500, 1 hours);

        primary = new MockOracle(8, 100_000 * 1e8, block.timestamp);
        secondary = new MockOracle(8, 101_000 * 1e8, block.timestamp);
    }

    function test_setOracleConfig_storesValues() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));

        OracleGuard.OracleConfig memory config = guard.getOracleConfig(BTC);
        assertEq(config.primaryOracle, address(primary));
        assertEq(config.secondaryOracle, address(secondary));
    }

    function test_setOracleConfig_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        guard.setOracleConfig(BTC, address(primary), address(secondary));
    }

    function test_setOracleConfig_revertsOnZeroAssetId() external {
        vm.expectRevert(OracleGuard.InvalidAssetId.selector);
        guard.setOracleConfig(bytes32(0), address(primary), address(secondary));
    }

    function test_setOracleConfig_revertsOnZeroPrimary() external {
        vm.expectRevert(OracleGuard.ZeroAddress.selector);
        guard.setOracleConfig(BTC, address(0), address(secondary));
    }

    function test_setMaxDeviationBps_updatesValue() external {
        guard.setMaxDeviationBps(250);
        assertEq(guard.maxDeviationBps(), 250);
    }

    function test_setMaxStaleness_updatesValue() external {
        guard.setMaxStaleness(2 hours);
        assertEq(guard.maxStaleness(), 2 hours);
    }

    function test_getValidatedPrice_returnsPrimaryIfNoSecondary() external {
        guard.setOracleConfig(BTC, address(primary), address(0));

        uint256 price = guard.getValidatedPrice(BTC);
        assertEq(price, 100_000 ether);
    }

    function test_getValidatedPrice_returnsMedianIfBothValid() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));

        uint256 price = guard.getValidatedPrice(BTC);
        assertEq(price, 100_500 ether);
    }

    function test_getMedianPrice_returnsMedian() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));

        uint256 price = guard.getMedianPrice(BTC);
        assertEq(price, 100_500 ether);
    }

    function test_getValidatedPrice_revertsIfDeviationTooHigh() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));
        secondary.setAnswer(120_000 * 1e8);

        vm.expectRevert();
        guard.getValidatedPrice(BTC);
    }

    function test_getValidatedPrice_revertsIfPrimaryStale() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));

        vm.warp(10 hours);
        primary.setUpdatedAt(block.timestamp - 2 hours);

        vm.expectRevert();
        guard.getValidatedPrice(BTC);
    }

    function test_getValidatedPrice_revertsIfSecondaryStale() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));

        vm.warp(10 hours);
        secondary.setUpdatedAt(block.timestamp - 2 hours);

        vm.expectRevert();
        guard.getValidatedPrice(BTC);
    }

    function test_getValidatedPrice_revertsIfPrimaryInvalid() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));
        primary.setAnswer(0);

        vm.expectRevert(OracleGuard.InvalidOracleResponse.selector);
        guard.getValidatedPrice(BTC);
    }

    function test_getValidatedPrice_revertsIfSecondaryInvalid() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));
        secondary.setAnswer(-1);

        vm.expectRevert(OracleGuard.InvalidOracleResponse.selector);
        guard.getValidatedPrice(BTC);
    }

    function test_getValidatedPrice_revertsIfNotConfigured() external {
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.AssetOracleNotSet.selector, BTC));
        guard.getValidatedPrice(BTC);
    }

    function test_isPriceValid_trueForGoodPrice() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));
        assertEq(guard.isPriceValid(BTC), true);
    }

    function test_isPriceValid_falseForBadPrice() external {
        guard.setOracleConfig(BTC, address(primary), address(secondary));
        secondary.setAnswer(200_000 * 1e8);

        assertEq(guard.isPriceValid(BTC), false);
    }

    function test_normalizesDifferentDecimals() external {
        MockOracle d6 = new MockOracle(6, 100_000 * 1e6, block.timestamp);
        guard.setOracleConfig(BTC, address(d6), address(0));

        uint256 price = guard.getValidatedPrice(BTC);
        assertEq(price, 100_000 ether);
    }
}
