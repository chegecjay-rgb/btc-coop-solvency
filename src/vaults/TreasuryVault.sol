// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TreasuryVault is Ownable {
    error ZeroAddress();
    error InvalidAmount();
    error NotAuthorized();
    error BudgetExceeded(bytes32 category, uint256 requested, uint256 remaining);
    error InsufficientStableBalance(uint256 requested, uint256 available);
    error InsufficientBTCBalance(uint256 requested, uint256 available);

    address public immutable stableToken;
    address public immutable btcToken;

    uint256 public stableBalance;
    uint256 public btcBalance;

    mapping(address => bool) public approvedSpenders;
    mapping(bytes32 => uint256) public budgetByCategory;

    event ApprovedSpenderSet(address indexed spender, bool allowed);
    event ProtocolRevenueReceived(address indexed from, uint256 amount, uint256 newStableBalance);
    event ResidualCollateralReceived(address indexed from, uint256 amount, uint256 newBTCBalance);
    event BudgetAllocated(bytes32 indexed category, uint256 amount);
    event Disbursed(
        bytes32 indexed category,
        address indexed operator,
        address indexed to,
        address token,
        uint256 amount,
        uint256 remainingBudget
    );

    modifier onlySpenderOrOwner() {
        if (!(approvedSpenders[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

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

    function setApprovedSpender(address spender, bool allowed) external onlyOwner {
        if (spender == address(0)) revert ZeroAddress();
        approvedSpenders[spender] = allowed;
        emit ApprovedSpenderSet(spender, allowed);
    }

    function receiveProtocolRevenue(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        bool ok = IERC20(stableToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        stableBalance += amount;

        emit ProtocolRevenueReceived(msg.sender, amount, stableBalance);
    }

    function receiveResidualCollateral(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        bool ok = IERC20(btcToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        btcBalance += amount;

        emit ResidualCollateralReceived(msg.sender, amount, btcBalance);
    }

    function allocateBudget(bytes32 category, uint256 amount) external onlyOwner {
        if (category == bytes32(0)) revert ZeroAddress();
        budgetByCategory[category] = amount;
        emit BudgetAllocated(category, amount);
    }

    function disburse(
        bytes32 category,
        address to,
        address token,
        uint256 amount
    ) external onlySpenderOrOwner {
        if (category == bytes32(0) || to == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 remainingBudget = budgetByCategory[category];
        if (amount > remainingBudget) {
            revert BudgetExceeded(category, amount, remainingBudget);
        }

        if (token == stableToken) {
            if (amount > stableBalance) {
                revert InsufficientStableBalance(amount, stableBalance);
            }
            stableBalance -= amount;
        } else if (token == btcToken) {
            if (amount > btcBalance) {
                revert InsufficientBTCBalance(amount, btcBalance);
            }
            btcBalance -= amount;
        } else {
            revert ZeroAddress();
        }

        budgetByCategory[category] = remainingBudget - amount;

        bool ok = IERC20(token).transfer(to, amount);
        require(ok, "TRANSFER_FAILED");

        emit Disbursed(
            category,
            msg.sender,
            to,
            token,
            amount,
            budgetByCategory[category]
        );
    }
}
