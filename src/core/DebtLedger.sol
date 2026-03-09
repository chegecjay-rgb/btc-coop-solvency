// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DebtLedger is Ownable {
    error ZeroAddress();
    error NotAuthorized();
    error PositionNotFound(uint256 positionId);
    error InvalidAmount();
    error AlreadyInitialized(uint256 positionId);
    error RepayExceedsPrincipal(uint256 repayment, uint256 principal);
    error InterestRepayExceedsAccrued(uint256 repayment, uint256 accruedInterest);
    error RescueFeeRepayExceedsAccrued(uint256 repayment, uint256 accruedFee);
    error InsuranceChargeRepayExceedsAccrued(uint256 repayment, uint256 accruedCharge);
    error SettlementCostRepayExceedsAccrued(uint256 repayment, uint256 accruedSettlementCost);
    error RescueCapitalRepayExceedsUsed(uint256 repayment, uint256 rescueCapitalUsed);
    error InsuranceCapitalRepayExceedsUsed(uint256 repayment, uint256 insuranceCapitalUsed);

    struct DebtRecord {
        uint256 principal;
        uint256 accruedInterest;
        uint256 rescueCapitalUsed;
        uint256 rescueFeesAccrued;
        uint256 insuranceCapitalUsed;
        uint256 insuranceChargesAccrued;
        uint256 settlementCosts;
        uint256 lastAccrualTime;
    }

    mapping(uint256 => DebtRecord) private _debtByPosition;
    mapping(address => bool) public authorizedWriter;

    uint256 public totalProtocolDebt;
    uint256 public totalPrincipal;
    uint256 public totalAccruedInterest;
    uint256 public totalRescueCapitalUsed;
    uint256 public totalRescueFeesAccrued;
    uint256 public totalInsuranceCapitalUsed;
    uint256 public totalInsuranceChargesAccrued;
    uint256 public totalSettlementCosts;

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

    event RescueUsageRecorded(
        uint256 indexed positionId,
        uint256 capitalUsed,
        uint256 fee,
        uint256 newRescueCapitalUsed,
        uint256 newRescueFeesAccrued
    );

    event RescueCapitalRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRescueCapitalUsed
    );

    event RescueFeeRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRescueFeesAccrued
    );

    event InsuranceUsageRecorded(
        uint256 indexed positionId,
        uint256 capitalUsed,
        uint256 charge,
        uint256 newInsuranceCapitalUsed,
        uint256 newInsuranceChargesAccrued
    );

    event InsuranceCapitalRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newInsuranceCapitalUsed
    );

    event InsuranceChargeRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newInsuranceChargesAccrued
    );

    event SettlementCostRecorded(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newSettlementCosts
    );

    event SettlementCostRepaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newSettlementCosts
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
        if (_exists(positionId)) revert AlreadyInitialized(positionId);

        DebtRecord storage record = _debtByPosition[positionId];
        record.principal = principalAmount;
        record.lastAccrualTime = block.timestamp;

        totalPrincipal += principalAmount;
        _refreshTotalProtocolDebt();

        emit DebtRecordInitialized(positionId, principalAmount, block.timestamp);
    }

    function increaseDebt(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.principal += amount;
        totalPrincipal += amount;
        _refreshTotalProtocolDebt();

        emit PrincipalIncreased(positionId, amount, record.principal);
    }

    function repayDebt(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        if (amount > record.principal) {
            revert RepayExceedsPrincipal(amount, record.principal);
        }

        record.principal -= amount;
        totalPrincipal -= amount;
        _refreshTotalProtocolDebt();

        emit PrincipalRepaid(positionId, amount, record.principal);
    }

    function accrueInterest(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.accruedInterest += amount;
        record.lastAccrualTime = block.timestamp;
        totalAccruedInterest += amount;
        _refreshTotalProtocolDebt();

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
        _refreshTotalProtocolDebt();

        emit InterestRepaid(positionId, amount, record.accruedInterest);
    }

    function recordRescueUsage(
        uint256 positionId,
        uint256 capitalUsed,
        uint256 fee
    ) external onlyAuthorized {
        if (capitalUsed == 0 && fee == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.rescueCapitalUsed += capitalUsed;
        record.rescueFeesAccrued += fee;

        totalRescueCapitalUsed += capitalUsed;
        totalRescueFeesAccrued += fee;
        _refreshTotalProtocolDebt();

        emit RescueUsageRecorded(
            positionId,
            capitalUsed,
            fee,
            record.rescueCapitalUsed,
            record.rescueFeesAccrued
        );
    }

    function repayRescueCapital(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        if (amount > record.rescueCapitalUsed) {
            revert RescueCapitalRepayExceedsUsed(amount, record.rescueCapitalUsed);
        }

        record.rescueCapitalUsed -= amount;
        totalRescueCapitalUsed -= amount;
        _refreshTotalProtocolDebt();

        emit RescueCapitalRepaid(positionId, amount, record.rescueCapitalUsed);
    }

    function repayRescueFee(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        if (amount > record.rescueFeesAccrued) {
            revert RescueFeeRepayExceedsAccrued(amount, record.rescueFeesAccrued);
        }

        record.rescueFeesAccrued -= amount;
        totalRescueFeesAccrued -= amount;
        _refreshTotalProtocolDebt();

        emit RescueFeeRepaid(positionId, amount, record.rescueFeesAccrued);
    }

    function recordInsuranceUsage(
        uint256 positionId,
        uint256 capitalUsed,
        uint256 charge
    ) external onlyAuthorized {
        if (capitalUsed == 0 && charge == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.insuranceCapitalUsed += capitalUsed;
        record.insuranceChargesAccrued += charge;

        totalInsuranceCapitalUsed += capitalUsed;
        totalInsuranceChargesAccrued += charge;
        _refreshTotalProtocolDebt();

        emit InsuranceUsageRecorded(
            positionId,
            capitalUsed,
            charge,
            record.insuranceCapitalUsed,
            record.insuranceChargesAccrued
        );
    }

    function repayInsuranceCapital(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        if (amount > record.insuranceCapitalUsed) {
            revert InsuranceCapitalRepayExceedsUsed(amount, record.insuranceCapitalUsed);
        }

        record.insuranceCapitalUsed -= amount;
        totalInsuranceCapitalUsed -= amount;
        _refreshTotalProtocolDebt();

        emit InsuranceCapitalRepaid(positionId, amount, record.insuranceCapitalUsed);
    }

    function repayInsuranceCharge(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        if (amount > record.insuranceChargesAccrued) {
            revert InsuranceChargeRepayExceedsAccrued(amount, record.insuranceChargesAccrued);
        }

        record.insuranceChargesAccrued -= amount;
        totalInsuranceChargesAccrued -= amount;
        _refreshTotalProtocolDebt();

        emit InsuranceChargeRepaid(positionId, amount, record.insuranceChargesAccrued);
    }

    function recordSettlementCost(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        record.settlementCosts += amount;
        totalSettlementCosts += amount;
        _refreshTotalProtocolDebt();

        emit SettlementCostRecorded(positionId, amount, record.settlementCosts);
    }

    function repaySettlementCost(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        DebtRecord storage record = _requireDebtRecord(positionId);

        if (amount > record.settlementCosts) {
            revert SettlementCostRepayExceedsAccrued(amount, record.settlementCosts);
        }

        record.settlementCosts -= amount;
        totalSettlementCosts -= amount;
        _refreshTotalProtocolDebt();

        emit SettlementCostRepaid(positionId, amount, record.settlementCosts);
    }

    function closeDebt(uint256 positionId) external onlyAuthorized {
        DebtRecord storage record = _requireDebtRecord(positionId);

        totalPrincipal -= record.principal;
        totalAccruedInterest -= record.accruedInterest;
        totalRescueCapitalUsed -= record.rescueCapitalUsed;
        totalRescueFeesAccrued -= record.rescueFeesAccrued;
        totalInsuranceCapitalUsed -= record.insuranceCapitalUsed;
        totalInsuranceChargesAccrued -= record.insuranceChargesAccrued;
        totalSettlementCosts -= record.settlementCosts;

        delete _debtByPosition[positionId];
        _refreshTotalProtocolDebt();

        emit DebtClosed(positionId);
    }

    function getDebtRecord(uint256 positionId) external view returns (DebtRecord memory) {
        if (!_exists(positionId)) revert PositionNotFound(positionId);
        return _debtByPosition[positionId];
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

    function _refreshTotalProtocolDebt() internal {
        totalProtocolDebt =
            totalPrincipal +
            totalAccruedInterest +
            totalRescueCapitalUsed +
            totalRescueFeesAccrued +
            totalInsuranceCapitalUsed +
            totalInsuranceChargesAccrued +
            totalSettlementCosts;
    }
}
