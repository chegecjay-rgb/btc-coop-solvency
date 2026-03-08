// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPriceOracle {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract OracleGuard is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error AssetOracleNotSet(bytes32 assetId);
    error InvalidOracleResponse();
    error StalePrice(bytes32 assetId, address oracle, uint256 updatedAt, uint256 maxStaleness);
    error PriceDeviationTooHigh(bytes32 assetId, uint256 deviationBps, uint256 maxDeviationBps);
    error OracleDecimalsTooHigh(uint8 decimals);

    struct OracleConfig {
        address primaryOracle;
        address secondaryOracle;
    }

    mapping(bytes32 => OracleConfig) private _oracleConfigByAsset;

    uint256 public maxDeviationBps;
    uint256 public maxStaleness;

    event OracleConfigSet(
        bytes32 indexed assetId,
        address indexed primaryOracle,
        address indexed secondaryOracle
    );

    event MaxDeviationBpsSet(uint256 newValue);
    event MaxStalenessSet(uint256 newValue);

    constructor(
        address initialOwner,
        uint256 initialMaxDeviationBps,
        uint256 initialMaxStaleness
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        _validateBps(initialMaxDeviationBps);

        maxDeviationBps = initialMaxDeviationBps;
        maxStaleness = initialMaxStaleness;
    }

    function setOracleConfig(
        bytes32 assetId,
        address primaryOracle,
        address secondaryOracle
    ) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (primaryOracle == address(0)) revert ZeroAddress();

        _oracleConfigByAsset[assetId] = OracleConfig({
            primaryOracle: primaryOracle,
            secondaryOracle: secondaryOracle
        });

        emit OracleConfigSet(assetId, primaryOracle, secondaryOracle);
    }

    function setMaxDeviationBps(uint256 newValue) external onlyOwner {
        _validateBps(newValue);
        maxDeviationBps = newValue;
        emit MaxDeviationBpsSet(newValue);
    }

    function setMaxStaleness(uint256 newValue) external onlyOwner {
        maxStaleness = newValue;
        emit MaxStalenessSet(newValue);
    }

    function getOracleConfig(bytes32 assetId) external view returns (OracleConfig memory) {
        OracleConfig memory config = _oracleConfigByAsset[assetId];
        if (config.primaryOracle == address(0)) revert AssetOracleNotSet(assetId);
        return config;
    }

    function isPriceValid(bytes32 assetId) external view returns (bool) {
        try this.getValidatedPrice(assetId) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function getValidatedPrice(bytes32 assetId) external view returns (uint256) {
        OracleConfig memory config = _requireOracleConfig(assetId);

        uint256 primaryPrice = _readOracle(assetId, config.primaryOracle);

        if (config.secondaryOracle == address(0)) {
            return primaryPrice;
        }

        uint256 secondaryPrice = _readOracle(assetId, config.secondaryOracle);
        uint256 deviationBps = _deviationBps(primaryPrice, secondaryPrice);

        if (deviationBps > maxDeviationBps) {
            revert PriceDeviationTooHigh(assetId, deviationBps, maxDeviationBps);
        }

        return _medianOfTwo(primaryPrice, secondaryPrice);
    }

    function getMedianPrice(bytes32 assetId) external view returns (uint256) {
        OracleConfig memory config = _requireOracleConfig(assetId);

        uint256 primaryPrice = _readOracle(assetId, config.primaryOracle);

        if (config.secondaryOracle == address(0)) {
            return primaryPrice;
        }

        uint256 secondaryPrice = _readOracle(assetId, config.secondaryOracle);
        return _medianOfTwo(primaryPrice, secondaryPrice);
    }

    function _requireOracleConfig(bytes32 assetId) internal view returns (OracleConfig memory config) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        config = _oracleConfigByAsset[assetId];
        if (config.primaryOracle == address(0)) revert AssetOracleNotSet(assetId);
    }

    function _readOracle(bytes32 assetId, address oracle) internal view returns (uint256 normalizedPrice) {
        uint8 oracleDecimals = IPriceOracle(oracle).decimals();
        if (oracleDecimals > 18) revert OracleDecimalsTooHigh(oracleDecimals);

        (, int256 answer,, uint256 updatedAt,) = IPriceOracle(oracle).latestRoundData();

        if (answer <= 0) revert InvalidOracleResponse();
        if (block.timestamp > updatedAt + maxStaleness) {
            revert StalePrice(assetId, oracle, updatedAt, maxStaleness);
        }

        normalizedPrice = _scaleTo1e18(uint256(answer), oracleDecimals);
    }

    function _scaleTo1e18(uint256 value, uint8 oracleDecimals) internal pure returns (uint256) {
        if (oracleDecimals == 18) return value;
        return value * (10 ** (18 - oracleDecimals));
    }

    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 larger = a > b ? a : b;
        uint256 smaller = a > b ? b : a;
        return ((larger - smaller) * 10_000) / larger;
    }

    function _medianOfTwo(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b) / 2;
    }

    function _validateBps(uint256 value) internal pure {
        if (value > 10_000) revert PriceDeviationTooHigh(bytes32(0), value, 10_000);
    }
}
