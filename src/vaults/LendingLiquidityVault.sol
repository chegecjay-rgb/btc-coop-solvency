// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LendingLiquidityVault is Ownable {
    error ZeroAddress();
    error InvalidAssetId();
    error NotAuthorized();
    error InvalidAmount();
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientAvailableLiquidity(uint256 requested, uint256 available);

    address public immutable quoteAsset;
    bytes32 public immutable assetId;

    uint256 public totalLiquidity;
    uint256 public availableLiquidity;
    uint256 public totalShares;

    mapping(address => uint256) public lenderShares;
    mapping(address => bool) public authorizedWriter;

    event AuthorizedWriterSet(address indexed writer, bool allowed);

    event LiquidityDeposited(
        address indexed lender,
        address indexed receiver,
        uint256 assetAmount,
        uint256 shareAmount,
        uint256 newTotalLiquidity,
        uint256 newAvailableLiquidity,
        uint256 newTotalShares
    );

    event LiquidityWithdrawn(
        address indexed lender,
        address indexed receiver,
        uint256 assetAmount,
        uint256 shareAmount,
        uint256 newTotalLiquidity,
        uint256 newAvailableLiquidity,
        uint256 newTotalShares
    );

    event BorrowerLiquidityAllocated(
        address indexed receiver,
        uint256 amount,
        uint256 newAvailableLiquidity
    );

    event RepaymentReceived(
        address indexed from,
        uint256 amount,
        uint256 newTotalLiquidity,
        uint256 newAvailableLiquidity
    );

    constructor(
        address initialOwner,
        address quoteAsset_,
        bytes32 assetId_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || quoteAsset_ == address(0)) revert ZeroAddress();
        if (assetId_ == bytes32(0)) revert InvalidAssetId();

        quoteAsset = quoteAsset_;
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

    function depositLiquidity(uint256 amount, address receiver) external returns (uint256 sharesMinted) {
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();

        sharesMinted = _previewDepositShares(amount);

        bool ok = IERC20(quoteAsset).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        lenderShares[receiver] += sharesMinted;
        totalShares += sharesMinted;
        totalLiquidity += amount;
        availableLiquidity += amount;

        emit LiquidityDeposited(
            msg.sender,
            receiver,
            amount,
            sharesMinted,
            totalLiquidity,
            availableLiquidity,
            totalShares
        );
    }

    function withdrawLiquidity(uint256 shareAmount, address receiver) external returns (uint256 assetAmount) {
        if (shareAmount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();

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

        bool ok = IERC20(quoteAsset).transfer(receiver, assetAmount);
        require(ok, "TRANSFER_FAILED");

        emit LiquidityWithdrawn(
            msg.sender,
            receiver,
            assetAmount,
            shareAmount,
            totalLiquidity,
            availableLiquidity,
            totalShares
        );
    }

    function allocateToBorrower(address receiver, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (amount > availableLiquidity) {
            revert InsufficientAvailableLiquidity(amount, availableLiquidity);
        }

        availableLiquidity -= amount;

        bool ok = IERC20(quoteAsset).transfer(receiver, amount);
        require(ok, "TRANSFER_FAILED");

        emit BorrowerLiquidityAllocated(receiver, amount, availableLiquidity);
    }

    function receiveRepaymentFrom(address from, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        if (from == address(0)) revert ZeroAddress();

        bool ok = IERC20(quoteAsset).transferFrom(from, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        totalLiquidity += amount;
        availableLiquidity += amount;

        emit RepaymentReceived(from, amount, totalLiquidity, availableLiquidity);
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
