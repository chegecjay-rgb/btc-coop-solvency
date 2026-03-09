// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RemoteLiquidityRouter} from "src/remote/RemoteLiquidityRouter.sol";
import {SolverRegistry} from "src/remote/SolverRegistry.sol";
import {SettlementAdapter} from "src/remote/SettlementAdapter.sol";

contract RemoteLiquidityRouterTest is Test {
    RemoteLiquidityRouter internal router;
    SolverRegistry internal solverRegistry;
    SettlementAdapter internal settlementAdapter;

    address internal owner = address(this);
    address internal opener = address(0xABCD);
    address internal nonAuthorized = address(0xBEEF);
    address internal solver = address(0xCAFE);
    address internal beneficiary = address(0x1234);
    address internal settlementAsset = address(0x5678);

    bytes32 internal constant BTC = keccak256("BTC");
    bytes32 internal constant ROUTE_ID = keccak256("ROUTE_A");
    bytes32 internal constant INTENT_ID = keccak256("INTENT_1");

    function setUp() external {
        solverRegistry = new SolverRegistry(owner);
        settlementAdapter = new SettlementAdapter(owner);
        router = new RemoteLiquidityRouter(
            owner,
            address(solverRegistry),
            address(settlementAdapter)
        );

        router.setAuthorizedOpener(opener, true);
        solverRegistry.approveSolver(solver, 150, 1_000_000e6);
        settlementAdapter.setApprovedRoute(ROUTE_ID, 150, true);
    }

    function test_openIntent_storesValues() external {
        vm.prank(opener);
        router.openIntent(
            INTENT_ID,
            BTC,
            1,
            RemoteLiquidityRouter.RemoteIntentType.BorrowFill,
            100e6,
            120,
            block.timestamp + 1 hours,
            beneficiary,
            settlementAsset
        );

        (
            bytes32 intentId,
            bytes32 assetId,
            uint256 positionId,
            RemoteLiquidityRouter.RemoteIntentType intentType,
            uint256 amountNeeded,
            uint256 amountFilled,
            uint256 maxFeeBps,
            uint256 deadline,
            address storedBeneficiary,
            address storedSettlementAsset,
            RemoteLiquidityRouter.RemoteIntentState state,
            address winningSolver
        ) = router.intents(INTENT_ID);

        assertEq(intentId, INTENT_ID);
        assertEq(assetId, BTC);
        assertEq(positionId, 1);
        assertEq(uint256(intentType), uint256(RemoteLiquidityRouter.RemoteIntentType.BorrowFill));
        assertEq(amountNeeded, 100e6);
        assertEq(amountFilled, 0);
        assertEq(maxFeeBps, 120);
        assertGt(deadline, block.timestamp);
        assertEq(storedBeneficiary, beneficiary);
        assertEq(storedSettlementAsset, settlementAsset);
        assertEq(uint256(state), uint256(RemoteLiquidityRouter.RemoteIntentState.Open));
        assertEq(winningSolver, address(0));
    }

    function test_openIntent_revertsIfNotAuthorized() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(RemoteLiquidityRouter.NotAuthorized.selector);
        router.openIntent(
            INTENT_ID,
            BTC,
            1,
            RemoteLiquidityRouter.RemoteIntentType.BorrowFill,
            100e6,
            120,
            block.timestamp + 1 hours,
            beneficiary,
            settlementAsset
        );
    }

    function test_fillIntent_updatesPendingAndFees() external {
        _openIntent(100e6, 120);

        vm.prank(solver);
        router.fillIntent(INTENT_ID, 40e6, 100);

        assertEq(router.pendingRemoteInbound(BTC), 40e6);
        assertEq(router.remoteFeesAccrued(BTC), 400_000); // 40e6 * 100 bps / 10000

        (
            ,
            ,
            ,
            ,
            ,
            uint256 amountFilled,
            ,
            ,
            ,
            ,
            RemoteLiquidityRouter.RemoteIntentState state,
            address winningSolver
        ) = router.intents(INTENT_ID);

        assertEq(amountFilled, 40e6);
        assertEq(uint256(state), uint256(RemoteLiquidityRouter.RemoteIntentState.PartiallyFilled));
        assertEq(winningSolver, solver);
    }

    function test_fillIntent_revertsIfSolverNotApproved() external {
        _openIntent(100e6, 120);

        vm.prank(nonAuthorized);
        vm.expectRevert(
            abi.encodeWithSelector(RemoteLiquidityRouter.SolverNotApproved.selector, nonAuthorized)
        );
        router.fillIntent(INTENT_ID, 10e6, 100);
    }

    function test_fillIntent_revertsIfIntentFeeCapExceeded() external {
        _openIntent(100e6, 80);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(RemoteLiquidityRouter.IntentFeeCapExceeded.selector, 100, 80)
        );
        router.fillIntent(INTENT_ID, 10e6, 100);
    }

    function test_fillIntent_revertsIfSolverFeeCapExceeded() external {
        _openIntent(100e6, 200);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(RemoteLiquidityRouter.SolverFeeCapExceeded.selector, 200, 150)
        );
        router.fillIntent(INTENT_ID, 10e6, 200);
    }

    function test_fillIntent_revertsIfCapacityExceeded() external {
        _openIntent(2_000_000e6, 120);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                RemoteLiquidityRouter.SolverCapacityExceeded.selector,
                2_000_000e6,
                1_000_000e6
            )
        );
        router.fillIntent(INTENT_ID, 2_000_000e6, 100);
    }

    function test_fillIntent_revertsIfFillExceedsRemaining() external {
        _openIntent(100e6, 120);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(RemoteLiquidityRouter.FillExceedsRemaining.selector, 110e6, 100e6)
        );
        router.fillIntent(INTENT_ID, 110e6, 100);
    }

    function test_fillIntent_setsFilledWhenComplete() external {
        _openIntent(100e6, 120);

        vm.prank(solver);
        router.fillIntent(INTENT_ID, 100e6, 100);

        (, , , , , uint256 amountFilled, , , , , RemoteLiquidityRouter.RemoteIntentState state, ) =
            router.intents(INTENT_ID);

        assertEq(amountFilled, 100e6);
        assertEq(uint256(state), uint256(RemoteLiquidityRouter.RemoteIntentState.Filled));
    }

    function test_settleIntent_requiresAdapterFinalization() external {
        _openIntent(100e6, 120);

        vm.prank(solver);
        router.fillIntent(INTENT_ID, 100e6, 100);

        vm.prank(opener);
        vm.expectRevert(
            abi.encodeWithSelector(RemoteLiquidityRouter.SettlementNotFinalized.selector, INTENT_ID)
        );
        router.settleIntent(INTENT_ID, 100e6);
    }

    function test_settleIntent_updatesCommittedAndState() external {
        _openIntent(100e6, 120);

        vm.prank(solver);
        router.fillIntent(INTENT_ID, 100e6, 100);

        settlementAdapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);
        settlementAdapter.settleBorrowFill(INTENT_ID, 1);

        vm.prank(opener);
        router.settleIntent(INTENT_ID, 100e6);

        assertEq(router.pendingRemoteInbound(BTC), 0);
        assertEq(router.committedRemoteInbound(BTC), 100e6);
        assertEq(router.settledAmountByIntent(INTENT_ID), 100e6);

        (, , , , , , , , , , RemoteLiquidityRouter.RemoteIntentState state, ) =
            router.intents(INTENT_ID);

        assertEq(uint256(state), uint256(RemoteLiquidityRouter.RemoteIntentState.Settled));
    }

    function test_settleIntent_revertsIfRejected() external {
        _openIntent(100e6, 120);

        vm.prank(solver);
        router.fillIntent(INTENT_ID, 100e6, 100);

        settlementAdapter.verifyFill(INTENT_ID, 100e6, ROUTE_ID, solver);
        settlementAdapter.rejectFill(INTENT_ID);

        vm.prank(opener);
        vm.expectRevert(
            abi.encodeWithSelector(RemoteLiquidityRouter.SettlementRejected.selector, INTENT_ID)
        );
        router.settleIntent(INTENT_ID, 100e6);
    }

    function test_expireIntent_marksExpiredAndFailed() external {
        _openIntent(100e6, 120);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(opener);
        router.expireIntent(INTENT_ID);

        assertEq(router.failedRemoteInbound(BTC), 100e6);

        (, , , , , , , , , , RemoteLiquidityRouter.RemoteIntentState state, ) =
            router.intents(INTENT_ID);

        assertEq(uint256(state), uint256(RemoteLiquidityRouter.RemoteIntentState.Expired));
    }

    function test_cancelIntent_marksCancelledAndFailed() external {
        _openIntent(100e6, 120);

        vm.prank(opener);
        router.cancelIntent(INTENT_ID);

        assertEq(router.failedRemoteInbound(BTC), 100e6);

        (, , , , , , , , , , RemoteLiquidityRouter.RemoteIntentState state, ) =
            router.intents(INTENT_ID);

        assertEq(uint256(state), uint256(RemoteLiquidityRouter.RemoteIntentState.Cancelled));
    }

    function test_remainingAmount_returnsExpected() external {
        _openIntent(100e6, 120);

        vm.prank(solver);
        router.fillIntent(INTENT_ID, 40e6, 100);

        assertEq(router.remainingAmount(INTENT_ID), 60e6);
    }

    function _openIntent(uint256 amountNeeded, uint256 maxFeeBps) internal {
        vm.prank(opener);
        router.openIntent(
            INTENT_ID,
            BTC,
            1,
            RemoteLiquidityRouter.RemoteIntentType.BorrowFill,
            amountNeeded,
            maxFeeBps,
            block.timestamp + 1 hours,
            beneficiary,
            settlementAsset
        );
    }
}
