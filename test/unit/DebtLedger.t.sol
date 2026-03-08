// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";

contract DebtLedgerTest is Test {
    DebtLedger internal ledger;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);

    uint256 internal constant POSITION_ID = 1;

    function setUp() external {
        ledger = new DebtLedger(owner);
        ledger.setAuthorizedWriter(writer, true);
    }

    function test_initializeDebtRecord_storesPrincipal() external {
        ledger.initializeDebtRecord(POSITION_ID, 5 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.principal, 5 ether);
        assertGt(record.lastAccrualTime, 0);
        assertEq(ledger.totalProtocolPrincipal(), 5 ether);
    }

    function test_initializeDebtRecord_revertsForZeroPositionId() external {
        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PositionNotFound.selector, 0));
        ledger.initializeDebtRecord(0, 1 ether);
    }

    function test_initializeDebtRecord_revertsIfAlreadyInitialized() external {
        ledger.initializeDebtRecord(POSITION_ID, 1 ether);

        vm.expectRevert(DebtLedger.InvalidAmount.selector);
        ledger.initializeDebtRecord(POSITION_ID, 1 ether);
    }

    function test_initializeDebtRecord_revertsIfNotAuthorized() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.initializeDebtRecord(POSITION_ID, 1 ether);
    }

    function test_authorizedWriter_canInitializeDebtRecord() external {
        vm.prank(writer);
        ledger.initializeDebtRecord(POSITION_ID, 2 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.principal, 2 ether);
    }

    function test_increaseDebt_updatesPrincipal() external {
        _init();

        ledger.increaseDebt(POSITION_ID, 2 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.principal, 7 ether);
        assertEq(ledger.totalProtocolPrincipal(), 7 ether);
    }

    function test_increaseDebt_revertsOnZeroAmount() external {
        _init();

        vm.expectRevert(DebtLedger.InvalidAmount.selector);
        ledger.increaseDebt(POSITION_ID, 0);
    }

    function test_repayDebt_updatesPrincipal() external {
        _init();

        ledger.repayDebt(POSITION_ID, 2 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.principal, 3 ether);
        assertEq(ledger.totalProtocolPrincipal(), 3 ether);
    }

    function test_repayDebt_revertsIfTooMuch() external {
        _init();

        vm.expectRevert(
            abi.encodeWithSelector(DebtLedger.RepayExceedsPrincipal.selector, 6 ether, 5 ether)
        );
        ledger.repayDebt(POSITION_ID, 6 ether);
    }

    function test_accrueInterest_updatesInterestAndTimestamp() external {
        _init();

        vm.warp(123456);
        ledger.accrueInterest(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.accruedInterest, 1 ether);
        assertEq(record.lastAccrualTime, 123456);
        assertEq(ledger.totalAccruedInterest(), 1 ether);
    }

    function test_repayInterest_updatesInterest() external {
        _init();
        ledger.accrueInterest(POSITION_ID, 2 ether);

        ledger.repayInterest(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.accruedInterest, 1 ether);
        assertEq(ledger.totalAccruedInterest(), 1 ether);
    }

    function test_repayInterest_revertsIfTooMuch() external {
        _init();
        ledger.accrueInterest(POSITION_ID, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DebtLedger.InterestRepayExceedsAccrued.selector,
                2 ether,
                1 ether
            )
        );
        ledger.repayInterest(POSITION_ID, 2 ether);
    }

    function test_addRescueObligation_updatesFields() external {
        _init();

        ledger.addRescueObligation(POSITION_ID, 3 ether, 0.2 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.rescueObligation, 3 ether);
        assertEq(record.rescueFeesAccrued, 0.2 ether);
        assertEq(ledger.totalRescueObligation(), 3 ether);
        assertEq(ledger.totalRescueFees(), 0.2 ether);
    }

    function test_repayRescueObligation_updatesValue() external {
        _init();
        ledger.addRescueObligation(POSITION_ID, 3 ether, 0.2 ether);

        ledger.repayRescueObligation(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.rescueObligation, 2 ether);
        assertEq(ledger.totalRescueObligation(), 2 ether);
    }

    function test_repayRescueFee_updatesValue() external {
        _init();
        ledger.addRescueObligation(POSITION_ID, 3 ether, 0.2 ether);

        ledger.repayRescueFee(POSITION_ID, 0.1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.rescueFeesAccrued, 0.1 ether);
        assertEq(ledger.totalRescueFees(), 0.1 ether);
    }

    function test_addPendingRemoteFunding_updatesFields() external {
        _init();

        ledger.addPendingRemoteFunding(POSITION_ID, 4 ether, 0.3 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.pendingRemoteFunding, 4 ether);
        assertEq(record.remoteFundingFees, 0.3 ether);
        assertEq(ledger.totalPendingRemoteFunding(), 4 ether);
        assertEq(ledger.totalRemoteFundingFees(), 0.3 ether);
    }

    function test_clearPendingRemoteFunding_updatesValue() external {
        _init();
        ledger.addPendingRemoteFunding(POSITION_ID, 4 ether, 0.3 ether);

        ledger.clearPendingRemoteFunding(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.pendingRemoteFunding, 3 ether);
        assertEq(ledger.totalPendingRemoteFunding(), 3 ether);
    }

    function test_repayRemoteFundingFee_updatesValue() external {
        _init();
        ledger.addPendingRemoteFunding(POSITION_ID, 4 ether, 0.3 ether);

        ledger.repayRemoteFundingFee(POSITION_ID, 0.1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.remoteFundingFees, 0.2 ether);
        assertEq(ledger.totalRemoteFundingFees(), 0.2 ether);
    }

    function test_addRemoteRescueObligation_updatesValue() external {
        _init();

        ledger.addRemoteRescueObligation(POSITION_ID, 2 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.remoteRescueObligation, 2 ether);
        assertEq(ledger.totalRemoteRescueObligation(), 2 ether);
    }

    function test_repayRemoteRescueObligation_updatesValue() external {
        _init();
        ledger.addRemoteRescueObligation(POSITION_ID, 2 ether);

        ledger.repayRemoteRescueObligation(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.remoteRescueObligation, 1 ether);
        assertEq(ledger.totalRemoteRescueObligation(), 1 ether);
    }

    function test_closeDebt_clearsAllValuesAndTotals() external {
        _init();
        ledger.accrueInterest(POSITION_ID, 1 ether);
        ledger.addRescueObligation(POSITION_ID, 3 ether, 0.2 ether);
        ledger.addPendingRemoteFunding(POSITION_ID, 4 ether, 0.3 ether);
        ledger.addRemoteRescueObligation(POSITION_ID, 2 ether);

        ledger.closeDebt(POSITION_ID);

        assertEq(ledger.exists(POSITION_ID), false);
        assertEq(ledger.totalProtocolPrincipal(), 0);
        assertEq(ledger.totalAccruedInterest(), 0);
        assertEq(ledger.totalRescueObligation(), 0);
        assertEq(ledger.totalRescueFees(), 0);
        assertEq(ledger.totalPendingRemoteFunding(), 0);
        assertEq(ledger.totalRemoteFundingFees(), 0);
        assertEq(ledger.totalRemoteRescueObligation(), 0);
    }

    function test_onlyAuthorized_canIncreaseDebt() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.increaseDebt(POSITION_ID, 1 ether);
    }

    function test_onlyAuthorized_canRepayDebt() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.repayDebt(POSITION_ID, 1 ether);
    }

    function test_onlyAuthorized_canAccrueInterest() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.accrueInterest(POSITION_ID, 1 ether);
    }

    function test_onlyAuthorized_canAddRescueObligation() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.addRescueObligation(POSITION_ID, 1 ether, 0.1 ether);
    }

    function test_onlyAuthorized_canAddPendingRemoteFunding() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.addPendingRemoteFunding(POSITION_ID, 1 ether, 0.1 ether);
    }

    function test_onlyAuthorized_canAddRemoteRescueObligation() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.addRemoteRescueObligation(POSITION_ID, 1 ether);
    }

    function _init() internal {
        ledger.initializeDebtRecord(POSITION_ID, 5 ether);
    }
}
