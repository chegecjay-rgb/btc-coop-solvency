// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Registry for BTC-side proof-pack metadata.
/// @dev This stores proof references and digests. It does not validate Bitcoin
///      data directly. Phase C services can submit proof packs here, while
///      verifier contracts decide whether a proof pack is acceptable.
contract NativeProofPackRegistry is Ownable {
    enum ProofPackKind {
        Unset,
        Pledge,
        Finality,
        Enforceability,
        EnforcementRequest,
        EnforcementExecution,
        RecoveryObservation,
        Settlement
    }

    struct ProofPack {
        bytes32 proofRef;
        uint256 positionId;
        bytes32 pledgeId;
        ProofPackKind kind;
        bytes32 digest;
        string uri;
        address submitter;
        uint64 submittedAt;
    }

    error ZeroAddress();
    error NotAuthorized();
    error InvalidPositionId();
    error InvalidProofPackKind();
    error InvalidDigest();
    error ProofPackAlreadySubmitted(bytes32 proofRef);
    error ProofPackNotFound(bytes32 proofRef);

    mapping(address => bool) public authorizedSubmitter;
    mapping(bytes32 => ProofPack) private _proofPacks;
    mapping(uint256 => bytes32[]) private _proofRefsByPosition;

    event AuthorizedSubmitterSet(address indexed submitter, bool allowed);
    event ProofPackSubmitted(
        bytes32 indexed proofRef,
        uint256 indexed positionId,
        bytes32 indexed pledgeId,
        ProofPackKind kind,
        bytes32 digest,
        string uri,
        address submitter
    );

    modifier onlyAuthorized() {
        if (!(msg.sender == owner() || authorizedSubmitter[msg.sender])) revert NotAuthorized();
        _;
    }

    constructor(address initialOwner) Ownable(_requireNonZeroOwner(initialOwner)) {}

    function setAuthorizedSubmitter(address submitter, bool allowed) external onlyOwner {
        if (submitter == address(0)) revert ZeroAddress();

        authorizedSubmitter[submitter] = allowed;

        emit AuthorizedSubmitterSet(submitter, allowed);
    }

    function submitProofPack(
        uint256 positionId,
        bytes32 pledgeId,
        ProofPackKind kind,
        bytes32 digest,
        string calldata uri
    ) external onlyAuthorized returns (bytes32 proofRef) {
        if (positionId == 0) revert InvalidPositionId();
        if (kind == ProofPackKind.Unset) revert InvalidProofPackKind();
        if (digest == bytes32(0)) revert InvalidDigest();

        proofRef = deriveProofRef(positionId, pledgeId, kind, digest, uri);

        if (_proofPacks[proofRef].submittedAt != 0) {
            revert ProofPackAlreadySubmitted(proofRef);
        }

        _proofPacks[proofRef] = ProofPack({
            proofRef: proofRef,
            positionId: positionId,
            pledgeId: pledgeId,
            kind: kind,
            digest: digest,
            uri: uri,
            submitter: msg.sender,
            submittedAt: uint64(block.timestamp)
        });

        _proofRefsByPosition[positionId].push(proofRef);

        emit ProofPackSubmitted(proofRef, positionId, pledgeId, kind, digest, uri, msg.sender);
    }

    function getProofPack(bytes32 proofRef) external view returns (ProofPack memory) {
        ProofPack memory proofPack = _proofPacks[proofRef];
        if (proofPack.submittedAt == 0) revert ProofPackNotFound(proofRef);

        return proofPack;
    }

    function hasProofPack(bytes32 proofRef) external view returns (bool) {
        return _proofPacks[proofRef].submittedAt != 0;
    }

    function proofRefsOfPosition(uint256 positionId) external view returns (bytes32[] memory) {
        return _proofRefsByPosition[positionId];
    }

    function deriveProofRef(
        uint256 positionId,
        bytes32 pledgeId,
        ProofPackKind kind,
        bytes32 digest,
        string calldata uri
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("LUNA_NATIVE_BTC_PROOF_PACK_V1", positionId, pledgeId, kind, digest, keccak256(bytes(uri)))
        );
    }

    function _requireNonZeroOwner(address initialOwner) internal pure returns (address) {
        if (initialOwner == address(0)) revert ZeroAddress();

        return initialOwner;
    }
}
