// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AssetRegistry is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error AssetAlreadyRegistered(bytes32 assetId);
    error AssetNotFound(bytes32 assetId);
    error InvalidDecimals(uint8 decimals);

    struct AssetConfig {
        address token;
        address oracle;
        bool isActive;
        uint8 decimals;
        bytes32 assetId;
        bytes32 interestModelId;
    }

    mapping(bytes32 => AssetConfig) private _assets;
    mapping(address => bytes32) private _assetIdByToken;

    event AssetRegistered(
        bytes32 indexed assetId,
        address indexed token,
        address indexed oracle,
        uint8 decimals,
        bytes32 interestModelId
    );

    event AssetStatusUpdated(bytes32 indexed assetId, bool isActive);
    event AssetOracleUpdated(bytes32 indexed assetId, address indexed oracle);
    event AssetInterestModelUpdated(bytes32 indexed assetId, bytes32 indexed interestModelId);

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function registerAsset(
        bytes32 assetId,
        address token,
        address oracle,
        uint8 decimals,
        bytes32 interestModelId
    ) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (token == address(0) || oracle == address(0)) revert ZeroAddress();
        if (decimals > 18) revert InvalidDecimals(decimals);
        if (_assets[assetId].assetId != bytes32(0)) revert AssetAlreadyRegistered(assetId);

        _assets[assetId] = AssetConfig({
            token: token,
            oracle: oracle,
            isActive: true,
            decimals: decimals,
            assetId: assetId,
            interestModelId: interestModelId
        });

        _assetIdByToken[token] = assetId;

        emit AssetRegistered(assetId, token, oracle, decimals, interestModelId);
    }

    function setAssetStatus(bytes32 assetId, bool active) external onlyOwner {
        AssetConfig storage config = _requireAsset(assetId);
        config.isActive = active;
        emit AssetStatusUpdated(assetId, active);
    }

    function setOracle(bytes32 assetId, address oracle) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        AssetConfig storage config = _requireAsset(assetId);
        config.oracle = oracle;
        emit AssetOracleUpdated(assetId, oracle);
    }

    function setInterestModelId(bytes32 assetId, bytes32 interestModelId) external onlyOwner {
        AssetConfig storage config = _requireAsset(assetId);
        config.interestModelId = interestModelId;
        emit AssetInterestModelUpdated(assetId, interestModelId);
    }

    function getAsset(bytes32 assetId) external view returns (AssetConfig memory) {
        return _requireAsset(assetId);
    }

    function getAssetConfig(bytes32 assetId) external view returns (AssetConfig memory) {
        return _requireAsset(assetId);
    }

    function getAssetIdByToken(address token) external view returns (bytes32) {
        return _assetIdByToken[token];
    }

    function isSupported(bytes32 assetId) external view returns (bool) {
        return _assets[assetId].assetId != bytes32(0);
    }

    function isActive(bytes32 assetId) external view returns (bool) {
        AssetConfig storage config = _requireAsset(assetId);
        return config.isActive;
    }

    function _requireAsset(bytes32 assetId) internal view returns (AssetConfig storage config) {
        config = _assets[assetId];
        if (config.assetId == bytes32(0)) revert AssetNotFound(assetId);
    }
}
