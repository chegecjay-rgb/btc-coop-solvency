// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PositionRegistry is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error PositionNotFound(uint256 positionId);
    error NotAuthorized();
    error InvalidState();
    error NoActiveRemoteIntent();
    error RemoteIntentAlreadySet();

    enum PositionState {
        Healthy,
        AtRisk,
        RescueEligible,
        RemoteFundingPending,
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
    }

    mapping(uint256 => Position) private _positions;
    uint256 public nextPositionId = 1;

    mapping(address => bool) public authorizedWriter;

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event PositionCreated(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        bool hasBuybackCover
    );
    event PositionStateUpdated(uint256 indexed positionId, PositionState newState);
    event PositionAmountsUpdated(
        uint256 indexed positionId,
        uint256 collateralAmount,
        uint256 debtPrincipal
    );
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
        if (positionOwner == address(0)) revert ZeroAddress();
        if (assetId == bytes32(0)) revert InvalidAssetId();

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
            activeRemoteIntentId: bytes32(0)
        });

        emit PositionCreated(
            positionId,
            positionOwner,
            assetId,
            collateralAmount,
            debtPrincipal,
            hasBuybackCover
        );
    }

    function updateState(uint256 positionId, PositionState newState) external onlyAuthorized {
        Position storage position = _requirePosition(positionId);
        position.state = newState;
        emit PositionStateUpdated(positionId, newState);
    }

    function updateAmounts(
        uint256 positionId,
        uint256 collateralAmount,
        uint256 debtPrincipal
    ) external onlyAuthorized {
        Position storage position = _requirePosition(positionId);
        position.collateralAmount = collateralAmount;
        position.debtPrincipal = debtPrincipal;
        emit PositionAmountsUpdated(positionId, collateralAmount, debtPrincipal);
    }

    function incrementRescueCount(uint256 positionId) external onlyAuthorized {
        Position storage position = _requirePosition(positionId);
        position.rescueCount += 1;
        position.lastRescueTime = block.timestamp;
        emit RescueCountIncremented(positionId, position.rescueCount);
    }

    function setBuybackCover(uint256 positionId, bool covered) external onlyAuthorized {
        Position storage position = _requirePosition(positionId);
        position.hasBuybackCover = covered;
        emit BuybackCoverSet(positionId, covered);
    }

    function bindRemoteIntent(uint256 positionId, bytes32 intentId) external onlyAuthorized {
        Position storage position = _requirePosition(positionId);
        if (intentId == bytes32(0)) revert InvalidState();
        if (position.activeRemoteIntentId != bytes32(0)) revert RemoteIntentAlreadySet();

        position.activeRemoteIntentId = intentId;
        position.state = PositionState.RemoteFundingPending;

        emit RemoteIntentBound(positionId, intentId);
        emit PositionStateUpdated(positionId, PositionState.RemoteFundingPending);
    }

    function clearRemoteIntent(uint256 positionId) external onlyAuthorized {
        Position storage position = _requirePosition(positionId);
        if (position.activeRemoteIntentId == bytes32(0)) revert NoActiveRemoteIntent();

        position.activeRemoteIntentId = bytes32(0);
        emit RemoteIntentCleared(positionId);
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return _requirePosition(positionId);
    }

    function ownerOfPosition(uint256 positionId) external view returns (address) {
        return _requirePosition(positionId).owner;
    }

    function exists(uint256 positionId) external view returns (bool) {
        return _positions[positionId].owner != address(0);
    }

    function _requirePosition(uint256 positionId) internal view returns (Position storage position) {
        position = _positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound(positionId);
    }
}
