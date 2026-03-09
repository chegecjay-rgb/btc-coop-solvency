// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CircuitBreaker is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error InvalidWindowDuration();
    error InvalidThreshold();
    error ProtocolPaused();
    error RescueVelocityExceeded(bytes32 assetId, uint256 current, uint256 maxAllowed);
    error RemoteIntentVelocityExceeded(bytes32 assetId, uint256 current, uint256 maxAllowed);

    bool public paused;
    uint256 public maxRescueVelocity;
    uint256 public maxTerminalSettlementsPerWindow;
    uint256 public maxRemoteIntentVelocity;
    uint256 public windowDuration;

    mapping(bytes32 => bool) public borrowingFrozenByAsset;

    mapping(bytes32 => uint256) public rescueVelocityByAsset;
    mapping(bytes32 => uint256) public remoteIntentVelocityByAsset;
    mapping(bytes32 => uint256) public rescueWindowStartByAsset;
    mapping(bytes32 => uint256) public remoteIntentWindowStartByAsset;

    uint256 public terminalSettlementsInWindow;
    uint256 public terminalSettlementWindowStart;

    mapping(address => bool) public authorizedOperator;

    event AuthorizedOperatorSet(address indexed operator, bool allowed);
    event Paused();
    event Unpaused();
    event BorrowingFrozen(bytes32 indexed assetId, bool frozen);
    event VelocityThresholdsSet(
        uint256 maxRescueVelocity,
        uint256 maxTerminalSettlementsPerWindow,
        uint256 maxRemoteIntentVelocity,
        uint256 windowDuration
    );
    event RescueVelocityRecorded(bytes32 indexed assetId, uint256 amount, uint256 newVelocity);
    event RemoteIntentVelocityRecorded(bytes32 indexed assetId, uint256 amount, uint256 newVelocity);
    event TerminalSettlementRecorded(uint256 newCount);

    constructor(
        address initialOwner,
        uint256 maxRescueVelocity_,
        uint256 maxTerminalSettlementsPerWindow_,
        uint256 maxRemoteIntentVelocity_,
        uint256 windowDuration_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (windowDuration_ == 0) revert InvalidWindowDuration();

        maxRescueVelocity = maxRescueVelocity_;
        maxTerminalSettlementsPerWindow = maxTerminalSettlementsPerWindow_;
        maxRemoteIntentVelocity = maxRemoteIntentVelocity_;
        windowDuration = windowDuration_;
        terminalSettlementWindowStart = block.timestamp;
    }

    modifier onlyAuthorized() {
        if (!(authorizedOperator[msg.sender] || msg.sender == owner())) revert ZeroAddress();
        _;
    }

    function setAuthorizedOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        authorizedOperator[operator] = allowed;
        emit AuthorizedOperatorSet(operator, allowed);
    }

    function setThresholds(
        uint256 maxRescueVelocity_,
        uint256 maxTerminalSettlementsPerWindow_,
        uint256 maxRemoteIntentVelocity_,
        uint256 windowDuration_
    ) external onlyOwner {
        if (windowDuration_ == 0) revert InvalidWindowDuration();

        maxRescueVelocity = maxRescueVelocity_;
        maxTerminalSettlementsPerWindow = maxTerminalSettlementsPerWindow_;
        maxRemoteIntentVelocity = maxRemoteIntentVelocity_;
        windowDuration = windowDuration_;

        emit VelocityThresholdsSet(
            maxRescueVelocity_,
            maxTerminalSettlementsPerWindow_,
            maxRemoteIntentVelocity_,
            windowDuration_
        );
    }

    function pause() external onlyAuthorized {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAuthorized {
        paused = false;
        emit Unpaused();
    }

    function freezeBorrowing(bytes32 assetId) external onlyAuthorized {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        borrowingFrozenByAsset[assetId] = true;
        emit BorrowingFrozen(assetId, true);
    }

    function unfreezeBorrowing(bytes32 assetId) external onlyAuthorized {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        borrowingFrozenByAsset[assetId] = false;
        emit BorrowingFrozen(assetId, false);
    }

    function checkRescueVelocity(bytes32 assetId) external view returns (bool) {
        if (paused) revert ProtocolPaused();
        if (assetId == bytes32(0)) revert InvalidAssetId();

        uint256 current = rescueVelocityByAsset[assetId];
        if (current > maxRescueVelocity) {
            revert RescueVelocityExceeded(assetId, current, maxRescueVelocity);
        }
        return true;
    }

    function checkRemoteIntentVelocity(bytes32 assetId) external view returns (bool) {
        if (paused) revert ProtocolPaused();
        if (assetId == bytes32(0)) revert InvalidAssetId();

        uint256 current = remoteIntentVelocityByAsset[assetId];
        if (current > maxRemoteIntentVelocity) {
            revert RemoteIntentVelocityExceeded(assetId, current, maxRemoteIntentVelocity);
        }
        return true;
    }

    function recordRescue(bytes32 assetId, uint256 amount) external onlyAuthorized {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (amount == 0) revert InvalidThreshold();

        _refreshRescueWindow(assetId);
        rescueVelocityByAsset[assetId] += amount;

        emit RescueVelocityRecorded(assetId, amount, rescueVelocityByAsset[assetId]);
    }

    function recordRemoteIntent(bytes32 assetId, uint256 amount) external onlyAuthorized {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (amount == 0) revert InvalidThreshold();

        _refreshRemoteIntentWindow(assetId);
        remoteIntentVelocityByAsset[assetId] += amount;

        emit RemoteIntentVelocityRecorded(assetId, amount, remoteIntentVelocityByAsset[assetId]);
    }

    function recordTerminalSettlement() external onlyAuthorized {
        _refreshTerminalSettlementWindow();
        terminalSettlementsInWindow += 1;
        emit TerminalSettlementRecorded(terminalSettlementsInWindow);
    }

    function isBorrowingFrozen(bytes32 assetId) external view returns (bool) {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        return paused || borrowingFrozenByAsset[assetId];
    }

    function _refreshRescueWindow(bytes32 assetId) internal {
        if (block.timestamp >= rescueWindowStartByAsset[assetId] + windowDuration) {
            rescueWindowStartByAsset[assetId] = block.timestamp;
            rescueVelocityByAsset[assetId] = 0;
        } else if (rescueWindowStartByAsset[assetId] == 0) {
            rescueWindowStartByAsset[assetId] = block.timestamp;
        }
    }

    function _refreshRemoteIntentWindow(bytes32 assetId) internal {
        if (block.timestamp >= remoteIntentWindowStartByAsset[assetId] + windowDuration) {
            remoteIntentWindowStartByAsset[assetId] = block.timestamp;
            remoteIntentVelocityByAsset[assetId] = 0;
        } else if (remoteIntentWindowStartByAsset[assetId] == 0) {
            remoteIntentWindowStartByAsset[assetId] = block.timestamp;
        }
    }

    function _refreshTerminalSettlementWindow() internal {
        if (block.timestamp >= terminalSettlementWindowStart + windowDuration) {
            terminalSettlementWindowStart = block.timestamp;
            terminalSettlementsInWindow = 0;
        }
    }
}
