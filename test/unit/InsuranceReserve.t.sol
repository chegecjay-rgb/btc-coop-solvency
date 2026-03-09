// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract InsuranceReserveTest is Test {
    InsuranceReserve internal reserve;
    MockERC20 internal token;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);
    address internal alice = address(0x1111);
    address internal bob = address(0x2222);

    bytes32 internal constant BTC_ASSET = keccak256("BTC");
    uint256 internal constant POSITION_ID = 1;

    function setUp() external {
        token = new MockERC20("USD Coin", "USDC", 6);
        reserve = new InsuranceReserve(owner, address(token));
        reserve.setAuthorizedWriter(writer, true);

        token.mint(alice, 1_000_000e6);
        token.mint(bob, 1_000_000e6);
        token.mint(writer, 1_000_000e6);
    }

    function test_depositReserve_updatesBalancesAndShares() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        uint256 shares = reserve.depositReserve(100e6);
        vm.stopPrank();

        assertEq(shares, 100e6);
        assertEq(reserve.insurerShares(alice), 100e6);
        assertEq(reserve.totalShares(), 100e6);
        assertEq(reserve.totalReserveBalance(), 100e6);
        assertEq(reserve.systemReserveBalance(), 100e6);
        assertEq(reserve.coverReserveBalance(), 0);
    }

    function test_requestWithdraw_returnsAssets() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        reserve.depositReserve(100e6);

        uint256 assets = reserve.requestWithdraw(40e6);
        vm.stopPrank();

        assertEq(assets, 40e6);
        assertEq(reserve.insurerShares(alice), 60e6);
        assertEq(reserve.totalShares(), 60e6);
        assertEq(reserve.totalReserveBalance(), 60e6);
        assertEq(reserve.systemReserveBalance(), 60e6);
    }

    function test_requestWithdraw_revertsIfInsufficientShares() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        reserve.depositReserve(100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                InsuranceReserve.InsufficientShares.selector,
                101e6,
                100e6
            )
        );
        reserve.requestWithdraw(101e6);
        vm.stopPrank();
    }

    function test_requestWithdraw_revertsIfFreeReserveTooLow() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        reserve.depositReserve(100e6);
        vm.stopPrank();

        reserve.coverTerminalDeficit(POSITION_ID, 80e6);

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsuranceReserve.InsufficientFreeReserve.selector,
                50e6,
                20e6
            )
        );
        reserve.requestWithdraw(50e6);
        vm.stopPrank();
    }

    function test_reserveOptionalCover_movesFundsFromSystemToCover() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        reserve.depositReserve(100e6);
        vm.stopPrank();

        reserve.reserveOptionalCover(POSITION_ID, 25e6);

        assertEq(reserve.systemReserveBalance(), 75e6);
        assertEq(reserve.coverReserveBalance(), 25e6);
        assertEq(reserve.lockedCoverLiabilities(), 25e6);

        (
            uint256 coveredClaimAmount,
            uint256 systemDeficitCovered,
            uint256 recoveryReceivable,
            bool active
        ) = reserve.exposureByPosition(POSITION_ID);

        assertEq(coveredClaimAmount, 25e6);
        assertEq(systemDeficitCovered, 0);
        assertEq(recoveryReceivable, 0);
        assertEq(active, true);
    }

    function test_coverTerminalDeficit_updatesSystemExposure() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        reserve.depositReserve(100e6);
        vm.stopPrank();

        reserve.coverTerminalDeficit(POSITION_ID, 40e6);

        assertEq(reserve.systemReserveBalance(), 60e6);
        assertEq(reserve.lockedSystemLiabilities(), 40e6);

        (
            uint256 coveredClaimAmount,
            uint256 systemDeficitCovered,
            uint256 recoveryReceivable,
            bool active
        ) = reserve.exposureByPosition(POSITION_ID);

        assertEq(coveredClaimAmount, 0);
        assertEq(systemDeficitCovered, 40e6);
        assertEq(recoveryReceivable, 0);
        assertEq(active, true);
    }

    function test_reimburseStabilizationPool_transfersOutFunds() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        reserve.depositReserve(100e6);
        vm.stopPrank();

        uint256 before = token.balanceOf(address(this));
        reserve.reimburseStabilizationPool(BTC_ASSET, 30e6);
        uint256 afterBal = token.balanceOf(address(this));

        assertEq(afterBal - before, 30e6);
        assertEq(reserve.totalReserveBalance(), 70e6);
        assertEq(reserve.systemReserveBalance(), 70e6);
    }

    function test_registerRecoveryReceivable_updatesExposure() external {
        reserve.registerRecoveryReceivable(POSITION_ID, 15e6);

        (, , uint256 recoveryReceivable, bool active) = reserve.exposureByPosition(POSITION_ID);
        assertEq(recoveryReceivable, 15e6);
        assertEq(active, true);
    }

    function test_receiveRecovery_reducesReceivableAndAddsReserve() external {
        reserve.registerRecoveryReceivable(POSITION_ID, 20e6);

        vm.startPrank(writer);
        token.approve(address(reserve), 20e6);
        reserve.receiveRecovery(POSITION_ID, 12e6);
        vm.stopPrank();

        (, , uint256 recoveryReceivable, bool active) = reserve.exposureByPosition(POSITION_ID);
        assertEq(recoveryReceivable, 8e6);
        assertEq(active, true);
        assertEq(reserve.totalReserveBalance(), 12e6);
        assertEq(reserve.systemReserveBalance(), 12e6);
    }

    function test_receiveRecovery_revertsIfNoActiveExposure() external {
        vm.startPrank(writer);
        token.approve(address(reserve), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(InsuranceReserve.NoActiveExposure.selector, POSITION_ID)
        );
        reserve.receiveRecovery(POSITION_ID, 1e6);
        vm.stopPrank();
    }

    function test_receiveRecovery_revertsIfTooMuch() external {
        reserve.registerRecoveryReceivable(POSITION_ID, 5e6);

        vm.startPrank(writer);
        token.approve(address(reserve), 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsuranceReserve.InsufficientRecoveryReceivable.selector,
                10e6,
                5e6
            )
        );
        reserve.receiveRecovery(POSITION_ID, 10e6);
        vm.stopPrank();
    }

    function test_solvencyRatio_returnsMaxIfNoLockedLiabilities() external view {
        assertEq(reserve.solvencyRatio(), type(uint256).max);
    }

    function test_solvencyRatio_returnsExpectedValue() external {
        vm.startPrank(alice);
        token.approve(address(reserve), 100e6);
        reserve.depositReserve(100e6);
        vm.stopPrank();

        reserve.coverTerminalDeficit(POSITION_ID, 40e6);

        assertEq(reserve.solvencyRatio(), 25_000);
    }

    function test_onlyAuthorized_canReserveOptionalCover() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(InsuranceReserve.NotAuthorized.selector);
        reserve.reserveOptionalCover(POSITION_ID, 1e6);
    }

    function test_onlyAuthorized_canCoverTerminalDeficit() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(InsuranceReserve.NotAuthorized.selector);
        reserve.coverTerminalDeficit(POSITION_ID, 1e6);
    }

    function test_onlyAuthorized_canReimburseStabilizationPool() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(InsuranceReserve.NotAuthorized.selector);
        reserve.reimburseStabilizationPool(BTC_ASSET, 1e6);
    }

    function test_onlyAuthorized_canRegisterRecoveryReceivable() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(InsuranceReserve.NotAuthorized.selector);
        reserve.registerRecoveryReceivable(POSITION_ID, 1e6);
    }

    function test_onlyAuthorized_canReceiveRecovery() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(InsuranceReserve.NotAuthorized.selector);
        reserve.receiveRecovery(POSITION_ID, 1e6);
    }

    function test_setAuthorizedWriter_revertsOnZeroAddress() external {
        vm.expectRevert(InsuranceReserve.ZeroAddress.selector);
        reserve.setAuthorizedWriter(address(0), true);
    }
}
