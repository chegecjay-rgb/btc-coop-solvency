// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface INativePledgeRegistryForEnforcementCoordinator {
    function hasPledge(uint256 positionId) external view returns (bool);
    function pledgeIdOfPosition(uint256 positionId) external view returns (bytes32);
    function isCreditReady(uint256 positionId) external view returns (bool);
    function isEnforcementActive(uint256 positionId) external view returns (bool);
    function requestEnforcement(uint256 positionId, bytes32 proofRef) external;
    function updateEnforcementState(uint256 positionId, uint8 nextState, bytes32 proofRef) external;
}

/// @notice Phase C.1 skeleton for coordinating native BTC enforcement.
/// @dev This contract does not execute BTC transactions. It coordinates state
///      transitions between Luna accounting and BTC-side proof/watcher services.
contract NativeEnforcementCoordinator is Ownable {
    enum EnforcementPhase {
        Unset,
        Requested,
        InProgress,
        RecoveryObserved,
        Settled,
        Failed
    }

    struct EnforcementCase {
        uint256 positionId;
        bytes32 pledgeId;
        EnforcementPhase phase;
        bytes32 requestProofRef;
        bytes32 executionProofRef;
        bytes32 recoveryProofRef;
        bytes32 settlementProofRef;
        bytes32 failureProofRef;
        uint64 requestedAt;
        uint64 updatedAt;
    }

    uint8 internal constant REGISTRY_STATE_ENFORCEMENT_IN_PROGRESS = 4;
    uint8 internal constant REGISTRY_STATE_RECOVERY_OBSERVED = 5;
    uint8 internal constant REGISTRY_STATE_SETTLED = 6;
    uint8 internal constant REGISTRY_STATE_FAILED = 8;

    error ZeroAddress();
    error NotAuthorized();
    error InvalidPositionId();
    error InvalidProofReference();
    error NativePledgeMissing(uint256 positionId);
    error NativePledgeNotCreditReady(uint256 positionId);
    error NativeEnforcementAlreadyActive(uint256 positionId);
    error EnforcementCaseAlreadyExists(uint256 positionId);
    error EnforcementCaseNotFound(uint256 positionId);
    error InvalidPhase(EnforcementPhase currentPhase, EnforcementPhase requiredPhase);

    INativePledgeRegistryForEnforcementCoordinator public immutable nativePledgeRegistry;

    mapping(address => bool) public authorizedActor;
    mapping(uint256 => EnforcementCase) private _casesByPosition;

    event AuthorizedActorSet(address indexed actor, bool allowed);
    event NativeEnforcementRequested(uint256 indexed positionId, bytes32 indexed pledgeId, bytes32 proofRef);
    event NativeEnforcementInProgress(uint256 indexed positionId, bytes32 indexed pledgeId, bytes32 proofRef);
    event NativeRecoveryObserved(uint256 indexed positionId, bytes32 indexed pledgeId, bytes32 proofRef);
    event NativeEnforcementSettled(uint256 indexed positionId, bytes32 indexed pledgeId, bytes32 proofRef);
    event NativeEnforcementFailed(uint256 indexed positionId, bytes32 indexed pledgeId, bytes32 proofRef);

    modifier onlyAuthorized() {
        if (!(msg.sender == owner() || authorizedActor[msg.sender])) revert NotAuthorized();
        _;
    }

    constructor(address initialOwner, address nativePledgeRegistry_) Ownable(_requireNonZeroOwner(initialOwner)) {
        if (nativePledgeRegistry_ == address(0)) revert ZeroAddress();

        nativePledgeRegistry = INativePledgeRegistryForEnforcementCoordinator(nativePledgeRegistry_);
    }

    function setAuthorizedActor(address actor, bool allowed) external onlyOwner {
        if (actor == address(0)) revert ZeroAddress();

        authorizedActor[actor] = allowed;

        emit AuthorizedActorSet(actor, allowed);
    }

    function startEnforcement(uint256 positionId, bytes32 requestProofRef) external onlyAuthorized {
        _requirePositionId(positionId);
        _requireProofRef(requestProofRef);

        if (_casesByPosition[positionId].positionId != 0) {
            revert EnforcementCaseAlreadyExists(positionId);
        }

        if (!nativePledgeRegistry.hasPledge(positionId)) {
            revert NativePledgeMissing(positionId);
        }

        if (!nativePledgeRegistry.isCreditReady(positionId)) {
            revert NativePledgeNotCreditReady(positionId);
        }

        if (nativePledgeRegistry.isEnforcementActive(positionId)) {
            revert NativeEnforcementAlreadyActive(positionId);
        }

        bytes32 pledgeId = nativePledgeRegistry.pledgeIdOfPosition(positionId);

        nativePledgeRegistry.requestEnforcement(positionId, requestProofRef);

        uint64 nowTs = uint64(block.timestamp);

        _casesByPosition[positionId] = EnforcementCase({
            positionId: positionId,
            pledgeId: pledgeId,
            phase: EnforcementPhase.Requested,
            requestProofRef: requestProofRef,
            executionProofRef: bytes32(0),
            recoveryProofRef: bytes32(0),
            settlementProofRef: bytes32(0),
            failureProofRef: bytes32(0),
            requestedAt: nowTs,
            updatedAt: nowTs
        });

        emit NativeEnforcementRequested(positionId, pledgeId, requestProofRef);
    }

    function markEnforcementInProgress(uint256 positionId, bytes32 executionProofRef) external onlyAuthorized {
        _requireProofRef(executionProofRef);

        EnforcementCase storage enforcementCase = _requireCase(positionId);
        _requirePhase(enforcementCase, EnforcementPhase.Requested);

        nativePledgeRegistry.updateEnforcementState(
            positionId, REGISTRY_STATE_ENFORCEMENT_IN_PROGRESS, executionProofRef
        );

        enforcementCase.phase = EnforcementPhase.InProgress;
        enforcementCase.executionProofRef = executionProofRef;
        enforcementCase.updatedAt = uint64(block.timestamp);

        emit NativeEnforcementInProgress(positionId, enforcementCase.pledgeId, executionProofRef);
    }

    function recordRecoveryObserved(uint256 positionId, bytes32 recoveryProofRef) external onlyAuthorized {
        _requireProofRef(recoveryProofRef);

        EnforcementCase storage enforcementCase = _requireCase(positionId);
        _requirePhase(enforcementCase, EnforcementPhase.InProgress);

        nativePledgeRegistry.updateEnforcementState(positionId, REGISTRY_STATE_RECOVERY_OBSERVED, recoveryProofRef);

        enforcementCase.phase = EnforcementPhase.RecoveryObserved;
        enforcementCase.recoveryProofRef = recoveryProofRef;
        enforcementCase.updatedAt = uint64(block.timestamp);

        emit NativeRecoveryObserved(positionId, enforcementCase.pledgeId, recoveryProofRef);
    }

    function markSettled(uint256 positionId, bytes32 settlementProofRef) external onlyAuthorized {
        _requireProofRef(settlementProofRef);

        EnforcementCase storage enforcementCase = _requireCase(positionId);

        if (
            enforcementCase.phase != EnforcementPhase.InProgress
                && enforcementCase.phase != EnforcementPhase.RecoveryObserved
        ) {
            revert InvalidPhase(enforcementCase.phase, EnforcementPhase.InProgress);
        }

        nativePledgeRegistry.updateEnforcementState(positionId, REGISTRY_STATE_SETTLED, settlementProofRef);

        enforcementCase.phase = EnforcementPhase.Settled;
        enforcementCase.settlementProofRef = settlementProofRef;
        enforcementCase.updatedAt = uint64(block.timestamp);

        emit NativeEnforcementSettled(positionId, enforcementCase.pledgeId, settlementProofRef);
    }

    function markFailed(uint256 positionId, bytes32 failureProofRef) external onlyAuthorized {
        _requireProofRef(failureProofRef);

        EnforcementCase storage enforcementCase = _requireCase(positionId);

        if (enforcementCase.phase == EnforcementPhase.Settled || enforcementCase.phase == EnforcementPhase.Failed) {
            revert InvalidPhase(enforcementCase.phase, EnforcementPhase.Requested);
        }

        nativePledgeRegistry.updateEnforcementState(positionId, REGISTRY_STATE_FAILED, failureProofRef);

        enforcementCase.phase = EnforcementPhase.Failed;
        enforcementCase.failureProofRef = failureProofRef;
        enforcementCase.updatedAt = uint64(block.timestamp);

        emit NativeEnforcementFailed(positionId, enforcementCase.pledgeId, failureProofRef);
    }

    function hasObservedRecovery(uint256 positionId, bytes32 proofRef) external view returns (bool) {
        if (positionId == 0 || proofRef == bytes32(0)) {
            return false;
        }

        EnforcementCase storage enforcementCase = _casesByPosition[positionId];

        return enforcementCase.positionId == positionId && enforcementCase.recoveryProofRef == proofRef
            && uint8(enforcementCase.phase) >= uint8(EnforcementPhase.RecoveryObserved);
    }

    function getCase(uint256 positionId) external view returns (EnforcementCase memory) {
        return _requireCase(positionId);
    }

    function hasCase(uint256 positionId) external view returns (bool) {
        return _casesByPosition[positionId].positionId != 0;
    }

    function _requireCase(uint256 positionId) internal view returns (EnforcementCase storage enforcementCase) {
        enforcementCase = _casesByPosition[positionId];

        if (enforcementCase.positionId == 0) {
            revert EnforcementCaseNotFound(positionId);
        }
    }

    function _requirePhase(EnforcementCase storage enforcementCase, EnforcementPhase requiredPhase) internal view {
        if (enforcementCase.phase != requiredPhase) {
            revert InvalidPhase(enforcementCase.phase, requiredPhase);
        }
    }

    function _requirePositionId(uint256 positionId) internal pure {
        if (positionId == 0) revert InvalidPositionId();
    }

    function _requireProofRef(bytes32 proofRef) internal pure {
        if (proofRef == bytes32(0)) revert InvalidProofReference();
    }

    function _requireNonZeroOwner(address initialOwner) internal pure returns (address) {
        if (initialOwner == address(0)) revert ZeroAddress();

        return initialOwner;
    }
}
