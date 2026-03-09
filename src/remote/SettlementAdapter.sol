// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SettlementAdapter is Ownable {
    error ZeroAddress();
    error InvalidRouteId();
    error InvalidIntentId();
    error InvalidAmount();
    error InvalidBpsValue(uint256 value);
    error RouteNotApproved(bytes32 routeId);
    error RoutePaused(bytes32 routeId);
    error FillNotVerified(bytes32 intentId);
    error FillAlreadyVerified(bytes32 intentId);
    error IntentAlreadyFinalized(bytes32 intentId);

    enum SettlementKind {
        None,
        BorrowFill,
        RescueFill,
        RefinanceFill,
        Rejected
    }

    struct FillVerification {
        bool verified;
        bool finalized;
        uint256 amount;
        bytes32 routeId;
        address solver;
        SettlementKind kind;
    }

    mapping(bytes32 => bool) public approvedRoute;
    mapping(bytes32 => uint256) public routeFeeCapBps;
    mapping(bytes32 => bool) public routePaused;
    mapping(bytes32 => FillVerification) public fillByIntent;

    event ApprovedRouteSet(bytes32 indexed routeId, uint256 feeCapBps, bool approved);
    event RoutePausedSet(bytes32 indexed routeId, bool paused);

    event FillVerified(
        bytes32 indexed intentId,
        uint256 amount,
        bytes32 indexed routeId,
        address indexed solver
    );

    event BorrowFillSettled(bytes32 indexed intentId, uint256 indexed positionId, uint256 amount);
    event RescueFillSettled(bytes32 indexed intentId, uint256 indexed positionId, uint256 amount);
    event RefinanceFillSettled(bytes32 indexed intentId, uint256 indexed positionId, uint256 amount);
    event FillRejected(bytes32 indexed intentId);

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function setApprovedRoute(
        bytes32 routeId,
        uint256 feeCapBps,
        bool approved
    ) external onlyOwner {
        if (routeId == bytes32(0)) revert InvalidRouteId();
        if (feeCapBps > 10_000) revert InvalidBpsValue(feeCapBps);

        approvedRoute[routeId] = approved;
        routeFeeCapBps[routeId] = feeCapBps;

        emit ApprovedRouteSet(routeId, feeCapBps, approved);
    }

    function setRoutePaused(bytes32 routeId, bool paused) external onlyOwner {
        if (routeId == bytes32(0)) revert InvalidRouteId();
        if (!approvedRoute[routeId]) revert RouteNotApproved(routeId);

        routePaused[routeId] = paused;
        emit RoutePausedSet(routeId, paused);
    }

    function verifyFill(
        bytes32 intentId,
        uint256 amount,
        bytes32 routeId,
        address solver
    ) external returns (bool) {
        if (intentId == bytes32(0)) revert InvalidIntentId();
        if (amount == 0) revert InvalidAmount();
        if (routeId == bytes32(0)) revert InvalidRouteId();
        if (solver == address(0)) revert ZeroAddress();
        if (!approvedRoute[routeId]) revert RouteNotApproved(routeId);
        if (routePaused[routeId]) revert RoutePaused(routeId);

        FillVerification storage fill = fillByIntent[intentId];
        if (fill.verified) revert FillAlreadyVerified(intentId);
        if (fill.finalized) revert IntentAlreadyFinalized(intentId);

        fill.verified = true;
        fill.amount = amount;
        fill.routeId = routeId;
        fill.solver = solver;
        fill.kind = SettlementKind.None;

        emit FillVerified(intentId, amount, routeId, solver);
        return true;
    }

    function settleBorrowFill(bytes32 intentId, uint256 positionId) external {
        if (intentId == bytes32(0)) revert InvalidIntentId();
        FillVerification storage fill = _requireVerified(intentId);
        if (fill.finalized) revert IntentAlreadyFinalized(intentId);

        fill.finalized = true;
        fill.kind = SettlementKind.BorrowFill;

        emit BorrowFillSettled(intentId, positionId, fill.amount);
    }

    function settleRescueFill(bytes32 intentId, uint256 positionId) external {
        if (intentId == bytes32(0)) revert InvalidIntentId();
        FillVerification storage fill = _requireVerified(intentId);
        if (fill.finalized) revert IntentAlreadyFinalized(intentId);

        fill.finalized = true;
        fill.kind = SettlementKind.RescueFill;

        emit RescueFillSettled(intentId, positionId, fill.amount);
    }

    function settleRefinanceFill(bytes32 intentId, uint256 positionId) external {
        if (intentId == bytes32(0)) revert InvalidIntentId();
        FillVerification storage fill = _requireVerified(intentId);
        if (fill.finalized) revert IntentAlreadyFinalized(intentId);

        fill.finalized = true;
        fill.kind = SettlementKind.RefinanceFill;

        emit RefinanceFillSettled(intentId, positionId, fill.amount);
    }

    function rejectFill(bytes32 intentId) external {
        if (intentId == bytes32(0)) revert InvalidIntentId();

        FillVerification storage fill = fillByIntent[intentId];
        if (fill.finalized) revert IntentAlreadyFinalized(intentId);

        fill.finalized = true;
        fill.kind = SettlementKind.Rejected;

        emit FillRejected(intentId);
    }

    function _requireVerified(bytes32 intentId)
        internal
        view
        returns (FillVerification storage fill)
    {
        fill = fillByIntent[intentId];
        if (!fill.verified) revert FillNotVerified(intentId);
    }
}
