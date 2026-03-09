// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AssetVault is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error NotAuthorized();
    error InvalidAmount();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientAvailableAssets(uint256 requested, uint256 available);
    error InsufficientLockedByPosition(uint256 requested, uint256 locked);

    address public immutable underlyingAsset;
    bytes32 public immutable assetId;

    uint256 public totalAssetsTracked;
    uint256 public totalShares;
    uint256 public totalLockedAssetsTracked;

    mapping(address => uint256) public shareBalance;
    mapping(uint256 => uint256) public lockedByPosition;
    mapping(address => bool) public authorizedWriter;

    event AuthorizedWriterSet(address indexed writer, bool allowed);

    event Deposited(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 newTotalAssetsTracked,
        uint256 newTotalShares
    );

    event Withdrawn(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares,
        uint256 newTotalAssetsTracked,
        uint256 newTotalShares
    );

    event LockedForPosition(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newLockedAmount
    );

    event UnlockedForPosition(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newLockedAmount
    );

    constructor(
        address initialOwner,
        address underlyingAsset_,
        bytes32 assetId_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || underlyingAsset_ == address(0)) revert ZeroAddress();
        if (assetId_ == bytes32(0)) revert InvalidAssetId();

        underlyingAsset = underlyingAsset_;
        assetId = assetId_;
    }

    modifier onlyAuthorized() {
        if (!(authorizedWriter[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        authorizedWriter[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();

        shares = _previewDepositShares(assets);

        bool ok = IERC20(underlyingAsset).transferFrom(msg.sender, address(this), assets);
        require(ok, "TRANSFER_FROM_FAILED");

        shareBalance[receiver] += shares;
        totalShares += shares;
        totalAssetsTracked += assets;

        emit Deposited(
            msg.sender,
            receiver,
            assets,
            shares,
            totalAssetsTracked,
            totalShares
        );
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) external returns (uint256 sharesBurned) {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (msg.sender != owner_) revert NotAuthorized();

        sharesBurned = previewWithdrawShares(assets);

        uint256 ownerShares = shareBalance[owner_];
        if (sharesBurned > ownerShares) {
            revert InsufficientShares(sharesBurned, ownerShares);
        }

        uint256 available = availableAssets();
        if (assets > available) {
            revert InsufficientAvailableAssets(assets, available);
        }

        shareBalance[owner_] = ownerShares - sharesBurned;
        totalShares -= sharesBurned;
        totalAssetsTracked -= assets;

        bool ok = IERC20(underlyingAsset).transfer(receiver, assets);
        require(ok, "TRANSFER_FAILED");

        emit Withdrawn(
            msg.sender,
            receiver,
            owner_,
            assets,
            sharesBurned,
            totalAssetsTracked,
            totalShares
        );
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assetsRequired) {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();

        assetsRequired = previewMintAssets(shares);

        bool ok = IERC20(underlyingAsset).transferFrom(msg.sender, address(this), assetsRequired);
        require(ok, "TRANSFER_FROM_FAILED");

        shareBalance[receiver] += shares;
        totalShares += shares;
        totalAssetsTracked += assetsRequired;

        emit Deposited(
            msg.sender,
            receiver,
            assetsRequired,
            shares,
            totalAssetsTracked,
            totalShares
        );
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) external returns (uint256 assetsReturned) {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (msg.sender != owner_) revert NotAuthorized();

        uint256 ownerShares = shareBalance[owner_];
        if (shares > ownerShares) {
            revert InsufficientShares(shares, ownerShares);
        }

        assetsReturned = previewRedeemAssets(shares);

        uint256 available = availableAssets();
        if (assetsReturned > available) {
            revert InsufficientAvailableAssets(assetsReturned, available);
        }

        shareBalance[owner_] = ownerShares - shares;
        totalShares -= shares;
        totalAssetsTracked -= assetsReturned;

        bool ok = IERC20(underlyingAsset).transfer(receiver, assetsReturned);
        require(ok, "TRANSFER_FAILED");

        emit Withdrawn(
            msg.sender,
            receiver,
            owner_,
            assetsReturned,
            shares,
            totalAssetsTracked,
            totalShares
        );
    }

    function lockForPosition(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert InvalidAmount();
        if (amount == 0) revert InvalidAmount();

        uint256 available = availableAssets();
        if (amount > available) {
            revert InsufficientAvailableAssets(amount, available);
        }

        lockedByPosition[positionId] += amount;
        totalLockedAssetsTracked += amount;

        emit LockedForPosition(positionId, amount, lockedByPosition[positionId]);
    }

    function unlockForPosition(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert InvalidAmount();
        if (amount == 0) revert InvalidAmount();

        uint256 locked = lockedByPosition[positionId];
        if (amount > locked) {
            revert InsufficientLockedByPosition(amount, locked);
        }

        lockedByPosition[positionId] = locked - amount;
        totalLockedAssetsTracked -= amount;

        emit UnlockedForPosition(positionId, amount, lockedByPosition[positionId]);
    }

    function availableAssets() public view returns (uint256) {
        return totalAssetsTracked - totalLockedAssetsTracked;
    }

    function previewDepositShares(uint256 assets) external view returns (uint256) {
        return _previewDepositShares(assets);
    }

    function previewWithdrawShares(uint256 assets) public view returns (uint256) {
        if (assets == 0) return 0;
        if (totalAssetsTracked == 0 || totalShares == 0) return assets;
        return (assets * totalShares) / totalAssetsTracked;
    }

    function previewMintAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;
        if (totalAssetsTracked == 0 || totalShares == 0) return shares;
        return (shares * totalAssetsTracked) / totalShares;
    }

    function previewRedeemAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;
        if (totalShares == 0) return 0;
        return (shares * totalAssetsTracked) / totalShares;
    }

    function _previewDepositShares(uint256 assets) internal view returns (uint256) {
        if (assets == 0) return 0;
        if (totalAssetsTracked == 0 || totalShares == 0) return assets;
        return (assets * totalShares) / totalAssetsTracked;
    }
}
