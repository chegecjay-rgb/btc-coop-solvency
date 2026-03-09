// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LendingLiquidityVaultTest is Test {
    LendingLiquidityVault internal vault;
    MockERC20 internal token;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);
    address internal alice = address(0x1111);
    address internal bob = address(0x2222);
    address internal receiver = address(0x3333);

    bytes32 internal constant ASSET_ID = keccak256("BTC");

    function setUp() external {
        token = new MockERC20("USD Coin", "USDC", 6);
        vault = new LendingLiquidityVault(owner, address(token), ASSET_ID);
        vault.setAuthorizedWriter(writer, true);

        token.mint(alice, 1_000_000e6);
        token.mint(bob, 1_000_000e6);
    }

    function test_constructor_setsMetadata() external view {
        assertEq(vault.quoteAsset(), address(token));
        assertEq(vault.assetId(), ASSET_ID);
    }

    function test_depositLiquidity_firstDepositMintsOneToOneShares() external {
        vm.startPrank(alice);
        token.approve(address(vault), 100e6);

        uint256 shares = vault.depositLiquidity(100e6, alice);
        vm.stopPrank();

        assertEq(shares, 100e6);
        assertEq(vault.lenderShares(alice), 100e6);
        assertEq(vault.totalShares(), 100e6);
        assertEq(vault.totalLiquidity(), 100e6);
        assertEq(vault.availableLiquidity(), 100e6);
    }

    function test_depositLiquidity_canDepositForReceiver() external {
        vm.startPrank(alice);
        token.approve(address(vault), 100e6);

        uint256 shares = vault.depositLiquidity(100e6, receiver);
        vm.stopPrank();

        assertEq(shares, 100e6);
        assertEq(vault.lenderShares(receiver), 100e6);
        assertEq(vault.lenderShares(alice), 0);
    }

    function test_depositLiquidity_secondDepositMintsProRataShares() external {
        vm.startPrank(alice);
        token.approve(address(vault), 100e6);
        vault.depositLiquidity(100e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(vault), 50e6);
        uint256 shares = vault.depositLiquidity(50e6, bob);
        vm.stopPrank();

        assertEq(shares, 50e6);
        assertEq(vault.lenderShares(bob), 50e6);
        assertEq(vault.totalShares(), 150e6);
        assertEq(vault.totalLiquidity(), 150e6);
        assertEq(vault.availableLiquidity(), 150e6);
    }

    function test_depositLiquidity_revertsOnZeroAmount() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1e6);
        vm.expectRevert(LendingLiquidityVault.InvalidAmount.selector);
        vault.depositLiquidity(0, alice);
        vm.stopPrank();
    }

    function test_depositLiquidity_revertsOnZeroReceiver() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1e6);
        vm.expectRevert(LendingLiquidityVault.ZeroAddress.selector);
        vault.depositLiquidity(1e6, address(0));
        vm.stopPrank();
    }

    function test_withdrawLiquidity_returnsAssets() external {
        vm.startPrank(alice);
        token.approve(address(vault), 100e6);
        vault.depositLiquidity(100e6, alice);

        uint256 assets = vault.withdrawLiquidity(40e6, alice);
        vm.stopPrank();

        assertEq(assets, 40e6);
        assertEq(vault.lenderShares(alice), 60e6);
        assertEq(vault.totalShares(), 60e6);
        assertEq(vault.totalLiquidity(), 60e6);
        assertEq(vault.availableLiquidity(), 60e6);
        assertEq(token.balanceOf(alice), 1_000_000e6 - 100e6 + 40e6);
    }

    function test_withdrawLiquidity_canWithdrawToReceiver() external {
        vm.startPrank(alice);
        token.approve(address(vault), 100e6);
        vault.depositLiquidity(100e6, alice);

        uint256 assets = vault.withdrawLiquidity(25e6, receiver);
        vm.stopPrank();

        assertEq(assets, 25e6);
        assertEq(token.balanceOf(receiver), 25e6);
    }

    function test_withdrawLiquidity_revertsOnZeroAmount() external {
        vm.prank(alice);
        vm.expectRevert(LendingLiquidityVault.InvalidAmount.selector);
        vault.withdrawLiquidity(0, alice);
    }

    function test_withdrawLiquidity_revertsOnZeroReceiver() external {
        vm.prank(alice);
        vm.expectRevert(LendingLiquidityVault.ZeroAddress.selector);
        vault.withdrawLiquidity(1, address(0));
    }

    function test_withdrawLiquidity_revertsIfInsufficientShares() external {
        vm.startPrank(alice);
        token.approve(address(vault), 100e6);
        vault.depositLiquidity(100e6, alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                LendingLiquidityVault.InsufficientShares.selector,
                101e6,
                100e6
            )
        );
        vault.withdrawLiquidity(101e6, alice);
        vm.stopPrank();
    }

    function test_withdrawLiquidity_revertsIfInsufficientAvailableLiquidity() external {
        vm.startPrank(alice);
        token.approve(address(vault), 100e6);
        vault.depositLiquidity(100e6, alice);
        vm.stopPrank();

        vault.allocateToBorrower(receiver, 80e6);

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingLiquidityVault.InsufficientAvailableLiquidity.selector,
                100e6,
                20e6
            )
        );
        vault.withdrawLiquidity(100e6, alice);
        vm.stopPrank();
    }

    function test_allocateToBorrower_reducesAvailableLiquidity() external {
        _seedVault(100e6);

        vault.allocateToBorrower(receiver, 30e6);

        assertEq(vault.totalLiquidity(), 100e6);
        assertEq(vault.availableLiquidity(), 70e6);
    }

    function test_allocateToBorrower_revertsIfNotAuthorized() external {
        _seedVault(100e6);

        vm.prank(nonAuthorized);
        vm.expectRevert(LendingLiquidityVault.NotAuthorized.selector);
        vault.allocateToBorrower(receiver, 30e6);
    }

    function test_allocateToBorrower_revertsIfInsufficientAvailable() external {
        _seedVault(100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                LendingLiquidityVault.InsufficientAvailableLiquidity.selector,
                120e6,
                100e6
            )
        );
        vault.allocateToBorrower(receiver, 120e6);
    }

    function test_receiveRepayment_increasesLiquidity() external {
        _seedVault(100e6);
        vault.allocateToBorrower(receiver, 40e6);

        vm.prank(alice);
        token.approve(address(vault), 25e6);

        vm.prank(writer);
        vault.receiveRepaymentFrom(alice, 25e6);

        assertEq(vault.totalLiquidity(), 125e6);
        assertEq(vault.availableLiquidity(), 85e6);
    }

    function test_receiveRepayment_revertsIfNotAuthorized() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(LendingLiquidityVault.NotAuthorized.selector);
        vault.receiveRepaymentFrom(alice, 1e6);
    }

    function test_utilization_returnsZeroWhenEmpty() external view {
        assertEq(vault.utilization(), 0);
    }

    function test_utilization_returnsExpectedBps() external {
        _seedVault(100e6);
        vault.allocateToBorrower(receiver, 25e6);

        assertEq(vault.utilization(), 2500);
    }

    function test_previewDepositShares_firstDeposit() external view {
        assertEq(vault.previewDepositShares(100e6), 100e6);
    }

    function test_previewRedeemAssets_returnsProRataAssets() external {
        _seedVault(100e6);

        assertEq(vault.previewRedeemAssets(40e6), 40e6);
    }

    function test_setAuthorizedWriter_revertsOnZeroAddress() external {
        vm.expectRevert(LendingLiquidityVault.ZeroAddress.selector);
        vault.setAuthorizedWriter(address(0), true);
    }

    function _seedVault(uint256 amount) internal {
        vm.startPrank(alice);
        token.approve(address(vault), amount);
        vault.depositLiquidity(amount, alice);
        vm.stopPrank();
    }
}
