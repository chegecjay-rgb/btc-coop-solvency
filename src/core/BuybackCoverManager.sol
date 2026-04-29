// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPositionRegistryForCover {
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
    function ownerOfPosition(uint256 positionId) external view returns (address);
}

interface IParameterRegistryForCover {
    struct InsuranceParams {
        uint256 baseSystemInsuranceRateBps;
        uint256 baseOptionalCoverRateBps;
        uint256 maxCoverageBps;
    }

    function getInsuranceParams(bytes32 assetId) external view returns (InsuranceParams memory);
}

interface IInsuranceReserveForCover {
    function reserveOptionalCover(uint256 positionId, uint256 amount) external;
}

interface IProtocolRevenueRouterForCover {
    function routeHeldRevenue(uint8 feeKind, bytes32 assetId, uint256 amount) external;
}

contract BuybackCoverManager is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error PositionNotEligible(uint256 positionId);
    error NotPositionOwner(uint256 positionId, address caller);
    error CoverAlreadyActive(uint256 positionId);
    error InactiveCover(uint256 positionId);
    error TransferFailed();

    uint8 internal constant FEE_KIND_INSURANCE_PREMIUM = 2;
    uint256 public constant COVER_DURATION = 30 days;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct CoverTerms {
        uint256 premiumPaid;
        uint256 coverageLimit;
        uint256 expiry;
        bool active;
    }

    address public immutable positionRegistry;
    address public immutable parameterRegistry;
    address public immutable insuranceReserve;
    address public immutable stableToken;
    address public immutable protocolRevenueRouter;

    mapping(uint256 => CoverTerms) public coverByPosition;

    event CoverPurchased(
        uint256 indexed positionId,
        bytes32 indexed assetId,
        address indexed owner,
        uint256 premiumPaid,
        uint256 coverageLimit,
        uint256 expiry
    );

    event CoverClaimed(uint256 indexed positionId);

    constructor(
        address initialOwner,
        address positionRegistry_,
        address parameterRegistry_,
        address insuranceReserve_,
        address stableToken_,
        address protocolRevenueRouter_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || positionRegistry_ == address(0) || parameterRegistry_ == address(0)
                || insuranceReserve_ == address(0) || stableToken_ == address(0) || protocolRevenueRouter_ == address(0)
        ) revert ZeroAddress();

        positionRegistry = positionRegistry_;
        parameterRegistry = parameterRegistry_;
        insuranceReserve = insuranceReserve_;
        stableToken = stableToken_;
        protocolRevenueRouter = protocolRevenueRouter_;
    }

    function quoteCover(uint256 positionId)
        public
        view
        returns (uint256 premium, uint256 coverageLimit, uint256 expiry)
    {
        if (positionId == 0) {
            revert InvalidPositionId(positionId);
        }

        IPositionRegistryForCover.Position memory p =
            IPositionRegistryForCover(positionRegistry).getPosition(positionId);

        if (!p.hasBuybackCover || p.debtPrincipal == 0) {
            revert PositionNotEligible(positionId);
        }

        CoverTerms memory existing = coverByPosition[positionId];
        if (existing.active && existing.expiry >= block.timestamp) {
            revert CoverAlreadyActive(positionId);
        }

        IParameterRegistryForCover.InsuranceParams memory params =
            IParameterRegistryForCover(parameterRegistry).getInsuranceParams(p.assetId);

        coverageLimit = (p.debtPrincipal * params.maxCoverageBps) / BPS_DENOMINATOR;
        if (coverageLimit == 0) revert PositionNotEligible(positionId);

        premium = (coverageLimit * params.baseOptionalCoverRateBps) / BPS_DENOMINATOR;
        if (premium == 0) revert PositionNotEligible(positionId);

        expiry = block.timestamp + COVER_DURATION;
    }

    function purchaseCover(uint256 positionId) external {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IPositionRegistryForCover.Position memory p =
            IPositionRegistryForCover(positionRegistry).getPosition(positionId);

        if (p.owner != msg.sender) {
            revert NotPositionOwner(positionId, msg.sender);
        }

        (uint256 premium, uint256 coverageLimit, uint256 expiry) = quoteCover(positionId);

        _collectAndRoutePremium(p.assetId, msg.sender, premium);

        IInsuranceReserveForCover(insuranceReserve).reserveOptionalCover(positionId, coverageLimit);

        coverByPosition[positionId] =
            CoverTerms({premiumPaid: premium, coverageLimit: coverageLimit, expiry: expiry, active: true});

        emit CoverPurchased(positionId, p.assetId, msg.sender, premium, coverageLimit, expiry);
    }

    function isCovered(uint256 positionId) external view returns (bool) {
        CoverTerms memory cover = coverByPosition[positionId];
        return cover.active && cover.expiry >= block.timestamp;
    }

    function markClaimed(uint256 positionId) external onlyOwner {
        CoverTerms storage cover = coverByPosition[positionId];
        if (!cover.active) revert InactiveCover(positionId);

        cover.active = false;

        emit CoverClaimed(positionId);
    }

    function _collectAndRoutePremium(bytes32 assetId, address payer, uint256 premium) internal {
        if (!IERC20(stableToken).transferFrom(payer, address(this), premium)) {
            revert TransferFailed();
        }

        if (!IERC20(stableToken).transfer(protocolRevenueRouter, premium)) {
            revert TransferFailed();
        }

        IProtocolRevenueRouterForCover(protocolRevenueRouter)
            .routeHeldRevenue(FEE_KIND_INSURANCE_PREMIUM, assetId, premium);
    }
}
