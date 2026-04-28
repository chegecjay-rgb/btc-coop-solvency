// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafetyTypes} from "src/libraries/SafetyTypes.sol";

interface IProtocolSafety is IERC165 {
    function protocolMetadata() external view returns (SafetyTypes.ProtocolMetadata memory);

    function componentCount() external view returns (uint256);

    function componentAt(uint256 index) external view returns (SafetyTypes.Component memory);

    function componentInfo(address component) external view returns (SafetyTypes.Component memory);

    function isRegisteredComponent(address component) external view returns (bool);

    function nodeCount() external view returns (uint256);

    function nodeAt(uint256 index) external view returns (SafetyTypes.GraphNode memory);

    function nodeInfo(address node) external view returns (SafetyTypes.GraphNode memory);

    function isRegisteredNode(address node) external view returns (bool);

    function powerCount() external view returns (uint256);

    function powerAt(uint256 index) external view returns (SafetyTypes.PowerDescriptor memory);

    function powerInfo(bytes32 powerId) external view returns (SafetyTypes.PowerDescriptor memory);

    function powerCountForTarget(address target) external view returns (uint256);

    function powerIdForTargetAt(address target, uint256 index) external view returns (bytes32);

    function edgeCount() external view returns (uint256);

    function edgeAt(uint256 index) external view returns (SafetyTypes.GraphEdge memory);

    function edgeInfo(bytes32 edgeId) external view returns (SafetyTypes.GraphEdge memory);

    function disclosureSummary() external view returns (SafetyTypes.DisclosureSummary memory);

    function constraintSummary() external view returns (SafetyTypes.ConstraintSummary memory);

    function proofLevelDistribution() external view returns (SafetyTypes.ProofLevelDistribution memory);

    function findingCount() external view returns (uint256);

    function findingAt(uint256 index) external view returns (SafetyTypes.ComplianceFinding memory);

    function findingCountByKind(SafetyTypes.FailureKind kind) external view returns (uint256);

    function hasFinding(SafetyTypes.FailureKind kind) external view returns (bool);

    function hasTransitiveControlPath(address from, address to) external view returns (bool);

    function hasTransitivePowerPath(address from, address target, SafetyTypes.PowerKind powerKind)
        external
        view
        returns (bool);
}
