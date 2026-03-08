// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LendingLiquidityVault is Ownable {
    error ZeroAddress();
    error NotAuthorized();
    error InvalidAmount();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientAvailableLiquidity(uint256 requested, uint256 available);

    address public immutable quoteAsset;
    bytes32 public immutable marketId;

    uint256 public totalLiquidity;
    uint256 public availableLiquidity;
    uint256 public totalShares;

    uint256 public pendingRemoteInbound;
    uint256 public settledRemoteInbound;
    uint256 public remoteLiquidityUtilized;

    mapping(address => uint256) public lenderShares;
    mapping(address => bool) public authorizedWriter;

    event AuthorizedWriterSet(address indexed writer, bool allowed);

    event LiquidityDeposited(
        address indexed lender,
        uint256 assetAmount,
        uint256 shareAmount,
        uint256 newTotalLiquidity,
        uint256 newAvailableLiquidity,
        uint256 newTotalShares
    );

    event LiquidityWithdrawn(
        address indexed lender,
        uint256 assetAmount,
        uint256 shareAmount,
        uint256 newTotalLiquidity,
        uint256 newAvailableLiquidity,
        uint256 newTotalShares
    );

    event BorrowerLiquidityAllocated(
        uint256 amount,
        uint256 newAvailableLiquidity
    );

    event RepaymentReceived(
        uint256 amount,
        uint256 newTotalLiquidity,
        uint256 newAvailableLiquidity
    );

    event PendingRemoteInboundRegistered(
        uint256 amount,
        uint256 newPendingRemoteInbound
    );

    event RemoteLiquidityReceived(
        uint256 amount,
        uint256 newPendingRemoteInbound,
        uint256 newSettledRemoteInbound,
        uint256 newTotalLiquidity,
        uint256 newAvailableLiquidity
    );

    constructor(
        address initialOwner,
        address quoteAsset_,
        bytes32 marketId_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || quoteAsset_ == address(0)) revert ZeroAddress();
        if (marketId_ == bytes32(0)) revert ZeroAddress();

        quoteAsset = quoteAsset_;
        marketId = marketId_;
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

    function depositLiquidity(uint256 amount) external returns (uint256 sharesMinted) {
        if (amount == 0) revert InvalidAmount();

        sharesMinted = _previewDepositShares(amount);

        bool ok = IERC20(quoteAsset).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        lenderShares[msg.sender] += sharesMinted;
        totalShares += sharesMinted;
        totalLiquidity += amount;
        availableLiquidity += amount;

        emit LiquidityDeposited(
            msg.sender,
            amount,
            sharesMinted,
            totalLiquidity,
            availableLiquidity,
            totalShares
        );
    }

    function withdrawLiquidity(uint256 shareAmount) external returns (uint256 assetAmount) {
        if (shareAmount == 0) revert InvalidAmount();

        uint256 userShares = lenderShares[msg.sender];
        if (shareAmount > userShares) {
            revert InsufficientShares(shareAmount, userShares);
        }

        assetAmount = previewRedeemAssets(shareAmount);

        if (assetAmount > availableLiquidity) {
            revert InsufficientAvailableLiquidity(assetAmount, availableLiquidity);
        }

        lenderShares[msg.sender] = userShares - shareAmount;
        totalShares -= shareAmount;
        totalLiquidity -= assetAmount;
        availableLiquidity -= assetAmount;

        bool ok = IERC20(quoteAsset).transfer(msg.sender, assetAmount);
        require(ok, "TRANSFER_FAILED");

        emit LiquidityWithdrawn(
            msg.sender,
            assetAmount,
            shareAmount,
            totalLiquidity,
            availableLiquidity,
            totalShares
        );
    }

    function allocateToBorrower(uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        if (amount > availableLiquidity) {
            revert InsufficientAvailableLiquidity(amount, availableLiquidity);
        }

        availableLiquidity -= amount;

        emit BorrowerLiquidityAllocated(amount, availableLiquidity);
    }

    function receiveRepayment(uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();

        totalLiquidity += amount;
        availableLiquidity += amount;

        emit RepaymentReceived(amount, totalLiquidity, availableLiquidity);
    }

    function registerPendingRemoteInbound(uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();

        pendingRemoteInbound += amount;

        emit PendingRemoteInboundRegistered(amount, pendingRemoteInbound);
    }

    function receiveRemoteLiquidity(uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        if (amount > pendingRemoteInbound) {
            revert InsufficientAvailableLiquidity(amount, pendingRemoteInbound);
        }

        pendingRemoteInbound -= amount;
        settledRemoteInbound += amount;
        totalLiquidity += amount;
        availableLiquidity += amount;
        remoteLiquidityUtilized += amount;

        emit RemoteLiquidityReceived(
            amount,
            pendingRemoteInbound,
            settledRemoteInbound,
            totalLiquidity,
            availableLiquidity
        );
    }

    function utilization() external view returns (uint256) {
        if (totalLiquidity == 0) return 0;
        uint256 borrowed = totalLiquidity - availableLiquidity;
        return (borrowed * 10_000) / totalLiquidity;
    }

    function previewRedeemAssets(uint256 shareAmount) public view returns (uint256) {
        if (shareAmount == 0) return 0;
        if (totalShares == 0) return 0;
        return (shareAmount * totalLiquidity) / totalShares;
    }

    function previewDepositShares(uint256 assetAmount) external view returns (uint256) {
        return _previewDepositShares(assetAmount);
    }

    function _previewDepositShares(uint256 assetAmount) internal view returns (uint256) {
        if (assetAmount == 0) return 0;
        if (totalShares == 0 || totalLiquidity == 0) {
            return assetAmount;
        }
        return (assetAmount * totalShares) / totalLiquidity;
    }
}
