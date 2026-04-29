// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    function claimByPosition(uint256 positionId)
        external
        view
        returns (
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

    function settleClaim(uint256 positionId, uint256 amount) external;
}

interface ICollateralManagerForFlash {
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

interface IProtocolRevenueRouterForFlash {
    struct RevenueBreakdown {
        uint256 borrowInterest;
        uint256 rescueFee;
        uint256 insurancePremium;
        uint256 insuranceCharge;
        uint256 settlementCost;
        uint256 remoteLiquidityFee;
    }

    function getRoute(bytes32 assetId)
        external
        view
        returns (
            address feeToken,
            address lendingVault,
            address stabilizationPool,
            address insuranceReserve,
            address treasuryVault,
            bool configured
        );

    function routeRevenueBreakdownHeld(bytes32 assetId, RevenueBreakdown calldata breakdown) external;
}

interface ILendingLiquidityVaultForFlash {
    function receiveRepaymentFrom(address payer, uint256 amount) external;
}

interface IStabilizationPoolForFlash {
    function receiveRecovery(bytes32 assetId, uint256 amount) external;
}

interface IInsuranceReserveForFlash {
    function receiveRecovery(uint256 positionId, uint256 amount) external;
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
    error RevenueRouterNotConfigured();
    error LendingVaultNotConfigured();
    error StabilizationPoolNotConfigured();
    error InsuranceReserveNotConfigured();
    error FeeRouteNotConfigured(bytes32 assetId);
    error TransferFailed();

    struct ClaimSettlementBreakdown {
        uint256 debtOutstanding;
        uint256 accruedInterest;
        uint256 rescueCapitalUsed;
        uint256 rescueFees;
        uint256 insuranceCapitalUsed;
        uint256 insuranceCharges;
        uint256 settlementCosts;
        uint256 totalRequired;
        uint256 collateralEntitlement;
    }

    address public immutable buybackClaimLedger;
    address public immutable collateralManager;
    address public immutable positionRegistry;

    address public protocolRevenueRouter;
    address public lendingLiquidityVault;
    address public stabilizationPool;
    address public insuranceReserve;

    mapping(address => bool) public approvedFlashLoanProvider;
    mapping(address => bool) public approvedSwapAdapter;
    mapping(address => bool) public approvedRefinanceAdapter;
    mapping(address => bool) public authorizedSettler;

    event ApprovedFlashLoanProviderSet(address indexed provider, bool allowed);
    event ApprovedSwapAdapterSet(address indexed adapter, bool allowed);
    event ApprovedRefinanceAdapterSet(address indexed adapter, bool allowed);
    event AuthorizedSettlerSet(address indexed settler, bool allowed);

    event SettlementRoutingUpdated(
        address indexed protocolRevenueRouter,
        address indexed lendingLiquidityVault,
        address indexed stabilizationPool,
        address insuranceReserve
    );

    event FlashCloseInitiated(
        uint256 indexed positionId,
        address indexed owner,
        address indexed flashProvider,
        address swapAdapter,
        address refinanceAdapter,
        uint256 totalRequired
    );

    event FlashCloseSettled(uint256 indexed positionId, uint256 amountSettled, uint256 collateralReleased);

    constructor(
        address initialOwner,
        address buybackClaimLedger_,
        address collateralManager_,
        address positionRegistry_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || buybackClaimLedger_ == address(0) || collateralManager_ == address(0)
                || positionRegistry_ == address(0)
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

    function setSettlementRouting(
        address protocolRevenueRouter_,
        address lendingLiquidityVault_,
        address stabilizationPool_,
        address insuranceReserve_
    ) external onlyOwner {
        if (
            protocolRevenueRouter_ == address(0) || lendingLiquidityVault_ == address(0)
                || stabilizationPool_ == address(0) || insuranceReserve_ == address(0)
        ) revert ZeroAddress();

        protocolRevenueRouter = protocolRevenueRouter_;
        lendingLiquidityVault = lendingLiquidityVault_;
        stabilizationPool = stabilizationPool_;
        insuranceReserve = insuranceReserve_;

        emit SettlementRoutingUpdated(
            protocolRevenueRouter_, lendingLiquidityVault_, stabilizationPool_, insuranceReserve_
        );
    }

    function quoteClosePath(uint256 positionId)
        external
        view
        returns (uint256 totalRequired, uint256 collateralEntitlement, bool covered, bool settled, uint256 expiry)
    {
        if (positionId == 0) {
            revert InvalidPositionId(positionId);
        }

        IBuybackClaimLedgerForFlash.BuybackClaim memory claim = _loadClaim(positionId);

        if (claim.expiry == 0) revert ClaimNotReady(positionId);

        return (claim.totalRepaymentRequired, claim.collateralEntitlement, claim.covered, claim.settled, claim.expiry);
    }

    function previewSettlementBreakdown(uint256 positionId)
        external
        view
        returns (ClaimSettlementBreakdown memory breakdown)
    {
        if (positionId == 0) revert InvalidPositionId(positionId);

        IBuybackClaimLedgerForFlash.BuybackClaim memory claim = _loadClaim(positionId);

        if (claim.expiry == 0) revert ClaimNotReady(positionId);
        if (block.timestamp > claim.expiry) revert ClaimExpired(positionId);
        if (claim.settled) revert ClaimAlreadySettled(positionId);

        breakdown = ClaimSettlementBreakdown({
            debtOutstanding: claim.debtOutstanding,
            accruedInterest: claim.accruedInterest,
            rescueCapitalUsed: claim.rescueCapitalUsed,
            rescueFees: claim.rescueFees,
            insuranceCapitalUsed: claim.insuranceCapitalUsed,
            insuranceCharges: claim.insuranceCharges,
            settlementCosts: claim.settlementCosts,
            totalRequired: claim.totalRepaymentRequired,
            collateralEntitlement: claim.collateralEntitlement
        });
    }

    function closeWithFlashLoan(uint256 positionId, bytes calldata params) external {
        if (positionId == 0) revert InvalidPositionId(positionId);

        address owner_ = IPositionRegistryForFlash(positionRegistry).ownerOfPosition(positionId);
        if (owner_ != msg.sender) revert NotPositionOwner(positionId, msg.sender);

        (address flashProvider, address swapAdapter, address refinanceAdapter, uint256 proposedSettlement) =
            abi.decode(params, (address, address, address, uint256));

        if (!approvedFlashLoanProvider[flashProvider]) {
            revert FlashProviderNotApproved(flashProvider);
        }
        if (swapAdapter != address(0) && !approvedSwapAdapter[swapAdapter]) {
            revert SwapAdapterNotApproved(swapAdapter);
        }
        if (refinanceAdapter != address(0) && !approvedRefinanceAdapter[refinanceAdapter]) {
            revert RefinanceAdapterNotApproved(refinanceAdapter);
        }

        IBuybackClaimLedgerForFlash.BuybackClaim memory claim = _loadClaim(positionId);

        if (claim.expiry == 0) revert ClaimNotReady(positionId);
        if (block.timestamp > claim.expiry) revert ClaimExpired(positionId);
        if (claim.settled) revert ClaimAlreadySettled(positionId);

        emit FlashCloseInitiated(
            positionId,
            msg.sender,
            flashProvider,
            swapAdapter,
            refinanceAdapter,
            proposedSettlement > claim.totalRepaymentRequired ? proposedSettlement : claim.totalRepaymentRequired
        );
    }

    function settleAndRelease(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        if (protocolRevenueRouter == address(0)) revert RevenueRouterNotConfigured();
        if (lendingLiquidityVault == address(0)) revert LendingVaultNotConfigured();
        if (stabilizationPool == address(0)) revert StabilizationPoolNotConfigured();
        if (insuranceReserve == address(0)) revert InsuranceReserveNotConfigured();

        IBuybackClaimLedgerForFlash.BuybackClaim memory claim = _loadClaim(positionId);

        if (claim.expiry == 0) revert ClaimNotReady(positionId);
        if (block.timestamp > claim.expiry) revert ClaimExpired(positionId);
        if (claim.settled) revert ClaimAlreadySettled(positionId);

        IPositionRegistryForFlash.Position memory p =
            IPositionRegistryForFlash(positionRegistry).getPosition(positionId);

        address settlementToken = _getSettlementToken(p.assetId);

        bool ok = IERC20(settlementToken).transferFrom(msg.sender, address(this), claim.totalRepaymentRequired);
        if (!ok) revert TransferFailed();

        if (claim.debtOutstanding > 0) {
            IERC20(settlementToken).approve(lendingLiquidityVault, 0);
            IERC20(settlementToken).approve(lendingLiquidityVault, claim.debtOutstanding);
            ILendingLiquidityVaultForFlash(lendingLiquidityVault)
                .receiveRepaymentFrom(address(this), claim.debtOutstanding);
        }

        if (claim.rescueCapitalUsed > 0) {
            ok = IERC20(settlementToken).transfer(stabilizationPool, claim.rescueCapitalUsed);
            if (!ok) revert TransferFailed();

            IStabilizationPoolForFlash(stabilizationPool).receiveRecovery(p.assetId, claim.rescueCapitalUsed);
        }

        if (claim.insuranceCapitalUsed > 0) {
            IERC20(settlementToken).approve(insuranceReserve, 0);
            IERC20(settlementToken).approve(insuranceReserve, claim.insuranceCapitalUsed);
            IInsuranceReserveForFlash(insuranceReserve).receiveRecovery(positionId, claim.insuranceCapitalUsed);
        }

        uint256 revenueTotal = claim.accruedInterest + claim.rescueFees + claim.insuranceCharges + claim.settlementCosts;

        if (revenueTotal > 0) {
            ok = IERC20(settlementToken).transfer(protocolRevenueRouter, revenueTotal);
            if (!ok) revert TransferFailed();

            IProtocolRevenueRouterForFlash.RevenueBreakdown memory revenueBreakdown =
                IProtocolRevenueRouterForFlash.RevenueBreakdown({
                    borrowInterest: claim.accruedInterest,
                    rescueFee: claim.rescueFees,
                    insurancePremium: 0,
                    insuranceCharge: claim.insuranceCharges,
                    settlementCost: claim.settlementCosts,
                    remoteLiquidityFee: 0
                });

            IProtocolRevenueRouterForFlash(protocolRevenueRouter).routeRevenueBreakdownHeld(p.assetId, revenueBreakdown);
        }

        IBuybackClaimLedgerForFlash(buybackClaimLedger).settleClaim(positionId, claim.totalRepaymentRequired);

        if (claim.collateralEntitlement > 0) {
            ICollateralManagerForFlash(collateralManager).releaseCollateral(positionId, claim.collateralEntitlement);
        }

        emit FlashCloseSettled(positionId, claim.totalRepaymentRequired, claim.collateralEntitlement);
    }

    function _loadClaim(uint256 positionId)
        internal
        view
        returns (IBuybackClaimLedgerForFlash.BuybackClaim memory claim)
    {
        (bool ok, bytes memory data) = buybackClaimLedger.staticcall(
            abi.encodeWithSelector(IBuybackClaimLedgerForFlash.claimByPosition.selector, positionId)
        );

        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }

        claim = abi.decode(data, (IBuybackClaimLedgerForFlash.BuybackClaim));
    }

    function _getSettlementToken(bytes32 assetId) internal view returns (address settlementToken) {
        (address feeToken,,,,, bool configured) =
            IProtocolRevenueRouterForFlash(protocolRevenueRouter).getRoute(assetId);

        if (!configured) revert FeeRouteNotConfigured(assetId);
        settlementToken = feeToken;
    }
}
