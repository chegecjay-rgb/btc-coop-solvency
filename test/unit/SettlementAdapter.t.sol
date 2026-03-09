// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementAdapter} from "src/remote/SettlementAdapter.sol";

contract SettlementAdapterTest is Test {
    SettlementAdapter internal adapter;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);
    address internal solver = address(0xCAFE);

    bytes32 internal constant ROUTE_ID = keccak256("ROUTE_A");
    bytes32 internal constant INTENT_ID = keccak256("INTENT_1");

    function setUp() external {
        adapter = new SettlementAdapter(owner);
    }

    function test_setApprovedRoute_storesValues() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);

        assertEq(adapter.approvedRoute(ROUTE_ID), true);
        assertEq(adapter.routeFeeCapBps(ROUTE_ID), 150);
    }

    function test_setApprovedRoute_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        adapter.setApprovedRoute(ROUTE_ID, 150, true);
    }

    function test_setApprovedRoute_revertsOnZeroRouteId() external {
        vm.expectRevert(SettlementAdapter.InvalidRouteId.selector);
        adapter.setApprovedRoute(bytes32(0), 150, true);
    }

    function test_setApprovedRoute_revertsOnInvalidBps() external {
        vm.expectRevert(
            abi.encodeWithSelector(SettlementAdapter.InvalidBpsValue.selector, 10_001)
        );
        adapter.setApprovedRoute(ROUTE_ID, 10_001, true);
    }

    function test_setRoutePaused_updatesValue() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);

        adapter.setRoutePaused(ROUTE_ID, true);
        assertEq(adapter.routePaused(ROUTE_ID), true);

        adapter.setRoutePaused(ROUTE_ID, false);
        assertEq(adapter.routePaused(ROUTE_ID), false);
    }

    function test_setRoutePaused_revertsIfRouteNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(SettlementAdapter.RouteNotApproved.selector, ROUTE_ID)
        );
        adapter.setRoutePaused(ROUTE_ID, true);
    }

    function test_verifyFill_storesVerification() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);

        bool ok = adapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);
        assertEq(ok, true);

        (
            bool verified,
            bool finalized,
            uint256 amount,
            bytes32 routeId,
            address storedSolver,
            SettlementAdapter.SettlementKind kind
        ) = adapter.fillByIntent(INTENT_ID);

        assertEq(verified, true);
        assertEq(finalized, false);
        assertEq(amount, 100e6);
        assertEq(routeId, ROUTE_ID);
        assertEq(storedSolver, solver);
        assertEq(uint256(kind), uint256(SettlementAdapter.SettlementKind.None));
    }

    function test_verifyFill_revertsIfRouteNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(SettlementAdapter.RouteNotApproved.selector, ROUTE_ID)
        );
        adapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);
    }

    function test_verifyFill_revertsIfRoutePaused() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);
        adapter.setRoutePaused(ROUTE_ID, true);

        vm.expectRevert(
            abi.encodeWithSelector(SettlementAdapter.RoutePaused.selector, ROUTE_ID)
        );
        adapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);
    }

    function test_verifyFill_revertsIfAlreadyVerified() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);
        adapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);

        vm.expectRevert(
            abi.encodeWithSelector(SettlementAdapter.FillAlreadyVerified.selector, INTENT_ID)
        );
        adapter.verifyFill(INTENT_ID, 50e6, ROUTE_ID, solver);
    }

    function test_settleBorrowFill_updatesKindAndFinalized() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);
        adapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);

        adapter.settleBorrowFill(INTENT_ID, 1);

        (
            bool verified,
            bool finalized,
            uint256 amount,
            bytes32 routeId,
            address storedSolver,
            SettlementAdapter.SettlementKind kind
        ) = adapter.fillByIntent(INTENT_ID);

        assertEq(verified, true);
        assertEq(finalized, true);
        assertEq(amount, 100e6);
        assertEq(routeId, ROUTE_ID);
        assertEq(storedSolver, solver);
        assertEq(uint256(kind), uint256(SettlementAdapter.SettlementKind.BorrowFill));
    }

    function test_settleRescueFill_updatesKindAndFinalized() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);
        adapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);

        adapter.settleRescueFill(INTENT_ID, 1);

        (
            ,
            bool finalized,
            ,
            ,
            ,
            SettlementAdapter.SettlementKind kind
        ) = adapter.fillByIntent(INTENT_ID);

        assertEq(finalized, true);
        assertEq(uint256(kind), uint256(SettlementAdapter.SettlementKind.RescueFill));
    }

    function test_settleRefinanceFill_updatesKindAndFinalized() external {
        adapter.setApprovedRoute(ROUTE_ID, 150, true);
        adapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);

        adapter.settleRefinanceFill(INTENT_ID, 1);

        (
            ,
            bool finalized,
            ,
            ,
            ,
            SettlementAdapter.SettlementKind kind
        ) = adapter.fillByIntent(INTENT_ID);

        assertEq(finalized, true);
        assertEq(uint256(kind), uint256(SettlementAdapter.SettlementKind.RefinanceFill));
    }

    function test_settle_revertsIfNotVerified() external {
        vm.expectRevert(
            abi.encodeWithSelector(SettlementAdapter.FillNotVerified.selector, INTENT_ID)
        );
        adapter.settleBorrowFill(INTENT_ID, 1);
    }

    function test_rejectFill_marksRejected() external {
        adapter.rejectFill(INTENT_ID);

        (
            ,
            bool finalized,
            ,
            ,
            ,
            SettlementAdapter.SettlementKind kind
        ) = adapter.fillByIntent(INTENT_ID);

        assertEq(finalized, true);
        assertEq(uint256(kind), uint256(SettlementAdapter.SettlementKind.Rejected));
    }

    function test_rejectFill_revertsIfAlreadyFinalized() external {
        adapter.rejectFill(INTENT_ID);

        vm.expectRevert(
            abi.encodeWithSelector(SettlementAdapter.IntentAlreadyFinalized.selector, INTENT_ID)
        );
        adapter.rejectFill(INTENT_ID);
    }
}
