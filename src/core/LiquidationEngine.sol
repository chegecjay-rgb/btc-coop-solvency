// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CollateralRail} from "../types/CollateralRail.sol";

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
        uint8 collateralRail;
    }

    function getPosition(uint256 positionId) external view returns (Position memory);
    function updateState(uint256 positionId, uint8 newState) external;
    function updateAmounts(uint256 positionId, uint256 collateralAmount, uint256 debtPrincipal) external;
    function collateralRailOf(uint256 positionId) external view returns (uint8);
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

interface INativeSettlementAdapterForLunaAccounting {
    function finalizeNativeLiquidation(uint256 positionId, bytes32 proofPackRef) external;
    function finalizeNativeTerminalSettlement(uint256 positionId, bytes32 proofPackRef) external;
}

contract LiquidationEngine is Ownable {
    uint8 internal constant RAIL_PROTOCOL_ESCROWED_WRAPPED_BTC = 0;
    uint8 internal constant RAIL_ENFORCEABLE_NATIVE_BTC = 1;
    error NativeRailProofPackRequired(uint256 positionId);
    error NotNativeRail(uint256 positionId, uint8 rail);
    error EmptyProofPackRef();
    event NativeSettlementAdapterSet(address indexed adapter);
    event NativeLiquidationForwardedToAdapter(
        uint256 indexed positionId, bytes32 indexed proofPackRef, address indexed adapter
    );

    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error NotAuthorized();
    error PositionNotLiquidatable(uint256 positionId);
    error AlreadyLiquidated(uint256 positionId);
    error NativeRailSettlementAdapterMissing(uint256 positionId);
    error InvalidCollateralRail(uint8 rail);
    error NativeProofPackRefRequired(uint256 positionId);
    error NativeSettlementAdapterCallFailed(uint256 positionId);

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
    address public nativeSettlementAdapter;

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
    event NativeTerminalSettlementRouted(
        uint256 indexed positionId, bytes32 indexed proofPackRef, address indexed adapter
    );

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
            initialOwner == address(0) || positionRegistry_ == address(0) || collateralManager_ == address(0)
                || debtLedger_ == address(0) || riskEngine_ == address(0) || recapitalizationEngine_ == address(0)
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

    function setNativeSettlementAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        nativeSettlementAdapter = adapter;
        emit NativeSettlementAdapterSet(adapter);
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

    function executeNativeLiquidation(uint256 positionId, bytes32 proofPackRef) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        _requireNativeRail(positionId);
        _requireNativeSettlementAdapter(positionId);
        _requireProofPackRef(proofPackRef);

        if (liquidatedPosition[positionId]) revert AlreadyLiquidated(positionId);
        if (!isLiquidatable(positionId)) revert PositionNotLiquidatable(positionId);

        INativeSettlementAdapterForLunaAccounting(nativeSettlementAdapter)
            .finalizeNativeLiquidation(positionId, proofPackRef);

        IPositionRegistryForLiquidation(positionRegistry).updateState(positionId, STATE_LIQUIDATABLE);
        liquidatedPosition[positionId] = true;

        emit NativeLiquidationForwardedToAdapter(positionId, proofPackRef, nativeSettlementAdapter);
    }

    function executeLiquidation(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        _guardNativeRailLegacyLiquidation(positionId);
        if (liquidatedPosition[positionId]) revert AlreadyLiquidated(positionId);
        if (!isLiquidatable(positionId)) revert PositionNotLiquidatable(positionId);

        IPositionRegistryForLiquidation.Position memory p =
            IPositionRegistryForLiquidation(positionRegistry).getPosition(positionId);

        uint8 rail = _positionRail(positionId);
        if (rail == RAIL_ENFORCEABLE_NATIVE_BTC) {
            revert NativeRailSettlementAdapterMissing(positionId);
        }

        if (_positionRail(positionId) != CollateralRail.PROTOCOL_ESCROW) {
            revert InvalidCollateralRail(_positionRail(positionId));
        }

        ICollateralManagerForLiquidation.CollateralRecord memory c =
            ICollateralManagerForLiquidation(collateralManager).getCollateralRecord(positionId);

        IDebtLedgerForLiquidation.DebtRecord memory d = IDebtLedgerForLiquidation(debtLedger).getDebtRecord(positionId);

        uint256 collateralMoved = c.lockedCollateral;
        if (collateralMoved > 0) {
            ICollateralManagerForLiquidation(collateralManager).transferToStabilization(positionId, collateralMoved);
        }

        uint256 settlementCost = (d.principal * liquidationPenaltyBps) / 10_000;
        if (settlementCost > 0) {
            IDebtLedgerForLiquidation(debtLedger).recordSettlementCost(positionId, settlementCost);
        }

        uint256 recoveryRecorded = d.principal + d.accruedInterest + d.rescueCapitalUsed + d.rescueFeesAccrued
            + d.insuranceCapitalUsed + d.insuranceChargesAccrued;

        liquidationRecoveryByPosition[positionId] = recoveryRecorded;
        if (recoveryRecorded > 0) {
            IRecapitalizationEngineForLiquidation(recapitalizationEngine).recordRecovery(positionId, recoveryRecorded);
        }

        IPositionRegistryForLiquidation(positionRegistry).updateState(positionId, STATE_LIQUIDATABLE);
        liquidatedPosition[positionId] = true;

        emit LiquidationExecuted(positionId, p.assetId, collateralMoved, settlementCost, recoveryRecorded);
    }

    function _nativeTerminalPositionRail(uint256 positionId) internal view returns (uint8) {
        (bool ok, bytes memory data) =
            positionRegistry.staticcall(abi.encodeWithSignature("collateralRailOf(uint256)", positionId));

        if (!ok || data.length < 32) {
            return type(uint8).max;
        }

        return abi.decode(data, (uint8));
    }

    function settleNativePostLiquidation(uint256 positionId, bytes32 proofPackRef) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        uint8 rail = _nativeTerminalPositionRail(positionId);
        if (rail != 1) {
            revert InvalidCollateralRail(rail);
        }

        if (nativeSettlementAdapter == address(0)) {
            revert NativeRailSettlementAdapterMissing(positionId);
        }

        if (proofPackRef == bytes32(0)) {
            revert NativeProofPackRefRequired(positionId);
        }

        IDebtLedgerForLiquidation.DebtRecord memory d = IDebtLedgerForLiquidation(debtLedger).getDebtRecord(positionId);

        uint256 recoveryAmount = d.principal + d.accruedInterest + d.rescueCapitalUsed + d.rescueFeesAccrued
            + d.insuranceCapitalUsed + d.insuranceChargesAccrued;
        bytes memory callData = abi.encodeWithSignature(
            "finalizeNativeTerminalSettlement(uint256,bytes32,uint256,uint256)",
            positionId,
            proofPackRef,
            recoveryAmount,
            0
        );

        (bool ok, bytes memory returnData) = nativeSettlementAdapter.call(callData);

        if (!ok) {
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }

            revert NativeSettlementAdapterCallFailed(positionId);
        }

        emit NativeTerminalSettlementRouted(positionId, proofPackRef, nativeSettlementAdapter);
    }

    function settlePostLiquidation(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        _guardNativeRailLegacyLiquidation(positionId);

        if (_positionRail(positionId) == CollateralRail.ENFORCEABLE_NATIVE) {
            revert NativeRailSettlementAdapterMissing(positionId);
        }
        uint8 rail = _positionRail(positionId);
        if (rail != RAIL_PROTOCOL_ESCROWED_WRAPPED_BTC) {
            revert InvalidCollateralRail(rail);
        }

        if (!liquidatedPosition[positionId]) revert PositionNotLiquidatable(positionId);

        IDebtLedgerForLiquidation(debtLedger).closeDebt(positionId);
        IPositionRegistryForLiquidation(positionRegistry).updateAmounts(positionId, 0, 0);
        IPositionRegistryForLiquidation(positionRegistry).updateState(positionId, STATE_CLOSED);

        emit PostLiquidationSettled(positionId);
    }

    function _guardNativeRailLegacyLiquidation(uint256 positionId) internal view {
        uint8 rail = IPositionRegistryForLiquidation(positionRegistry).collateralRailOf(positionId);
        if (rail == RAIL_ENFORCEABLE_NATIVE_BTC) {
            if (nativeSettlementAdapter == address(0)) revert NativeRailSettlementAdapterMissing(positionId);
            revert NativeRailProofPackRequired(positionId);
        }
    }

    function _positionRailOf(uint256 positionId) internal view returns (uint8) {
        return IPositionRegistryForLiquidation(positionRegistry).collateralRailOf(positionId);
    }

    function _positionRail(uint256 positionId) internal view returns (uint8) {
        return IPositionRegistryForLiquidation(positionRegistry).collateralRailOf(positionId);
    }

    function _requireNativeRail(uint256 positionId) internal view {
        uint8 rail = IPositionRegistryForLiquidation(positionRegistry).collateralRailOf(positionId);
        if (rail != RAIL_ENFORCEABLE_NATIVE_BTC) revert NotNativeRail(positionId, rail);
    }

    function _requireNativeSettlementAdapter(uint256 positionId) internal view {
        if (nativeSettlementAdapter == address(0)) revert NativeRailSettlementAdapterMissing(positionId);
    }

    function _requireProofPackRef(bytes32 proofPackRef) internal pure {
        if (proofPackRef == bytes32(0)) revert EmptyProofPackRef();
    }
}
