// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IParameterRegistryForRisk {
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

    struct RemoteLiquidityParams {
        uint256 minLocalLiquidityBps;
        uint256 highUtilizationBps;
        uint256 maxPendingRescueLoadBps;
        uint256 remoteIntentFeeCapBps;
        uint256 remoteIntentDeadline;
    }

    function getRiskParams(bytes32 assetId) external view returns (RiskParams memory);
    function getRemoteLiquidityParams(bytes32 assetId) external view returns (RemoteLiquidityParams memory);
}

interface IHealthFactorCalculatorForRisk {
    function riskAdjustedCollateral(uint256 positionId) external view returns (uint256);
    function healthFactor(uint256 positionId) external view returns (uint256);
    function classify(uint256 positionId) external view returns (uint8);
}

interface ILendingLiquidityVaultForRisk {
    function assetId() external view returns (bytes32);
    function totalLiquidity() external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
    function utilization() external view returns (uint256);
}

interface IStabilizationPoolForRisk {
    function pools(bytes32 assetId)
        external
        view
        returns (
            uint256 stableLiquidity,
            uint256 btcLiquidity,
            uint256 activeRescueExposure,
            uint256 recoveredProceeds
        );

    function availableRescueLiquidity(bytes32 assetId) external view returns (uint256);
}

interface IExpectedLossEngineForRisk {
    function volatilityBpsByAsset(bytes32 assetId) external view returns (uint256);
    function liquidityStressBpsByAsset(bytes32 assetId) external view returns (uint256);
    function rescueSensitivity(bytes32 assetId, uint256 shockBps) external view returns (uint256);
}

interface IPositionRegistryForRisk {
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
}

interface IDebtLedgerForRisk {
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
}

contract RiskEngine is Ownable {
    error ZeroAddress();
    error InvalidAssetId();

    enum LiquidityStressState {
        Normal,
        Tight,
        Stressed,
        Critical
    }

    struct PositionRiskSnapshot {
        uint256 healthFactor;
        uint256 adjustedCollateral;
        uint256 totalDebt;
        uint256 currentLTVBps;
        uint8 classification;
    }

    address public immutable parameterRegistry;
    address public immutable healthFactorCalculator;
    address public immutable lendingLiquidityVault;
    address public immutable stabilizationPool;
    address public immutable expectedLossEngine;
    address public immutable positionRegistry;
    address public immutable debtLedger;

    mapping(bytes32 => uint256) public dynamicBorrowCapBps;
    mapping(bytes32 => LiquidityStressState) public stressStateByAsset;

    event DynamicBorrowCapRefreshed(bytes32 indexed assetId, uint256 newBorrowCapBps);
    event MarketStressEvaluated(bytes32 indexed assetId, LiquidityStressState newState);

    constructor(
        address initialOwner,
        address parameterRegistry_,
        address healthFactorCalculator_,
        address lendingLiquidityVault_,
        address stabilizationPool_,
        address expectedLossEngine_,
        address positionRegistry_,
        address debtLedger_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            parameterRegistry_ == address(0) ||
            healthFactorCalculator_ == address(0) ||
            lendingLiquidityVault_ == address(0) ||
            stabilizationPool_ == address(0) ||
            expectedLossEngine_ == address(0) ||
            positionRegistry_ == address(0) ||
            debtLedger_ == address(0)
        ) revert ZeroAddress();

        parameterRegistry = parameterRegistry_;
        healthFactorCalculator = healthFactorCalculator_;
        lendingLiquidityVault = lendingLiquidityVault_;
        stabilizationPool = stabilizationPool_;
        expectedLossEngine = expectedLossEngine_;
        positionRegistry = positionRegistry_;
        debtLedger = debtLedger_;
    }

    function refreshDynamicBorrowCap(bytes32 assetId) external returns (uint256) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        IParameterRegistryForRisk.RiskParams memory riskParams =
            IParameterRegistryForRisk(parameterRegistry).getRiskParams(assetId);

        LiquidityStressState state = evaluateMarketStress(assetId);

        uint256 cap = riskParams.maxBorrowLTVBps;
        if (state == LiquidityStressState.Tight) {
            cap = cap > 500 ? cap - 500 : 0;
        } else if (state == LiquidityStressState.Stressed) {
            cap = cap > 1_000 ? cap - 1_000 : 0;
        } else if (state == LiquidityStressState.Critical) {
            cap = cap > 1_500 ? cap - 1_500 : 0;
        }

        dynamicBorrowCapBps[assetId] = cap;
        emit DynamicBorrowCapRefreshed(assetId, cap);
        return cap;
    }

    function positionRiskSnapshot(uint256 positionId)
        external
        view
        returns (PositionRiskSnapshot memory snapshot)
    {
        uint256 adjustedCollateral =
            IHealthFactorCalculatorForRisk(healthFactorCalculator).riskAdjustedCollateral(positionId);
        uint256 hf =
            IHealthFactorCalculatorForRisk(healthFactorCalculator).healthFactor(positionId);
        uint8 classification =
            IHealthFactorCalculatorForRisk(healthFactorCalculator).classify(positionId);

        uint256 totalDebt = _totalDebt(positionId);
        uint256 currentLTVBps = adjustedCollateral == 0 ? type(uint256).max : (totalDebt * 10_000) / adjustedCollateral;

        snapshot = PositionRiskSnapshot({
            healthFactor: hf,
            adjustedCollateral: adjustedCollateral,
            totalDebt: totalDebt,
            currentLTVBps: currentLTVBps,
            classification: classification
        });
    }

    function evaluateMarketStress(bytes32 assetId) public returns (LiquidityStressState) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        IParameterRegistryForRisk.RemoteLiquidityParams memory remoteParams =
            IParameterRegistryForRisk(parameterRegistry).getRemoteLiquidityParams(assetId);

        uint256 utilizationBps = _vaultAssetId() == assetId
            ? ILendingLiquidityVaultForRisk(lendingLiquidityVault).utilization()
            : 0;

        uint256 localLiquidityBps = _localLiquidityBps(assetId);
        uint256 rescueLoadBps = rescueLoadRatio(assetId);

        LiquidityStressState newState;

        if (
            utilizationBps >= 9_500 ||
            localLiquidityBps < remoteParams.minLocalLiquidityBps / 2 ||
            rescueLoadBps >= 9_000
        ) {
            newState = LiquidityStressState.Critical;
        } else if (
            utilizationBps >= remoteParams.highUtilizationBps ||
            localLiquidityBps < remoteParams.minLocalLiquidityBps ||
            rescueLoadBps >= remoteParams.maxPendingRescueLoadBps
        ) {
            newState = LiquidityStressState.Stressed;
        } else if (
            utilizationBps >= 7_000 ||
            rescueLoadBps >= remoteParams.maxPendingRescueLoadBps / 2
        ) {
            newState = LiquidityStressState.Tight;
        } else {
            newState = LiquidityStressState.Normal;
        }

        stressStateByAsset[assetId] = newState;
        emit MarketStressEvaluated(assetId, newState);
        return newState;
    }

    function availableLocalLiquidity(bytes32 assetId) public view returns (uint256) {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        return _vaultAssetId() == assetId
            ? ILendingLiquidityVaultForRisk(lendingLiquidityVault).availableLiquidity()
            : 0;
    }

    function rescueLoadRatio(bytes32 assetId) public view returns (uint256) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        (
            uint256 stableLiquidity,
            ,
            uint256 activeRescueExposure,

        ) = IStabilizationPoolForRisk(stabilizationPool).pools(assetId);

        uint256 denom = stableLiquidity + activeRescueExposure;
        if (denom == 0) return 0;

        return (activeRescueExposure * 10_000) / denom;
    }

    function shouldOpenRemoteIntent(
        bytes32 assetId,
        uint256 amountNeeded,
        uint8 intentType
    ) external returns (bool) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        LiquidityStressState state = evaluateMarketStress(assetId);
        uint256 localLiquidity = availableLocalLiquidity(assetId);

        // intentType: 0=BorrowFill, 1=RescueFill, 2=Refinance
        if (amountNeeded > localLiquidity) return true;
        if (state == LiquidityStressState.Stressed || state == LiquidityStressState.Critical) return true;
        if (intentType == 1 && rescueLoadRatio(assetId) > 5_000) return true;

        return false;
    }

    function rescueCapitalRequired(bytes32 assetId, uint256 shockBps) external view returns (uint256) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        uint256 sensitivity =
            IExpectedLossEngineForRisk(expectedLossEngine).rescueSensitivity(assetId, shockBps);
        uint256 rescueLiquidity =
            IStabilizationPoolForRisk(stabilizationPool).availableRescueLiquidity(assetId);

        return (rescueLiquidity * sensitivity) / 10_000;
    }

    function liquidationExposure(bytes32 assetId, uint256 shockBps) external view returns (uint256) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        uint256 localLiquidity = availableLocalLiquidity(assetId);
        uint256 liquidityStress =
            IExpectedLossEngineForRisk(expectedLossEngine).liquidityStressBpsByAsset(assetId);

        uint256 stressed = liquidityStress + shockBps;
        if (stressed > 10_000) stressed = 10_000;

        return (localLiquidity * stressed) / 10_000;
    }

    function solvencyRatio(bytes32 assetId, uint256 shockBps) external view returns (uint256) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        uint256 localLiquidity = availableLocalLiquidity(assetId);
        uint256 rescueLiquidity =
            IStabilizationPoolForRisk(stabilizationPool).availableRescueLiquidity(assetId);
        uint256 required =
            this.rescueCapitalRequired(assetId, shockBps);

        if (required == 0) return type(uint256).max;

        return ((localLiquidity + rescueLiquidity) * 1e18) / required;
    }

    function _vaultAssetId() internal view returns (bytes32) {
        return ILendingLiquidityVaultForRisk(lendingLiquidityVault).assetId();
    }

    function _localLiquidityBps(bytes32 assetId) internal view returns (uint256) {
        if (_vaultAssetId() != assetId) return 0;

        uint256 totalLiquidity = ILendingLiquidityVaultForRisk(lendingLiquidityVault).totalLiquidity();
        if (totalLiquidity == 0) return 0;

        uint256 available = ILendingLiquidityVaultForRisk(lendingLiquidityVault).availableLiquidity();
        return (available * 10_000) / totalLiquidity;
    }

    function _totalDebt(uint256 positionId) internal view returns (uint256) {
        IDebtLedgerForRisk.DebtRecord memory d =
            IDebtLedgerForRisk(debtLedger).getDebtRecord(positionId);

        return
            d.principal +
            d.accruedInterest +
            d.rescueCapitalUsed +
            d.rescueFeesAccrued +
            d.insuranceCapitalUsed +
            d.insuranceChargesAccrued +
            d.settlementCosts;
    }
}
