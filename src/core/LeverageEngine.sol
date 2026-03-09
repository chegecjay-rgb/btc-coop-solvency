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
    function createPosition(
        address positionOwner,
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        bool hasBuybackCover
    ) external returns (uint256 positionId);

    function getPosition(uint256 positionId) external view returns (
        address owner,
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 debtPrincipal,
        uint8 state,
        uint256 rescueCount,
        uint256 lastRescueTime,
        bool hasBuybackCover,
        bytes32 activeRemoteIntentId
    );

    function ownerOfPosition(uint256 positionId) external view returns (address);
    function updateAmounts(uint256 positionId, uint256 collateralAmount, uint256 debtPrincipal) external;
}

interface ICollateralManagerForLeverage {
    function initializeCollateralRecord(uint256 positionId, uint256 initialCollateral) external;
    function addCollateral(uint256 positionId, uint256 amount) external;
    function lockCollateral(uint256 positionId, uint256 amount) external;
    function releaseCollateral(uint256 positionId, uint256 amount) external;
}

interface IDebtLedgerForLeverage {
    function initializeDebtRecord(uint256 positionId, uint256 principalAmount) external;
    function increaseDebt(uint256 positionId, uint256 amount) external;
    function repayDebt(uint256 positionId, uint256 amount) external;
    function getDebtRecord(uint256 positionId) external view returns (
        uint256 principal,
        uint256 accruedInterest,
        uint256 rescueCapitalUsed,
        uint256 rescueFeesAccrued,
        uint256 insuranceCapitalUsed,
        uint256 insuranceChargesAccrued,
        uint256 settlementCosts,
        uint256 lastAccrualTime
    );
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

contract LeverageEngine is Ownable {
    error ZeroAddress();
    error InvalidAmount();
    error AssetNotActive(bytes32 assetId);
    error AssetTokenMismatch(address expected, address actual);
    error NotPositionOwner(uint256 positionId, address caller);

    address public immutable assetRegistry;
    address public immutable positionRegistry;
    address public immutable collateralManager;
    address public immutable debtLedger;
    address public immutable assetVault;
    address public immutable lendingLiquidityVault;
    address public immutable riskEngine;

    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed assetId,
        uint256 collateralAmount,
        uint256 borrowAmount,
        bool buybackCover
    );

    event CollateralAdded(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newCollateralAmount
    );

    event Borrowed(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newDebtPrincipal
    );

    event Repaid(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newDebtPrincipal
    );

    event PositionClosed(uint256 indexed positionId);

    constructor(
        address initialOwner,
        address assetRegistry_,
        address positionRegistry_,
        address collateralManager_,
        address debtLedger_,
        address assetVault_,
        address lendingLiquidityVault_,
        address riskEngine_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            assetRegistry_ == address(0) ||
            positionRegistry_ == address(0) ||
            collateralManager_ == address(0) ||
            debtLedger_ == address(0) ||
            assetVault_ == address(0) ||
            lendingLiquidityVault_ == address(0)
        ) revert ZeroAddress();

        assetRegistry = assetRegistry_;
        positionRegistry = positionRegistry_;
        collateralManager = collateralManager_;
        debtLedger = debtLedger_;
        assetVault = assetVault_;
        lendingLiquidityVault = lendingLiquidityVault_;
        riskEngine = riskEngine_;
    }

    function openPosition(
        bytes32 assetId,
        uint256 collateralAmount,
        uint256 borrowAmount,
        bool buybackCover
    ) external returns (uint256 positionId) {
        if (collateralAmount == 0 && borrowAmount == 0) revert InvalidAmount();

        IAssetRegistryForLeverage.AssetConfig memory asset =
            IAssetRegistryForLeverage(assetRegistry).getAsset(assetId);

        if (!asset.isActive) revert AssetNotActive(assetId);
        if (asset.token != IAssetVaultForLeverage(assetVault).underlyingAsset()) {
            revert AssetTokenMismatch(IAssetVaultForLeverage(assetVault).underlyingAsset(), asset.token);
        }

        if (collateralAmount > 0) {
            IERC20(asset.token).transferFrom(msg.sender, address(this), collateralAmount);
            IERC20(asset.token).approve(assetVault, collateralAmount);
            IAssetVaultForLeverage(assetVault).deposit(collateralAmount, address(this));
        }

        positionId = IPositionRegistryForLeverage(positionRegistry).createPosition(
            msg.sender,
            assetId,
            collateralAmount,
            borrowAmount,
            buybackCover
        );

        ICollateralManagerForLeverage(collateralManager).initializeCollateralRecord(positionId, collateralAmount);
        IDebtLedgerForLeverage(debtLedger).initializeDebtRecord(positionId, borrowAmount);

        if (collateralAmount > 0) {
            ICollateralManagerForLeverage(collateralManager).lockCollateral(positionId, collateralAmount);
            IAssetVaultForLeverage(assetVault).lockForPosition(positionId, collateralAmount);
        }

        if (borrowAmount > 0) {
            ILendingLiquidityVaultForLeverage(lendingLiquidityVault).allocateToBorrower(msg.sender, borrowAmount);
        }

        emit PositionOpened(positionId, msg.sender, assetId, collateralAmount, borrowAmount, buybackCover);
    }

    function addCollateral(uint256 positionId, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _assertPositionOwner(positionId, msg.sender);

        (
            ,
            bytes32 assetId,
            uint256 collateralAmount,
            uint256 debtPrincipal,
            ,
            ,
            ,
            ,

        ) = IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        IAssetRegistryForLeverage.AssetConfig memory asset =
            IAssetRegistryForLeverage(assetRegistry).getAsset(assetId);

        IERC20(asset.token).transferFrom(msg.sender, address(this), amount);
        IERC20(asset.token).approve(assetVault, amount);
        IAssetVaultForLeverage(assetVault).deposit(amount, address(this));

        ICollateralManagerForLeverage(collateralManager).addCollateral(positionId, amount);
        ICollateralManagerForLeverage(collateralManager).lockCollateral(positionId, amount);
        IAssetVaultForLeverage(assetVault).lockForPosition(positionId, amount);

        uint256 newCollateral = collateralAmount + amount;
        IPositionRegistryForLeverage(positionRegistry).updateAmounts(positionId, newCollateral, debtPrincipal);

        emit CollateralAdded(positionId, amount, newCollateral);
    }

    function borrow(uint256 positionId, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _assertPositionOwner(positionId, msg.sender);

        (
            ,
            ,
            uint256 collateralAmount,
            uint256 debtPrincipal,
            ,
            ,
            ,
            ,

        ) = IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        ILendingLiquidityVaultForLeverage(lendingLiquidityVault).allocateToBorrower(msg.sender, amount);
        IDebtLedgerForLeverage(debtLedger).increaseDebt(positionId, amount);

        uint256 newDebt = debtPrincipal + amount;
        IPositionRegistryForLeverage(positionRegistry).updateAmounts(positionId, collateralAmount, newDebt);

        emit Borrowed(positionId, amount, newDebt);
    }

    function repay(uint256 positionId, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _assertPositionOwner(positionId, msg.sender);

        (
            ,
            ,
            uint256 collateralAmount,
            uint256 debtPrincipal,
            ,
            ,
            ,
            ,

        ) = IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        IERC20(ILendingLiquidityVaultForLeverage(lendingLiquidityVault).quoteAsset())
            .approve(lendingLiquidityVault, 0);
        ILendingLiquidityVaultForLeverage(lendingLiquidityVault).receiveRepaymentFrom(msg.sender, amount);

        IDebtLedgerForLeverage(debtLedger).repayDebt(positionId, amount);

        uint256 newDebt = debtPrincipal - amount;
        IPositionRegistryForLeverage(positionRegistry).updateAmounts(positionId, collateralAmount, newDebt);

        emit Repaid(positionId, amount, newDebt);
    }

    function closePosition(uint256 positionId) external {
        _assertPositionOwner(positionId, msg.sender);

        (
            ,
            ,
            uint256 collateralAmount,
            ,
            ,
            ,
            ,
            ,

        ) = IPositionRegistryForLeverage(positionRegistry).getPosition(positionId);

        (
            uint256 principal,
            uint256 accruedInterest,
            uint256 rescueCapitalUsed,
            uint256 rescueFeesAccrued,
            uint256 insuranceCapitalUsed,
            uint256 insuranceChargesAccrued,
            uint256 settlementCosts,

        ) = IDebtLedgerForLeverage(debtLedger).getDebtRecord(positionId);

        uint256 totalDebt =
            principal +
            accruedInterest +
            rescueCapitalUsed +
            rescueFeesAccrued +
            insuranceCapitalUsed +
            insuranceChargesAccrued +
            settlementCosts;

        if (totalDebt > 0) {
            ILendingLiquidityVaultForLeverage(lendingLiquidityVault).receiveRepaymentFrom(msg.sender, totalDebt);
            IDebtLedgerForLeverage(debtLedger).closeDebt(positionId);
        }

        if (collateralAmount > 0) {
            ICollateralManagerForLeverage(collateralManager).releaseCollateral(positionId, collateralAmount);
            IAssetVaultForLeverage(assetVault).unlockForPosition(positionId, collateralAmount);
            IAssetVaultForLeverage(assetVault).withdraw(collateralAmount, msg.sender, address(this));
        }

        IPositionRegistryForLeverage(positionRegistry).updateAmounts(positionId, 0, 0);

        emit PositionClosed(positionId);
    }

    function _assertPositionOwner(uint256 positionId, address caller) internal view {
        address owner_ = IPositionRegistryForLeverage(positionRegistry).ownerOfPosition(positionId);
        if (owner_ != caller) revert NotPositionOwner(positionId, caller);
    }
}
