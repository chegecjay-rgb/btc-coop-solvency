// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPositionRegistryForRescue {
    struct Position {
        address owner;
        bytes32 assetId;
        uint256 collateralAmount;
        uint256 debtPrincipal;
        uint8 state;
        uint256 rescueCount;
        uint256 lastRescueTime;
        bool hasBuybackCover;
        bytes32 activeRemoteIntentId;
    }

    function getPosition(uint256 positionId) external view returns (Position memory);
    function updateState(uint256 positionId, uint8 newState) external;
    function incrementRescueCount(uint256 positionId) external;
}

interface IParameterRegistryForRescue {
    struct RiskParams {
        uint256 maxBorrowLTVBps;
        uint256 rescueTriggerLTVBps;
        uint256 liquidationLTVBps;
        uint256 targetPostRescueLTVBps;
        uint256 collateralHaircutBps;
        uint256 liquidationBufferBps;
        uint256 maxRescueAttempts;
        uint256 rescueCooldown;
        uint256 buybackClaimDuration;
    }

    function getRiskParams(bytes32 assetId) external view returns (RiskParams memory);
}

interface IDebtLedgerForRescue {
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

    function getDebtRecord(uint256 positionId) external view returns (DebtRecord memory);
    function recordRescueUsage(uint256 positionId, uint256 capitalUsed, uint256 fee) external;
    function recordInsuranceUsage(uint256 positionId, uint256 capitalUsed, uint256 charge) external;
}

interface ICollateralManagerForRescue {
    struct CollateralRecord {
        uint256 totalCollateral;
        uint256 lockedCollateral;
        uint256 transferredToStabilization;
        uint256 transferredToInsurance;
        bool releaseFrozen;
        bool initialized;
    }

    function getCollateralRecord(uint256 positionId) external view returns (CollateralRecord memory);
    function transferToInsurance(uint256 positionId, uint256 amount) external;
}

interface IStabilizationPoolForRescue {
    function deployRescueCapital(bytes32 assetId, uint256 amount) external;
    function availableRescueLiquidity(bytes32 assetId) external view returns (uint256);
}

interface IInsuranceReserveForRescue {
    function coverTerminalDeficit(uint256 positionId, uint256 amount) external;
}

interface IRiskEngineForRescue {
    struct PositionRiskSnapshot {
        uint256 healthFactor;
        uint256 adjustedCollateral;
        uint256 totalDebt;
        uint256 currentLTVBps;
        uint8 classification;
    }

    function positionRiskSnapshot(uint256 positionId) external view returns (PositionRiskSnapshot memory);
}

contract RescueController is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error NotAuthorized();
    error RescueNotNeeded(uint256 positionId);

    uint8 internal constant STATE_RESCUED = 4;
    uint8 internal constant STATE_TERMINAL = 6;

    uint256 public constant BASE_RESCUE_FEE_BPS = 100;
    uint256 public constant REPEAT_RESCUE_SURCHARGE_BPS = 50;

    struct RescueRecord {
        uint256 totalRescued;
        uint256 lastRescueAmount;
        uint256 rescueFees;
        bool terminalFlag;
    }

    address public immutable positionRegistry;
    address public immutable parameterRegistry;
    address public immutable debtLedger;
    address public immutable collateralManager;
    address public immutable stabilizationPool;
    address public immutable insuranceReserve;
    address public immutable riskEngine;

    mapping(uint256 => RescueRecord) public rescueByPosition;
    mapping(address => bool) public authorizedExecutor;

    event AuthorizedExecutorSet(address indexed executor, bool allowed);
    event RescueExecuted(
        uint256 indexed positionId,
        bytes32 indexed assetId,
        uint256 rescueAmount,
        uint256 rescueFee
    );
    event PositionMarkedTerminal(uint256 indexed positionId);
    event TerminalSettlementRouted(
        uint256 indexed positionId,
        uint256 deficitCovered,
        uint256 collateralMovedToInsurance
    );

    constructor(
        address initialOwner,
        address positionRegistry_,
        address parameterRegistry_,
        address debtLedger_,
        address collateralManager_,
        address stabilizationPool_,
        address insuranceReserve_,
        address riskEngine_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            positionRegistry_ == address(0) ||
            parameterRegistry_ == address(0) ||
            debtLedger_ == address(0) ||
            collateralManager_ == address(0) ||
            stabilizationPool_ == address(0) ||
            insuranceReserve_ == address(0) ||
            riskEngine_ == address(0)
        ) revert ZeroAddress();

        positionRegistry = positionRegistry_;
        parameterRegistry = parameterRegistry_;
        debtLedger = debtLedger_;
        collateralManager = collateralManager_;
        stabilizationPool = stabilizationPool_;
        insuranceReserve = insuranceReserve_;
        riskEngine = riskEngine_;
    }

    modifier onlyAuthorized() {
        if (!(authorizedExecutor[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    function setAuthorizedExecutor(address executor, bool allowed) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        authorizedExecutor[executor] = allowed;
        emit AuthorizedExecutorSet(executor, allowed);
    }

    function calculateRescueSize(uint256 positionId) public view returns (uint256) {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IPositionRegistryForRescue.Position memory p =
            IPositionRegistryForRescue(positionRegistry).getPosition(positionId);

        IParameterRegistryForRescue.RiskParams memory params_ =
            IParameterRegistryForRescue(parameterRegistry).getRiskParams(p.assetId);

        IRiskEngineForRescue.PositionRiskSnapshot memory snap =
            IRiskEngineForRescue(riskEngine).positionRiskSnapshot(positionId);

        uint256 targetDebt = (snap.adjustedCollateral * params_.targetPostRescueLTVBps) / 10_000;
        if (snap.totalDebt <= targetDebt) return 0;

        return snap.totalDebt - targetDebt;
    }

    function applyRescueFee(uint256 positionId, uint256 amount) public view returns (uint256) {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IPositionRegistryForRescue.Position memory p =
            IPositionRegistryForRescue(positionRegistry).getPosition(positionId);

        uint256 feeBps = BASE_RESCUE_FEE_BPS + (p.rescueCount * REPEAT_RESCUE_SURCHARGE_BPS);
        return (amount * feeBps) / 10_000;
    }

    function executeRescue(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IPositionRegistryForRescue.Position memory p =
            IPositionRegistryForRescue(positionRegistry).getPosition(positionId);

        IParameterRegistryForRescue.RiskParams memory params_ =
            IParameterRegistryForRescue(parameterRegistry).getRiskParams(p.assetId);

        if (p.rescueCount >= params_.maxRescueAttempts) {
            _markTerminalInternal(positionId);
            return;
        }

        uint256 rescueAmount = calculateRescueSize(positionId);
        if (rescueAmount == 0) revert RescueNotNeeded(positionId);

        uint256 available =
            IStabilizationPoolForRescue(stabilizationPool).availableRescueLiquidity(p.assetId);

        if (rescueAmount > available) {
            _markTerminalInternal(positionId);
            return;
        }

        uint256 rescueFee = applyRescueFee(positionId, rescueAmount);

        IStabilizationPoolForRescue(stabilizationPool).deployRescueCapital(p.assetId, rescueAmount);
        IDebtLedgerForRescue(debtLedger).recordRescueUsage(positionId, rescueAmount, rescueFee);
        IPositionRegistryForRescue(positionRegistry).incrementRescueCount(positionId);
        IPositionRegistryForRescue(positionRegistry).updateState(positionId, STATE_RESCUED);

        RescueRecord storage r = rescueByPosition[positionId];
        r.totalRescued += rescueAmount;
        r.lastRescueAmount = rescueAmount;
        r.rescueFees += rescueFee;

        emit RescueExecuted(positionId, p.assetId, rescueAmount, rescueFee);
    }

    function markTerminal(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        _markTerminalInternal(positionId);
    }

    function routeTerminalSettlement(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        RescueRecord storage r = rescueByPosition[positionId];
        if (!r.terminalFlag) {
            _markTerminalInternal(positionId);
        }

        IRiskEngineForRescue.PositionRiskSnapshot memory snap =
            IRiskEngineForRescue(riskEngine).positionRiskSnapshot(positionId);

        uint256 deficitCovered = 0;
        if (snap.totalDebt > snap.adjustedCollateral) {
            deficitCovered = snap.totalDebt - snap.adjustedCollateral;
            IInsuranceReserveForRescue(insuranceReserve).coverTerminalDeficit(positionId, deficitCovered);
            IDebtLedgerForRescue(debtLedger).recordInsuranceUsage(positionId, deficitCovered, 0);
        }

        ICollateralManagerForRescue.CollateralRecord memory c =
            ICollateralManagerForRescue(collateralManager).getCollateralRecord(positionId);

        uint256 collateralMoved = c.lockedCollateral;
        if (collateralMoved > 0) {
            ICollateralManagerForRescue(collateralManager).transferToInsurance(positionId, collateralMoved);
        }

        emit TerminalSettlementRouted(positionId, deficitCovered, collateralMoved);
    }

    function _markTerminalInternal(uint256 positionId) internal {
        rescueByPosition[positionId].terminalFlag = true;
        IPositionRegistryForRescue(positionRegistry).updateState(positionId, STATE_TERMINAL);
        emit PositionMarkedTerminal(positionId);
    }
}
