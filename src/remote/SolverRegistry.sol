// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SolverRegistry is Ownable {
    error ZeroAddress();
    error InvalidBpsValue(uint256 value);
    error SolverNotApproved(address solver);

    mapping(address => bool) public approvedSolver;
    mapping(address => uint256) public solverFeeCapBps;
    mapping(address => uint256) public solverCapacityLimit;
    mapping(address => bool) public solverPaused;
    mapping(address => uint256) public solverReputationScore;

    event SolverApproved(
        address indexed solver,
        uint256 feeCapBps,
        uint256 capacityLimit
    );

    event SolverDisabled(address indexed solver);
    event SolverPausedSet(address indexed solver, bool paused);
    event SolverReputationScoreSet(address indexed solver, uint256 score);

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function approveSolver(
        address solver,
        uint256 feeCapBps,
        uint256 capacityLimit
    ) external onlyOwner {
        if (solver == address(0)) revert ZeroAddress();
        if (feeCapBps > 10_000) revert InvalidBpsValue(feeCapBps);

        approvedSolver[solver] = true;
        solverFeeCapBps[solver] = feeCapBps;
        solverCapacityLimit[solver] = capacityLimit;
        solverPaused[solver] = false;

        emit SolverApproved(solver, feeCapBps, capacityLimit);
    }

    function disableSolver(address solver) external onlyOwner {
        if (solver == address(0)) revert ZeroAddress();
        if (!approvedSolver[solver]) revert SolverNotApproved(solver);

        approvedSolver[solver] = false;
        solverPaused[solver] = true;

        emit SolverDisabled(solver);
    }

    function setSolverPaused(address solver, bool paused) external onlyOwner {
        if (solver == address(0)) revert ZeroAddress();
        if (!approvedSolver[solver]) revert SolverNotApproved(solver);

        solverPaused[solver] = paused;
        emit SolverPausedSet(solver, paused);
    }

    function setSolverReputationScore(address solver, uint256 score) external onlyOwner {
        if (solver == address(0)) revert ZeroAddress();
        if (!approvedSolver[solver]) revert SolverNotApproved(solver);

        solverReputationScore[solver] = score;
        emit SolverReputationScoreSet(solver, score);
    }

    function isApprovedSolver(address solver) external view returns (bool) {
        return approvedSolver[solver] && !solverPaused[solver];
    }

    function maxSolverFill(address solver, bytes32) external view returns (uint256) {
        if (!approvedSolver[solver] || solverPaused[solver]) {
            return 0;
        }
        return solverCapacityLimit[solver];
    }
}
