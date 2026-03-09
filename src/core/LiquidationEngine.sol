// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPositionRegistryForLiquidation {
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
    function updateAmounts(uint256 positionId, uint256 collateralAmount, uint256 debtPrincipal) external;
}

interface ICollateralManagerForLiquidation {
    struct CollateralRecord {
        uint256 totalCollateral;
        uint256 lockedCollateral;
        uint256 transferredToStabilization;
        uint256 transferredToInsurance;
        bool releaseFrozen;
        bool initialized;
    }

    function getCollateralRecord(uint256 positionId) external view returns (CollateralRecord memory);
    function transferToStabilization(uint256 positionId, uint256 amount) external;
}

interface IDebtLedgerForLiquidation {
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
    function recordSettlementCost(uint256 positionId, uint256 amount) external;
    function closeDebt(uint256 positionId) external;
}

interface IRiskEngineForLiquidation {
    struct PositionRiskSnapshot {
        uint256 healthFactor;
        uint256 adjustedCollateral;
        uint256 totalDebt;
        uint256 currentLTVBps;
        uint8 classification;
    }

    function positionRiskSnapshot(uint256 positionId) external view returns (PositionRiskSnapshot memory);
}

interface IRecapitalizationEngineForLiquidation {
    function recordRecovery(uint256 positionId, uint256 amount) external;
}

contract LiquidationEngine is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error NotAuthorized();
    error PositionNotLiquidatable(uint256 positionId);
    error AlreadyLiquidated(uint256 positionId);

    uint8 internal constant STATE_TERMINAL = 6;
    uint8 internal constant STATE_LIQUIDATABLE = 7;
    uint8 internal constant STATE_CLOSED = 8;

    uint256 public liquidationPenaltyBps;
    uint256 public maxAuctionDuration;

    address public immutable positionRegistry;
    address public immutable collateralManager;
    address public immutable debtLedger;
    address public immutable riskEngine;
    address public immutable recapitalizationEngine;

    mapping(address => bool) public authorizedLiquidator;
    mapping(uint256 => bool) public liquidatedPosition;
    mapping(uint256 => uint256) public liquidationRecoveryByPosition;

    event AuthorizedLiquidatorSet(address indexed liquidator, bool allowed);
    event LiquidationParametersSet(uint256 liquidationPenaltyBps, uint256 maxAuctionDuration);
    event LiquidationExecuted(
        uint256 indexed positionId,
        bytes32 indexed assetId,
        uint256 collateralMoved,
        uint256 settlementCost,
        uint256 recordedRecovery
    );
    event PostLiquidationSettled(uint256 indexed positionId);

    constructor(
        address initialOwner,
        address positionRegistry_,
        address collateralManager_,
        address debtLedger_,
        address riskEngine_,
        address recapitalizationEngine_,
        uint256 liquidationPenaltyBps_,
        uint256 maxAuctionDuration_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            positionRegistry_ == address(0) ||
            collateralManager_ == address(0) ||
            debtLedger_ == address(0) ||
            riskEngine_ == address(0) ||
            recapitalizationEngine_ == address(0)
        ) revert ZeroAddress();

        if (liquidationPenaltyBps_ > 10_000) revert ZeroAddress();

        positionRegistry = positionRegistry_;
        collateralManager = collateralManager_;
        debtLedger = debtLedger_;
        riskEngine = riskEngine_;
        recapitalizationEngine = recapitalizationEngine_;
        liquidationPenaltyBps = liquidationPenaltyBps_;
        maxAuctionDuration = maxAuctionDuration_;
    }

    modifier onlyAuthorized() {
        if (!(authorizedLiquidator[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    function setAuthorizedLiquidator(address liquidator, bool allowed) external onlyOwner {
        if (liquidator == address(0)) revert ZeroAddress();
        authorizedLiquidator[liquidator] = allowed;
        emit AuthorizedLiquidatorSet(liquidator, allowed);
    }

    function setLiquidationParameters(uint256 penaltyBps, uint256 auctionDuration) external onlyOwner {
        if (penaltyBps > 10_000) revert ZeroAddress();
        liquidationPenaltyBps = penaltyBps;
        maxAuctionDuration = auctionDuration;
        emit LiquidationParametersSet(penaltyBps, auctionDuration);
    }

    function isLiquidatable(uint256 positionId) public view returns (bool) {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IPositionRegistryForLiquidation.Position memory p =
            IPositionRegistryForLiquidation(positionRegistry).getPosition(positionId);

        if (liquidatedPosition[positionId]) return false;
        if (p.state == STATE_LIQUIDATABLE || p.state == STATE_TERMINAL) return true;

        IRiskEngineForLiquidation.PositionRiskSnapshot memory snap =
            IRiskEngineForLiquidation(riskEngine).positionRiskSnapshot(positionId);

        // v1: classification 3 = Liquidatable in current calculator flow
        return snap.classification == 3;
    }

    function executeLiquidation(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        if (liquidatedPosition[positionId]) revert AlreadyLiquidated(positionId);
        if (!isLiquidatable(positionId)) revert PositionNotLiquidatable(positionId);

        IPositionRegistryForLiquidation.Position memory p =
            IPositionRegistryForLiquidation(positionRegistry).getPosition(positionId);

        ICollateralManagerForLiquidation.CollateralRecord memory c =
            ICollateralManagerForLiquidation(collateralManager).getCollateralRecord(positionId);

        IDebtLedgerForLiquidation.DebtRecord memory d =
            IDebtLedgerForLiquidation(debtLedger).getDebtRecord(positionId);

        uint256 collateralMoved = c.lockedCollateral;
        if (collateralMoved > 0) {
            ICollateralManagerForLiquidation(collateralManager).transferToStabilization(positionId, collateralMoved);
        }

        uint256 settlementCost = (d.principal * liquidationPenaltyBps) / 10_000;
        if (settlementCost > 0) {
            IDebtLedgerForLiquidation(debtLedger).recordSettlementCost(positionId, settlementCost);
        }

        uint256 recoveryRecorded =
            d.principal +
            d.accruedInterest +
            d.rescueCapitalUsed +
            d.rescueFeesAccrued +
            d.insuranceCapitalUsed +
            d.insuranceChargesAccrued;

        liquidationRecoveryByPosition[positionId] = recoveryRecorded;
        if (recoveryRecorded > 0) {
            IRecapitalizationEngineForLiquidation(recapitalizationEngine).recordRecovery(positionId, recoveryRecorded);
        }

        IPositionRegistryForLiquidation(positionRegistry).updateState(positionId, STATE_LIQUIDATABLE);
        liquidatedPosition[positionId] = true;

        emit LiquidationExecuted(
            positionId,
            p.assetId,
            collateralMoved,
            settlementCost,
            recoveryRecorded
        );
    }

    function settlePostLiquidation(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        if (!liquidatedPosition[positionId]) revert PositionNotLiquidatable(positionId);

        IPositionRegistryForLiquidation.Position memory p =
            IPositionRegistryForLiquidation(positionRegistry).getPosition(positionId);

        IDebtLedgerForLiquidation(debtLedger).closeDebt(positionId);
        IPositionRegistryForLiquidation(positionRegistry).updateAmounts(positionId, 0, 0);
        IPositionRegistryForLiquidation(positionRegistry).updateState(positionId, STATE_CLOSED);

        emit PostLiquidationSettled(positionId);
    }
}
