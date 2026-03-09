// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InsuranceReserve is Ownable {
    error ZeroAddress();
    error InvalidAmount();
    error NotAuthorized();
    error PositionNotFound(uint256 positionId);
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientFreeReserve(uint256 requested, uint256 available);
    error InsufficientSystemReserve(uint256 requested, uint256 available);
    error InsufficientCoverReserve(uint256 requested, uint256 available);
    error InsufficientRecoveryReceivable(uint256 requested, uint256 available);
    error NoActiveExposure(uint256 positionId);

    struct PositionInsuranceExposure {
        uint256 coveredClaimAmount;
        uint256 systemDeficitCovered;
        uint256 recoveryReceivable;
        bool active;
    }

    address public immutable reserveToken;

    uint256 public totalReserveBalance;
    uint256 public systemReserveBalance;
    uint256 public coverReserveBalance;
    uint256 public lockedSystemLiabilities;
    uint256 public lockedCoverLiabilities;

    uint256 public totalShares;
    mapping(address => uint256) public insurerShares;
    mapping(uint256 => PositionInsuranceExposure) public exposureByPosition;
    mapping(address => bool) public authorizedWriter;

    event AuthorizedWriterSet(address indexed writer, bool allowed);

    event ReserveDeposited(
        address indexed depositor,
        uint256 amount,
        uint256 sharesMinted,
        uint256 newTotalReserveBalance,
        uint256 newSystemReserveBalance
    );

    event WithdrawRequested(
        address indexed depositor,
        uint256 sharesBurned,
        uint256 assetsReturned,
        uint256 newTotalReserveBalance
    );

    event OptionalCoverReserved(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newCoverReserveBalance,
        uint256 newLockedCoverLiabilities
    );

    event TerminalDeficitCovered(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newSystemReserveBalance,
        uint256 newLockedSystemLiabilities
    );

    event StabilizationReimbursed(
        bytes32 indexed assetId,
        uint256 amount,
        uint256 newSystemReserveBalance,
        uint256 newLockedSystemLiabilities
    );

    event RecoveryReceivableRegistered(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newRecoveryReceivable
    );

    event RecoveryReceived(
        uint256 indexed positionId,
        uint256 amount,
        uint256 newTotalReserveBalance,
        uint256 newSystemReserveBalance,
        uint256 newRecoveryReceivable
    );

    constructor(
        address initialOwner,
        address reserveToken_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || reserveToken_ == address(0)) revert ZeroAddress();
        reserveToken = reserveToken_;
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

    function depositReserve(uint256 amount) external returns (uint256 sharesMinted) {
        if (amount == 0) revert InvalidAmount();

        sharesMinted = _previewDepositShares(amount);

        bool ok = IERC20(reserveToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        insurerShares[msg.sender] += sharesMinted;
        totalShares += sharesMinted;

        totalReserveBalance += amount;
        systemReserveBalance += amount;

        emit ReserveDeposited(
            msg.sender,
            amount,
            sharesMinted,
            totalReserveBalance,
            systemReserveBalance
        );
    }

    function requestWithdraw(uint256 shares) external returns (uint256 assetsReturned) {
        if (shares == 0) revert InvalidAmount();

        uint256 userShares = insurerShares[msg.sender];
        if (shares > userShares) {
            revert InsufficientShares(shares, userShares);
        }

        assetsReturned = previewRedeemAssets(shares);

        uint256 freeReserve = _freeReserve();
        if (assetsReturned > freeReserve) {
            revert InsufficientFreeReserve(assetsReturned, freeReserve);
        }

        insurerShares[msg.sender] = userShares - shares;
        totalShares -= shares;

        totalReserveBalance -= assetsReturned;

        // withdraw from system reserve first, then cover reserve if ever needed
        if (assetsReturned <= systemReserveBalance) {
            systemReserveBalance -= assetsReturned;
        } else {
            uint256 fromSystem = systemReserveBalance;
            uint256 remaining = assetsReturned - fromSystem;
            systemReserveBalance = 0;
            coverReserveBalance -= remaining;
        }

        bool ok = IERC20(reserveToken).transfer(msg.sender, assetsReturned);
        require(ok, "TRANSFER_FAILED");

        emit WithdrawRequested(
            msg.sender,
            shares,
            assetsReturned,
            totalReserveBalance
        );
    }

    function reserveOptionalCover(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert PositionNotFound(positionId);
        if (amount == 0) revert InvalidAmount();
        if (amount > systemReserveBalance) {
            revert InsufficientSystemReserve(amount, systemReserveBalance);
        }

        PositionInsuranceExposure storage exposure = exposureByPosition[positionId];

        systemReserveBalance -= amount;
        coverReserveBalance += amount;
        lockedCoverLiabilities += amount;

        exposure.coveredClaimAmount += amount;
        exposure.active = true;

        emit OptionalCoverReserved(
            positionId,
            amount,
            coverReserveBalance,
            lockedCoverLiabilities
        );
    }

    function coverTerminalDeficit(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert PositionNotFound(positionId);
        if (amount == 0) revert InvalidAmount();
        if (amount > systemReserveBalance) {
            revert InsufficientSystemReserve(amount, systemReserveBalance);
        }

        PositionInsuranceExposure storage exposure = exposureByPosition[positionId];

        systemReserveBalance -= amount;
        lockedSystemLiabilities += amount;

        exposure.systemDeficitCovered += amount;
        exposure.active = true;

        emit TerminalDeficitCovered(
            positionId,
            amount,
            systemReserveBalance,
            lockedSystemLiabilities
        );
    }

    function reimburseStabilizationPool(bytes32 assetId, uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();
        if (amount > systemReserveBalance) {
            revert InsufficientSystemReserve(amount, systemReserveBalance);
        }

        systemReserveBalance -= amount;
        totalReserveBalance -= amount;

        bool ok = IERC20(reserveToken).transfer(msg.sender, amount);
        require(ok, "TRANSFER_FAILED");

        emit StabilizationReimbursed(
            assetId,
            amount,
            systemReserveBalance,
            lockedSystemLiabilities
        );
    }

    function registerRecoveryReceivable(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert PositionNotFound(positionId);
        if (amount == 0) revert InvalidAmount();

        PositionInsuranceExposure storage exposure = exposureByPosition[positionId];
        exposure.recoveryReceivable += amount;
        exposure.active = true;

        emit RecoveryReceivableRegistered(
            positionId,
            amount,
            exposure.recoveryReceivable
        );
    }

    function receiveRecovery(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert PositionNotFound(positionId);
        if (amount == 0) revert InvalidAmount();

        PositionInsuranceExposure storage exposure = exposureByPosition[positionId];
        if (!exposure.active) revert NoActiveExposure(positionId);
        if (amount > exposure.recoveryReceivable) {
            revert InsufficientRecoveryReceivable(amount, exposure.recoveryReceivable);
        }

        bool ok = IERC20(reserveToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAILED");

        exposure.recoveryReceivable -= amount;

        totalReserveBalance += amount;
        systemReserveBalance += amount;

        if (
            exposure.coveredClaimAmount == 0 &&
            exposure.systemDeficitCovered == 0 &&
            exposure.recoveryReceivable == 0
        ) {
            exposure.active = false;
        }

        emit RecoveryReceived(
            positionId,
            amount,
            totalReserveBalance,
            systemReserveBalance,
            exposure.recoveryReceivable
        );
    }

    function solvencyRatio() external view returns (uint256) {
        uint256 lockedLiabilities = lockedSystemLiabilities + lockedCoverLiabilities;
        if (lockedLiabilities == 0) return type(uint256).max;
        return (totalReserveBalance * 10_000) / lockedLiabilities;
    }

    function previewRedeemAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;
        if (totalShares == 0 || totalReserveBalance == 0) return 0;
        return (shares * totalReserveBalance) / totalShares;
    }

    function previewDepositShares(uint256 amount) external view returns (uint256) {
        return _previewDepositShares(amount);
    }

    function _previewDepositShares(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (totalShares == 0 || totalReserveBalance == 0) return amount;
        return (amount * totalShares) / totalReserveBalance;
    }

    function _freeReserve() internal view returns (uint256) {
        uint256 lockedLiabilities = lockedSystemLiabilities + lockedCoverLiabilities;
        if (totalReserveBalance <= lockedLiabilities) return 0;
        return totalReserveBalance - lockedLiabilities;
    }
}
