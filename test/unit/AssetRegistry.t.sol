// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetRegistry} from "src/core/AssetRegistry.sol";

contract AssetRegistryTest is Test {
    AssetRegistry internal registry;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);

    bytes32 internal constant BTC = keccak256("BTC");
    bytes32 internal constant BTC_INTEREST = keccak256("BTC_INTEREST");

    address internal constant BTC_TOKEN = address(0x1001);
    address internal constant BTC_ORACLE = address(0x2001);

    function setUp() external {
        registry = new AssetRegistry(owner);
    }

    function test_registerAsset_storesConfig() external {
        registry.registerAsset(
            BTC,
            BTC_TOKEN,
            BTC_ORACLE,
            8,
            BTC_INTEREST
        );

        AssetRegistry.AssetConfig memory cfg = registry.getAsset(BTC);

        assertEq(cfg.token, BTC_TOKEN);
        assertEq(cfg.oracle, BTC_ORACLE);
        assertEq(cfg.isActive, true);
        assertEq(cfg.decimals, 8);
        assertEq(cfg.assetId, BTC);
        assertEq(cfg.interestModelId, BTC_INTEREST);
    }

    function test_registerAsset_setsTokenMapping() external {
        registry.registerAsset(
            BTC,
            BTC_TOKEN,
            BTC_ORACLE,
            8,
            BTC_INTEREST
        );

        bytes32 assetId = registry.getAssetIdByToken(BTC_TOKEN);
        assertEq(assetId, BTC);
    }

    function test_registerAsset_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.registerAsset(
            BTC,
            BTC_TOKEN,
            BTC_ORACLE,
            8,
            BTC_INTEREST
        );
    }

    function test_registerAsset_revertsOnZeroAssetId() external {
        vm.expectRevert(AssetRegistry.InvalidAssetId.selector);
        registry.registerAsset(
            bytes32(0),
            BTC_TOKEN,
            BTC_ORACLE,
            8,
            BTC_INTEREST
        );
    }

    function test_registerAsset_revertsOnZeroToken() external {
        vm.expectRevert(AssetRegistry.ZeroAddress.selector);
        registry.registerAsset(
            BTC,
            address(0),
            BTC_ORACLE,
            8,
            BTC_INTEREST
        );
    }

    function test_registerAsset_revertsOnZeroOracle() external {
        vm.expectRevert(AssetRegistry.ZeroAddress.selector);
        registry.registerAsset(
            BTC,
            BTC_TOKEN,
            address(0),
            8,
            BTC_INTEREST
        );
    }

    function test_registerAsset_revertsOnInvalidDecimals() external {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidDecimals.selector, 19));
        registry.registerAsset(
            BTC,
            BTC_TOKEN,
            BTC_ORACLE,
            19,
            BTC_INTEREST
        );
    }

    function test_registerAsset_revertsOnDuplicateAsset() external {
        registry.registerAsset(
            BTC,
            BTC_TOKEN,
            BTC_ORACLE,
            8,
            BTC_INTEREST
        );

        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetAlreadyRegistered.selector, BTC));
        registry.registerAsset(
            BTC,
            address(0x9999),
            address(0x8888),
            8,
            BTC_INTEREST
        );
    }

    function test_setAssetStatus_updatesValue() external {
        _registerBTC();

        registry.setAssetStatus(BTC, false);
        assertEq(registry.isActive(BTC), false);

        registry.setAssetStatus(BTC, true);
        assertEq(registry.isActive(BTC), true);
    }

    function test_setOracle_updatesOracle() external {
        _registerBTC();

        address newOracle = address(0x3001);
        registry.setOracle(BTC, newOracle);

        AssetRegistry.AssetConfig memory cfg = registry.getAsset(BTC);
        assertEq(cfg.oracle, newOracle);
    }

    function test_setInterestModelId_updatesValue() external {
        _registerBTC();

        bytes32 newInterestModel = keccak256("BTC_INTEREST_V2");
        registry.setInterestModelId(BTC, newInterestModel);

        AssetRegistry.AssetConfig memory cfg = registry.getAsset(BTC);
        assertEq(cfg.interestModelId, newInterestModel);
    }

    function test_isSupported_returnsFalseForUnknownAsset() external {
        assertEq(registry.isSupported(BTC), false);
    }

    function test_isSupported_returnsTrueForRegisteredAsset() external {
        _registerBTC();
        assertEq(registry.isSupported(BTC), true);
    }

    function test_getAsset_revertsForUnknownAsset() external {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetNotFound.selector, BTC));
        registry.getAsset(BTC);
    }

    function test_getAssetConfig_revertsForUnknownAsset() external {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetNotFound.selector, BTC));
        registry.getAssetConfig(BTC);
    }

    function test_isActive_revertsForUnknownAsset() external {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetNotFound.selector, BTC));
        registry.isActive(BTC);
    }

    function _registerBTC() internal {
        registry.registerAsset(
            BTC,
            BTC_TOKEN,
            BTC_ORACLE,
            8,
            BTC_INTEREST
        );
    }
}
