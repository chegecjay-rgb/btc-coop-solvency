// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {NativePledgeBuilder} from "src/native/NativePledgeBuilder.sol";
import {NativePledgeRegistry} from "src/native/NativePledgeRegistry.sol";
import {NativeEnforcementCoordinator} from "src/native/NativeEnforcementCoordinator.sol";
import {NativeProofPackRegistry} from "src/native/NativeProofPackRegistry.sol";
import {NativeSettlementAdapter} from "src/native/NativeSettlementAdapter.sol";

contract MockLifecyclePositionRegistry {
    mapping(uint256 => address) internal owners;
    mapping(uint256 => uint8) internal rails;

    function seedPosition(uint256 positionId, address owner, uint8 rail) external {
        owners[positionId] = owner;
        rails[positionId] = rail;
    }

    function ownerOfPosition(uint256 positionId) external view returns (address) {
        return owners[positionId];
    }

    function collateralRailOf(uint256 positionId) external view returns (uint8) {
        return rails[positionId];
    }

    function getPositionRail(uint256 positionId) external view returns (uint8) {
        return rails[positionId];
    }
}

contract MockLifecycleDebtLedger {
    mapping(uint256 => uint256) internal settlementCosts;

    function recordSettlementCost(uint256 positionId, uint256 amount) external {
        settlementCosts[positionId] += amount;
    }

    function settlementCostOf(uint256 positionId) external view returns (uint256) {
        return settlementCosts[positionId];
    }
}

contract MockLifecycleRecapitalizationEngine {
    mapping(uint256 => uint256) internal recoveries;

    function recordRecovery(uint256 positionId, uint256 amount) external {
        recoveries[positionId] += amount;
    }

    function recoveryOf(uint256 positionId) external view returns (uint256) {
        return recoveries[positionId];
    }
}

contract GenericLifecycleSettlementVerifier {
    bool public accepted = true;

    function setAccepted(bool nextAccepted) external {
        accepted = nextAccepted;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(accepted);
    }
}

contract NativeEnforcementLifecycleIntegrationTest is Test {
    uint256 internal constant POSITION_ID = 9001;
    uint256 internal constant BYPASS_POSITION_ID = 9002;
    uint256 internal constant WRONG_RAIL_POSITION_ID = 9003;

    uint256 internal constant AMOUNT_SATS = 100e8;
    uint256 internal constant RECOVERED_SATS = 92e8;
    uint256 internal constant SETTLEMENT_COST = 2e8;
    uint32 internal constant VOUT = 0;

    uint8 internal constant RAIL_ONE = 0;

    bytes32 internal constant SCRIPT_COMMITMENT = keccak256("native-btc-script-commitment");

    address internal borrower = address(0xB0B);

    MockLifecyclePositionRegistry internal positions;
    MockLifecycleDebtLedger internal debt;
    MockLifecycleRecapitalizationEngine internal recap;
    GenericLifecycleSettlementVerifier internal verifier;

    NativePledgeBuilder internal builder;
    NativePledgeRegistry internal pledges;
    NativeEnforcementCoordinator internal coordinator;
    NativeProofPackRegistry internal proofPacks;
    NativeSettlementAdapter internal adapter;

    uint8 internal nativeRail;

    function setUp() external {
        positions = new MockLifecyclePositionRegistry();
        debt = new MockLifecycleDebtLedger();
        recap = new MockLifecycleRecapitalizationEngine();
        verifier = new GenericLifecycleSettlementVerifier();

        builder = new NativePledgeBuilder();
        pledges = new NativePledgeRegistry(address(this), address(positions));
        coordinator = new NativeEnforcementCoordinator(address(this), address(pledges));
        proofPacks = new NativeProofPackRegistry(address(this));

        adapter = new NativeSettlementAdapter(
            address(this),
            address(positions),
            address(debt),
            address(recap),
            address(proofPacks),
            address(coordinator),
            address(verifier)
        );

        nativeRail = adapter.RAIL_NATIVE_BTC();

        pledges.setAuthorizedWriter(address(this), true);
        pledges.setAuthorizedWriter(address(coordinator), true);

        coordinator.setAuthorizedActor(address(this), true);

        proofPacks.setAuthorizedSubmitter(address(this), true);

        adapter.setAuthorizedFinalizer(address(this), true);
    }

    function test_phaseE1_fullNativeEnforcementLifecycleFinalizesLunaAccounting() external {
        positions.seedPosition(POSITION_ID, borrower, nativeRail);

        NativePledgeBuilder.PledgeIntent memory firstIntent = builder.buildPledgeIntent(_pledgeTerms(POSITION_ID));
        NativePledgeBuilder.PledgeIntent memory secondIntent = builder.buildPledgeIntent(_pledgeTerms(POSITION_ID));

        assertEq(
            keccak256(abi.encode(firstIntent)),
            keccak256(abi.encode(secondIntent)),
            "pledge commitment must be deterministic"
        );

        bytes32 pledgeId = _registerPledgeAndMakeCreditReady(POSITION_ID);

        coordinator.startEnforcement(POSITION_ID, _proof("enforcement-request", POSITION_ID));
        coordinator.markEnforcementInProgress(POSITION_ID, _proof("enforcement-progress", POSITION_ID));

        bytes32 digest = _proof("settlement-proof-pack-digest", POSITION_ID);
        string memory uri = "ipfs://phase-e1-native-settlement-proof-pack";

        bytes32 proofPackRef = proofPacks.submitProofPack(
            POSITION_ID, pledgeId, NativeProofPackRegistry.ProofPackKind.Settlement, digest, uri
        );

        assertTrue(proofPackRef != bytes32(0), "proof-pack ref should be non-zero");

        coordinator.recordRecoveryObserved(POSITION_ID, proofPackRef);

        assertTrue(
            coordinator.hasObservedRecovery(POSITION_ID, proofPackRef),
            "coordinator should expose observed recovery to adapter"
        );

        vm.expectRevert();
        proofPacks.submitProofPack(POSITION_ID, pledgeId, NativeProofPackRegistry.ProofPackKind.Settlement, digest, uri);

        adapter.finalizeNativeLiquidation(POSITION_ID, proofPackRef, RECOVERED_SATS, SETTLEMENT_COST);

        assertEq(recap.recoveryOf(POSITION_ID), RECOVERED_SATS, "native recovery should reach Luna accounting");
        assertEq(debt.settlementCostOf(POSITION_ID), SETTLEMENT_COST, "settlement cost should reach Luna accounting");

        vm.expectRevert();
        adapter.finalizeNativeLiquidation(POSITION_ID, proofPackRef, RECOVERED_SATS, SETTLEMENT_COST);
    }

    function test_phaseE1_cannotBypassObservedRecoveryRule() external {
        positions.seedPosition(BYPASS_POSITION_ID, borrower, nativeRail);

        bytes32 pledgeId = _registerPledgeAndMakeCreditReady(BYPASS_POSITION_ID);

        coordinator.startEnforcement(BYPASS_POSITION_ID, _proof("bypass-request", BYPASS_POSITION_ID));
        coordinator.markEnforcementInProgress(BYPASS_POSITION_ID, _proof("bypass-progress", BYPASS_POSITION_ID));

        bytes32 digest = _proof("bypass-settlement-digest", BYPASS_POSITION_ID);
        string memory uri = "ipfs://phase-e1-bypass-proof-pack";

        bytes32 proofPackRef = proofPacks.submitProofPack(
            BYPASS_POSITION_ID, pledgeId, NativeProofPackRegistry.ProofPackKind.Settlement, digest, uri
        );

        assertFalse(
            coordinator.hasObservedRecovery(BYPASS_POSITION_ID, proofPackRef),
            "test setup should not mark recovery observed"
        );

        vm.expectRevert();
        adapter.finalizeNativeLiquidation(BYPASS_POSITION_ID, proofPackRef, RECOVERED_SATS, SETTLEMENT_COST);
    }

    function test_phaseE1_wrongRailCannotUseNativeSettlementAdapter() external {
        positions.seedPosition(WRONG_RAIL_POSITION_ID, borrower, RAIL_ONE);

        bytes32 fakeProofPackRef = _proof("wrong-rail-proof-pack", WRONG_RAIL_POSITION_ID);

        vm.expectRevert();
        adapter.finalizeNativeLiquidation(WRONG_RAIL_POSITION_ID, fakeProofPackRef, RECOVERED_SATS, SETTLEMENT_COST);
    }

    function _registerPledgeAndMakeCreditReady(uint256 positionId) internal returns (bytes32 pledgeId) {
        pledges.registerPledge(
            positionId,
            _btcTxId(positionId),
            VOUT,
            uint64(AMOUNT_SATS),
            SCRIPT_COMMITMENT,
            _proof("pledge-registration", positionId)
        );

        pledgeId = pledges.pledgeIdOfPosition(positionId);

        pledges.recordFinality(
            positionId,
            NativePledgeRegistry.FinalityState.Finalized,
            uint64(840_000 + positionId),
            uint16(6),
            _proof("bitcoin-finality", positionId)
        );

        pledges.markEnforceable(positionId, _proof("credit-ready", positionId));

        assertTrue(pledges.isCreditReady(positionId), "pledge should be credit-ready");
    }

    function _pledgeTerms(uint256 positionId) internal view returns (NativePledgeBuilder.PledgeTerms memory) {
        return NativePledgeBuilder.PledgeTerms({
            positionId: positionId,
            borrower: borrower,
            amountSats: uint64(AMOUNT_SATS),
            borrowerKeyCommitment: keccak256(abi.encodePacked("borrowerKeyCommitment", positionId)),
            protocolKeyCommitment: keccak256(abi.encodePacked("protocolKeyCommitment", positionId)),
            recoveryKeyCommitment: keccak256(abi.encodePacked("recoveryKeyCommitment", positionId)),
            minConfirmations: uint32(6),
            enforcementDelayBlocks: uint32(144),
            expiryTimestamp: uint64(block.timestamp + 30 days),
            metadataHash: keccak256(abi.encodePacked("metadataHash", positionId)),
            scriptKind: NativePledgeBuilder.PledgeScriptKind(1)
        });
    }

    function _btcTxId(uint256 positionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("btc-tx", positionId));
    }

    function _proof(string memory label, uint256 positionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(label, positionId));
    }
}
