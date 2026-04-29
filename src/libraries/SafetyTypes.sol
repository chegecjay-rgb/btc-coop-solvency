// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library SafetyTypes {
    enum PowerKind {
        UPGRADE,
        PAUSE_DEPOSITS,
        PAUSE_WITHDRAWALS,
        MINT,
        BURN,
        BLACKLIST,
        SWEEP_FUNDS,
        MOVE_RESERVES,
        CHANGE_FEES,
        CHANGE_ORACLE,
        CHANGE_RISK_PARAMS,
        ARBITRARY_CALL,
        GRANT_ROLE,
        REVOKE_ROLE,
        INSTALL_MODULE,
        DELEGATECALL_EXTENSION,
        BYPASS_DELAY
    }

    enum ControllerType {
        NONE,
        EOA,
        MULTISIG,
        TIMELOCK,
        ACCESS_MANAGER,
        DAO,
        MODULE,
        GUARDIAN,
        BRIDGE,
        CUSTOM
    }

    enum ProofLevel {
        SELF_DECLARED,
        ONCHAIN_DERIVED,
        EXACT_VERIFIED,
        FORMALLY_PROVEN
    }

    enum Scope {
        GLOBAL,
        CONTRACT,
        FUNCTION_SELECTOR,
        PARAMETER_RANGE,
        ASSET,
        USER_SET,
        MODULE_SET,
        BRIDGE_ROUTE,
        CUSTODY_POOL,
        OTHER
    }

    enum ImpactLevel {
        NONE,
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL,
        UNBOUNDED
    }

    enum NodeType {
        CONTRACT,
        PROXY,
        IMPLEMENTATION,
        PROXY_ADMIN,
        TIMELOCK,
        MULTISIG,
        MODULE,
        GUARD,
        FALLBACK_HANDLER,
        BRIDGE_ADAPTER,
        CUSTODIAN,
        ORACLE_MANAGER,
        GOVERNANCE_EXECUTOR,
        ACCESS_MANAGER,
        ROLE_ADMIN,
        BEACON,
        EMERGENCY_CONTROLLER,
        TREASURY,
        OTHER
    }

    enum EdgeKind {
        CONTROLS,
        CAN_UPGRADE,
        CAN_PAUSE,
        CAN_MINT,
        CAN_BURN,
        CAN_BLACKLIST,
        CAN_SWEEP_FUNDS,
        CAN_MOVE_RESERVES,
        CAN_CHANGE_FEES,
        CAN_CHANGE_ORACLE,
        CAN_CHANGE_RISK_PARAMS,
        CAN_ARBITRARY_CALL,
        CAN_GRANT_ROLE,
        CAN_REVOKE_ROLE,
        CAN_INSTALL_MODULE,
        CAN_DELEGATECALL,
        CAN_BYPASS_DELAY
    }

    enum FailureKind {
        MANIFEST_CLOSURE_VIOLATION,
        UNKNOWN_PRIVILEGED_PATH,
        SINGLE_EOA_CRITICAL_CONTROL,
        ZERO_DELAY_CUSTODY_UPGRADE,
        UNDISCLOSED_DELEGATECALL_EXTENSION,
        OMITTED_RESERVE_CUSTODIAN,
        OMITTED_BRIDGE_ADAPTER,
        HIDDEN_MODULE_WITH_EXECUTION_RIGHTS,
        OMITTED_FALLBACK_HANDLER,
        OMITTED_GUARD,
        UNDISCLOSED_ADMIN_CONTROLLER,
        MISSING_EXACT_VERIFICATION_CRITICAL_COMPONENT
    }

    struct ProtocolMetadata {
        string protocolName;
        uint64 standardVersion;
        uint256 chainId;
        bytes32 manifestHash;
        string manifestURI;
        string metadataURI;
        bool manifestClosedClaimed;
    }

    struct Component {
        address component;
        NodeType nodeType;
        bool inManifest;
        bool critical;
        bool custodyCritical;
        bool exactVerified;
        bool upgradeable;
        address implementation;
        address adminController;
        ProofLevel proofLevel;
        bytes32 metadataHash;
    }

    struct GraphNode {
        address node;
        NodeType nodeType;
        bool inManifest;
        bool critical;
        bool authority;
        ProofLevel proofLevel;
        bytes32 metadataHash;
    }

    struct PowerDescriptor {
        bytes32 powerId;
        PowerKind powerKind;
        bool enabled;
        address target;
        ControllerType controllerType;
        address controller;
        uint16 threshold;
        uint16 controllerCount;
        uint32 executionDelaySeconds;
        bool emergencyBypass;
        Scope scope;
        ImpactLevel impactLevel;
        uint256 maxImpactValue;
        bool canTouchUserFunds;
        uint128 rateLimit;
        uint32 rateLimitWindowSeconds;
        bool revocable;
        ProofLevel proofLevel;
        bytes32 scopeHash;
        bytes32 notesHash;
    }

    struct GraphEdge {
        bytes32 edgeId;
        EdgeKind edgeKind;
        PowerKind powerKind;
        address from;
        address to;
        bool direct;
        bool transitive;
        bool canBypassDelay;
        bool touchesUserFunds;
        ProofLevel proofLevel;
        bytes32 notesHash;
    }

    struct DisclosureSummary {
        bool interfaceSupported;
        bool manifestClaimedClosed;
        bool manifestClosed;
        bool allNodesInManifest;
        bool allPowersHaveKnownControllers;
        bool allEdgesKnown;
        bool exactVerifiedCriticalComponents;
        uint256 componentCount;
        uint256 nodeCount;
        uint256 edgeCount;
        uint256 powerCount;
        uint256 unknownPrivilegeCount;
    }

    struct ConstraintSummary {
        bool noSingleKeyCriticalControl;
        bool noZeroDelayCustodyUpgrade;
        bool noUndisclosedDelegatecall;
        bool noUndisclosedCustodian;
        bool noUndisclosedBridgeAdapter;
        bool criticalPowersDelayed;
        bool userFundsIsolated;
        uint256 criticalPowerCount;
        uint256 delayedCriticalPowerCount;
    }

    struct ComplianceFinding {
        FailureKind kind;
        bool active;
        address subject;
        address related;
        bytes32 referenceId;
        ProofLevel proofLevel;
        bytes32 detailsHash;
    }

    struct ProofLevelDistribution {
        uint256 selfDeclared;
        uint256 onchainDerived;
        uint256 exactVerified;
        uint256 formallyProven;
    }
}
