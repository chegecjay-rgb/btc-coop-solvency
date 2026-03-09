// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPositionRegistryForRecap {
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
}

interface IStabilizationPoolForRecap {
    function receiveRecovery(bytes32 assetId, uint256 amount) external;
}

interface IInsuranceReserveForRecap {
    function receiveRecovery(uint256 positionId, uint256 amount) external;
}

interface ITreasuryVaultForRecap {
    function receiveProtocolRevenue(uint256 amount) external;
}

contract RecapitalizationEngine is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error InvalidAmount();
    error NotAuthorized();
    error NoRecoveryRecorded(uint256 positionId);

    address public immutable stabilizationPool;
    address public immutable insuranceReserve;
    address public immutable treasuryVault;
    address public immutable positionRegistry;
    address public immutable reserveToken;

    mapping(uint256 => uint256) public recoveryByPosition;
    mapping(bytes32 => uint256) public pendingRecoveryByAsset;
    mapping(address => bool) public authorizedWriter;

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event RecoveryRecorded(uint256 indexed positionId, bytes32 indexed assetId, uint256 amount);
    event RecoveryDistributed(
        uint256 indexed positionId,
        bytes32 indexed assetId,
        uint256 toStabilization,
        uint256 toInsurance,
        uint256 toTreasury
    );
    event StabilizationReplenished(bytes32 indexed assetId, uint256 amount);
    event InsuranceReplenished(uint256 indexed positionId, uint256 amount);
    event TreasuryFunded(uint256 amount);

    constructor(
        address initialOwner,
        address stabilizationPool_,
        address insuranceReserve_,
        address treasuryVault_,
        address positionRegistry_,
        address reserveToken_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            stabilizationPool_ == address(0) ||
            insuranceReserve_ == address(0) ||
            treasuryVault_ == address(0) ||
            positionRegistry_ == address(0) ||
            reserveToken_ == address(0)
        ) revert ZeroAddress();

        stabilizationPool = stabilizationPool_;
        insuranceReserve = insuranceReserve_;
        treasuryVault = treasuryVault_;
        positionRegistry = positionRegistry_;
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

    function recordRecovery(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        if (amount == 0) revert InvalidAmount();

        IPositionRegistryForRecap.Position memory p =
            IPositionRegistryForRecap(positionRegistry).getPosition(positionId);

        recoveryByPosition[positionId] += amount;
        pendingRecoveryByAsset[p.assetId] += amount;

        emit RecoveryRecorded(positionId, p.assetId, amount);
    }

    function distributeRecovery(uint256 positionId) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);

        uint256 totalRecovery = recoveryByPosition[positionId];
        if (totalRecovery == 0) revert NoRecoveryRecorded(positionId);

        IPositionRegistryForRecap.Position memory p =
            IPositionRegistryForRecap(positionRegistry).getPosition(positionId);

        uint256 toStabilization = (totalRecovery * 5_000) / 10_000;
        uint256 toInsurance = (totalRecovery * 3_000) / 10_000;
        uint256 toTreasury = totalRecovery - toStabilization - toInsurance;

        if (toStabilization > 0) {
            IStabilizationPoolForRecap(stabilizationPool).receiveRecovery(p.assetId, toStabilization);
            emit StabilizationReplenished(p.assetId, toStabilization);
        }

        if (toInsurance > 0) {
            IERC20(reserveToken).approve(insuranceReserve, 0);
            IERC20(reserveToken).approve(insuranceReserve, toInsurance);
            IInsuranceReserveForRecap(insuranceReserve).receiveRecovery(positionId, toInsurance);
            emit InsuranceReplenished(positionId, toInsurance);
        }

        if (toTreasury > 0) {
            IERC20(reserveToken).approve(treasuryVault, 0);
            IERC20(reserveToken).approve(treasuryVault, toTreasury);
            ITreasuryVaultForRecap(treasuryVault).receiveProtocolRevenue(toTreasury);
            emit TreasuryFunded(toTreasury);
        }

        pendingRecoveryByAsset[p.assetId] -= totalRecovery;
        recoveryByPosition[positionId] = 0;

        emit RecoveryDistributed(
            positionId,
            p.assetId,
            toStabilization,
            toInsurance,
            toTreasury
        );
    }

    function replenishStabilization(bytes32 assetId, uint256 amount) external onlyAuthorized {
        if (assetId == bytes32(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        IStabilizationPoolForRecap(stabilizationPool).receiveRecovery(assetId, amount);
        emit StabilizationReplenished(assetId, amount);
    }

    function replenishInsurance(uint256 positionId, uint256 amount) external onlyAuthorized {
        if (positionId == 0) revert InvalidPositionId(positionId);
        if (amount == 0) revert InvalidAmount();

        IERC20(reserveToken).approve(insuranceReserve, 0);
        IERC20(reserveToken).approve(insuranceReserve, amount);
        IInsuranceReserveForRecap(insuranceReserve).receiveRecovery(positionId, amount);
        emit InsuranceReplenished(positionId, amount);
    }

    function sendResidualToTreasury(uint256 amount) external onlyAuthorized {
        if (amount == 0) revert InvalidAmount();

        IERC20(reserveToken).approve(treasuryVault, 0);
        IERC20(reserveToken).approve(treasuryVault, amount);
        ITreasuryVaultForRecap(treasuryVault).receiveProtocolRevenue(amount);
        emit TreasuryFunded(amount);
    }
}
