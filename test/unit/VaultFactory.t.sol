// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {VaultFactory} from "src/vaults/VaultFactory.sol";
import {AssetVault} from "src/vaults/AssetVault.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract VaultFactoryTest is Test {
    VaultFactory internal factory;
    MockERC20 internal assetToken;
    MockERC20 internal quoteToken;

    address internal governance = address(this);
    address internal other = address(0xBEEF);

    bytes32 internal constant BTC = keccak256("BTC");
    bytes32 internal constant ETH = keccak256("ETH");

    function setUp() external {
        factory = new VaultFactory(governance);
        assetToken = new MockERC20("Wrapped BTC", "WBTC", 18);
        quoteToken = new MockERC20("USD Coin", "USDC", 6);
    }

    function test_constructor_setsGovernance() external view {
        assertEq(factory.governance(), governance);
    }

    function test_createAssetVault_deploysAndRegistersVault() external {
        address vault = factory.createAssetVault(BTC, address(assetToken));

        assertEq(factory.assetVaultByAssetId(BTC), vault);
        assertEq(factory.isOfficialVault(vault), true);

        AssetVault assetVault = AssetVault(vault);
        assertEq(assetVault.underlyingAsset(), address(assetToken));
        assertEq(assetVault.assetId(), BTC);
        assertEq(assetVault.owner(), governance);
    }

    function test_createAssetVault_revertsIfNotGovernance() external {
        vm.prank(other);
        vm.expectRevert(VaultFactory.NotGovernance.selector);
        factory.createAssetVault(BTC, address(assetToken));
    }

    function test_createAssetVault_revertsOnZeroAssetId() external {
        vm.expectRevert(VaultFactory.ZeroAssetId.selector);
        factory.createAssetVault(bytes32(0), address(assetToken));
    }

    function test_createAssetVault_revertsOnZeroToken() external {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.createAssetVault(BTC, address(0));
    }

    function test_createAssetVault_revertsIfAlreadyExists() external {
        factory.createAssetVault(BTC, address(assetToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                VaultFactory.VaultAlreadyExists.selector,
                BTC,
                factory.VAULT_TYPE_ASSET()
            )
        );
        factory.createAssetVault(BTC, address(assetToken));
    }

    function test_createLendingVault_deploysAndRegistersVault() external {
        address vault = factory.createLendingVault(BTC, address(quoteToken));

        assertEq(factory.lendingVaultByAssetId(BTC), vault);
        assertEq(factory.isOfficialVault(vault), true);

        LendingLiquidityVault lendingVault = LendingLiquidityVault(vault);
        assertEq(lendingVault.quoteAsset(), address(quoteToken));
        assertEq(lendingVault.assetId(), BTC);
        assertEq(lendingVault.owner(), governance);
    }

    function test_createLendingVault_revertsIfNotGovernance() external {
        vm.prank(other);
        vm.expectRevert(VaultFactory.NotGovernance.selector);
        factory.createLendingVault(BTC, address(quoteToken));
    }

    function test_createLendingVault_revertsOnZeroAssetId() external {
        vm.expectRevert(VaultFactory.ZeroAssetId.selector);
        factory.createLendingVault(bytes32(0), address(quoteToken));
    }

    function test_createLendingVault_revertsOnZeroToken() external {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.createLendingVault(BTC, address(0));
    }

    function test_createLendingVault_revertsIfAlreadyExists() external {
        factory.createLendingVault(BTC, address(quoteToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                VaultFactory.VaultAlreadyExists.selector,
                BTC,
                factory.VAULT_TYPE_LENDING()
            )
        );
        factory.createLendingVault(BTC, address(quoteToken));
    }

    function test_registerVault_setsAssetVaultAndMarksOfficial() external {
        address vault = address(0xA11CE);

        factory.registerVault(ETH, factory.VAULT_TYPE_ASSET(), vault);

        assertEq(factory.assetVaultByAssetId(ETH), vault);
        assertEq(factory.isOfficialVault(vault), true);
    }

    function test_registerVault_setsLendingVaultAndMarksOfficial() external {
        address vault = address(0xB0B);

        factory.registerVault(ETH, factory.VAULT_TYPE_LENDING(), vault);

        assertEq(factory.lendingVaultByAssetId(ETH), vault);
        assertEq(factory.isOfficialVault(vault), true);
    }

    function test_registerVault_replacesOldAssetVaultAndDisablesOldOfficialStatus() external {
        address firstVault = address(0x1111);
        address secondVault = address(0x2222);

        factory.registerVault(BTC, factory.VAULT_TYPE_ASSET(), firstVault);
        assertEq(factory.isOfficialVault(firstVault), true);

        factory.registerVault(BTC, factory.VAULT_TYPE_ASSET(), secondVault);

        assertEq(factory.assetVaultByAssetId(BTC), secondVault);
        assertEq(factory.isOfficialVault(firstVault), false);
        assertEq(factory.isOfficialVault(secondVault), true);
    }

    function test_registerVault_replacesOldLendingVaultAndDisablesOldOfficialStatus() external {
        address firstVault = address(0x3333);
        address secondVault = address(0x4444);

        factory.registerVault(BTC, factory.VAULT_TYPE_LENDING(), firstVault);
        assertEq(factory.isOfficialVault(firstVault), true);

        factory.registerVault(BTC, factory.VAULT_TYPE_LENDING(), secondVault);

        assertEq(factory.lendingVaultByAssetId(BTC), secondVault);
        assertEq(factory.isOfficialVault(firstVault), false);
        assertEq(factory.isOfficialVault(secondVault), true);
    }

    function test_registerVault_revertsIfNotGovernance() external {
        uint8 vaultType = factory.VAULT_TYPE_ASSET();

        vm.expectRevert(VaultFactory.NotGovernance.selector);
        vm.prank(other);
        factory.registerVault(BTC, vaultType, address(0x1234));
    }

    function test_registerVault_revertsOnZeroAssetId() external {
        uint8 vaultType = factory.VAULT_TYPE_ASSET();

        vm.expectRevert(VaultFactory.ZeroAssetId.selector);
        factory.registerVault(bytes32(0), vaultType, address(0x1234));
    }

    function test_registerVault_revertsOnZeroVault() external {
        uint8 vaultType = factory.VAULT_TYPE_ASSET();

        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.registerVault(BTC, vaultType, address(0));
    }

    function test_registerVault_revertsOnInvalidVaultType() external {
        vm.expectRevert(
            abi.encodeWithSelector(VaultFactory.InvalidVaultType.selector, uint8(99))
        );
        factory.registerVault(BTC, 99, address(0x1234));
    }

    function test_setVaultStatus_updatesOfficialStatus() external {
        address vault = address(0x1234);

        factory.setVaultStatus(vault, true);
        assertEq(factory.isOfficialVault(vault), true);

        factory.setVaultStatus(vault, false);
        assertEq(factory.isOfficialVault(vault), false);
    }

    function test_setVaultStatus_revertsIfNotGovernance() external {
        vm.prank(other);
        vm.expectRevert(VaultFactory.NotGovernance.selector);
        factory.setVaultStatus(address(0x1234), true);
    }

    function test_setVaultStatus_revertsOnZeroAddress() external {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setVaultStatus(address(0), true);
    }

    function test_setGovernance_updatesGovernanceAndOwnership() external {
        address newGovernance = address(0xCAFE);

        factory.setGovernance(newGovernance);

        assertEq(factory.governance(), newGovernance);
        assertEq(factory.owner(), newGovernance);
    }

    function test_setGovernance_revertsIfNotGovernance() external {
        vm.prank(other);
        vm.expectRevert(VaultFactory.NotGovernance.selector);
        factory.setGovernance(address(0xCAFE));
    }

    function test_setGovernance_revertsOnZeroAddress() external {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setGovernance(address(0));
    }
}
