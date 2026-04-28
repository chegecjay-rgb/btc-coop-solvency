// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CollateralRail} from "src/types/CollateralRail.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {INativeSettlementProofVerifier} from "src/interfaces/INativeSettlementProofVerifier.sol";

interface IDebtLedgerForNativeSettlement {
    function recordSettlementCost(uint256 positionId, uint256 amount) external;
}

interface IRecapitalizationEngineForNativeSettlement {
    function recordRecovery(uint256 positionId, uint256 amount) external;
}

/// @notice Accounting adapter for enforceable native-BTC collateral settlement.
/// @dev This contract does not execute Bitcoin transactions. It only consumes already-observed,
/// proof-pack-backed native settlement evidence and records the resulting recovery/costs into Luna accounting.
contract NativeSettlementAdapter is Ownable {
    error ZeroAddress();
    error InvalidPositionId(uint256 positionId);
    error EmptyProofPackRef();
    error InvalidAmount();
    error NotAuthorizedFinalizer(address caller);
    error PositionIsNotNativeRail(uint256 positionId, uint8 rail);
    error PositionRailLookupFailed(uint256 positionId);
    error ProofPackNotFound(bytes32 proofPackRef);
    error RecoveryNotObserved(uint256 positionId, bytes32 proofPackRef);
    error ProofVerificationFailed(bytes32 proofPackRef);
    error PositionAlreadySettled(uint256 positionId);
    error ProofPackAlreadyConsumed(bytes32 proofPackRef);

    uint8 public constant RAIL_NATIVE_BTC = CollateralRail.ENFORCEABLE_NATIVE;

    enum SettlementKind {
        None,
        Liquidation,
        TerminalSettlement
    }

    struct NativeSettlement {
        uint256 positionId;
        SettlementKind kind;
        bytes32 proofPackRef;
        uint256 recoveredAmount;
        uint256 settlementCost;
        address finalizedBy;
        bool finalized;
    }

    address public immutable positionRegistry;
    address public immutable debtLedger;
    address public immutable recapitalizationEngine;
    address public immutable proofPackRegistry;
    address public immutable enforcementCoordinator;
    address public immutable proofVerifier;

    mapping(address => bool) public authorizedFinalizer;
    mapping(uint256 => NativeSettlement) public settlementByPosition;
    mapping(bytes32 => bool) public consumedProofPack;

    event AuthorizedFinalizerSet(address indexed finalizer, bool allowed);

    event NativeSettlementFinalized(
        uint256 indexed positionId,
        SettlementKind indexed kind,
        bytes32 indexed proofPackRef,
        uint256 recoveredAmount,
        uint256 settlementCost,
        address finalizedBy
    );

    constructor(
        address initialOwner,
        address positionRegistry_,
        address debtLedger_,
        address recapitalizationEngine_,
        address proofPackRegistry_,
        address enforcementCoordinator_,
        address proofVerifier_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || positionRegistry_ == address(0) || debtLedger_ == address(0)
                || recapitalizationEngine_ == address(0) || proofPackRegistry_ == address(0)
                || enforcementCoordinator_ == address(0) || proofVerifier_ == address(0)
        ) revert ZeroAddress();

        positionRegistry = positionRegistry_;
        debtLedger = debtLedger_;
        recapitalizationEngine = recapitalizationEngine_;
        proofPackRegistry = proofPackRegistry_;
        enforcementCoordinator = enforcementCoordinator_;
        proofVerifier = proofVerifier_;
    }

    modifier onlyFinalizer() {
        if (!(authorizedFinalizer[msg.sender] || msg.sender == owner())) {
            revert NotAuthorizedFinalizer(msg.sender);
        }
        _;
    }

    function setAuthorizedFinalizer(address finalizer, bool allowed) external onlyOwner {
        if (finalizer == address(0)) revert ZeroAddress();
        authorizedFinalizer[finalizer] = allowed;
        emit AuthorizedFinalizerSet(finalizer, allowed);
    }

    function finalizeNativeLiquidation(
        uint256 positionId,
        bytes32 proofPackRef,
        uint256 recoveredAmount,
        uint256 settlementCost
    ) external onlyFinalizer {
        _finalizeNativeSettlement(positionId, proofPackRef, recoveredAmount, settlementCost, SettlementKind.Liquidation);
    }

    function finalizeNativeTerminalSettlement(
        uint256 positionId,
        bytes32 proofPackRef,
        uint256 recoveredAmount,
        uint256 settlementCost
    ) external onlyFinalizer {
        _finalizeNativeSettlement(
            positionId, proofPackRef, recoveredAmount, settlementCost, SettlementKind.TerminalSettlement
        );
    }

    function _finalizeNativeSettlement(
        uint256 positionId,
        bytes32 proofPackRef,
        uint256 recoveredAmount,
        uint256 settlementCost,
        SettlementKind kind
    ) internal {
        _requireNativeRail(positionId);
        if (positionId == 0) revert InvalidPositionId(positionId);
        if (proofPackRef == bytes32(0)) revert EmptyProofPackRef();
        if (recoveredAmount == 0) revert InvalidAmount();

        if (settlementByPosition[positionId].finalized) {
            revert PositionAlreadySettled(positionId);
        }

        if (consumedProofPack[proofPackRef]) {
            revert ProofPackAlreadyConsumed(proofPackRef);
        }

        uint8 rail = _positionRail(positionId);
        if (rail != RAIL_NATIVE_BTC) {
            revert PositionIsNotNativeRail(positionId, rail);
        }

        if (!_proofPackExists(proofPackRef)) {
            revert ProofPackNotFound(proofPackRef);
        }

        if (!_recoveryObserved(positionId, proofPackRef)) {
            revert RecoveryNotObserved(positionId, proofPackRef);
        }

        bool verified = INativeSettlementProofVerifier(proofVerifier)
            .verifyNativeSettlement(positionId, proofPackRef, recoveredAmount, settlementCost, uint8(kind));

        if (!verified) {
            revert ProofVerificationFailed(proofPackRef);
        }

        consumedProofPack[proofPackRef] = true;

        settlementByPosition[positionId] = NativeSettlement({
            positionId: positionId,
            kind: kind,
            proofPackRef: proofPackRef,
            recoveredAmount: recoveredAmount,
            settlementCost: settlementCost,
            finalizedBy: msg.sender,
            finalized: true
        });

        if (settlementCost > 0) {
            IDebtLedgerForNativeSettlement(debtLedger).recordSettlementCost(positionId, settlementCost);
        }

        IRecapitalizationEngineForNativeSettlement(recapitalizationEngine).recordRecovery(positionId, recoveredAmount);

        emit NativeSettlementFinalized(positionId, kind, proofPackRef, recoveredAmount, settlementCost, msg.sender);
    }

    function _requireNativeRail(uint256 positionId) internal view {
        uint8 rail = _nativeSettlementPositionRail(positionId);

        if (rail != RAIL_NATIVE_BTC) {
            revert PositionIsNotNativeRail(positionId, rail);
        }
    }

    function _nativeSettlementPositionRail(uint256 positionId) internal view returns (uint8) {
        (bool ok, bytes memory data) =
            positionRegistry.staticcall(abi.encodeWithSignature("collateralRailOf(uint256)", positionId));

        if (ok && data.length >= 32) {
            return abi.decode(data, (uint8));
        }

        (ok, data) = positionRegistry.staticcall(abi.encodeWithSignature("getPositionRail(uint256)", positionId));

        if (ok && data.length >= 32) {
            return abi.decode(data, (uint8));
        }

        (ok, data) = positionRegistry.staticcall(abi.encodeWithSignature("positionRail(uint256)", positionId));

        if (ok && data.length >= 32) {
            return abi.decode(data, (uint8));
        }

        revert PositionRailLookupFailed(positionId);
    }

    function _positionRail(uint256 positionId) internal view returns (uint8) {
        (bool ok, bytes memory data) =
            positionRegistry.staticcall(abi.encodeWithSignature("getPositionRail(uint256)", positionId));

        if (ok && data.length >= 32) {
            return abi.decode(data, (uint8));
        }

        (ok, data) = positionRegistry.staticcall(abi.encodeWithSignature("positionRail(uint256)", positionId));

        if (ok && data.length >= 32) {
            return abi.decode(data, (uint8));
        }

        revert PositionRailLookupFailed(positionId);
    }

    function _proofPackExists(bytes32 proofPackRef) internal view returns (bool) {
        (bool ok, bytes memory data) =
            proofPackRegistry.staticcall(abi.encodeWithSignature("hasProofPack(bytes32)", proofPackRef));

        if (ok && data.length >= 32) {
            return abi.decode(data, (bool));
        }

        (ok, data) = proofPackRegistry.staticcall(abi.encodeWithSignature("proofPackExists(bytes32)", proofPackRef));

        if (ok && data.length >= 32) {
            return abi.decode(data, (bool));
        }

        return false;
    }

    function _recoveryObserved(uint256 positionId, bytes32 proofPackRef) internal view returns (bool) {
        (bool ok, bytes memory data) = enforcementCoordinator.staticcall(
            abi.encodeWithSignature("hasObservedRecovery(uint256,bytes32)", positionId, proofPackRef)
        );

        if (ok && data.length >= 32) {
            return abi.decode(data, (bool));
        }

        (ok, data) = enforcementCoordinator.staticcall(
            abi.encodeWithSignature("isRecoveryObserved(uint256,bytes32)", positionId, proofPackRef)
        );

        if (ok && data.length >= 32) {
            return abi.decode(data, (bool));
        }

        return false;
    }
}
