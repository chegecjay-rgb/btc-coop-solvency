// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralManager is Ownable {
    error ZeroAddress();
    error NotAuthorized();
    error PositionNotFound(uint256 positionId);
    error InvalidAmount();
    error InsufficientAvailableCollateral(uint256 requested, uint256 available);
    error InsufficientLockedCollateral(uint256 requested, uint256 locked);
    error ReleaseFrozen(uint256 positionId);
    error AlreadyFrozen(uint256 positionId);
    error NotFrozen(uint256 positionId);
    error AlreadyInitialized(uint256 positionId);

    struct CollateralRecord {
        uint256 totalCollateral;
        uint256 lockedCollateral;
        uint256 transferredToStabilization;
        uint256 transferredToInsurance;
        bool releaseFrozen;
        bool initialized;
    }

    mapping(uint256 => CollateralRecord) private _collateralByPosition;
    mapping(address => bool) public authorizedWriter;

    uint256 public totalTrackedCollateral;
    uint256 public totalLockedCollateral;
    uint256 public totalTransferredToStabilization;
    uint256 public totalTransferredToInsurance;

    event AuthorizedWriterSet(address indexed writer, bool allowed);

    event CollateralRecordInitialized(
        uint256 indexed positionId,
        uint256 initialCollateral
    );

    event CollateralAdded(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newTotalCollateral
    );

    event CollateralLocked(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newLockedCollateral
    );

    event CollateralReleased(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newLockedCollateral
    );

    event ReleaseFrozenSet(uint256 indexed positionId, bool frozen);

    event CollateralTransferredToStabilization(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newTransferredToStabilization,
        uint256 newTotalCollateral,
        uint256 newLockedCollateral
    );

    event CollateralTransferredToInsurance(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newTransferredToInsurance,
        uint256 newTotalCollateral,
        uint256 newLockedCollateral
    );

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

    function initializeCollateralRecord(
        uint256 positionId,
        uint256 initialCollateral
    ) external onlyAuthorized {
        if (positionId == 0) revert PositionNotFound(positionId);
        if (_collateralByPosition[positionId].initialized) revert AlreadyInitialized(positionId);

        _collateralByPosition[positionId] = CollateralRecord({
            totalCollateral: initialCollateral,
            lockedCollateral: 0,
            transferredToStabilization: 0,
            transferredToInsurance: 0,
            releaseFrozen: false,
            initialized: true
        });

        totalTrackedCollateral += initialCollateral;

        emit CollateralRecordInitialized(positionId, initialCollateral);
    }

    function addCollateral(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        CollateralRecord storage record = _requireRecord(positionId);

        record.totalCollateral += amount;
        totalTrackedCollateral += amount;

        emit CollateralAdded(positionId, amount, record.totalCollateral);
    }

    function lockCollateral(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        CollateralRecord storage record = _requireRecord(positionId);

        uint256 available = availableCollateral(positionId);
        if (amount > available) {
            revert InsufficientAvailableCollateral(amount, available);
        }

        record.lockedCollateral += amount;
        totalLockedCollateral += amount;

        emit CollateralLocked(positionId, amount, record.lockedCollateral);
    }

    function releaseCollateral(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        CollateralRecord storage record = _requireRecord(positionId);

        if (record.releaseFrozen) revert ReleaseFrozen(positionId);
        if (amount > record.lockedCollateral) {
            revert InsufficientLockedCollateral(amount, record.lockedCollateral);
        }

        record.lockedCollateral -= amount;
        totalLockedCollateral -= amount;

        emit CollateralReleased(positionId, amount, record.lockedCollateral);
    }

    function freezeRelease(uint256 positionId) external onlyAuthorized {
        CollateralRecord storage record = _requireRecord(positionId);
        if (record.releaseFrozen) revert AlreadyFrozen(positionId);

        record.releaseFrozen = true;
        emit ReleaseFrozenSet(positionId, true);
    }

    function unfreezeRelease(uint256 positionId) external onlyAuthorized {
        CollateralRecord storage record = _requireRecord(positionId);
        if (!record.releaseFrozen) revert NotFrozen(positionId);

        record.releaseFrozen = false;
        emit ReleaseFrozenSet(positionId, false);
    }

    function transferToStabilization(
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        CollateralRecord storage record = _requireRecord(positionId);

        if (amount > record.lockedCollateral) {
            revert InsufficientLockedCollateral(amount, record.lockedCollateral);
        }

        record.lockedCollateral -= amount;
        record.totalCollateral -= amount;
        record.transferredToStabilization += amount;

        totalLockedCollateral -= amount;
        totalTrackedCollateral -= amount;
        totalTransferredToStabilization += amount;

        emit CollateralTransferredToStabilization(
            positionId,
            amount,
            record.transferredToStabilization,
            record.totalCollateral,
            record.lockedCollateral
        );
    }

    function transferToInsurance(
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        CollateralRecord storage record = _requireRecord(positionId);

        if (amount > record.lockedCollateral) {
            revert InsufficientLockedCollateral(amount, record.lockedCollateral);
        }

        record.lockedCollateral -= amount;
        record.totalCollateral -= amount;
        record.transferredToInsurance += amount;

        totalLockedCollateral -= amount;
        totalTrackedCollateral -= amount;
        totalTransferredToInsurance += amount;

        emit CollateralTransferredToInsurance(
            positionId,
            amount,
            record.transferredToInsurance,
            record.totalCollateral,
            record.lockedCollateral
        );
    }

    function getCollateralRecord(
        uint256 positionId
    ) external view returns (CollateralRecord memory) {
        return _requireRecord(positionId);
    }

    function exists(uint256 positionId) external view returns (bool) {
        return _collateralByPosition[positionId].initialized;
    }

    function availableCollateral(uint256 positionId) public view returns (uint256) {
        CollateralRecord storage record = _requireRecord(positionId);
        return record.totalCollateral - record.lockedCollateral;
    }

    function _requireRecord(
        uint256 positionId
    ) internal view returns (CollateralRecord storage record) {
        if (positionId == 0 || !_collateralByPosition[positionId].initialized) {
            revert PositionNotFound(positionId);
        }
        record = _collateralByPosition[positionId];
    }
}
