// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IParameterRegistryForHF {
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

interface IOracleGuardForHF {
    function getValidatedPrice(bytes32 assetId) external view returns (uint256);
}

interface IExpectedLossEngineForHF {
    function rescueProbability(uint256 positionId) external view returns (uint256);
    function expectedLoss(uint256 positionId) external view returns (uint256);
}

interface IPositionRegistryForHF {
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

interface IDebtLedgerForHF {
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

contract HealthFactorCalculator {
    error ZeroAddress();
    error InvalidCollateralValue();

    enum HealthClassification {
        Healthy,
        AtRisk,
        RescueEligible,
        Liquidatable
    }

    address public immutable parameterRegistry;
    address public immutable oracleGuard;
    address public immutable expectedLossEngine;
    address public immutable positionRegistry;
    address public immutable debtLedger;

    constructor(
        address parameterRegistry_,
        address oracleGuard_,
        address expectedLossEngine_,
        address positionRegistry_,
        address debtLedger_
    ) {
        if (
            parameterRegistry_ == address(0) ||
            oracleGuard_ == address(0) ||
            expectedLossEngine_ == address(0) ||
            positionRegistry_ == address(0) ||
            debtLedger_ == address(0)
        ) revert ZeroAddress();

        parameterRegistry = parameterRegistry_;
        oracleGuard = oracleGuard_;
        expectedLossEngine = expectedLossEngine_;
        positionRegistry = positionRegistry_;
        debtLedger = debtLedger_;
    }

    function riskAdjustedCollateral(uint256 positionId) public view returns (uint256) {
        IPositionRegistryForHF.Position memory p =
            IPositionRegistryForHF(positionRegistry).getPosition(positionId);

        IParameterRegistryForHF.RiskParams memory params_ =
            IParameterRegistryForHF(parameterRegistry).getRiskParams(p.assetId);

        uint256 price = IOracleGuardForHF(oracleGuard).getValidatedPrice(p.assetId);

        uint256 grossCollateralValue = (p.collateralAmount * price) / 1e18;
        uint256 haircutFactor = 10_000 - params_.collateralHaircutBps;

        return (grossCollateralValue * haircutFactor) / 10_000;
    }

    function expectedRescueCapital(uint256 positionId) public view returns (uint256) {
        return IExpectedLossEngineForHF(expectedLossEngine).expectedLoss(positionId);
    }

    function expectedRescueFee(uint256 positionId) public view returns (uint256) {
        uint256 rescueCapital = expectedRescueCapital(positionId);
        uint256 rescueProb = IExpectedLossEngineForHF(expectedLossEngine).rescueProbability(positionId);

        return (rescueCapital * rescueProb) / 10_000;
    }

    function liquidationExecutionBuffer(uint256 positionId) public view returns (uint256) {
        IPositionRegistryForHF.Position memory p =
            IPositionRegistryForHF(positionRegistry).getPosition(positionId);

        IParameterRegistryForHF.RiskParams memory params_ =
            IParameterRegistryForHF(parameterRegistry).getRiskParams(p.assetId);

        uint256 debt = _totalDebt(positionId);
        return (debt * params_.liquidationBufferBps) / 10_000;
    }

    function healthFactor(uint256 positionId) external view returns (uint256) {
        uint256 debt = _totalDebt(positionId);
        if (debt == 0) return type(uint256).max;

        uint256 adjustedCollateral = riskAdjustedCollateral(positionId);
        uint256 rescueCapital = expectedRescueCapital(positionId);
        uint256 rescueFee = expectedRescueFee(positionId);
        uint256 liqBuffer = liquidationExecutionBuffer(positionId);

        uint256 totalAdjustments = rescueCapital + rescueFee + liqBuffer;
        if (adjustedCollateral <= totalAdjustments) {
            return 0;
        }

        uint256 netCollateral = adjustedCollateral - totalAdjustments;
        return (netCollateral * 1e18) / debt;
    }

    function classify(uint256 positionId) external view returns (HealthClassification) {
        IPositionRegistryForHF.Position memory p =
            IPositionRegistryForHF(positionRegistry).getPosition(positionId);

        IParameterRegistryForHF.RiskParams memory params_ =
            IParameterRegistryForHF(parameterRegistry).getRiskParams(p.assetId);

        uint256 adjustedCollateral = riskAdjustedCollateral(positionId);
        if (adjustedCollateral == 0) revert InvalidCollateralValue();

        uint256 debt = _totalDebt(positionId);
        if (debt == 0) return HealthClassification.Healthy;

        uint256 currentLTVBps = (debt * 10_000) / adjustedCollateral;

        if (currentLTVBps <= params_.maxBorrowLTVBps) {
            return HealthClassification.Healthy;
        }
        if (currentLTVBps <= params_.rescueTriggerLTVBps) {
            return HealthClassification.AtRisk;
        }
        if (currentLTVBps <= params_.liquidationLTVBps) {
            return HealthClassification.RescueEligible;
        }
        return HealthClassification.Liquidatable;
    }

    function _totalDebt(uint256 positionId) internal view returns (uint256) {
        IDebtLedgerForHF.DebtRecord memory d =
            IDebtLedgerForHF(debtLedger).getDebtRecord(positionId);

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
