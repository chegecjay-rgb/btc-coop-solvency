// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ParameterRegistry is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error AssetParamsNotFound(bytes32 assetId);
    error InvalidBpsValue(uint256 value);
    error InvalidRiskWindow();

    struct RiskParams {
        uint256 maxBorrowLTV;
        uint256 rescueTriggerLTV;
        uint256 liquidationLTV;
        uint256 targetPostRescueLTV;
        uint256 collateralHaircutBps;
        uint256 liquidationBufferBps;
        uint256 maxRescueAttempts;
        uint256 rescueCooldown;
        uint256 buybackClaimDuration;
        uint256 remoteIntentFeeCapBps;
        uint256 remoteIntentMaxSize;
        uint256 remoteIntentExpiry;
        uint256 remoteFillMinBps;
        uint256 remoteLiquidityStressTriggerBps;
        uint256 maxRemoteDependencyBps;
        uint256 maxSolverConcentrationBps;
    }

    mapping(bytes32 => RiskParams) private _riskParamsByAsset;
    mapping(bytes32 => uint256) private _globalParams;

    event RiskParamsSet(
        bytes32 indexed assetId,
        uint256 maxBorrowLTV,
        uint256 rescueTriggerLTV,
        uint256 liquidationLTV,
        uint256 targetPostRescueLTV
    );

    event GlobalParamSet(bytes32 indexed key, uint256 value);

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function setRiskParams(bytes32 assetId, RiskParams calldata params) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        _validateBps(params.maxBorrowLTV);
        _validateBps(params.rescueTriggerLTV);
        _validateBps(params.liquidationLTV);
        _validateBps(params.targetPostRescueLTV);
        _validateBps(params.collateralHaircutBps);
        _validateBps(params.liquidationBufferBps);
        _validateBps(params.remoteIntentFeeCapBps);
        _validateBps(params.remoteFillMinBps);
        _validateBps(params.remoteLiquidityStressTriggerBps);
        _validateBps(params.maxRemoteDependencyBps);
        _validateBps(params.maxSolverConcentrationBps);

        if (
            !(params.maxBorrowLTV <= params.rescueTriggerLTV &&
              params.rescueTriggerLTV <= params.liquidationLTV)
        ) revert InvalidRiskWindow();

        _riskParamsByAsset[assetId] = params;

        emit RiskParamsSet(
            assetId,
            params.maxBorrowLTV,
            params.rescueTriggerLTV,
            params.liquidationLTV,
            params.targetPostRescueLTV
        );
    }

    function setGlobalParam(bytes32 key, uint256 value) external onlyOwner {
        if (key == bytes32(0)) revert InvalidAssetId();
        _globalParams[key] = value;
        emit GlobalParamSet(key, value);
    }

    function getRiskParams(bytes32 assetId) external view returns (RiskParams memory) {
        RiskParams memory params = _riskParamsByAsset[assetId];
        if (_isUnset(params)) revert AssetParamsNotFound(assetId);
        return params;
    }

    function getGlobalParam(bytes32 key) external view returns (uint256) {
        return _globalParams[key];
    }

    function hasRiskParams(bytes32 assetId) external view returns (bool) {
        return !_isUnset(_riskParamsByAsset[assetId]);
    }

    function _validateBps(uint256 value) internal pure {
        if (value > 10_000) revert InvalidBpsValue(value);
    }

    function _isUnset(RiskParams memory params) internal pure returns (bool) {
        return
            params.maxBorrowLTV == 0 &&
            params.rescueTriggerLTV == 0 &&
            params.liquidationLTV == 0 &&
            params.targetPostRescueLTV == 0 &&
            params.collateralHaircutBps == 0 &&
            params.liquidationBufferBps == 0 &&
            params.maxRescueAttempts == 0 &&
            params.rescueCooldown == 0 &&
            params.buybackClaimDuration == 0 &&
            params.remoteIntentFeeCapBps == 0 &&
            params.remoteIntentMaxSize == 0 &&
            params.remoteIntentExpiry == 0 &&
            params.remoteFillMinBps == 0 &&
            params.remoteLiquidityStressTriggerBps == 0 &&
            params.maxRemoteDependencyBps == 0 &&
            params.maxSolverConcentrationBps == 0;
    }
}
