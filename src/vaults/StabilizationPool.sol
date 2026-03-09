// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StabilizationPool is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error InvalidAmount();
    error NotAuthorized();
    error AssetNotSupported(bytes32 assetId);
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientStableLiquidity(uint256 requested, uint256 available);
    error InsufficientBTCLiquidity(uint256 requested, uint256 available);

    struct MarketPool {
        uint256 stableLiquidity;
        uint256 btcLiquidity;
        uint256 activeRescueExposure;
        uint256 recoveredProceeds;
    }

    address public immutable stableToken;
    address public immutable btcToken;

    mapping(bytes32 => MarketPool) public pools;
    mapping(bytes32 => mapping(address => uint256)) public depositorShares;
    mapping(bytes32 => uint256) public totalSharesByAsset;
    mapping(bytes32 => bool) public supportedAsset;
    mapping(address => bool) public authorizedWriter;

    event SupportedAssetSet(bytes32 indexed assetId, bool supported);
    event AuthorizedWriterSet(address indexed writer, bool allowed);

    event StableDeposited(
        bytes32 indexed assetId,
        address indexed depositor,
        uint256 amount,
        uint256 sharesMinted,
        uint256 newStableLiquidity
    );

    event BTCDeposited(
        bytes32 indexed assetId,
        address indexed depositor,
        uint256 amount,
        uint256 sharesMinted,
        uint256 newBTCLiquidity
    );

    event WithdrawRequested(
        bytes32 indexed assetId,
        address indexed depositor,
        uint256 sharesBurned,
        uint256 stableReturned,
        uint256 btcReturned
    );

    event RescueCapitalDeployed(
        bytes32 indexed assetId,
        uint256 amount,
        uint256 newStableLiquidity,
        uint256 newActiveRescueExposure
    );

    event RecoveryReceived(
        bytes32 indexed assetId,
        uint256 amount,
        uint256 newStableLiquidity,
        uint256 newRecoveredProceeds,
        uint256 newActiveRescueExposure
    );

    constructor(
        address initialOwner,
        address stableToken_,
        address btcToken_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || stableToken_ == address(0) || btcToken_ == address(0)) {
            revert ZeroAddress();
        }

        stableToken = stableToken_;
        btcToken = btcToken_;
    }

    modifier onlyAuthorized() {
        if (!(authorizedWriter[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    function setSupportedAsset(bytes32 assetId, bool isSupported) external onlyOwner {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        supportedAsset[assetId] = isSupported;
        emit SupportedAssetSet(assetId, isSupported);
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        authorizedWriter[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function depositStable(bytes32 assetId, uint256 amount) external returns (uint256 sharesMinted) {
        if (!supportedAsset[assetId]) revert AssetNotSupported(assetId);
        if (amount == 0) revert InvalidAmount();

        sharesMinted = amount;

        bool ok = IERC20(stableToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        pools[assetId].stableLiquidity += amount;
        depositorShares[assetId][msg.sender] += sharesMinted;
        totalSharesByAsset[assetId] += sharesMinted;

        emit StableDeposited(
            assetId,
            msg.sender,
            amount,
            sharesMinted,
            pools[assetId].stableLiquidity
        );
    }

    function depositBTC(bytes32 assetId, uint256 amount) external returns (uint256 sharesMinted) {
        if (!supportedAsset[assetId]) revert AssetNotSupported(assetId);
        if (amount == 0) revert InvalidAmount();

        sharesMinted = amount;

        bool ok = IERC20(btcToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        pools[assetId].btcLiquidity += amount;
        depositorShares[assetId][msg.sender] += sharesMinted;
        totalSharesByAsset[assetId] += sharesMinted;

        emit BTCDeposited(
            assetId,
            msg.sender,
            amount,
            sharesMinted,
            pools[assetId].btcLiquidity
        );
    }

    function requestWithdraw(
        bytes32 assetId,
        uint256 shares
    ) external returns (uint256 stableReturned, uint256 btcReturned) {
        if (!supportedAsset[assetId]) revert AssetNotSupported(assetId);
        if (shares == 0) revert InvalidAmount();

        uint256 userShares = depositorShares[assetId][msg.sender];
        if (shares > userShares) {
            revert InsufficientShares(shares, userShares);
        }

        uint256 totalShares = totalSharesByAsset[assetId];
        MarketPool storage pool = pools[assetId];

        stableReturned = totalShares == 0 ? 0 : (shares * pool.stableLiquidity) / totalShares;
        btcReturned = totalShares == 0 ? 0 : (shares * pool.btcLiquidity) / totalShares;

        depositorShares[assetId][msg.sender] = userShares - shares;
        totalSharesByAsset[assetId] = totalShares - shares;

        pool.stableLiquidity -= stableReturned;
        pool.btcLiquidity -= btcReturned;

        if (stableReturned > 0) {
            bool okStable = IERC20(stableToken).transfer(msg.sender, stableReturned);
            require(okStable, "STABLE_TRANSFER_FAILED");
        }

        if (btcReturned > 0) {
            bool okBTC = IERC20(btcToken).transfer(msg.sender, btcReturned);
            require(okBTC, "BTC_TRANSFER_FAILED");
        }

        emit WithdrawRequested(assetId, msg.sender, shares, stableReturned, btcReturned);
    }

    function deployRescueCapital(bytes32 assetId, uint256 amount) external onlyAuthorized {
        if (!supportedAsset[assetId]) revert AssetNotSupported(assetId);
        if (amount == 0) revert InvalidAmount();

        MarketPool storage pool = pools[assetId];
        if (amount > pool.stableLiquidity) {
            revert InsufficientStableLiquidity(amount, pool.stableLiquidity);
        }

        pool.stableLiquidity -= amount;
        pool.activeRescueExposure += amount;

        emit RescueCapitalDeployed(
            assetId,
            amount,
            pool.stableLiquidity,
            pool.activeRescueExposure
        );
    }

    function receiveRecovery(bytes32 assetId, uint256 amount) external onlyAuthorized {
        if (!supportedAsset[assetId]) revert AssetNotSupported(assetId);
        if (amount == 0) revert InvalidAmount();

        MarketPool storage pool = pools[assetId];

        pool.stableLiquidity += amount;
        pool.recoveredProceeds += amount;

        if (amount >= pool.activeRescueExposure) {
            pool.activeRescueExposure = 0;
        } else {
            pool.activeRescueExposure -= amount;
        }

        emit RecoveryReceived(
            assetId,
            amount,
            pool.stableLiquidity,
            pool.recoveredProceeds,
            pool.activeRescueExposure
        );
    }

    function availableRescueLiquidity(bytes32 assetId) external view returns (uint256) {
        if (!supportedAsset[assetId]) revert AssetNotSupported(assetId);
        return pools[assetId].stableLiquidity;
    }
}
