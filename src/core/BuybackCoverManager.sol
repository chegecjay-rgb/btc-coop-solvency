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

contract BuybackCoverManager is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error InvalidAmount();
    error NotPositionOwner(uint256 positionId, address caller);
    error PositionNotEligible(uint256 positionId);
    error CoverAlreadyPurchased(uint256 positionId);
    error CoverNotActive(uint256 positionId);

    struct CoverTerms {
        uint256 premiumPaid;
        uint256 coverageLimit;
        uint256 expiry;
        bool active;
    }

    address public immutable positionRegistry;
    address public immutable parameterRegistry;
    address public immutable insuranceReserve;
    address public immutable premiumToken;

    mapping(uint256 => CoverTerms) public coverByPosition;
    mapping(address => bool) public authorizedWriter;

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event CoverPurchased(
        uint256 indexed positionId,
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
        address premiumToken_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            positionRegistry_ == address(0) ||
            parameterRegistry_ == address(0) ||
            insuranceReserve_ == address(0) ||
            premiumToken_ == address(0)
        ) revert ZeroAddress();

        positionRegistry = positionRegistry_;
        parameterRegistry = parameterRegistry_;
        insuranceReserve = insuranceReserve_;
        premiumToken = premiumToken_;
    }

    modifier onlyAuthorized() {
        if (!(authorizedWriter[msg.sender] || msg.sender == owner())) revert ZeroAddress();
        _;
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        authorizedWriter[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function quoteCover(uint256 positionId)
        public
        view
        returns (uint256 premium, uint256 coverageLimit, uint256 expiry)
    {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IPositionRegistryForCover.Position memory p =
            IPositionRegistryForCover(positionRegistry).getPosition(positionId);

        if (!p.hasBuybackCover) revert PositionNotEligible(positionId);

        IParameterRegistryForCover.InsuranceParams memory params_ =
            IParameterRegistryForCover(parameterRegistry).getInsuranceParams(p.assetId);

        coverageLimit = (p.debtPrincipal * params_.maxCoverageBps) / 10_000;
        premium = (coverageLimit * params_.baseOptionalCoverRateBps) / 10_000;
        expiry = block.timestamp + 30 days;
    }

    function purchaseCover(uint256 positionId) external {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IPositionRegistryForCover.Position memory p =
            IPositionRegistryForCover(positionRegistry).getPosition(positionId);

        if (p.owner != msg.sender) revert NotPositionOwner(positionId, msg.sender);
        if (!p.hasBuybackCover) revert PositionNotEligible(positionId);
        if (coverByPosition[positionId].active) revert CoverAlreadyPurchased(positionId);

        (uint256 premium, uint256 coverageLimit, uint256 expiry) = quoteCover(positionId);
        if (premium == 0 || coverageLimit == 0) revert InvalidAmount();

        bool ok = IERC20(premiumToken).transferFrom(msg.sender, address(this), premium);
        require(ok, "TRANSFER_FROM_FAILED");

        IInsuranceReserveForCover(insuranceReserve).reserveOptionalCover(positionId, coverageLimit);

        coverByPosition[positionId] = CoverTerms({
            premiumPaid: premium,
            coverageLimit: coverageLimit,
            expiry: expiry,
            active: true
        });

        emit CoverPurchased(positionId, msg.sender, premium, coverageLimit, expiry);
    }

    function isCovered(uint256 positionId) external view returns (bool) {
        CoverTerms memory c = coverByPosition[positionId];
        return c.active && c.expiry >= block.timestamp;
    }

    function markClaimed(uint256 positionId) external {
        if (!(authorizedWriter[msg.sender] || msg.sender == owner())) revert ZeroAddress();

        CoverTerms storage c = coverByPosition[positionId];
        if (!c.active) revert CoverNotActive(positionId);

        c.active = false;
        emit CoverClaimed(positionId);
    }
}
