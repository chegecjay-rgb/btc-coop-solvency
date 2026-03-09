// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetVault} from "src/vaults/AssetVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract AssetVaultTest is Test {
    AssetVault internal vault;
    MockERC20 internal token;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);
    address internal alice = address(0x1111);
    address internal bob = address(0x2222);
    address internal receiver = address(0x3333);

    bytes32 internal constant ASSET_ID = keccak256("BTC");

    function setUp() external {
        token = new MockERC20("Wrapped BTC", "WBTC", 8);
        vault = new AssetVault(owner, address(token), ASSET_ID);
        vault.setAuthorizedWriter(writer, true);

        token.mint(alice, 1_000_000_000);
        token.mint(bob, 1_000_000_000);
    }

    function test_constructor_setsMetadata() external view {
        assertEq(vault.underlyingAsset(), address(token));
        assertEq(vault.assetId(), ASSET_ID);
    }

    function test_deposit_firstDepositMintsOneToOneShares() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000);

        uint256 shares = vault.deposit(1000, alice);
        vm.stopPrank();

        assertEq(shares, 1000);
        assertEq(vault.shareBalance(alice), 1000);
        assertEq(vault.totalShares(), 1000);
        assertEq(vault.totalAssetsTracked(), 1000);
    }

    function test_deposit_canDepositForReceiver() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000);

        uint256 shares = vault.deposit(1000, receiver);
        vm.stopPrank();

        assertEq(shares, 1000);
        assertEq(vault.shareBalance(receiver), 1000);
        assertEq(vault.shareBalance(alice), 0);
    }

    function test_deposit_revertsOnZeroAmount() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1);
        vm.expectRevert(AssetVault.InvalidAmount.selector);
        vault.deposit(0, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsOnZeroReceiver() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1);
        vm.expectRevert(AssetVault.ZeroAddress.selector);
        vault.deposit(1, address(0));
        vm.stopPrank();
    }

    function test_withdraw_returnsAssets() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000);
        vault.deposit(1000, alice);

        uint256 sharesBurned = vault.withdraw(400, alice, alice);
        vm.stopPrank();

        assertEq(sharesBurned, 400);
        assertEq(vault.shareBalance(alice), 600);
        assertEq(vault.totalShares(), 600);
        assertEq(vault.totalAssetsTracked(), 600);
    }

    function test_withdraw_revertsIfNotOwnerCaller() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000);
        vault.deposit(1000, alice);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(AssetVault.NotAuthorized.selector);
        vault.withdraw(100, bob, alice);
    }

    function test_withdraw_revertsIfInsufficientAvailableAssetsDueToLock() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000);
        vault.deposit(1000, alice);
        vm.stopPrank();

        vault.lockForPosition(1, 800);

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetVault.InsufficientAvailableAssets.selector,
                300,
                200
            )
        );
        vault.withdraw(300, alice, alice);
        vm.stopPrank();
    }

    function test_mint_mintsSharesForAssets() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000);

        uint256 assetsRequired = vault.mint(1000, alice);
        vm.stopPrank();

        assertEq(assetsRequired, 1000);
        assertEq(vault.shareBalance(alice), 1000);
        assertEq(vault.totalShares(), 1000);
        assertEq(vault.totalAssetsTracked(), 1000);
    }

    function test_redeem_returnsAssets() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000);
        vault.deposit(1000, alice);

        uint256 assets = vault.redeem(250, alice, alice);
        vm.stopPrank();

        assertEq(assets, 250);
        assertEq(vault.shareBalance(alice), 750);
        assertEq(vault.totalShares(), 750);
        assertEq(vault.totalAssetsTracked(), 750);
    }

    function test_lockForPosition_updatesState() external {
        _seedVault(1000);

        vault.lockForPosition(1, 400);

        assertEq(vault.lockedByPosition(1), 400);
        assertEq(vault.totalLockedAssetsTracked(), 400);
        assertEq(vault.availableAssets(), 600);
    }

    function test_lockForPosition_revertsIfNotAuthorized() external {
        _seedVault(1000);

        vm.prank(nonAuthorized);
        vm.expectRevert(AssetVault.NotAuthorized.selector);
        vault.lockForPosition(1, 100);
    }

    function test_lockForPosition_revertsIfInsufficientAvailable() external {
        _seedVault(1000);

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetVault.InsufficientAvailableAssets.selector,
                1200,
                1000
            )
        );
        vault.lockForPosition(1, 1200);
    }

    function test_unlockForPosition_updatesState() external {
        _seedVault(1000);
        vault.lockForPosition(1, 400);

        vault.unlockForPosition(1, 150);

        assertEq(vault.lockedByPosition(1), 250);
        assertEq(vault.totalLockedAssetsTracked(), 250);
        assertEq(vault.availableAssets(), 750);
    }

    function test_unlockForPosition_revertsIfTooMuch() external {
        _seedVault(1000);
        vault.lockForPosition(1, 200);

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetVault.InsufficientLockedByPosition.selector,
                300,
                200
            )
        );
        vault.unlockForPosition(1, 300);
    }

    function test_util_previewRedeemAssets() external {
        _seedVault(1000);
        assertEq(vault.previewRedeemAssets(400), 400);
    }

    function test_util_previewWithdrawShares() external {
        _seedVault(1000);
        assertEq(vault.previewWithdrawShares(400), 400);
    }

    function test_util_previewMintAssets() external {
        _seedVault(1000);
        assertEq(vault.previewMintAssets(400), 400);
    }

    function test_setAuthorizedWriter_revertsOnZeroAddress() external {
        vm.expectRevert(AssetVault.ZeroAddress.selector);
        vault.setAuthorizedWriter(address(0), true);
    }

    function _seedVault(uint256 amount) internal {
        vm.startPrank(alice);
        token.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }
}
