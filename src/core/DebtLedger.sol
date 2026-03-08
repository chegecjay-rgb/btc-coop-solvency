// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DebtLedger is Ownable {
    error ZeroAddress();
    error NotAuthorized();
    error PositionNotFound(uint256 positionId);
    error InvalidAmount();
    error RepayExceedsPrincipal(uint256 repayment, uint256 principal);
    error InterestRepayExceedsAccrued(uint256 repayment, uint256 accruedInterest);
    error RescueFeeRepayExceedsAccrued(uint256 repayment, uint256 accruedFee);
    error RemoteFundingRepayExceedsPending(uint256 repayment, uint256 pendingFunding);
    error RemoteFundingFeeRepayExceedsAccrued(uint256 repayment, uint256 accruedFee);
    error RemoteRescueRepayExceedsPending(uint256 repayment, uint256 pendingObligation);

    struct DebtRecord {
        uint256 principal;
        uint256 accruedInterest;
        uint256 rescueObligation;
        uint256 rescueFeesAccrued;
        uint256 pendingRemoteFunding;
        uint256 remoteFundingFees;
        uint256 remoteRescueObligation;
        uint256 lastAccrualTime;
    }

    mapping(uint256 => DebtRecord) private _debtByPosition;
    mapping(address => bool) public authorizedWriter;

    uint256 public totalProtocolPrincipal;
    uint256 public totalAccruedInterest;
    uint256 public totalRescueObligation;
    uint256 public totalRescueFees;
    uint256 public totalPendingRemoteFunding;
    uint256 public totalRemoteFundingFees;
    uint256 public totalRemoteRescueObligation;

    event AuthorizedWriterSet(address indexed writer, bool allowed);

    event DebtRecordInitialized(
        uint256 indexed positionId,
        uint256 principal,
        uint256 lastAccrualTime
    );

    event PrincipalIncreased(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newPrincipal
    );

    event PrincipalRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newPrincipal
    );

    event InterestAccrued(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newAccruedInterest,
        uint256 accrualTimestamp
    );

    event InterestRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newAccruedInterest
    );

    event RescueObligationAdded(
        uint256 indexed positionId,
        uint256 obligationAmount,
        uint256 feeAmount,
        uint256 newRescueObligation,
        uint256 newRescueFeesAccrued
    );

    event RescueObligationRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRescueObligation
    );

    event RescueFeeRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRescueFeesAccrued
    );

    event PendingRemoteFundingAdded(
        uint256 indexed positionId,
        uint256 fundingAmount,
        uint256 feeAmount,
        uint256 newPendingRemoteFunding,
        uint256 newRemoteFundingFees
    );

    event PendingRemoteFundingCleared(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newPendingRemoteFunding
    );

    event RemoteFundingFeeRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRemoteFundingFees
    );

    event RemoteRescueObligationAdded(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRemoteRescueObligation
    );

    event RemoteRescueObligationRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRemoteRescueObligation
    );

    event DebtClosed(uint256 indexed positionId);

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

    function initializeDebtRecord(
        uint256 positionId,
        uint256 principalAmount
    ) external onlyAuthorized {
        if (positionId == 0) revert PositionNotFound(positionId);
        DebtRecord storage record = _debtByPosition[positionId];
        if (_exists(positionId)) revert InvalidAmount();

        record.principal = principalAmount;
        record.lastAccrualTime = block.timestamp;

        totalProtocolPrincipal += principalAmount;

        emit DebtRecordInitialized(positionId, principalAmount, block.timestamp);
    }

    function increaseDebt(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.principal += amount;
        totalProtocolPrincipal += amount;

        emit PrincipalIncreased(positionId, amount, record.principal);
    }

    function repayDebt(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);
        if (amount > record.principal) {
            revert RepayExceedsPrincipal(amount, record.principal);
        }

        record.principal -= amount;
        totalProtocolPrincipal -= amount;

        emit PrincipalRepaid(positionId, amount, record.principal);
    }

    function accrueInterest(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.accruedInterest += amount;
        record.lastAccrualTime = block.timestamp;
        totalAccruedInterest += amount;

        emit InterestAccrued(
            positionId,
            amount,
            record.accruedInterest,
            block.timestamp
        );
    }

    function repayInterest(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);
        if (amount > record.accruedInterest) {
            revert InterestRepayExceedsAccrued(amount, record.accruedInterest);
        }

        record.accruedInterest -= amount;
        totalAccruedInterest -= amount;

        emit InterestRepaid(positionId, amount, record.accruedInterest);
    }

    function addRescueObligation(
        uint256 positionId,
        uint256 obligationAmount,
        uint256 feeAmount
    ) external onlyAuthorized {
        if (obligationAmount == 0 && feeAmount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.rescueObligation += obligationAmount;
        record.rescueFeesAccrued += feeAmount;

        totalRescueObligation += obligationAmount;
        totalRescueFees += feeAmount;

        emit RescueObligationAdded(
            positionId,
            obligationAmount,
            feeAmount,
            record.rescueObligation,
            record.rescueFeesAccrued
        );
    }

    function repayRescueObligation(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);
        if (amount > record.rescueObligation) {
            revert RemoteRescueRepayExceedsPending(amount, record.rescueObligation);
        }

        record.rescueObligation -= amount;
        totalRescueObligation -= amount;

        emit RescueObligationRepaid(positionId, amount, record.rescueObligation);
    }

    function repayRescueFee(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);
        if (amount > record.rescueFeesAccrued) {
            revert RescueFeeRepayExceedsAccrued(amount, record.rescueFeesAccrued);
        }

        record.rescueFeesAccrued -= amount;
        totalRescueFees -= amount;

        emit RescueFeeRepaid(positionId, amount, record.rescueFeesAccrued);
    }

    function addPendingRemoteFunding(
        uint256 positionId,
        uint256 fundingAmount,
        uint256 feeAmount
    ) external onlyAuthorized {
        if (fundingAmount == 0 && feeAmount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.pendingRemoteFunding += fundingAmount;
        record.remoteFundingFees += feeAmount;

        totalPendingRemoteFunding += fundingAmount;
        totalRemoteFundingFees += feeAmount;

        emit PendingRemoteFundingAdded(
            positionId,
            fundingAmount,
            feeAmount,
            record.pendingRemoteFunding,
            record.remoteFundingFees
        );
    }

    function clearPendingRemoteFunding(
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);
        if (amount > record.pendingRemoteFunding) {
            revert RemoteFundingRepayExceedsPending(amount, record.pendingRemoteFunding);
        }

        record.pendingRemoteFunding -= amount;
        totalPendingRemoteFunding -= amount;

        emit PendingRemoteFundingCleared(positionId, amount, record.pendingRemoteFunding);
    }

    function repayRemoteFundingFee(
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);
        if (amount > record.remoteFundingFees) {
            revert RemoteFundingFeeRepayExceedsAccrued(amount, record.remoteFundingFees);
        }

        record.remoteFundingFees -= amount;
        totalRemoteFundingFees -= amount;

        emit RemoteFundingFeeRepaid(positionId, amount, record.remoteFundingFees);
    }

    function addRemoteRescueObligation(
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.remoteRescueObligation += amount;
        totalRemoteRescueObligation += amount;

        emit RemoteRescueObligationAdded(
            positionId,
            amount,
            record.remoteRescueObligation
        );
    }

    function repayRemoteRescueObligation(
        uint256 positionId,
        uint256 amount
    ) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);
        if (amount > record.remoteRescueObligation) {
            revert RemoteRescueRepayExceedsPending(amount, record.remoteRescueObligation);
        }

        record.remoteRescueObligation -= amount;
        totalRemoteRescueObligation -= amount;

        emit RemoteRescueObligationRepaid(
            positionId,
            amount,
            record.remoteRescueObligation
        );
    }

    function closeDebt(uint256 positionId) external onlyAuthorized {
        DebtRecord storage record = _requireDebtRecord(positionId);

        totalProtocolPrincipal -= record.principal;
        totalAccruedInterest -= record.accruedInterest;
        totalRescueObligation -= record.rescueObligation;
        totalRescueFees -= record.rescueFeesAccrued;
        totalPendingRemoteFunding -= record.pendingRemoteFunding;
        totalRemoteFundingFees -= record.remoteFundingFees;
        totalRemoteRescueObligation -= record.remoteRescueObligation;

        delete _debtByPosition[positionId];

        emit DebtClosed(positionId);
    }

    function getDebtRecord(uint256 positionId) external view returns (DebtRecord memory) {
        DebtRecord memory record = _debtByPosition[positionId];
        if (!_exists(positionId)) revert PositionNotFound(positionId);
        return record;
    }

    function exists(uint256 positionId) external view returns (bool) {
        return _exists(positionId);
    }

    function _requireDebtRecord(uint256 positionId) internal view returns (DebtRecord storage record) {
        if (!_exists(positionId)) revert PositionNotFound(positionId);
        record = _debtByPosition[positionId];
    }

    function _exists(uint256 positionId) internal view returns (bool) {
        return positionId != 0 && _debtByPosition[positionId].lastAccrualTime != 0;
    }
}
