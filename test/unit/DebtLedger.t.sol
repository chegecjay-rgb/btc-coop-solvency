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
        assertEq(ledger.totalPrincipal(), 5 ether);
        assertEq(ledger.totalProtocolDebt(), 5 ether);
    }

    function test_initializeDebtRecord_revertsForZeroPositionId() external {
        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PositionNotFound.selector, 0));
        ledger.initializeDebtRecord(0, 1 ether);
    }

    function test_initializeDebtRecord_revertsIfAlreadyInitialized() external {
        ledger.initializeDebtRecord(POSITION_ID, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(DebtLedger.AlreadyInitialized.selector, POSITION_ID)
        );
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
        assertEq(ledger.totalPrincipal(), 7 ether);
        assertEq(ledger.totalProtocolDebt(), 7 ether);
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
        assertEq(ledger.totalPrincipal(), 3 ether);
        assertEq(ledger.totalProtocolDebt(), 3 ether);
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
        assertEq(ledger.totalProtocolDebt(), 6 ether);
    }

    function test_repayInterest_updatesInterest() external {
        _init();
        ledger.accrueInterest(POSITION_ID, 2 ether);

        ledger.repayInterest(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.accruedInterest, 1 ether);
        assertEq(ledger.totalAccruedInterest(), 1 ether);
        assertEq(ledger.totalProtocolDebt(), 6 ether);
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

    function test_recordRescueUsage_updatesFields() external {
        _init();

        ledger.recordRescueUsage(POSITION_ID, 3 ether, 0.2 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.rescueCapitalUsed, 3 ether);
        assertEq(record.rescueFeesAccrued, 0.2 ether);
        assertEq(ledger.totalRescueCapitalUsed(), 3 ether);
        assertEq(ledger.totalRescueFeesAccrued(), 0.2 ether);
        assertEq(ledger.totalProtocolDebt(), 8.2 ether);
    }

    function test_repayRescueCapital_updatesValue() external {
        _init();
        ledger.recordRescueUsage(POSITION_ID, 3 ether, 0.2 ether);

        ledger.repayRescueCapital(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.rescueCapitalUsed, 2 ether);
        assertEq(ledger.totalRescueCapitalUsed(), 2 ether);
        assertEq(ledger.totalProtocolDebt(), 7.2 ether);
    }

    function test_repayRescueFee_updatesValue() external {
        _init();
        ledger.recordRescueUsage(POSITION_ID, 3 ether, 0.2 ether);

        ledger.repayRescueFee(POSITION_ID, 0.1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.rescueFeesAccrued, 0.1 ether);
        assertEq(ledger.totalRescueFeesAccrued(), 0.1 ether);
        assertEq(ledger.totalProtocolDebt(), 8.1 ether);
    }

    function test_recordInsuranceUsage_updatesFields() external {
        _init();

        ledger.recordInsuranceUsage(POSITION_ID, 4 ether, 0.3 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.insuranceCapitalUsed, 4 ether);
        assertEq(record.insuranceChargesAccrued, 0.3 ether);
        assertEq(ledger.totalInsuranceCapitalUsed(), 4 ether);
        assertEq(ledger.totalInsuranceChargesAccrued(), 0.3 ether);
        assertEq(ledger.totalProtocolDebt(), 9.3 ether);
    }

    function test_repayInsuranceCapital_updatesValue() external {
        _init();
        ledger.recordInsuranceUsage(POSITION_ID, 4 ether, 0.3 ether);

        ledger.repayInsuranceCapital(POSITION_ID, 1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.insuranceCapitalUsed, 3 ether);
        assertEq(ledger.totalInsuranceCapitalUsed(), 3 ether);
        assertEq(ledger.totalProtocolDebt(), 8.3 ether);
    }

    function test_repayInsuranceCharge_updatesValue() external {
        _init();
        ledger.recordInsuranceUsage(POSITION_ID, 4 ether, 0.3 ether);

        ledger.repayInsuranceCharge(POSITION_ID, 0.1 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.insuranceChargesAccrued, 0.2 ether);
        assertEq(ledger.totalInsuranceChargesAccrued(), 0.2 ether);
        assertEq(ledger.totalProtocolDebt(), 9.2 ether);
    }

    function test_recordSettlementCost_updatesValue() external {
        _init();

        ledger.recordSettlementCost(POSITION_ID, 0.5 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.settlementCosts, 0.5 ether);
        assertEq(ledger.totalSettlementCosts(), 0.5 ether);
        assertEq(ledger.totalProtocolDebt(), 5.5 ether);
    }

    function test_repaySettlementCost_updatesValue() external {
        _init();
        ledger.recordSettlementCost(POSITION_ID, 0.5 ether);

        ledger.repaySettlementCost(POSITION_ID, 0.2 ether);

        DebtLedger.DebtRecord memory record = ledger.getDebtRecord(POSITION_ID);
        assertEq(record.settlementCosts, 0.3 ether);
        assertEq(ledger.totalSettlementCosts(), 0.3 ether);
        assertEq(ledger.totalProtocolDebt(), 5.3 ether);
    }

    function test_closeDebt_clearsAllValuesAndTotals() external {
        _init();
        ledger.accrueInterest(POSITION_ID, 1 ether);
        ledger.recordRescueUsage(POSITION_ID, 3 ether, 0.2 ether);
        ledger.recordInsuranceUsage(POSITION_ID, 4 ether, 0.3 ether);
        ledger.recordSettlementCost(POSITION_ID, 0.5 ether);

        ledger.closeDebt(POSITION_ID);

        assertEq(ledger.exists(POSITION_ID), false);
        assertEq(ledger.totalProtocolDebt(), 0);
        assertEq(ledger.totalPrincipal(), 0);
        assertEq(ledger.totalAccruedInterest(), 0);
        assertEq(ledger.totalRescueCapitalUsed(), 0);
        assertEq(ledger.totalRescueFeesAccrued(), 0);
        assertEq(ledger.totalInsuranceCapitalUsed(), 0);
        assertEq(ledger.totalInsuranceChargesAccrued(), 0);
        assertEq(ledger.totalSettlementCosts(), 0);
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

    function test_onlyAuthorized_canRecordRescueUsage() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.recordRescueUsage(POSITION_ID, 1 ether, 0.1 ether);
    }

    function test_onlyAuthorized_canRecordInsuranceUsage() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.recordInsuranceUsage(POSITION_ID, 1 ether, 0.1 ether);
    }

    function test_onlyAuthorized_canRecordSettlementCost() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(DebtLedger.NotAuthorized.selector);
        ledger.recordSettlementCost(POSITION_ID, 0.1 ether);
    }

    function _init() internal {
        ledger.initializeDebtRecord(POSITION_ID, 5 ether);
    }
}
