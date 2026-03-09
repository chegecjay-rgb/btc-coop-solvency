// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract InterestRateModel is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error InvalidBpsValue(uint256 value);
    error InvalidOptimalUtilization(uint256 value);
    error InvalidRevenueSplit(uint256 stabilizer, uint256 insurance, uint256 treasury);

    struct RateCurve {
        uint256 baseRateBps;
        uint256 slope1Bps;
        uint256 slope2Bps;
        uint256 optimalUtilizationBps;
        uint256 crisisPremiumBps;
    }

    struct RevenueSplit {
        uint256 stabilizerShareBps;
        uint256 insuranceShareBps;
        uint256 treasuryShareBps;
    }

    mapping(bytes32 => RateCurve) public curveByAsset;
    mapping(bytes32 => RevenueSplit) public revenueSplitByAsset;

    event RateCurveSet(
        bytes32 indexed assetId,
        uint256 baseRateBps,
        uint256 slope1Bps,
        uint256 slope2Bps,
        uint256 optimalUtilizationBps,
        uint256 crisisPremiumBps
    );

    event RevenueSplitSet(
        bytes32 indexed assetId,
        uint256 stabilizerShareBps,
        uint256 insuranceShareBps,
        uint256 treasuryShareBps
    );

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function setRateCurve(bytes32 assetId, RateCurve calldata curve) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        _validateBps(curve.baseRateBps);
        _validateBps(curve.slope1Bps);
        _validateBps(curve.slope2Bps);
        _validateBps(curve.crisisPremiumBps);

        if (curve.optimalUtilizationBps == 0 || curve.optimalUtilizationBps > 10_000) {
            revert InvalidOptimalUtilization(curve.optimalUtilizationBps);
        }

        curveByAsset[assetId] = curve;

        emit RateCurveSet(
            assetId,
            curve.baseRateBps,
            curve.slope1Bps,
            curve.slope2Bps,
            curve.optimalUtilizationBps,
            curve.crisisPremiumBps
        );
    }

    function setRevenueSplit(
        bytes32 assetId,
        uint256 stabilizerShare,
        uint256 insuranceShare,
        uint256 treasuryShare
    ) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();

        _validateBps(stabilizerShare);
        _validateBps(insuranceShare);
        _validateBps(treasuryShare);

        if (stabilizerShare + insuranceShare + treasuryShare > 10_000) {
            revert InvalidRevenueSplit(stabilizerShare, insuranceShare, treasuryShare);
        }

        revenueSplitByAsset[assetId] = RevenueSplit({
            stabilizerShareBps: stabilizerShare,
            insuranceShareBps: insuranceShare,
            treasuryShareBps: treasuryShare
        });

        emit RevenueSplitSet(assetId, stabilizerShare, insuranceShare, treasuryShare);
    }

    function borrowRate(
        bytes32 assetId,
        uint256 utilizationBps,
        uint256 currentLTVBps
    ) external view returns (uint256) {
        RateCurve memory curve = curveByAsset[assetId];

        uint256 utilizationPremium = _utilizationPremium(curve, utilizationBps);
        uint256 ltvPremium = _ltvPremium(currentLTVBps);
        uint256 crisisPremium = utilizationBps > curve.optimalUtilizationBps ? curve.crisisPremiumBps : 0;

        return curve.baseRateBps + utilizationPremium + ltvPremium + crisisPremium;
    }

    function stabilizerShareBps(bytes32 assetId) external view returns (uint256) {
        return revenueSplitByAsset[assetId].stabilizerShareBps;
    }

    function insuranceShareBps(bytes32 assetId) external view returns (uint256) {
        return revenueSplitByAsset[assetId].insuranceShareBps;
    }

    function treasuryShareBps(bytes32 assetId) external view returns (uint256) {
        return revenueSplitByAsset[assetId].treasuryShareBps;
    }

    function _utilizationPremium(
        RateCurve memory curve,
        uint256 utilizationBps
    ) internal pure returns (uint256) {
        if (utilizationBps == 0) return 0;

        if (utilizationBps <= curve.optimalUtilizationBps) {
            return (curve.slope1Bps * utilizationBps) / curve.optimalUtilizationBps;
        }

        uint256 premiumBelowKink = curve.slope1Bps;
        uint256 excessUtilization = utilizationBps - curve.optimalUtilizationBps;
        uint256 remainingRange = 10_000 - curve.optimalUtilizationBps;

        if (remainingRange == 0) return premiumBelowKink;

        uint256 premiumAboveKink = (curve.slope2Bps * excessUtilization) / remainingRange;
        return premiumBelowKink + premiumAboveKink;
    }

    function _ltvPremium(uint256 currentLTVBps) internal pure returns (uint256) {
        if (currentLTVBps <= 5_000) return 0;
        if (currentLTVBps <= 7_000) return 100;
        if (currentLTVBps <= 8_000) return 300;
        if (currentLTVBps <= 9_000) return 600;
        return 1_000;
    }

    function _validateBps(uint256 value) internal pure {
        if (value > 10_000) revert InvalidBpsValue(value);
    }
}
