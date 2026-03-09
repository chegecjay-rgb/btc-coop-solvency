// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ISolverRegistryForRouter {
    function isApprovedSolver(address solver) external view returns (bool);
    function solverFeeCapBps(address solver) external view returns (uint256);
    function maxSolverFill(address solver, bytes32 assetId) external view returns (uint256);
}

interface ISettlementAdapterForRouter {
    function fillByIntent(bytes32 intentId)
        external
        view
        returns (
            bool verified,
            bool finalized,
            uint256 amount,
            bytes32 routeId,
            address solver,
            uint8 kind
        );
}

contract RemoteLiquidityRouter is Ownable {
    error ZeroAddress();
    error InvalidIntentId();
    error InvalidAssetId();
    error InvalidAmount();
    error InvalidDeadline(uint256 deadline);
    error InvalidFeeBps(uint256 feeBps);
    error NotAuthorized();
    error IntentAlreadyExists(bytes32 intentId);
    error IntentNotFound(bytes32 intentId);
    error InvalidIntentState(bytes32 intentId);
    error IntentExpired(bytes32 intentId);
    error SolverNotApproved(address solver);
    error SolverFeeCapExceeded(uint256 feeBps, uint256 capBps);
    error IntentFeeCapExceeded(uint256 feeBps, uint256 capBps);
    error SolverCapacityExceeded(uint256 amount, uint256 capacity);
    error FillExceedsRemaining(uint256 amount, uint256 remaining);
    error SettlementNotFinalized(bytes32 intentId);
    error SettlementRejected(bytes32 intentId);
    error SettlementAmountExceedsVerified(uint256 amount, uint256 verifiedAmount);
    error SolverMismatch(address expected, address actual);

    enum RemoteIntentType {
        BorrowFill,
        RescueFill,
        Refinance
    }

    enum RemoteIntentState {
        Open,
        PartiallyFilled,
        Filled,
        Settled,
        Expired,
        Cancelled,
        Failed
    }

    struct RemoteLiquidityIntent {
        bytes32 intentId;
        bytes32 assetId;
        uint256 positionId;
        RemoteIntentType intentType;
        uint256 amountNeeded;
        uint256 amountFilled;
        uint256 maxFeeBps;
        uint256 deadline;
        address beneficiary;
        address settlementAsset;
        RemoteIntentState state;
        address winningSolver;
    }

    address public immutable solverRegistry;
    address public immutable settlementAdapter;

    mapping(bytes32 => RemoteLiquidityIntent) public intents;
    mapping(bytes32 => uint256) public pendingRemoteInbound;
    mapping(bytes32 => uint256) public committedRemoteInbound;
    mapping(bytes32 => uint256) public failedRemoteInbound;
    mapping(bytes32 => uint256) public remoteFeesAccrued;
    mapping(bytes32 => uint256) public settledAmountByIntent;
    mapping(address => bool) public authorizedOpener;

    event AuthorizedOpenerSet(address indexed opener, bool allowed);

    event IntentOpened(
        bytes32 indexed intentId,
        bytes32 indexed assetId,
        uint256 indexed positionId,
        RemoteIntentType intentType,
        uint256 amountNeeded,
        uint256 maxFeeBps,
        uint256 deadline,
        address beneficiary,
        address settlementAsset
    );

    event IntentFilled(
        bytes32 indexed intentId,
        address indexed solver,
        uint256 amount,
        uint256 feeBps,
        uint256 feeAmount,
        uint256 newAmountFilled,
        RemoteIntentState newState
    );

    event IntentSettled(
        bytes32 indexed intentId,
        uint256 amount,
        uint256 newSettledAmount,
        RemoteIntentState newState
    );

    event IntentExpiredEvent(bytes32 indexed intentId, uint256 failedAmount);
    event IntentCancelled(bytes32 indexed intentId, uint256 failedAmount);

    constructor(
        address initialOwner,
        address solverRegistry_,
        address settlementAdapter_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            solverRegistry_ == address(0) ||
            settlementAdapter_ == address(0)
        ) revert ZeroAddress();

        solverRegistry = solverRegistry_;
        settlementAdapter = settlementAdapter_;
    }

    modifier onlyAuthorizedOpener() {
        if (!(authorizedOpener[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    function setAuthorizedOpener(address opener, bool allowed) external onlyOwner {
        if (opener == address(0)) revert ZeroAddress();
        authorizedOpener[opener] = allowed;
        emit AuthorizedOpenerSet(opener, allowed);
    }

    function openIntent(
        bytes32 intentId,
        bytes32 assetId,
        uint256 positionId,
        RemoteIntentType intentType,
        uint256 amountNeeded,
        uint256 maxFeeBps,
        uint256 deadline,
        address beneficiary,
        address settlementAsset
    ) external onlyAuthorizedOpener {
        if (intentId == bytes32(0)) revert InvalidIntentId();
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (amountNeeded == 0) revert InvalidAmount();
        if (maxFeeBps > 10_000) revert InvalidFeeBps(maxFeeBps);
        if (deadline <= block.timestamp) revert InvalidDeadline(deadline);
        if (beneficiary == address(0) || settlementAsset == address(0)) revert ZeroAddress();
        if (intents[intentId].intentId != bytes32(0)) revert IntentAlreadyExists(intentId);

        intents[intentId] = RemoteLiquidityIntent({
            intentId: intentId,
            assetId: assetId,
            positionId: positionId,
            intentType: intentType,
            amountNeeded: amountNeeded,
            amountFilled: 0,
            maxFeeBps: maxFeeBps,
            deadline: deadline,
            beneficiary: beneficiary,
            settlementAsset: settlementAsset,
            state: RemoteIntentState.Open,
            winningSolver: address(0)
        });

        emit IntentOpened(
            intentId,
            assetId,
            positionId,
            intentType,
            amountNeeded,
            maxFeeBps,
            deadline,
            beneficiary,
            settlementAsset
        );
    }

    function fillIntent(bytes32 intentId, uint256 amount, uint256 feeBps) external {
        if (intentId == bytes32(0)) revert InvalidIntentId();
        if (amount == 0) revert InvalidAmount();
        if (!ISolverRegistryForRouter(solverRegistry).isApprovedSolver(msg.sender)) {
            revert SolverNotApproved(msg.sender);
        }

        RemoteLiquidityIntent storage intent = _requireIntent(intentId);

        if (block.timestamp > intent.deadline) revert IntentExpired(intentId);
        if (
            intent.state == RemoteIntentState.Settled ||
            intent.state == RemoteIntentState.Expired ||
            intent.state == RemoteIntentState.Cancelled ||
            intent.state == RemoteIntentState.Failed
        ) revert InvalidIntentState(intentId);

        uint256 solverCap = ISolverRegistryForRouter(solverRegistry).solverFeeCapBps(msg.sender);
        if (feeBps > solverCap) revert SolverFeeCapExceeded(feeBps, solverCap);
        if (feeBps > intent.maxFeeBps) revert IntentFeeCapExceeded(feeBps, intent.maxFeeBps);

        uint256 capacity = ISolverRegistryForRouter(solverRegistry).maxSolverFill(msg.sender, intent.assetId);
        if (amount > capacity) revert SolverCapacityExceeded(amount, capacity);

        if (intent.winningSolver == address(0)) {
            intent.winningSolver = msg.sender;
        } else if (intent.winningSolver != msg.sender) {
            revert SolverMismatch(intent.winningSolver, msg.sender);
        }

        uint256 remaining = intent.amountNeeded - intent.amountFilled;
        if (amount > remaining) revert FillExceedsRemaining(amount, remaining);

        intent.amountFilled += amount;
        pendingRemoteInbound[intent.assetId] += amount;

        uint256 feeAmount = (amount * feeBps) / 10_000;
        remoteFeesAccrued[intent.assetId] += feeAmount;

        if (intent.amountFilled == intent.amountNeeded) {
            intent.state = RemoteIntentState.Filled;
        } else {
            intent.state = RemoteIntentState.PartiallyFilled;
        }

        emit IntentFilled(
            intentId,
            msg.sender,
            amount,
            feeBps,
            feeAmount,
            intent.amountFilled,
            intent.state
        );
    }

    function settleIntent(bytes32 intentId, uint256 amount) external onlyAuthorizedOpener {
        if (intentId == bytes32(0)) revert InvalidIntentId();
        if (amount == 0) revert InvalidAmount();

        RemoteLiquidityIntent storage intent = _requireIntent(intentId);
        if (
            intent.state == RemoteIntentState.Expired ||
            intent.state == RemoteIntentState.Cancelled ||
            intent.state == RemoteIntentState.Failed ||
            intent.state == RemoteIntentState.Open
        ) revert InvalidIntentState(intentId);

        (
            bool verified,
            bool finalized,
            uint256 verifiedAmount,
            ,
            address verifiedSolver,
            uint8 kind
        ) = ISettlementAdapterForRouter(settlementAdapter).fillByIntent(intentId);

        if (!verified || !finalized) revert SettlementNotFinalized(intentId);
        if (kind == 4) revert SettlementRejected(intentId); // Rejected
        if (verifiedSolver != intent.winningSolver) {
            revert SolverMismatch(intent.winningSolver, verifiedSolver);
        }

        uint256 newSettled = settledAmountByIntent[intentId] + amount;
        if (newSettled > verifiedAmount) {
            revert SettlementAmountExceedsVerified(amount, verifiedAmount);
        }

        settledAmountByIntent[intentId] = newSettled;
        pendingRemoteInbound[intent.assetId] -= amount;
        committedRemoteInbound[intent.assetId] += amount;

        if (newSettled == intent.amountNeeded) {
            intent.state = RemoteIntentState.Settled;
        } else if (intent.amountFilled == intent.amountNeeded) {
            intent.state = RemoteIntentState.Filled;
        } else {
            intent.state = RemoteIntentState.PartiallyFilled;
        }

        emit IntentSettled(intentId, amount, newSettled, intent.state);
    }

    function expireIntent(bytes32 intentId) external onlyAuthorizedOpener {
        if (intentId == bytes32(0)) revert InvalidIntentId();

        RemoteLiquidityIntent storage intent = _requireIntent(intentId);
        if (block.timestamp <= intent.deadline) revert InvalidDeadline(intent.deadline);
        if (
            intent.state == RemoteIntentState.Settled ||
            intent.state == RemoteIntentState.Expired ||
            intent.state == RemoteIntentState.Cancelled
        ) revert InvalidIntentState(intentId);

        uint256 failedAmount = intent.amountNeeded - settledAmountByIntent[intentId];
        failedRemoteInbound[intent.assetId] += failedAmount;
        intent.state = RemoteIntentState.Expired;

        emit IntentExpiredEvent(intentId, failedAmount);
    }

    function cancelIntent(bytes32 intentId) external onlyAuthorizedOpener {
        if (intentId == bytes32(0)) revert InvalidIntentId();

        RemoteLiquidityIntent storage intent = _requireIntent(intentId);
        if (
            intent.state == RemoteIntentState.Settled ||
            intent.state == RemoteIntentState.Expired ||
            intent.state == RemoteIntentState.Cancelled
        ) revert InvalidIntentState(intentId);

        uint256 failedAmount = intent.amountNeeded - settledAmountByIntent[intentId];
        failedRemoteInbound[intent.assetId] += failedAmount;
        intent.state = RemoteIntentState.Cancelled;

        emit IntentCancelled(intentId, failedAmount);
    }

    function remainingAmount(bytes32 intentId) external view returns (uint256) {
        RemoteLiquidityIntent storage intent = _requireIntent(intentId);
        return intent.amountNeeded - intent.amountFilled;
    }

    function _requireIntent(bytes32 intentId)
        internal
        view
        returns (RemoteLiquidityIntent storage intent)
    {
        intent = intents[intentId];
        if (intent.intentId == bytes32(0)) revert IntentNotFound(intentId);
    }
}
