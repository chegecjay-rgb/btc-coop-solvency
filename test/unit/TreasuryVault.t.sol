// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TreasuryVault} from "src/vaults/TreasuryVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract TreasuryVaultTest is Test {
    TreasuryVault internal treasury;
    MockERC20 internal stable;
    MockERC20 internal btc;

    address internal owner = address(this);
    address internal spender = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);
    address internal alice = address(0x1111);

    bytes32 internal constant AUDITS = keccak256("AUDITS");
    bytes32 internal constant OPS = keccak256("OPS");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 6);
        btc = new MockERC20("Wrapped BTC", "WBTC", 8);

        treasury = new TreasuryVault(owner, address(stable), address(btc));
        treasury.setApprovedSpender(spender, true);

        stable.mint(alice, 1_000_000e6);
        btc.mint(alice, 1_000_000_000);
    }

    function test_receiveProtocolRevenue_updatesStableBalance() external {
        vm.startPrank(alice);
        stable.approve(address(treasury), 100e6);
        treasury.receiveProtocolRevenue(100e6);
        vm.stopPrank();

        assertEq(treasury.stableBalance(), 100e6);
    }

    function test_receiveResidualCollateral_updatesBTCBalance() external {
        vm.startPrank(alice);
        btc.approve(address(treasury), 1000);
        treasury.receiveResidualCollateral(1000);
        vm.stopPrank();

        assertEq(treasury.btcBalance(), 1000);
    }

    function test_allocateBudget_setsBudget() external {
        treasury.allocateBudget(AUDITS, 200e6);
        assertEq(treasury.budgetByCategory(AUDITS), 200e6);
    }

    function test_disburse_stable_byOwner() external {
        vm.startPrank(alice);
        stable.approve(address(treasury), 100e6);
        treasury.receiveProtocolRevenue(100e6);
        vm.stopPrank();

        treasury.allocateBudget(AUDITS, 80e6);
        treasury.disburse(AUDITS, alice, address(stable), 50e6);

        assertEq(treasury.stableBalance(), 50e6);
        assertEq(treasury.budgetByCategory(AUDITS), 30e6);
    }

    function test_disburse_btc_byApprovedSpender() external {
        vm.startPrank(alice);
        btc.approve(address(treasury), 1000);
        treasury.receiveResidualCollateral(1000);
        vm.stopPrank();

        treasury.allocateBudget(OPS, 600);

        vm.prank(spender);
        treasury.disburse(OPS, alice, address(btc), 400);

        assertEq(treasury.btcBalance(), 600);
        assertEq(treasury.budgetByCategory(OPS), 200);
    }

    function test_disburse_revertsIfNotAuthorized() external {
        treasury.allocateBudget(AUDITS, 10e6);

        vm.prank(nonAuthorized);
        vm.expectRevert(TreasuryVault.NotAuthorized.selector);
        treasury.disburse(AUDITS, alice, address(stable), 1e6);
    }

    function test_disburse_revertsIfBudgetExceeded() external {
        treasury.allocateBudget(AUDITS, 10e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryVault.BudgetExceeded.selector,
                AUDITS,
                11e6,
                10e6
            )
        );
        treasury.disburse(AUDITS, alice, address(stable), 11e6);
    }

    function test_disburse_revertsIfInsufficientStableBalance() external {
        treasury.allocateBudget(AUDITS, 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryVault.InsufficientStableBalance.selector,
                50e6,
                0
            )
        );
        treasury.disburse(AUDITS, alice, address(stable), 50e6);
    }

    function test_disburse_revertsIfInsufficientBTCBalance() external {
        treasury.allocateBudget(OPS, 1000);

        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryVault.InsufficientBTCBalance.selector,
                500,
                0
            )
        );
        treasury.disburse(OPS, alice, address(btc), 500);
    }

    function test_receiveProtocolRevenue_revertsOnZeroAmount() external {
        vm.expectRevert(TreasuryVault.InvalidAmount.selector);
        treasury.receiveProtocolRevenue(0);
    }

    function test_receiveResidualCollateral_revertsOnZeroAmount() external {
        vm.expectRevert(TreasuryVault.InvalidAmount.selector);
        treasury.receiveResidualCollateral(0);
    }

    function test_setApprovedSpender_revertsOnZeroAddress() external {
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        treasury.setApprovedSpender(address(0), true);
    }
}
