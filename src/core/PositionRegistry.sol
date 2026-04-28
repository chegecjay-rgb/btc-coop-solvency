// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CollateralRail} from "../types/CollateralRail.sol";

contract PositionRegistry is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error PositionNotFound(uint256 positionId);
    error NotAuthorized();
    error InvalidState();
    error NoActiveRemoteIntent();
    error RemoteIntentAlreadySet();
    error PositionAlreadyClosed(uint256 positionId);
    error InvalidCollateralRail(uint8 rail);

    enum PositionState {
        Healthy,
        AtRisk,
        RescueEligible,
        RemoteLiquidityPending,
        Rescued,
        Restricted,
        Terminal,
        Liquidatable,
        Closed
    }

    struct Position {
        address owner;
        bytes32 assetId;
        uint256 collateralAmount;
        uint256 debtPrincipal;
        PositionState state;
        uint256 rescueCount;
        uint256 lastRescueTime;
        bool hasBuybackCover;
        bytes32 activeRemoteIntentId;
        uint8 collateralRail;
    }

    mapping(uint256 => Position) private _positions;
    mapping(uint256 => PositionState) private _stateBeforeRemoteIntent;
    mapping(address => bool) public authorizedWriter;

    uint256 public nextPositionId = 1;

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event PositionCreated(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        bool hasBuybackCover
    );

    event PositionRailAssigned(uint256 indexed positionId, uint8 indexed collateralRail);
    event PositionStateUpdated(uint256 indexed positionId, PositionState newState);
    event PositionAmountsUpdated(uint256 indexed positionId, uint256 collateralAmount, uint256 debtPrincipal);
    event RescueCountIncremented(uint256 indexed positionId, uint256 newRescueCount);
    event BuybackCoverSet(uint256 indexed positionId, bool covered);
    event RemoteIntentBound(uint256 indexed positionId, bytes32 indexed intentId);
    event RemoteIntentCleared(uint256 indexed positionId);

    modifier onlyAuthorized() {
        if (!(authorizedWriter[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        authorizedWriter[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function createPosition(
        address positionOwner,
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        bool hasBuybackCover
    ) external onlyAuthorized returns (uint256 positionId) {
        positionId = _createPosition(
            positionOwner, assetId, collateralAmount, debtPrincipal, hasBuybackCover, CollateralRail.PROTOCOL_ESCROW
        );
    }

    function createPositionWithRail(
        address positionOwner,
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        bool hasBuybackCover,
        uint8 collateralRail
    ) external onlyAuthorized returns (uint256 positionId) {
        positionId = _createPosition(
            positionOwner, assetId, collateralAmount, debtPrincipal, hasBuybackCover, collateralRail
        );
    }

    function updateState(uint256 positionId, PositionState newState) external onlyAuthorized {
        Position storage position = _requireMutablePosition(positionId);
        position.state = newState;
        emit PositionStateUpdated(positionId, newState);
    }

    function updateAmounts(uint256 positionId, uint256 collateralAmount, uint256 debtPrincipal)
        external
        onlyAuthorized
    {
        Position storage position = _requireMutablePosition(positionId);
        position.collateralAmount = collateralAmount;
        position.debtPrincipal = debtPrincipal;
        emit PositionAmountsUpdated(positionId, collateralAmount, debtPrincipal);
    }

    function incrementRescueCount(uint256 positionId) external onlyAuthorized {
        Position storage position = _requireMutablePosition(positionId);
        position.rescueCount += 1;
        position.lastRescueTime = block.timestamp;
        emit RescueCountIncremented(positionId, position.rescueCount);
    }

    function setBuybackCover(uint256 positionId, bool covered) external onlyAuthorized {
        Position storage position = _requireMutablePosition(positionId);
        position.hasBuybackCover = covered;
        emit BuybackCoverSet(positionId, covered);
    }

    function bindRemoteIntent(uint256 positionId, bytes32 intentId) external onlyAuthorized {
        Position storage position = _requireMutablePosition(positionId);

        if (intentId == bytes32(0)) revert InvalidState();
        if (position.activeRemoteIntentId != bytes32(0)) revert RemoteIntentAlreadySet();

        _stateBeforeRemoteIntent[positionId] = position.state;
        position.activeRemoteIntentId = intentId;
        position.state = PositionState.RemoteLiquidityPending;

        emit RemoteIntentBound(positionId, intentId);
        emit PositionStateUpdated(positionId, PositionState.RemoteLiquidityPending);
    }

    function clearRemoteIntent(uint256 positionId) external onlyAuthorized {
        Position storage position = _requireMutablePosition(positionId);

        if (position.activeRemoteIntentId == bytes32(0)) revert NoActiveRemoteIntent();

        PositionState restoredState = _stateBeforeRemoteIntent[positionId];
        delete _stateBeforeRemoteIntent[positionId];

        position.activeRemoteIntentId = bytes32(0);
        emit RemoteIntentCleared(positionId);

        if (position.state == PositionState.RemoteLiquidityPending) {
            position.state = restoredState;
            emit PositionStateUpdated(positionId, restoredState);
        }
    }

    function closePosition(uint256 positionId) external onlyAuthorized {
        Position storage position = _requireMutablePosition(positionId);
        bool hadRemoteIntent = position.activeRemoteIntentId != bytes32(0);

        delete _stateBeforeRemoteIntent[positionId];

        position.collateralAmount = 0;
        position.debtPrincipal = 0;
        position.activeRemoteIntentId = bytes32(0);
        position.state = PositionState.Closed;

        if (hadRemoteIntent) {
            emit RemoteIntentCleared(positionId);
        }

        emit PositionAmountsUpdated(positionId, 0, 0);
        emit PositionStateUpdated(positionId, PositionState.Closed);
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return _requirePosition(positionId);
    }

    function ownerOfPosition(uint256 positionId) external view returns (address) {
        return _requirePosition(positionId).owner;
    }

    function collateralRailOf(uint256 positionId) external view returns (uint8) {
        return _requirePosition(positionId).collateralRail;
    }

    function isPositionOnRail(uint256 positionId, uint8 collateralRail) external view returns (bool) {
        if (!CollateralRail.isValid(collateralRail)) revert InvalidCollateralRail(collateralRail);
        return _requirePosition(positionId).collateralRail == collateralRail;
    }

    function exists(uint256 positionId) external view returns (bool) {
        return _positions[positionId].owner != address(0);
    }

    function _createPosition(
        address positionOwner,
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        bool hasBuybackCover,
        uint8 collateralRail
    ) internal returns (uint256 positionId) {
        if (positionOwner == address(0)) revert ZeroAddress();
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (!CollateralRail.isValid(collateralRail)) revert InvalidCollateralRail(collateralRail);

        positionId = nextPositionId++;
        _positions[positionId] = Position({
            owner: positionOwner,
            assetId: assetId,
            collateralAmount: collateralAmount,
            debtPrincipal: debtPrincipal,
            state: PositionState.Healthy,
            rescueCount: 0,
            lastRescueTime: 0,
            hasBuybackCover: hasBuybackCover,
            activeRemoteIntentId: bytes32(0),
            collateralRail: collateralRail
        });

        emit PositionCreated(positionId, positionOwner, assetId, collateralAmount, debtPrincipal, hasBuybackCover);
        emit PositionRailAssigned(positionId, collateralRail);
    }

    function _requirePosition(uint256 positionId) internal view returns (Position storage position) {
        position = _positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound(positionId);
    }

    function _requireMutablePosition(uint256 positionId) internal view returns (Position storage position) {
        position = _requirePosition(positionId);
        if (position.state == PositionState.Closed) revert PositionAlreadyClosed(positionId);
    }
}
