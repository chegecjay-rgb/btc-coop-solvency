// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IDebtLedgerForClaim {
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

interface ICollateralManagerForClaim {
    struct CollateralRecord {
        uint256 totalCollateral;
        uint256 lockedCollateral;
        uint256 transferredToStabilization;
        uint256 transferredToInsurance;
        bool releaseFrozen;
        bool initialized;
    }

    function getCollateralRecord(uint256 positionId) external view returns (CollateralRecord memory);
}

interface IPositionRegistryForClaim {
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

interface IBuybackCoverManagerForClaim {
    function isCovered(uint256 positionId) external view returns (bool);
}

contract BuybackClaimLedger is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error NotAuthorized();
    error ClaimAlreadyIssued(uint256 positionId);
    error ClaimNotFound(uint256 positionId);
    error ClaimAlreadySettled(uint256 positionId);
    error ClaimExpired(uint256 positionId);
    error InvalidSettlementAmount(uint256 amount, uint256 required);

    struct BuybackClaim {
        uint256 debtOutstanding;
        uint256 accruedInterest;
        uint256 rescueCapitalUsed;
        uint256 rescueFees;
        uint256 insuranceCapitalUsed;
        uint256 insuranceCharges;
        uint256 settlementCosts;
        uint256 totalRepaymentRequired;
        uint256 collateralEntitlement;
        uint256 expiry;
        bool covered;
        bool settled;
    }

    address public immutable debtLedger;
    address public immutable collateralManager;
    address public immutable positionRegistry;
    address public immutable buybackCoverManager;

    mapping(uint256 => BuybackClaim) public claimByPosition;
    mapping(address => bool) public authorizedIssuer;

    event AuthorizedIssuerSet(address indexed issuer, bool allowed);
    event ClaimIssued(
        uint256 indexed positionId,
        uint256 totalRepaymentRequired,
        uint256 collateralEntitlement,
        uint256 expiry,
        bool covered
    );
    event ClaimSettled(uint256 indexed positionId, uint256 amount);
    event ClaimExpiredEvent(uint256 indexed positionId);

    constructor(
        address initialOwner,
        address debtLedger_,
        address collateralManager_,
        address positionRegistry_,
        address buybackCoverManager_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            debtLedger_ == address(0) ||
            collateralManager_ == address(0) ||
            positionRegistry_ == address(0)
        ) revert ZeroAddress();

        debtLedger = debtLedger_;
        collateralManager = collateralManager_;
        positionRegistry = positionRegistry_;
        buybackCoverManager = buybackCoverManager_;
    }

    modifier onlyAuthorized() {
        if (!(authorizedIssuer[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    function setAuthorizedIssuer(address issuer, bool allowed) external onlyOwner {
        if (issuer == address(0)) revert ZeroAddress();
        authorizedIssuer[issuer] = allowed;
        emit AuthorizedIssuerSet(issuer, allowed);
    }

    function issueClaim(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        if (claimByPosition[positionId].expiry != 0) revert ClaimAlreadyIssued(positionId);

        IDebtLedgerForClaim.DebtRecord memory d =
            IDebtLedgerForClaim(debtLedger).getDebtRecord(positionId);

        ICollateralManagerForClaim.CollateralRecord memory c =
            ICollateralManagerForClaim(collateralManager).getCollateralRecord(positionId);

        bool covered = false;
        if (buybackCoverManager != address(0)) {
            covered = IBuybackCoverManagerForClaim(buybackCoverManager).isCovered(positionId);
        }

        uint256 totalRequired =
            d.principal +
            d.accruedInterest +
            d.rescueCapitalUsed +
            d.rescueFeesAccrued +
            d.insuranceCapitalUsed +
            d.insuranceChargesAccrued +
            d.settlementCosts;

        uint256 collateralEntitlement =
            c.lockedCollateral + c.transferredToStabilization + c.transferredToInsurance;

        uint256 expiry = block.timestamp + 30 days;

        claimByPosition[positionId] = BuybackClaim({
            debtOutstanding: d.principal,
            accruedInterest: d.accruedInterest,
            rescueCapitalUsed: d.rescueCapitalUsed,
            rescueFees: d.rescueFeesAccrued,
            insuranceCapitalUsed: d.insuranceCapitalUsed,
            insuranceCharges: d.insuranceChargesAccrued,
            settlementCosts: d.settlementCosts,
            totalRepaymentRequired: totalRequired,
            collateralEntitlement: collateralEntitlement,
            expiry: expiry,
            covered: covered,
            settled: false
        });

        emit ClaimIssued(positionId, totalRequired, collateralEntitlement, expiry, covered);
    }

    function settleClaim(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        BuybackClaim storage claim = claimByPosition[positionId];
        if (claim.expiry == 0) revert ClaimNotFound(positionId);
        if (claim.settled) revert ClaimAlreadySettled(positionId);
        if (block.timestamp > claim.expiry) revert ClaimExpired(positionId);
        if (amount < claim.totalRepaymentRequired) {
            revert InvalidSettlementAmount(amount, claim.totalRepaymentRequired);
        }

        claim.settled = true;
        emit ClaimSettled(positionId, amount);
    }

    function expireClaim(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        BuybackClaim storage claim = claimByPosition[positionId];
        if (claim.expiry == 0) revert ClaimNotFound(positionId);
        if (claim.settled) revert ClaimAlreadySettled(positionId);
        if (block.timestamp <= claim.expiry) revert ClaimExpired(positionId);

        emit ClaimExpiredEvent(positionId);
    }

    function getTotalRequired(uint256 positionId) external view returns (uint256) {
        BuybackClaim memory claim = claimByPosition[positionId];
        if (claim.expiry == 0) revert ClaimNotFound(positionId);
        return claim.totalRepaymentRequired;
    }
}
