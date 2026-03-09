// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolverRegistry} from "src/remote/SolverRegistry.sol";

contract SolverRegistryTest is Test {
    SolverRegistry internal registry;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);
    address internal solver = address(0xCAFE);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        registry = new SolverRegistry(owner);
    }

    function test_approveSolver_storesValues() external {
        registry.approveSolver(solver, 150, 1_000_000);

        assertEq(registry.approvedSolver(solver), true);
        assertEq(registry.solverFeeCapBps(solver), 150);
        assertEq(registry.solverCapacityLimit(solver), 1_000_000);
        assertEq(registry.solverPaused(solver), false);
    }

    function test_approveSolver_revertsIfNotOwner() external {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.approveSolver(solver, 150, 1_000_000);
    }

    function test_approveSolver_revertsOnZeroAddress() external {
        vm.expectRevert(SolverRegistry.ZeroAddress.selector);
        registry.approveSolver(address(0), 150, 1_000_000);
    }

    function test_approveSolver_revertsOnInvalidBps() external {
        vm.expectRevert(
            abi.encodeWithSelector(SolverRegistry.InvalidBpsValue.selector, 10_001)
        );
        registry.approveSolver(solver, 10_001, 1_000_000);
    }

    function test_disableSolver_updatesState() external {
        registry.approveSolver(solver, 150, 1_000_000);
        registry.disableSolver(solver);

        assertEq(registry.approvedSolver(solver), false);
        assertEq(registry.solverPaused(solver), true);
    }

    function test_disableSolver_revertsIfNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(SolverRegistry.SolverNotApproved.selector, solver)
        );
        registry.disableSolver(solver);
    }

    function test_setSolverPaused_updatesValue() external {
        registry.approveSolver(solver, 150, 1_000_000);

        registry.setSolverPaused(solver, true);
        assertEq(registry.solverPaused(solver), true);

        registry.setSolverPaused(solver, false);
        assertEq(registry.solverPaused(solver), false);
    }

    function test_setSolverPaused_revertsIfNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(SolverRegistry.SolverNotApproved.selector, solver)
        );
        registry.setSolverPaused(solver, true);
    }

    function test_setSolverReputationScore_updatesValue() external {
        registry.approveSolver(solver, 150, 1_000_000);
        registry.setSolverReputationScore(solver, 87);

        assertEq(registry.solverReputationScore(solver), 87);
    }

    function test_setSolverReputationScore_revertsIfNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(SolverRegistry.SolverNotApproved.selector, solver)
        );
        registry.setSolverReputationScore(solver, 87);
    }

    function test_isApprovedSolver_trueOnlyWhenApprovedAndNotPaused() external {
        registry.approveSolver(solver, 150, 1_000_000);
        assertEq(registry.isApprovedSolver(solver), true);

        registry.setSolverPaused(solver, true);
        assertEq(registry.isApprovedSolver(solver), false);
    }

    function test_maxSolverFill_returnsCapacityWhenActive() external {
        registry.approveSolver(solver, 150, 1_000_000);
        assertEq(registry.maxSolverFill(solver, BTC), 1_000_000);
    }

    function test_maxSolverFill_returnsZeroWhenPaused() external {
        registry.approveSolver(solver, 150, 1_000_000);
        registry.setSolverPaused(solver, true);

        assertEq(registry.maxSolverFill(solver, BTC), 0);
    }

    function test_maxSolverFill_returnsZeroWhenNotApproved() external view {
        assertEq(registry.maxSolverFill(solver, BTC), 0);
    }
}
