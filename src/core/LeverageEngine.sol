// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAssetRegistryForLeverage {
    struct AssetConfig {
        address token;
        address oracle;
        bool isActive;
        uint8 decimals;
        bytes32 assetId;
        bytes32 interestModelId;
    }

    function getAsset(bytes32 assetId) external view returns (AssetConfig memory);
}

interface IPositionRegistryForLeverage {
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

    function createPosition(
        address positionOwner,
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        bool hasBuybackCover
    ) external returns (uint256 positionId);

    function getPosition(uint256 positionId) external view returns (Position memory);

    function ownerOfPosition(uint256 positionId) external view returns (address);

    function updateAmounts(uint256 positionId, uint256 collateralAmount, uint256 debtPrincipal) external;

    function closePosition(uint256 positionId) external;
}

interface ICollateralManagerForLeverage {
    function initializeCollateralRecord(uint256 positionId, uint256 initialCollateral) external;
    function addCollateral(uint256 positionId, uint256 amount) external;
    function lockCollateral(uint256 positionId, uint256 amount) external;
    function releaseCollateral(uint256 positionId, uint256 amount) external;
}

interface IDebtLedgerForLeverage {
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

    function initializeDebtRecord(uint256 positionId, uint256 principalAmount) external;
    function increaseDebt(uint256 positionId, uint256 amount) external;
    function repayDebt(uint256 positionId, uint256 amount) external;
    function getDebtRecord(uint256 positionId) external view returns (DebtRecord memory);
    function closeDebt(uint256 positionId) external;
}

interface IAssetVaultForLeverage {
    function underlyingAsset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 sharesBurned);
    function lockForPosition(uint256 positionId, uint256 amount) external;
    function unlockForPosition(uint256 positionId, uint256 amount) external;
}

interface ILendingLiquidityVaultForLeverage {
    function quoteAsset() external view returns (address);
    function allocateToBorrower(address receiver, uint256 amount) external;
    function receiveRepaymentFrom(address from, uint256 amount) external;
}

interface IRiskEngineForLeverage {
    struct PositionRiskSnapshot {
        uint256 healthFactor;
        uint256 adjustedCollateral;
        uint256 totalDebt;
        uint256 currentLTVBps;
        uint8 classification;
    }

    function refreshDynamicBorrowCap(bytes32 assetId) external returns (uint256);
    function positionRiskSnapshot(uint256 positionId) external view returns (PositionRiskSnapshot memory);
    function shouldOpenRemoteIntent(bytes32 assetId, uint256 amountNeeded, uint8 intentType) external returns (bool);
}

interface ICircuitBreakerForLeverage {
    function isBorrowingFrozen(bytes32 assetId) external view returns (bool);
}

interface IRemoteIntentCoordinatorForLeverage {
    function requestBorrowFill(uint256 positionId, uint256 amountNeeded, address beneficiary, address settlementAsset)
        external
        returns (bytes32 intentId);
}

contract LeverageEngine is Ownable {
    error ZeroAddress();
    error InvalidAmount();
    error CollateralRequired();
    error AssetNotActive(bytes32 assetId);
    error AssetTokenMismatch(address expected, address actual);
    error NotPositionOwner(uint256 positionId, address caller);
    error PositionClosed(uint256 positionId);
    error PositionStateNotBorrowable(uint256 positionId, uint8 state);
    error InvalidRiskState(uint256 positionId);
    error BorrowExceedsDynamicCap(uint256 positionId, uint256 projectedLTVBps, uint256 allowedLTVBps);
    error BorrowingFrozen(bytes32 assetId);
    error NotAuthorizedSettlementHandler(address caller);

    uint8 internal constant STATE_HEALTHY = 0;
    uint8 internal constant STATE_CLOSED = 8;
    uint8 internal constant INTENT_BORROW_FILL = 0;

    address public immutable assetRegistry;
    address public immutable positionRegistry;
    address public immutable collateralManager;
    address public immutable debtLedger;
    address public immutable assetVault;
    address public immutable lendingLiquidityVault;
    address public immutable riskEngine;
    address public immutable circuitBreaker;
    address public immutable remoteIntentCoordinator;

    mapping(address => bool) public authorizedSettlementHandler;
    mapping(uint256 => uint256) public localBorrowedByPosition;
    mapping(uint256 => uint256) public remoteBorrowedByPosition;

    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed assetId,
        uint256 collateralAmount,
        uint256 borrowAmount,
        bool buybackCover
    );
    event CollateralAdded(uint256 indexed positionId, uint256 amount, uint256 newCollateralAmount);
    event Borrowed(uint256 indexed positionId, uint256 amount, uint256 newDebtPrincipal);
    event Repaid(uint256 indexed positionId, uint256 amount, uint256 newDebtPrincipal);
    event PositionFullyClosed(uint256 indexed positionId);
    event RemoteBorrowIntentOpened(
        uint256 indexed positionId,
        bytes32 indexed assetId,
        bytes32 indexed intentId,
        uint256 amount,
        address beneficiary,
        address settlementAsset
    );
    event AuthorizedSettlementHandlerSet(address indexed handler, bool allowed);
    event RemoteBorrowSettlementConsumed(
        uint256 indexed positionId, uint256 amount, uint256 newDebtPrincipal, bool isFinalSettlement
    );

    constructor(
        address initialOwner,
        address assetRegistry_,
        address positionRegistry_,
        address collateralManager_,
        address debtLedger_,
        address assetVault_,
        address lendingLiquidityVault_,
        address riskEngine_,
        address circuitBreaker_,
        address remoteIntentCoordinator_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || assetRegistry_ == address(0) || positionRegistry_ == address(0)
                || collateralManager_ == address(0) || debtLedger_ == address(0) || assetVault_ == address(0)
                || lendingLiquidityVault_ == address(0) || riskEngine_ == address(0) || circuitBreaker_ == address(0)
                || remoteIntentCoordinator_ == address(0)
        ) revert ZeroAddress();

        assetRegistry = assetRegistry_;
        positionRegistry = positionRegistry_;
        collateralManager = collateralManager_;
        debtLedger = debtLedger_;
        assetVault = assetVault_;
        lendingLiquidityVault = lendingLiquidityVault_;
        riskEngine = riskEngine_;
        circuitBreaker = circuitBreaker_;
        remoteIntentCoordinator = remoteIntentCoordinator_;
    }

    modifier onlySettlementHandler() {
        if (!(authorizedSettlementHandler[msg.sender] || msg.sender == owner())) {
            revert NotAuthorizedSettlementHandler(msg.sender);
        }
        _;
    }

    function setAuthorizedSettlementHandler(address handler, bool allowed) external onlyOwner {
        if (handler == address(0)) revert ZeroAddress();
        authorizedSettlementHandler[handler] = allowed;
        emit AuthorizedSettlementHandlerSet(handler, allowed);
    }

    function openPosition(bytes32 assetId, uint256 collateralAmount, uint256 borrowAmount, bool buybackCover)
        external
        returns (uint256 positionId)
    {
        if (collateralAmount == 0) revert CollateralRequired();

        IAssetRegistryForLeverage.AssetConfig memory asset = IAssetRegistryForLeverage(assetRegistry).getAsset(assetId);

        if (!asset.isActive) revert AssetNotActive(assetId);
        if (asset.token != IAssetVaultForLeverage(assetVault).underlyingAsset()) {
            revert AssetTokenMismatch(IAssetVaultForLeverage(assetVault).underlyingAsset(), asset.token);
        }

        if (borrowAmount > 0) {
            _assertBorrowingEnabled(assetId);
        }

        IERC20(asset.token).transferFrom(msg.sender, address(this), collateralAmount);
        IERC20(asset.token).approve(assetVault, collateralAmount);
        IAssetVaultForLeverage(assetVault).deposit(collateralAmount, address(this));

        positionId = IPositionRegistryForLeverage(positionRegistry)
            .createPosition(msg.sender, assetId, collateralAmount, 0, buybackCover);

        ICollateralManagerForLeverage(collateralManager).initializeCollateralRecord(positionId, collateralAmount);
        IDebtLedgerForLeverage(debtLedger).initializeDebtRecord(positionId, 0);

        ICollateralManagerForLeverage(collateralManager).lockCollateral(positionId, collateralAmount);
        IAssetVaultForLeverage(assetVault).lockForPosition(positionId, collateralAmount);

        uint256 executedBorrowAmount = 0;

        if (borrowAmount > 0) {
            if (_shouldRouteRemote(assetId, borrowAmount)) {
                _assertProjectedBorrowWithinCap(positionId, assetId, borrowAmount);

                bytes32 intentId = IRemoteIntentCoordinatorForLeverage(remoteIntentCoordinator)
                    .requestBorrowFill(
                        positionId,
                        borrowAmount,
                        msg.sender,
                        ILendingLiquidityVaultForLeverage(lendingLiquidityVault).quoteAsset()
                    );

                emit RemoteBorrowIntentOpened(
                    positionId,
                    assetId,
                    intentId,
                    borrowAmount,
                    msg.sender,
                    ILendingLiquidityVaultForLeverage(lendingLiquidityVault).quoteAsset()
                );
            } else {
                _increaseDebtWithRiskCheck(positionId, assetId, collateralAmount, borrowAmount, msg.sender);
                localBorrowedByPosition[positionId] += borrowAmount;
                executedBorrowAmount = borrowAmount;
            }
        }

        emit PositionOpened(positionId, msg.sender, assetId, collateralAmount, executedBorrowAmount, buybackCover);
    }

    function addCollateral(uint256 positionId, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _assertPositionOwner(positionId, msg.sender);

        IPositionRegistryForLeverage.Position memory position =
            IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        _assertPositionOpen(positionId, position.state);

        IAssetRegistryForLeverage.AssetConfig memory asset =
            IAssetRegistryForLeverage(assetRegistry).getAsset(position.assetId);

        IERC20(asset.token).transferFrom(msg.sender, address(this), amount);
        IERC20(asset.token).approve(assetVault, amount);
        IAssetVaultForLeverage(assetVault).deposit(amount, address(this));

        ICollateralManagerForLeverage(collateralManager).addCollateral(positionId, amount);
        ICollateralManagerForLeverage(collateralManager).lockCollateral(positionId, amount);
        IAssetVaultForLeverage(assetVault).lockForPosition(positionId, amount);

        uint256 newCollateral = position.collateralAmount + amount;
        IPositionRegistryForLeverage(positionRegistry).updateAmounts(positionId, newCollateral, position.debtPrincipal);

        emit CollateralAdded(positionId, amount, newCollateral);
    }

    function borrow(uint256 positionId, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _assertPositionOwner(positionId, msg.sender);

        IPositionRegistryForLeverage.Position memory position =
            IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        _assertPositionOpen(positionId, position.state);
        if (position.state != STATE_HEALTHY) {
            revert PositionStateNotBorrowable(positionId, position.state);
        }

        _assertBorrowingEnabled(position.assetId);

        if (_shouldRouteRemote(position.assetId, amount)) {
            _assertProjectedBorrowWithinCap(positionId, position.assetId, amount);

            bytes32 intentId = IRemoteIntentCoordinatorForLeverage(remoteIntentCoordinator)
                .requestBorrowFill(
                    positionId,
                    amount,
                    msg.sender,
                    ILendingLiquidityVaultForLeverage(lendingLiquidityVault).quoteAsset()
                );

            emit RemoteBorrowIntentOpened(
                positionId,
                position.assetId,
                intentId,
                amount,
                msg.sender,
                ILendingLiquidityVaultForLeverage(lendingLiquidityVault).quoteAsset()
            );
            return;
        }

        uint256 newDebt =
            _increaseDebtWithRiskCheck(positionId, position.assetId, position.collateralAmount, amount, msg.sender);

        localBorrowedByPosition[positionId] += amount;
        emit Borrowed(positionId, amount, newDebt);
    }

    function consumeRemoteBorrowSettlement(uint256 positionId, uint256 amount, bool isFinalSettlement)
        external
        onlySettlementHandler
    {
        if (amount == 0) revert InvalidAmount();

        IPositionRegistryForLeverage.Position memory position =
            IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        _assertPositionOpen(positionId, position.state);

        IDebtLedgerForLeverage(debtLedger).increaseDebt(positionId, amount);

        IDebtLedgerForLeverage.DebtRecord memory debt = IDebtLedgerForLeverage(debtLedger).getDebtRecord(positionId);

        IPositionRegistryForLeverage(positionRegistry)
            .updateAmounts(positionId, position.collateralAmount, debt.principal);

        remoteBorrowedByPosition[positionId] += amount;

        emit RemoteBorrowSettlementConsumed(positionId, amount, debt.principal, isFinalSettlement);
    }

    function repay(uint256 positionId, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _assertPositionOwner(positionId, msg.sender);

        IPositionRegistryForLeverage.Position memory position =
            IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        _assertPositionOpen(positionId, position.state);

        ILendingLiquidityVaultForLeverage(lendingLiquidityVault).receiveRepaymentFrom(msg.sender, amount);
        IDebtLedgerForLeverage(debtLedger).repayDebt(positionId, amount);

        IDebtLedgerForLeverage.DebtRecord memory debt = IDebtLedgerForLeverage(debtLedger).getDebtRecord(positionId);

        IPositionRegistryForLeverage(positionRegistry)
            .updateAmounts(positionId, position.collateralAmount, debt.principal);

        emit Repaid(positionId, amount, debt.principal);
    }

    function closePosition(uint256 positionId) external {
        _assertPositionOwner(positionId, msg.sender);

        IPositionRegistryForLeverage.Position memory position =
            IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        _assertPositionOpen(positionId, position.state);

        IDebtLedgerForLeverage.DebtRecord memory debt = IDebtLedgerForLeverage(debtLedger).getDebtRecord(positionId);

        uint256 totalDebt = debt.principal + debt.accruedInterest + debt.rescueCapitalUsed + debt.rescueFeesAccrued
            + debt.insuranceCapitalUsed + debt.insuranceChargesAccrued + debt.settlementCosts;

        if (totalDebt > 0) {
            ILendingLiquidityVaultForLeverage(lendingLiquidityVault).receiveRepaymentFrom(msg.sender, totalDebt);
            IDebtLedgerForLeverage(debtLedger).closeDebt(positionId);
        }

        if (position.collateralAmount > 0) {
            ICollateralManagerForLeverage(collateralManager).releaseCollateral(positionId, position.collateralAmount);
            IAssetVaultForLeverage(assetVault).unlockForPosition(positionId, position.collateralAmount);
            IAssetVaultForLeverage(assetVault).withdraw(position.collateralAmount, msg.sender, address(this));
        }

        IPositionRegistryForLeverage(positionRegistry).closePosition(positionId);

        emit PositionFullyClosed(positionId);
    }

    function _increaseDebtWithRiskCheck(
        uint256 positionId,
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 amount,
        address receiver
    ) internal returns (uint256 newDebt) {
        IDebtLedgerForLeverage(debtLedger).increaseDebt(positionId, amount);

        IDebtLedgerForLeverage.DebtRecord memory debt = IDebtLedgerForLeverage(debtLedger).getDebtRecord(positionId);

        newDebt = debt.principal;

        IPositionRegistryForLeverage(positionRegistry).updateAmounts(positionId, collateralAmount, newDebt);

        uint256 allowedLTVBps = IRiskEngineForLeverage(riskEngine).refreshDynamicBorrowCap(assetId);

        IRiskEngineForLeverage.PositionRiskSnapshot memory snapshot =
            IRiskEngineForLeverage(riskEngine).positionRiskSnapshot(positionId);

        if (snapshot.adjustedCollateral == 0) revert InvalidRiskState(positionId);
        if (snapshot.currentLTVBps > allowedLTVBps) {
            revert BorrowExceedsDynamicCap(positionId, snapshot.currentLTVBps, allowedLTVBps);
        }

        ILendingLiquidityVaultForLeverage(lendingLiquidityVault).allocateToBorrower(receiver, amount);
    }

    function _assertProjectedBorrowWithinCap(uint256 positionId, bytes32 assetId, uint256 additionalAmount) internal {
        uint256 allowedLTVBps = IRiskEngineForLeverage(riskEngine).refreshDynamicBorrowCap(assetId);

        IRiskEngineForLeverage.PositionRiskSnapshot memory snapshot =
            IRiskEngineForLeverage(riskEngine).positionRiskSnapshot(positionId);

        if (snapshot.adjustedCollateral == 0) revert InvalidRiskState(positionId);

        uint256 projectedDebt = snapshot.totalDebt + additionalAmount;
        uint256 projectedLTVBps = (projectedDebt * 10_000) / snapshot.adjustedCollateral;

        if (projectedLTVBps > allowedLTVBps) {
            revert BorrowExceedsDynamicCap(positionId, projectedLTVBps, allowedLTVBps);
        }
    }

    function _shouldRouteRemote(bytes32 assetId, uint256 amountNeeded) internal returns (bool) {
        return IRiskEngineForLeverage(riskEngine).shouldOpenRemoteIntent(assetId, amountNeeded, INTENT_BORROW_FILL);
    }

    function _assertBorrowingEnabled(bytes32 assetId) internal view {
        if (ICircuitBreakerForLeverage(circuitBreaker).isBorrowingFrozen(assetId)) {
            revert BorrowingFrozen(assetId);
        }
    }

    function _assertPositionOwner(uint256 positionId, address caller) internal view {
        address owner_ = IPositionRegistryForLeverage(positionRegistry).ownerOfPosition(positionId);
        if (owner_ != caller) revert NotPositionOwner(positionId, caller);
    }

    function _assertPositionOpen(uint256 positionId, uint8 state) internal pure {
        if (state == STATE_CLOSED) revert PositionClosed(positionId);
    }
}
