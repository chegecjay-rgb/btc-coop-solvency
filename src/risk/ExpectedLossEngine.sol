// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPositionRegistryForExpectedLoss {
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

interface IDebtLedgerForExpectedLoss {
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

contract ExpectedLossEngine is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error InvalidBpsValue(uint256 value);

    address public immutable positionRegistry;
    address public immutable debtLedger;

    mapping(bytes32 => uint256) public volatilityBpsByAsset;
    mapping(bytes32 => uint256) public liquidityStressBpsByAsset;
    mapping(bytes32 => uint256) public recoveryRateBpsByAsset;

    event VolatilityBpsSet(bytes32 indexed assetId, uint256 value);
    event LiquidityStressBpsSet(bytes32 indexed assetId, uint256 value);
    event RecoveryRateBpsSet(bytes32 indexed assetId, uint256 value);

    constructor(
        address initialOwner,
        address positionRegistry_,
        address debtLedger_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || positionRegistry_ == address(0) || debtLedger_ == address(0)) {
            revert ZeroAddress();
        }

        positionRegistry = positionRegistry_;
        debtLedger = debtLedger_;
    }

    function setVolatilityBps(bytes32 assetId, uint256 value) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        _validateBps(value);

        volatilityBpsByAsset[assetId] = value;
        emit VolatilityBpsSet(assetId, value);
    }

    function setLiquidityStressBps(bytes32 assetId, uint256 value) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        _validateBps(value);

        liquidityStressBpsByAsset[assetId] = value;
        emit LiquidityStressBpsSet(assetId, value);
    }

    function setRecoveryRateBps(bytes32 assetId, uint256 value) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        _validateBps(value);

        recoveryRateBpsByAsset[assetId] = value;
        emit RecoveryRateBpsSet(assetId, value);
    }

    function rescueProbability(uint256 positionId) public view returns (uint256) {
        IPositionRegistryForExpectedLoss.Position memory p =
            IPositionRegistryForExpectedLoss(positionRegistry).getPosition(positionId);

        uint256 vol = volatilityBpsByAsset[p.assetId];
        uint256 liq = liquidityStressBpsByAsset[p.assetId];

        return _capBps((vol + liq) / 2);
    }

    function expectedLoss(uint256 positionId) external view returns (uint256) {
        IPositionRegistryForExpectedLoss.Position memory p =
            IPositionRegistryForExpectedLoss(positionRegistry).getPosition(positionId);
        IDebtLedgerForExpectedLoss.DebtRecord memory d =
            IDebtLedgerForExpectedLoss(debtLedger).getDebtRecord(positionId);

        uint256 debt = _totalDebt(d);
        uint256 rescueProb = rescueProbability(positionId);
        uint256 recovery = recoveryRateBpsByAsset[p.assetId];
        uint256 lossGivenFailure = 10_000 - recovery;

        return (debt * rescueProb * lossGivenFailure) / 100_000_000;
    }

    function expectedTerminalLoss(uint256 positionId) external view returns (uint256) {
        IPositionRegistryForExpectedLoss.Position memory p =
            IPositionRegistryForExpectedLoss(positionRegistry).getPosition(positionId);
        IDebtLedgerForExpectedLoss.DebtRecord memory d =
            IDebtLedgerForExpectedLoss(debtLedger).getDebtRecord(positionId);

        uint256 debt = _totalDebt(d);
        uint256 liquidityStress = liquidityStressBpsByAsset[p.assetId];
        uint256 recovery = recoveryRateBpsByAsset[p.assetId];
        uint256 lossGivenFailure = 10_000 - recovery;

        return (debt * liquidityStress * lossGivenFailure) / 100_000_000;
    }

    function rescueSensitivity(bytes32 assetId, uint256 shockBps) external view returns (uint256) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        uint256 shockedVol = volatilityBpsByAsset[assetId] + shockBps;
        uint256 liq = liquidityStressBpsByAsset[assetId];

        return _capBps((shockedVol + liq) / 2);
    }

    function _totalDebt(
        IDebtLedgerForExpectedLoss.DebtRecord memory d
    ) internal pure returns (uint256) {
        return
            d.principal +
            d.accruedInterest +
            d.rescueCapitalUsed +
            d.rescueFeesAccrued +
            d.insuranceCapitalUsed +
            d.insuranceChargesAccrued +
            d.settlementCosts;
    }

    function _validateBps(uint256 value) internal pure {
        if (value > 10_000) revert InvalidBpsValue(value);
    }

    function _capBps(uint256 value) internal pure returns (uint256) {
        return value > 10_000 ? 10_000 : value;
    }
}
