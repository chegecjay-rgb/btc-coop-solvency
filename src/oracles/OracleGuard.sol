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
    uint8 private constant NORMALIZED_DECIMALS = 18;
    uint256 private constant BPS_SCALE = 10_000;

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

    struct OracleObservation {
        address oracle;
        uint8 decimals;
        uint80 roundId;
        uint80 answeredInRound;
        int256 answer;
        uint256 updatedAt;
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

    // Strict solvency path: every configured feed must validate, and dual-feed quotes
    // must remain within maxDeviationBps before the contract returns a median price.
    function getValidatedPrice(bytes32 assetId) external view returns (uint256) {
        OracleConfig memory config = _requireOracleConfig(assetId);
        uint256 primaryPrice = _loadValidatedPrice(assetId, config.primaryOracle);

        if (config.secondaryOracle == address(0)) {
            return primaryPrice;
        }

        uint256 secondaryPrice = _loadValidatedPrice(assetId, config.secondaryOracle);
        return _boundedMedianPrice(assetId, primaryPrice, secondaryPrice);
    }

    // Lighter helper path: it still validates each feed, but it intentionally skips
    // the cross-feed deviation bound and always returns the median of valid feeds.
    function getMedianPrice(bytes32 assetId) external view returns (uint256) {
        OracleConfig memory config = _requireOracleConfig(assetId);
        uint256 primaryPrice = _loadValidatedPrice(assetId, config.primaryOracle);

        if (config.secondaryOracle == address(0)) {
            return primaryPrice;
        }

        uint256 secondaryPrice = _loadValidatedPrice(assetId, config.secondaryOracle);
        return _medianOfTwo(primaryPrice, secondaryPrice);
    }

    function _requireOracleConfig(bytes32 assetId) internal view returns (OracleConfig memory config) {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        config = _oracleConfigByAsset[assetId];
        if (config.primaryOracle == address(0)) revert AssetOracleNotSet(assetId);
    }

    // Audit flow: raw oracle read -> validation -> normalization.
    function _loadValidatedPrice(bytes32 assetId, address oracle) internal view returns (uint256) {
        OracleObservation memory observation = _readObservation(oracle);
        _validateObservation(assetId, observation);
        return _scaleTo1e18(uint256(observation.answer), observation.decimals);
    }

    function _readObservation(address oracle) internal view returns (OracleObservation memory observation) {
        IPriceOracle priceOracle = IPriceOracle(oracle);

        observation.oracle = oracle;
        observation.decimals = priceOracle.decimals();
        (observation.roundId, observation.answer,, observation.updatedAt, observation.answeredInRound) =
            priceOracle.latestRoundData();
    }

    // Shared fail-safe checks before any feed can influence protocol solvency logic.
    function _validateObservation(bytes32 assetId, OracleObservation memory observation) internal view {
        _requireSupportedDecimals(observation.decimals);
        _requireSaneRound(observation);
        _requireFreshRound(assetId, observation);
    }

    function _boundedMedianPrice(
        bytes32 assetId,
        uint256 primaryPrice,
        uint256 secondaryPrice
    ) internal view returns (uint256) {
        uint256 deviationBps = _deviationBps(primaryPrice, secondaryPrice);
        if (deviationBps > maxDeviationBps) {
            revert PriceDeviationTooHigh(assetId, deviationBps, maxDeviationBps);
        }

        return _medianOfTwo(primaryPrice, secondaryPrice);
    }

    function _requireSupportedDecimals(uint8 decimals) internal pure {
        if (decimals > NORMALIZED_DECIMALS) revert OracleDecimalsTooHigh(decimals);
    }

    function _requireSaneRound(OracleObservation memory observation) internal pure {
        if (
            observation.roundId == 0 ||
            observation.answer <= 0 ||
            observation.updatedAt == 0 ||
            observation.answeredInRound < observation.roundId
        ) {
            revert InvalidOracleResponse();
        }
    }

    function _requireFreshRound(bytes32 assetId, OracleObservation memory observation) internal view {
        if (observation.updatedAt > block.timestamp) revert InvalidOracleResponse();

        if (block.timestamp - observation.updatedAt > maxStaleness) {
            revert StalePrice(assetId, observation.oracle, observation.updatedAt, maxStaleness);
        }
    }

    function _scaleTo1e18(uint256 value, uint8 oracleDecimals) internal pure returns (uint256) {
        if (oracleDecimals == NORMALIZED_DECIMALS) return value;
        return value * (10 ** uint256(NORMALIZED_DECIMALS - oracleDecimals));
    }

    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 larger = a > b ? a : b;
        uint256 smaller = a > b ? b : a;
        return ((larger - smaller) * BPS_SCALE) / larger;
    }

    function _medianOfTwo(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 larger = a > b ? a : b;
        uint256 smaller = a > b ? b : a;
        return smaller + ((larger - smaller) / 2);
    }

    function _validateBps(uint256 value) internal pure {
        if (value > BPS_SCALE) revert PriceDeviationTooHigh(bytes32(0), value, BPS_SCALE);
    }
}
