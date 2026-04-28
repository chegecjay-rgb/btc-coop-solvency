// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CollateralRail} from "../types/CollateralRail.sol";

import {INativePledgeProofVerifier} from "../interfaces/INativePledgeProofVerifier.sol";

interface IPositionRegistryForNativePledge {
    function ownerOfPosition(uint256 positionId) external view returns (address);
    function collateralRailOf(uint256 positionId) external view returns (uint8);
}

/// @notice Rail 2 identity layer for enforceable native BTC collateral.
/// @dev This contract does not execute BTC-side settlement. It only binds Luna
///      positions to native BTC pledge identities, proof references, finality
///      status, and enforcement workflow state.
contract NativePledgeRegistry is Ownable {
    enum EnforcementState {
        Unset,
        Pledged,
        Enforceable,
        EnforcementRequested,
        EnforcementInProgress,
        RecoveryObserved,
        Settled,
        Released,
        Failed
    }

    enum FinalityState {
        Unset,
        Unconfirmed,
        Confirming,
        Finalized,
        Reorged,
        Invalidated
    }

    struct NativePledge {
        uint256 positionId;
        address positionOwner;
        bytes32 pledgeId;
        bytes32 btcTxId;
        uint32 vout;
        uint64 amountSats;
        bytes32 scriptCommitment;
        bytes32 proofRef;
        bytes32 pledgeProofRef;
        bytes32 finalityProofRef;
        bytes32 enforcementProofRef;
        uint64 btcBlockHeight;
        uint32 confirmations;
        EnforcementState enforcementState;
        FinalityState finalityState;
        uint64 createdAt;
        uint64 updatedAt;
    }

    error ZeroAddress();
    error InvalidPositionId();
    error InvalidAmount();
    error InvalidOutpoint();
    error InvalidScriptCommitment();
    error InvalidProofReference();
    error PledgeNotFinalized(uint256 positionId, FinalityState finalityState);
    error PledgeNotEnforceable(uint256 positionId, EnforcementState enforcementState);
    error NotAuthorized();
    error NotNativeRail(uint256 positionId, uint8 actualRail);
    error PledgeAlreadyRegistered(uint256 positionId);
    error PledgeNotRegistered(uint256 positionId);
    error PledgeIdAlreadyRegistered(bytes32 pledgeId);
    error InvalidTransition(EnforcementState currentState, EnforcementState nextState);

    IPositionRegistryForNativePledge public immutable positionRegistry;
    INativePledgeProofVerifier public nativePledgeProofVerifier;

    mapping(address => bool) public authorizedWriter;
    mapping(uint256 => NativePledge) private _pledgesByPosition;
    mapping(bytes32 => uint256) public positionIdOfPledge;

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event NativePledgeRegistered(
        uint256 indexed positionId,
        bytes32 indexed pledgeId,
        address indexed positionOwner,
        bytes32 btcTxId,
        uint32 vout,
        uint64 amountSats,
        bytes32 scriptCommitment,
        bytes32 proofRef
    );
    event NativePledgeFinalityUpdated(
        uint256 indexed positionId,
        bytes32 indexed pledgeId,
        FinalityState finalityState,
        uint64 btcBlockHeight,
        uint32 confirmations,
        bytes32 proofRef
    );
    event NativePledgeEnforcementUpdated(
        uint256 indexed positionId,
        bytes32 indexed pledgeId,
        EnforcementState previousState,
        EnforcementState nextState,
        bytes32 proofRef
    );

    modifier onlyAuthorized() {
        if (!(authorizedWriter[msg.sender] || msg.sender == owner())) revert NotAuthorized();
        _;
    }

    error InvalidPledgeProof();

    event NativePledgeProofVerifierUpdated(address indexed verifier);

    constructor(address initialOwner, address positionRegistry_) Ownable(_requireNonZeroOwner(initialOwner)) {
        if (positionRegistry_ == address(0)) revert ZeroAddress();
        positionRegistry = IPositionRegistryForNativePledge(positionRegistry_);
    }

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        authorizedWriter[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    function setNativePledgeProofVerifier(address verifier) external onlyOwner {
        nativePledgeProofVerifier = INativePledgeProofVerifier(verifier);
        emit NativePledgeProofVerifierUpdated(verifier);
    }

    function registerPledge(
        uint256 positionId,
        bytes32 btcTxId,
        uint32 vout,
        uint64 amountSats,
        bytes32 scriptCommitment,
        bytes32 proofRef
    ) external onlyAuthorized returns (bytes32 pledgeId) {
        _verifyNativePledgeProof(positionId, btcTxId, vout, amountSats, scriptCommitment, proofRef);

        if (positionId == 0) revert InvalidPositionId();
        if (btcTxId == bytes32(0)) revert InvalidOutpoint();
        if (amountSats == 0) revert InvalidAmount();
        if (scriptCommitment == bytes32(0)) revert InvalidScriptCommitment();
        if (proofRef == bytes32(0)) revert InvalidProofReference();
        if (_pledgesByPosition[positionId].positionId != 0) {
            revert PledgeAlreadyRegistered(positionId);
        }

        uint8 actualRail = positionRegistry.collateralRailOf(positionId);
        if (actualRail != CollateralRail.ENFORCEABLE_NATIVE) {
            revert NotNativeRail(positionId, actualRail);
        }

        address positionOwner = positionRegistry.ownerOfPosition(positionId);

        pledgeId = derivePledgeId(positionId, positionOwner, btcTxId, vout, amountSats, scriptCommitment);

        if (positionIdOfPledge[pledgeId] != 0) revert PledgeIdAlreadyRegistered(pledgeId);

        uint64 nowTs = uint64(block.timestamp);

        _pledgesByPosition[positionId] = NativePledge({
            positionId: positionId,
            positionOwner: positionOwner,
            pledgeId: pledgeId,
            btcTxId: btcTxId,
            vout: vout,
            amountSats: amountSats,
            scriptCommitment: scriptCommitment,
            proofRef: proofRef,
            pledgeProofRef: proofRef,
            finalityProofRef: bytes32(0),
            enforcementProofRef: bytes32(0),
            btcBlockHeight: 0,
            confirmations: 0,
            enforcementState: EnforcementState.Pledged,
            finalityState: FinalityState.Unconfirmed,
            createdAt: nowTs,
            updatedAt: nowTs
        });

        positionIdOfPledge[pledgeId] = positionId;

        emit NativePledgeRegistered(
            positionId, pledgeId, positionOwner, btcTxId, vout, amountSats, scriptCommitment, proofRef
        );
    }

    function recordFinality(
        uint256 positionId,
        FinalityState finalityState,
        uint64 btcBlockHeight,
        uint32 confirmations,
        bytes32 proofRef
    ) external onlyAuthorized {
        if (finalityState == FinalityState.Unset) {
            revert InvalidTransition(EnforcementState.Unset, EnforcementState.Unset);
        }
        if (proofRef == bytes32(0)) revert InvalidProofReference();

        NativePledge storage pledge = _requirePledge(positionId);

        pledge.finalityState = finalityState;
        pledge.finalityProofRef = proofRef;
        pledge.btcBlockHeight = btcBlockHeight;
        pledge.confirmations = confirmations;
        pledge.proofRef = proofRef;
        pledge.updatedAt = uint64(block.timestamp);

        emit NativePledgeFinalityUpdated(
            positionId, pledge.pledgeId, finalityState, btcBlockHeight, confirmations, proofRef
        );
    }

    function updateEnforcementState(uint256 positionId, EnforcementState nextState, bytes32 proofRef)
        external
        onlyAuthorized
    {
        NativePledge storage pledge = _requirePledge(positionId);

        EnforcementState previousState = pledge.enforcementState;
        _validateEnforcementTransition(previousState, nextState);

        if (proofRef != bytes32(0)) {
            pledge.enforcementProofRef = proofRef;
            pledge.proofRef = proofRef;
        }

        pledge.enforcementState = nextState;
        pledge.updatedAt = uint64(block.timestamp);

        emit NativePledgeEnforcementUpdated(positionId, pledge.pledgeId, previousState, nextState, pledge.proofRef);
    }

    function markEnforceable(uint256 positionId, bytes32 proofRef) external onlyAuthorized {
        if (proofRef == bytes32(0)) revert InvalidProofReference();

        NativePledge storage pledge = _requirePledge(positionId);
        if (pledge.finalityState != FinalityState.Finalized) {
            revert PledgeNotFinalized(positionId, pledge.finalityState);
        }

        _updateEnforcementState(positionId, EnforcementState.Enforceable, proofRef);
    }

    function requestEnforcement(uint256 positionId, bytes32 proofRef) external onlyAuthorized {
        if (proofRef == bytes32(0)) revert InvalidProofReference();

        NativePledge storage pledge = _requirePledge(positionId);
        if (pledge.enforcementState != EnforcementState.Enforceable) {
            revert PledgeNotEnforceable(positionId, pledge.enforcementState);
        }

        _updateEnforcementState(positionId, EnforcementState.EnforcementRequested, proofRef);
    }

    function isFinalized(uint256 positionId) external view returns (bool) {
        return _requirePledge(positionId).finalityState == FinalityState.Finalized;
    }

    function isCreditReady(uint256 positionId) external view returns (bool) {
        NativePledge storage pledge = _requirePledge(positionId);
        return
            pledge.finalityState == FinalityState.Finalized && pledge.enforcementState == EnforcementState.Enforceable;
    }

    function isEnforcementActive(uint256 positionId) external view returns (bool) {
        EnforcementState state = _requirePledge(positionId).enforcementState;

        return state == EnforcementState.EnforcementRequested || state == EnforcementState.EnforcementInProgress
            || state == EnforcementState.RecoveryObserved;
    }

    function finalityOf(uint256 positionId)
        external
        view
        returns (FinalityState finalityState, uint64 btcBlockHeight, uint32 confirmations, bytes32 finalityProofRef)
    {
        NativePledge storage pledge = _requirePledge(positionId);

        return (pledge.finalityState, pledge.btcBlockHeight, pledge.confirmations, pledge.finalityProofRef);
    }

    function enforcementStateOf(uint256 positionId) external view returns (EnforcementState) {
        return _requirePledge(positionId).enforcementState;
    }

    function proofRefsOf(uint256 positionId)
        external
        view
        returns (bytes32 pledgeProofRef, bytes32 finalityProofRef, bytes32 enforcementProofRef, bytes32 latestProofRef)
    {
        NativePledge storage pledge = _requirePledge(positionId);

        return (pledge.pledgeProofRef, pledge.finalityProofRef, pledge.enforcementProofRef, pledge.proofRef);
    }

    function getPledge(uint256 positionId) external view returns (NativePledge memory) {
        return _requirePledge(positionId);
    }

    function hasPledge(uint256 positionId) external view returns (bool) {
        return _pledgesByPosition[positionId].positionId != 0;
    }

    function pledgeIdOfPosition(uint256 positionId) external view returns (bytes32) {
        return _requirePledge(positionId).pledgeId;
    }

    function derivePledgeId(
        uint256 positionId,
        address positionOwner,
        bytes32 btcTxId,
        uint32 vout,
        uint64 amountSats,
        bytes32 scriptCommitment
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "LUNA_NATIVE_BTC_PLEDGE_V1", positionId, positionOwner, btcTxId, vout, amountSats, scriptCommitment
            )
        );
    }

    function _requireNonZeroOwner(address initialOwner) internal pure returns (address) {
        if (initialOwner == address(0)) revert ZeroAddress();
        return initialOwner;
    }

    function _requirePledge(uint256 positionId) internal view returns (NativePledge storage pledge) {
        pledge = _pledgesByPosition[positionId];
        if (pledge.positionId == 0) revert PledgeNotRegistered(positionId);
    }

    function _updateEnforcementState(uint256 positionId, EnforcementState nextState, bytes32 proofRef) internal {
        NativePledge storage pledge = _requirePledge(positionId);

        EnforcementState previousState = pledge.enforcementState;
        _validateEnforcementTransition(previousState, nextState);

        if (proofRef != bytes32(0)) {
            pledge.enforcementProofRef = proofRef;
            pledge.proofRef = proofRef;
        }

        pledge.enforcementState = nextState;
        pledge.updatedAt = uint64(block.timestamp);

        emit NativePledgeEnforcementUpdated(positionId, pledge.pledgeId, previousState, nextState, pledge.proofRef);
    }

    function _verifyNativePledgeProof(
        uint256 positionId,
        bytes32 btcTxId,
        uint32 vout,
        uint64 amountSats,
        bytes32 scriptCommitment,
        bytes32 proofRef
    ) internal view {
        INativePledgeProofVerifier verifier = nativePledgeProofVerifier;
        if (address(verifier) == address(0)) {
            return;
        }

        bool validProof =
            verifier.verifyPledge(positionId, address(0), btcTxId, vout, amountSats, scriptCommitment, proofRef);

        if (!validProof) revert InvalidPledgeProof();
    }

    function _validateEnforcementTransition(EnforcementState currentState, EnforcementState nextState) internal pure {
        if (nextState == EnforcementState.Unset) {
            revert InvalidTransition(currentState, nextState);
        }

        if (currentState == nextState) {
            return;
        }

        if (currentState == EnforcementState.Pledged) {
            if (
                nextState == EnforcementState.Enforceable || nextState == EnforcementState.EnforcementRequested
                    || nextState == EnforcementState.Released || nextState == EnforcementState.Failed
            ) {
                return;
            }
        }

        if (currentState == EnforcementState.Enforceable) {
            if (
                nextState == EnforcementState.EnforcementRequested || nextState == EnforcementState.Released
                    || nextState == EnforcementState.Failed
            ) {
                return;
            }
        }

        if (currentState == EnforcementState.EnforcementRequested) {
            if (nextState == EnforcementState.EnforcementInProgress || nextState == EnforcementState.Failed) {
                return;
            }
        }

        if (currentState == EnforcementState.EnforcementInProgress) {
            if (
                nextState == EnforcementState.RecoveryObserved || nextState == EnforcementState.Settled
                    || nextState == EnforcementState.Failed
            ) {
                return;
            }
        }

        if (currentState == EnforcementState.RecoveryObserved) {
            if (nextState == EnforcementState.Settled || nextState == EnforcementState.Failed) {
                return;
            }
        }

        revert InvalidTransition(currentState, nextState);
    }
}
