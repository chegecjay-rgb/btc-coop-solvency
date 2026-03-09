// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ParameterRegistry is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error ParamsNotFound(bytes32 assetId);
    error InvalidBpsValue(uint256 value);
    error InvalidRiskWindow();

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

    struct InsuranceParams {
        uint256 baseSystemInsuranceRateBps;
        uint256 baseOptionalCoverRateBps;
        uint256 maxCoverageBps;
    }

    struct RemoteLiquidityParams {
        uint256 minLocalLiquidityBps;
        uint256 highUtilizationBps;
        uint256 maxPendingRescueLoadBps;
        uint256 remoteIntentFeeCapBps;
        uint256 remoteIntentDeadline;
    }

    mapping(bytes32 => RiskParams) private _riskParamsByAsset;
    mapping(bytes32 => InsuranceParams) private _insuranceParamsByAsset;
    mapping(bytes32 => RemoteLiquidityParams) private _remoteParamsByAsset;

    event RiskParamsSet(
        bytes32 indexed assetId,
        uint256 maxBorrowLTVBps,
        uint256 rescueTriggerLTVBps,
        uint256 liquidationLTVBps,
        uint256 targetPostRescueLTVBps
    );

    event InsuranceParamsSet(
        bytes32 indexed assetId,
        uint256 baseSystemInsuranceRateBps,
        uint256 baseOptionalCoverRateBps,
        uint256 maxCoverageBps
    );

    event RemoteLiquidityParamsSet(
        bytes32 indexed assetId,
        uint256 minLocalLiquidityBps,
        uint256 highUtilizationBps,
        uint256 maxPendingRescueLoadBps,
        uint256 remoteIntentFeeCapBps,
        uint256 remoteIntentDeadline
    );

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function setRiskParams(bytes32 assetId, RiskParams calldata params_) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        _validateBps(params_.maxBorrowLTVBps);
        _validateBps(params_.rescueTriggerLTVBps);
        _validateBps(params_.liquidationLTVBps);
        _validateBps(params_.targetPostRescueLTVBps);
        _validateBps(params_.collateralHaircutBps);
        _validateBps(params_.liquidationBufferBps);

        if (
            !(params_.maxBorrowLTVBps <= params_.rescueTriggerLTVBps &&
              params_.rescueTriggerLTVBps <= params_.liquidationLTVBps)
        ) revert InvalidRiskWindow();

        _riskParamsByAsset[assetId] = params_;

        emit RiskParamsSet(
            assetId,
            params_.maxBorrowLTVBps,
            params_.rescueTriggerLTVBps,
            params_.liquidationLTVBps,
            params_.targetPostRescueLTVBps
        );
    }

    function getRiskParams(bytes32 assetId) external view returns (RiskParams memory) {
        RiskParams memory params_ = _riskParamsByAsset[assetId];
        if (_isUnsetRisk(params_)) revert ParamsNotFound(assetId);
        return params_;
    }

    function hasRiskParams(bytes32 assetId) external view returns (bool) {
        return !_isUnsetRisk(_riskParamsByAsset[assetId]);
    }

    function setInsuranceParams(bytes32 assetId, InsuranceParams calldata params_) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        _validateBps(params_.baseSystemInsuranceRateBps);
        _validateBps(params_.baseOptionalCoverRateBps);
        _validateBps(params_.maxCoverageBps);

        _insuranceParamsByAsset[assetId] = params_;

        emit InsuranceParamsSet(
            assetId,
            params_.baseSystemInsuranceRateBps,
            params_.baseOptionalCoverRateBps,
            params_.maxCoverageBps
        );
    }

    function getInsuranceParams(bytes32 assetId) external view returns (InsuranceParams memory) {
        InsuranceParams memory params_ = _insuranceParamsByAsset[assetId];
        if (_isUnsetInsurance(params_)) revert ParamsNotFound(assetId);
        return params_;
    }

    function hasInsuranceParams(bytes32 assetId) external view returns (bool) {
        return !_isUnsetInsurance(_insuranceParamsByAsset[assetId]);
    }

    function setRemoteLiquidityParams(
        bytes32 assetId,
        RemoteLiquidityParams calldata params_
    ) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        _validateBps(params_.minLocalLiquidityBps);
        _validateBps(params_.highUtilizationBps);
        _validateBps(params_.maxPendingRescueLoadBps);
        _validateBps(params_.remoteIntentFeeCapBps);

        _remoteParamsByAsset[assetId] = params_;

        emit RemoteLiquidityParamsSet(
            assetId,
            params_.minLocalLiquidityBps,
            params_.highUtilizationBps,
            params_.maxPendingRescueLoadBps,
            params_.remoteIntentFeeCapBps,
            params_.remoteIntentDeadline
        );
    }

    function getRemoteLiquidityParams(
        bytes32 assetId
    ) external view returns (RemoteLiquidityParams memory) {
        RemoteLiquidityParams memory params_ = _remoteParamsByAsset[assetId];
        if (_isUnsetRemote(params_)) revert ParamsNotFound(assetId);
        return params_;
    }

    function hasRemoteLiquidityParams(bytes32 assetId) external view returns (bool) {
        return !_isUnsetRemote(_remoteParamsByAsset[assetId]);
    }

    function _validateBps(uint256 value) internal pure {
        if (value > 10_000) revert InvalidBpsValue(value);
    }

    function _isUnsetRisk(RiskParams memory p) internal pure returns (bool) {
        return
            p.maxBorrowLTVBps == 0 &&
            p.rescueTriggerLTVBps == 0 &&
            p.liquidationLTVBps == 0 &&
            p.targetPostRescueLTVBps == 0 &&
            p.collateralHaircutBps == 0 &&
            p.liquidationBufferBps == 0 &&
            p.maxRescueAttempts == 0 &&
            p.rescueCooldown == 0 &&
            p.buybackClaimDuration == 0;
    }

    function _isUnsetInsurance(InsuranceParams memory p) internal pure returns (bool) {
        return
            p.baseSystemInsuranceRateBps == 0 &&
            p.baseOptionalCoverRateBps == 0 &&
            p.maxCoverageBps == 0;
    }

    function _isUnsetRemote(RemoteLiquidityParams memory p) internal pure returns (bool) {
        return
            p.minLocalLiquidityBps == 0 &&
            p.highUtilizationBps == 0 &&
            p.maxPendingRescueLoadBps == 0 &&
            p.remoteIntentFeeCapBps == 0 &&
            p.remoteIntentDeadline == 0;
    }
}
