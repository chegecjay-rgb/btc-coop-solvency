// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IBuybackClaimLedgerForFlash {
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

    function claimByPosition(uint256 positionId) external view returns (
        uint256 debtOutstanding,
        uint256 accruedInterest,
        uint256 rescueCapitalUsed,
        uint256 rescueFees,
        uint256 insuranceCapitalUsed,
        uint256 insuranceCharges,
        uint256 settlementCosts,
        uint256 totalRepaymentRequired,
        uint256 collateralEntitlement,
        uint256 expiry,
        bool covered,
        bool settled
    );

    function getTotalRequired(uint256 positionId) external view returns (uint256);
    function settleClaim(uint256 positionId, uint256 amount) external;
}

interface ICollateralManagerForFlash {
    struct CollateralRecord {
        uint256 totalCollateral;
        uint256 lockedCollateral;
        uint256 transferredToStabilization;
        uint256 transferredToInsurance;
        bool releaseFrozen;
        bool initialized;
    }

    function getCollateralRecord(uint256 positionId) external view returns (CollateralRecord memory);
    function releaseCollateral(uint256 positionId, uint256 amount) external;
}

interface IPositionRegistryForFlash {
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

contract BuybackFlashRouter is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error NotPositionOwner(uint256 positionId, address caller);
    error ClaimNotReady(uint256 positionId);
    error ClaimExpired(uint256 positionId);
    error ClaimAlreadySettled(uint256 positionId);
    error FlashProviderNotApproved(address provider);
    error SwapAdapterNotApproved(address adapter);
    error RefinanceAdapterNotApproved(address adapter);
    error NotAuthorized();

    address public immutable buybackClaimLedger;
    address public immutable collateralManager;
    address public immutable positionRegistry;

    mapping(address => bool) public approvedFlashLoanProvider;
    mapping(address => bool) public approvedSwapAdapter;
    mapping(address => bool) public approvedRefinanceAdapter;
    mapping(address => bool) public authorizedSettler;

    event ApprovedFlashLoanProviderSet(address indexed provider, bool allowed);
    event ApprovedSwapAdapterSet(address indexed adapter, bool allowed);
    event ApprovedRefinanceAdapterSet(address indexed adapter, bool allowed);
    event AuthorizedSettlerSet(address indexed settler, bool allowed);

    event FlashCloseInitiated(
        uint256 indexed positionId,
        address indexed owner,
        address indexed flashProvider,
        address swapAdapter,
        address refinanceAdapter,
        uint256 totalRequired
    );

    event FlashCloseSettled(
        uint256 indexed positionId,
        uint256 amountSettled,
        uint256 collateralReleased
    );

    constructor(
        address initialOwner,
        address buybackClaimLedger_,
        address collateralManager_,
        address positionRegistry_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            buybackClaimLedger_ == address(0) ||
            collateralManager_ == address(0) ||
            positionRegistry_ == address(0)
        ) revert ZeroAddress();

        buybackClaimLedger = buybackClaimLedger_;
        collateralManager = collateralManager_;
        positionRegistry = positionRegistry_;
    }

    modifier onlyAuthorized() {
        if (!(authorizedSettler[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    function setApprovedFlashLoanProvider(address provider, bool allowed) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        approvedFlashLoanProvider[provider] = allowed;
        emit ApprovedFlashLoanProviderSet(provider, allowed);
    }

    function setApprovedSwapAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        approvedSwapAdapter[adapter] = allowed;
        emit ApprovedSwapAdapterSet(adapter, allowed);
    }

    function setApprovedRefinanceAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        approvedRefinanceAdapter[adapter] = allowed;
        emit ApprovedRefinanceAdapterSet(adapter, allowed);
    }

    function setAuthorizedSettler(address settler, bool allowed) external onlyOwner {
        if (settler == address(0)) revert ZeroAddress();
        authorizedSettler[settler] = allowed;
        emit AuthorizedSettlerSet(settler, allowed);
    }

    function quoteClosePath(uint256 positionId)
        external
        view
        returns (
            uint256 totalRequired,
            uint256 collateralEntitlement,
            bool covered,
            bool settled,
            uint256 expiry
        )
    {
        if (positionId == 0) revert InvalidPositionId(positionId);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            totalRequired,
            collateralEntitlement,
            expiry,
            covered,
            settled
        ) = IBuybackClaimLedgerForFlash(buybackClaimLedger).claimByPosition(positionId);

        if (expiry == 0) revert ClaimNotReady(positionId);
    }

    function closeWithFlashLoan(uint256 positionId, bytes calldata params) external {
        if (positionId == 0) revert InvalidPositionId(positionId);

        address owner_ = IPositionRegistryForFlash(positionRegistry).ownerOfPosition(positionId);
        if (owner_ != msg.sender) revert NotPositionOwner(positionId, msg.sender);

        (
            address flashProvider,
            address swapAdapter,
            address refinanceAdapter,
            uint256 proposedSettlement
        ) = abi.decode(params, (address, address, address, uint256));

        if (!approvedFlashLoanProvider[flashProvider]) {
            revert FlashProviderNotApproved(flashProvider);
        }
        if (swapAdapter != address(0) && !approvedSwapAdapter[swapAdapter]) {
            revert SwapAdapterNotApproved(swapAdapter);
        }
        if (refinanceAdapter != address(0) && !approvedRefinanceAdapter[refinanceAdapter]) {
            revert RefinanceAdapterNotApproved(refinanceAdapter);
        }

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 totalRequired,
            ,
            uint256 expiry,
            ,
            bool settled
        ) = IBuybackClaimLedgerForFlash(buybackClaimLedger).claimByPosition(positionId);

        if (expiry == 0) revert ClaimNotReady(positionId);
        if (block.timestamp > expiry) revert ClaimExpired(positionId);
        if (settled) revert ClaimAlreadySettled(positionId);

        // v1: abstract actual flash execution and just emit the route intent
        emit FlashCloseInitiated(
            positionId,
            msg.sender,
            flashProvider,
            swapAdapter,
            refinanceAdapter,
            proposedSettlement > totalRequired ? proposedSettlement : totalRequired
        );
    }

    function settleAndRelease(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 totalRequired,
            uint256 collateralEntitlement,
            uint256 expiry,
            ,
            bool settled
        ) = IBuybackClaimLedgerForFlash(buybackClaimLedger).claimByPosition(positionId);

        if (expiry == 0) revert ClaimNotReady(positionId);
        if (block.timestamp > expiry) revert ClaimExpired(positionId);
        if (settled) revert ClaimAlreadySettled(positionId);

        IBuybackClaimLedgerForFlash(buybackClaimLedger).settleClaim(positionId, totalRequired);

        if (collateralEntitlement > 0) {
            ICollateralManagerForFlash(collateralManager).releaseCollateral(positionId, collateralEntitlement);
        }

        emit FlashCloseSettled(positionId, totalRequired, collateralEntitlement);
    }
}
