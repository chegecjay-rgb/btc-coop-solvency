// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IInterestRateModelRevenue {
    function stabilizerShareBps(bytes32 assetId) external view returns (uint256);
    function insuranceShareBps(bytes32 assetId) external view returns (uint256);
    function treasuryShareBps(bytes32 assetId) external view returns (uint256);
}

interface ILendingLiquidityVaultRevenue {
    function receiveRepaymentFrom(address payer, uint256 amount) external;
}

interface IStabilizationPoolRevenue {
    function depositStable(bytes32 assetId, uint256 amount) external;
}

interface IInsuranceReserveRevenue {
    function depositReserve(uint256 amount) external;
}

interface ITreasuryVaultRevenue {
    function receiveProtocolRevenue(uint256 amount) external;
}

contract ProtocolRevenueRouter is Ownable {
    error ZeroAddress();
    error ZeroAssetId();
    error InvalidAmount();
    error NotAuthorizedCollector();
    error RouteNotConfigured(bytes32 assetId);
    error SplitNotConfigured(bytes32 assetId, uint8 feeKind);
    error InvalidSplitBps(uint256 totalBps);

    uint256 public constant BPS_DENOMINATOR = 10_000;

    enum FeeKind {
        BorrowInterest,
        RescueFee,
        InsurancePremium,
        SettlementCost,
        RemoteLiquidityFee
    }

    struct RouteConfig {
        address feeToken;
        address lendingVault;
        address stabilizationPool;
        address insuranceReserve;
        address treasuryVault;
        bool configured;
    }

    struct FeeSplit {
        uint16 lenderShareBps;
        uint16 stabilizerShareBps;
        uint16 insuranceShareBps;
        uint16 treasuryShareBps;
        bool configured;
    }

    address public immutable interestRateModel;

    mapping(bytes32 => RouteConfig) public routeByAssetId;
    mapping(bytes32 => mapping(uint8 => FeeSplit)) public feeSplitByAssetIdAndKind;
    mapping(address => bool) public authorizedCollector;

    event AuthorizedCollectorSet(address indexed collector, bool allowed);

    event RouteConfigured(
        bytes32 indexed assetId,
        address indexed feeToken,
        address indexed lendingVault,
        address stabilizationPool,
        address insuranceReserve,
        address treasuryVault
    );

    event FeeSplitConfigured(
        bytes32 indexed assetId,
        uint8 indexed feeKind,
        uint16 lenderShareBps,
        uint16 stabilizerShareBps,
        uint16 insuranceShareBps,
        uint16 treasuryShareBps
    );

    event RevenueReceived(
        FeeKind indexed feeKind,
        bytes32 indexed assetId,
        address indexed payer,
        uint256 amount
    );

    event RevenueRouted(
        FeeKind indexed feeKind,
        bytes32 indexed assetId,
        uint256 lenderAmount,
        uint256 stabilizerAmount,
        uint256 insuranceAmount,
        uint256 treasuryAmount
    );

    constructor(address initialOwner, address interestRateModel_)
        Ownable(initialOwner)
    {
        if (initialOwner == address(0) || interestRateModel_ == address(0)) {
            revert ZeroAddress();
        }

        interestRateModel = interestRateModel_;
    }

    modifier onlyAuthorizedCollector() {
        if (!(authorizedCollector[msg.sender] || msg.sender == owner())) {
            revert NotAuthorizedCollector();
        }
        _;
    }

    function setAuthorizedCollector(address collector, bool allowed) external onlyOwner {
        if (collector == address(0)) revert ZeroAddress();

        authorizedCollector[collector] = allowed;
        emit AuthorizedCollectorSet(collector, allowed);
    }

    function setRoute(
        bytes32 assetId,
        address feeToken,
        address lendingVault,
        address stabilizationPool,
        address insuranceReserve,
        address treasuryVault
    ) external onlyOwner {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (
            feeToken == address(0) ||
            lendingVault == address(0) ||
            stabilizationPool == address(0) ||
            insuranceReserve == address(0) ||
            treasuryVault == address(0)
        ) revert ZeroAddress();

        routeByAssetId[assetId] = RouteConfig({
            feeToken: feeToken,
            lendingVault: lendingVault,
            stabilizationPool: stabilizationPool,
            insuranceReserve: insuranceReserve,
            treasuryVault: treasuryVault,
            configured: true
        });

        emit RouteConfigured(
            assetId,
            feeToken,
            lendingVault,
            stabilizationPool,
            insuranceReserve,
            treasuryVault
        );
    }

    function setFeeSplit(
        bytes32 assetId,
        FeeKind feeKind,
        uint16 lenderShareBps,
        uint16 stabilizerShareBps,
        uint16 insuranceShareBps,
        uint16 treasuryShareBps
    ) external onlyOwner {
        if (assetId == bytes32(0)) revert ZeroAssetId();

        uint256 total =
            uint256(lenderShareBps) +
            uint256(stabilizerShareBps) +
            uint256(insuranceShareBps) +
            uint256(treasuryShareBps);

        if (total != BPS_DENOMINATOR) revert InvalidSplitBps(total);

        feeSplitByAssetIdAndKind[assetId][uint8(feeKind)] = FeeSplit({
            lenderShareBps: lenderShareBps,
            stabilizerShareBps: stabilizerShareBps,
            insuranceShareBps: insuranceShareBps,
            treasuryShareBps: treasuryShareBps,
            configured: true
        });

        emit FeeSplitConfigured(
            assetId,
            uint8(feeKind),
            lenderShareBps,
            stabilizerShareBps,
            insuranceShareBps,
            treasuryShareBps
        );
    }

    function previewDistribution(FeeKind feeKind, bytes32 assetId, uint256 amount)
        external
        view
        returns (
            uint256 lenderAmount,
            uint256 stabilizerAmount,
            uint256 insuranceAmount,
            uint256 treasuryAmount
        )
    {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (amount == 0) revert InvalidAmount();

        FeeSplit memory split = _resolveSplit(feeKind, assetId);

        lenderAmount = (amount * split.lenderShareBps) / BPS_DENOMINATOR;
        stabilizerAmount = (amount * split.stabilizerShareBps) / BPS_DENOMINATOR;
        insuranceAmount = (amount * split.insuranceShareBps) / BPS_DENOMINATOR;
        treasuryAmount = amount - lenderAmount - stabilizerAmount - insuranceAmount;
    }

    function routeRevenueFrom(
        FeeKind feeKind,
        bytes32 assetId,
        address payer,
        uint256 amount
    ) external onlyAuthorizedCollector {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        RouteConfig memory route = routeByAssetId[assetId];
        if (!route.configured) revert RouteNotConfigured(assetId);

        IERC20(route.feeToken).transferFrom(payer, address(this), amount);

        emit RevenueReceived(feeKind, assetId, payer, amount);

        _routeRevenue(feeKind, assetId, amount, route);
    }

    function routeHeldRevenue(
        FeeKind feeKind,
        bytes32 assetId,
        uint256 amount
    ) external onlyAuthorizedCollector {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (amount == 0) revert InvalidAmount();

        RouteConfig memory route = routeByAssetId[assetId];
        if (!route.configured) revert RouteNotConfigured(assetId);

        emit RevenueReceived(feeKind, assetId, address(this), amount);

        _routeRevenue(feeKind, assetId, amount, route);
    }

    function _routeRevenue(
        FeeKind feeKind,
        bytes32 assetId,
        uint256 amount,
        RouteConfig memory route
    ) internal {
        FeeSplit memory split = _resolveSplit(feeKind, assetId);

        uint256 lenderAmount = (amount * split.lenderShareBps) / BPS_DENOMINATOR;
        uint256 stabilizerAmount = (amount * split.stabilizerShareBps) / BPS_DENOMINATOR;
        uint256 insuranceAmount = (amount * split.insuranceShareBps) / BPS_DENOMINATOR;
        uint256 treasuryAmount = amount - lenderAmount - stabilizerAmount - insuranceAmount;

        if (lenderAmount > 0) {
            IERC20(route.feeToken).approve(route.lendingVault, 0);
            IERC20(route.feeToken).approve(route.lendingVault, lenderAmount);
            ILendingLiquidityVaultRevenue(route.lendingVault).receiveRepaymentFrom(
                address(this),
                lenderAmount
            );
        }

        if (stabilizerAmount > 0) {
            IERC20(route.feeToken).approve(route.stabilizationPool, 0);
            IERC20(route.feeToken).approve(route.stabilizationPool, stabilizerAmount);
            IStabilizationPoolRevenue(route.stabilizationPool).depositStable(
                assetId,
                stabilizerAmount
            );
        }

        if (insuranceAmount > 0) {
            IERC20(route.feeToken).approve(route.insuranceReserve, 0);
            IERC20(route.feeToken).approve(route.insuranceReserve, insuranceAmount);
            IInsuranceReserveRevenue(route.insuranceReserve).depositReserve(insuranceAmount);
        }

        if (treasuryAmount > 0) {
            IERC20(route.feeToken).approve(route.treasuryVault, 0);
            IERC20(route.feeToken).approve(route.treasuryVault, treasuryAmount);
            ITreasuryVaultRevenue(route.treasuryVault).receiveProtocolRevenue(treasuryAmount);
        }

        emit RevenueRouted(
            feeKind,
            assetId,
            lenderAmount,
            stabilizerAmount,
            insuranceAmount,
            treasuryAmount
        );
    }

    function _resolveSplit(FeeKind feeKind, bytes32 assetId)
        internal
        view
        returns (FeeSplit memory split)
    {
        if (feeKind == FeeKind.BorrowInterest) {
            uint256 stabilizerShare =
                IInterestRateModelRevenue(interestRateModel).stabilizerShareBps(assetId);
            uint256 insuranceShare =
                IInterestRateModelRevenue(interestRateModel).insuranceShareBps(assetId);
            uint256 treasuryShare =
                IInterestRateModelRevenue(interestRateModel).treasuryShareBps(assetId);

            uint256 nonLenderTotal = stabilizerShare + insuranceShare + treasuryShare;
            if (nonLenderTotal > BPS_DENOMINATOR) revert InvalidSplitBps(nonLenderTotal);

            split = FeeSplit({
                lenderShareBps: uint16(BPS_DENOMINATOR - nonLenderTotal),
                stabilizerShareBps: uint16(stabilizerShare),
                insuranceShareBps: uint16(insuranceShare),
                treasuryShareBps: uint16(treasuryShare),
                configured: true
            });
        } else {
            split = feeSplitByAssetIdAndKind[assetId][uint8(feeKind)];
            if (!split.configured) revert SplitNotConfigured(assetId, uint8(feeKind));
        }
    }
}
