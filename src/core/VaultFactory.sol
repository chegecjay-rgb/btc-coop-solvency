// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AssetVault} from "src/vaults/AssetVault.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";

contract VaultFactory is Ownable {
    error ZeroAddress();
    error ZeroAssetId();
    error NotGovernance();
    error VaultAlreadyExists(bytes32 assetId, uint8 vaultType);
    error InvalidVaultType(uint8 vaultType);

    uint8 public constant VAULT_TYPE_ASSET = 0;
    uint8 public constant VAULT_TYPE_LENDING = 1;

    mapping(bytes32 => address) public assetVaultByAssetId;
    mapping(bytes32 => address) public lendingVaultByAssetId;
    mapping(address => bool) public isOfficialVault;

    address public governance;

    event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);

    event AssetVaultCreated(
        bytes32 indexed assetId,
        address indexed assetToken,
        address indexed vault
    );

    event LendingVaultCreated(
        bytes32 indexed assetId,
        address indexed quoteToken,
        address indexed vault
    );

    event VaultRegistered(
        bytes32 indexed assetId,
        uint8 indexed vaultType,
        address indexed vault
    );

    event VaultStatusUpdated(address indexed vault, bool approved);

    constructor(address initialGovernance) Ownable(initialGovernance) {
        if (initialGovernance == address(0)) revert ZeroAddress();
        governance = initialGovernance;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();

        address oldGovernance = governance;
        governance = newGovernance;
        _transferOwnership(newGovernance);

        emit GovernanceUpdated(oldGovernance, newGovernance);
    }

    function createAssetVault(bytes32 assetId, address assetToken)
        external
        onlyGovernance
        returns (address vault)
    {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (assetToken == address(0)) revert ZeroAddress();
        if (assetVaultByAssetId[assetId] != address(0)) {
            revert VaultAlreadyExists(assetId, VAULT_TYPE_ASSET);
        }

        vault = address(new AssetVault(governance, assetToken, assetId));

        assetVaultByAssetId[assetId] = vault;
        isOfficialVault[vault] = true;

        emit AssetVaultCreated(assetId, assetToken, vault);
        emit VaultRegistered(assetId, VAULT_TYPE_ASSET, vault);
    }

    function createLendingVault(bytes32 assetId, address quoteToken)
        external
        onlyGovernance
        returns (address vault)
    {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (quoteToken == address(0)) revert ZeroAddress();
        if (lendingVaultByAssetId[assetId] != address(0)) {
            revert VaultAlreadyExists(assetId, VAULT_TYPE_LENDING);
        }

        vault = address(new LendingLiquidityVault(governance, quoteToken, assetId));

        lendingVaultByAssetId[assetId] = vault;
        isOfficialVault[vault] = true;

        emit LendingVaultCreated(assetId, quoteToken, vault);
        emit VaultRegistered(assetId, VAULT_TYPE_LENDING, vault);
    }

    function registerVault(bytes32 assetId, uint8 vaultType, address vault) external onlyGovernance {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (vault == address(0)) revert ZeroAddress();

        if (vaultType == VAULT_TYPE_ASSET) {
            address oldVault = assetVaultByAssetId[assetId];
            if (oldVault != address(0)) {
                isOfficialVault[oldVault] = false;
            }

            assetVaultByAssetId[assetId] = vault;
        } else if (vaultType == VAULT_TYPE_LENDING) {
            address oldVault = lendingVaultByAssetId[assetId];
            if (oldVault != address(0)) {
                isOfficialVault[oldVault] = false;
            }

            lendingVaultByAssetId[assetId] = vault;
        } else {
            revert InvalidVaultType(vaultType);
        }

        isOfficialVault[vault] = true;

        emit VaultRegistered(assetId, vaultType, vault);
    }

    function setVaultStatus(address vault, bool approved) external onlyGovernance {
        if (vault == address(0)) revert ZeroAddress();

        isOfficialVault[vault] = approved;

        emit VaultStatusUpdated(vault, approved);
    }
}
