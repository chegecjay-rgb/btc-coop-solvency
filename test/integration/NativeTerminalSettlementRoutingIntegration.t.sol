// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {
    LiquidationEngine,
    IPositionRegistryForLiquidation,
    ICollateralManagerForLiquidation,
    IDebtLedgerForLiquidation,
    IRiskEngineForLiquidation,
    IRecapitalizationEngineForLiquidation
} from "src/core/LiquidationEngine.sol";

contract MockTerminalPositionRegistry {
    address internal constant BORROWER = address(0xB0B);

    mapping(uint256 => IPositionRegistryForLiquidation.Position) internal positions;
    mapping(uint256 => uint8) internal rails;

    function seed(uint256 positionId, uint8 rail, uint256 collateralAmount, uint256 debtPrincipal, uint8 state_)
        external
    {
        rails[positionId] = rail;

        positions[positionId] = IPositionRegistryForLiquidation.Position({
            owner: BORROWER,
            assetId: bytes32("WBTC"),
            collateralAmount: collateralAmount,
            debtPrincipal: debtPrincipal,
            state: state_,
            rescueCount: 0,
            lastRescueTime: 0,
            hasBuybackCover: false,
            activeRemoteIntentId: bytes32(0),
            collateralRail: rail
        });
    }

    function collateralRailOf(uint256 positionId) external view returns (uint8) {
        return rails[positionId];
    }

    function getPosition(uint256 positionId) external view returns (IPositionRegistryForLiquidation.Position memory) {
        return positions[positionId];
    }

    function updateState(uint256 positionId, uint8 newState) external {
        positions[positionId].state = newState;
    }

    function updateAmounts(uint256 positionId, uint256 collateralAmount, uint256 debtPrincipal) external {
        positions[positionId].collateralAmount = collateralAmount;
        positions[positionId].debtPrincipal = debtPrincipal;
    }
}

contract MockTerminalCollateralManager {
    mapping(uint256 => ICollateralManagerForLiquidation.CollateralRecord) internal records;

    uint256 public transferCalls;

    function seed(uint256 positionId, uint256 amount) external {
        records[positionId] = ICollateralManagerForLiquidation.CollateralRecord({
            totalCollateral: amount,
            lockedCollateral: amount,
            transferredToStabilization: 0,
            transferredToInsurance: 0,
            releaseFrozen: false,
            initialized: true
        });
    }

    function getCollateralRecord(uint256 positionId)
        external
        view
        returns (ICollateralManagerForLiquidation.CollateralRecord memory)
    {
        return records[positionId];
    }

    function transferToStabilization(uint256 positionId, uint256 amount) external {
        ICollateralManagerForLiquidation.CollateralRecord storage record = records[positionId];

        if (amount > record.lockedCollateral) {
            amount = record.lockedCollateral;
        }

        record.lockedCollateral -= amount;
        record.transferredToStabilization += amount;
        transferCalls += 1;
    }
}

contract MockTerminalDebtLedger {
    mapping(uint256 => IDebtLedgerForLiquidation.DebtRecord) internal records;

    mapping(uint256 => bool) public closed;
    mapping(uint256 => uint256) public settlementCostByPosition;

    function seed(uint256 positionId, uint256 principal) external {
        records[positionId] = IDebtLedgerForLiquidation.DebtRecord({
            principal: principal,
            accruedInterest: 0,
            rescueCapitalUsed: 0,
            rescueFeesAccrued: 0,
            insuranceCapitalUsed: 0,
            insuranceChargesAccrued: 0,
            settlementCosts: 0,
            lastAccrualTime: block.timestamp
        });
    }

    function getDebtRecord(uint256 positionId) external view returns (IDebtLedgerForLiquidation.DebtRecord memory) {
        return records[positionId];
    }

    function recordSettlementCost(uint256 positionId, uint256 amount) external {
        records[positionId].settlementCosts += amount;
        settlementCostByPosition[positionId] += amount;
    }

    function closeDebt(uint256 positionId) external {
        closed[positionId] = true;
        delete records[positionId];
    }
}

contract MockTerminalRiskEngine {
    function positionRiskSnapshot(uint256)
        external
        pure
        returns (IRiskEngineForLiquidation.PositionRiskSnapshot memory)
    {
        return IRiskEngineForLiquidation.PositionRiskSnapshot({
            healthFactor: 0.8e18,
            adjustedCollateral: 80 ether,
            totalDebt: 100 ether,
            currentLTVBps: 12_500,
            classification: 3
        });
    }
}

contract MockTerminalRecapitalizationEngine {
    mapping(uint256 => uint256) public recoveryByPosition;

    function recordRecovery(uint256 positionId, uint256 amount) external {
        recoveryByPosition[positionId] += amount;
    }
}

contract MockTerminalNativeSettlementAdapter {
    error MissingProofPackRef();
    error ObservedNativeRecoveryMissing();

    uint256 public calls;
    bytes4 public lastSelector;
    uint256 public lastPositionId;
    bytes32 public lastProofPackRef;
    bool public rejectObservedRecovery;

    function setRejectObservedRecovery(bool reject_) external {
        rejectObservedRecovery = reject_;
    }

    function reset() external {
        calls = 0;
        lastSelector = bytes4(0);
        lastPositionId = 0;
        lastProofPackRef = bytes32(0);
        rejectObservedRecovery = false;
    }

    fallback() external {
        uint256 positionId;
        bytes32 proofPackRef;

        assembly {
            positionId := calldataload(4)
            proofPackRef := calldataload(36)
        }

        calls += 1;
        lastSelector = msg.sig;
        lastPositionId = positionId;
        lastProofPackRef = proofPackRef;

        if (proofPackRef == bytes32(0)) {
            revert MissingProofPackRef();
        }

        if (rejectObservedRecovery) {
            revert ObservedNativeRecoveryMissing();
        }
    }
}

contract NativeTerminalSettlementRoutingIntegrationTest is Test {
    uint8 internal constant RAIL_PROTOCOL_ESCROWED_WRAPPED_BTC = 0;
    uint8 internal constant RAIL_ENFORCEABLE_NATIVE_BTC = 1;

    uint8 internal constant STATE_ACTIVE = 1;
    uint8 internal constant STATE_CLOSED = 8;

    bytes32 internal constant LIQUIDATION_PROOF = keccak256("native-liquidation-proof");
    bytes32 internal constant TERMINAL_PROOF = keccak256("native-terminal-proof");

    MockTerminalPositionRegistry internal positionRegistry;
    MockTerminalCollateralManager internal collateralManager;
    MockTerminalDebtLedger internal debtLedger;
    MockTerminalRiskEngine internal riskEngine;
    MockTerminalRecapitalizationEngine internal recapitalizationEngine;
    MockTerminalNativeSettlementAdapter internal nativeAdapter;

    LiquidationEngine internal liquidation;

    function setUp() public {
        positionRegistry = new MockTerminalPositionRegistry();
        collateralManager = new MockTerminalCollateralManager();
        debtLedger = new MockTerminalDebtLedger();
        riskEngine = new MockTerminalRiskEngine();
        recapitalizationEngine = new MockTerminalRecapitalizationEngine();
        nativeAdapter = new MockTerminalNativeSettlementAdapter();

        liquidation = new LiquidationEngine(
            address(this),
            address(positionRegistry),
            address(collateralManager),
            address(debtLedger),
            address(riskEngine),
            address(recapitalizationEngine),
            500,
            1 days
        );
    }

    function test_rail1TerminalSettlementRemainsOnEscrowPathEvenWhenNativeAdapterConfigured() public {
        uint256 positionId = 1;

        liquidation.setNativeSettlementAdapter(address(nativeAdapter));

        positionRegistry.seed(positionId, RAIL_PROTOCOL_ESCROWED_WRAPPED_BTC, 80 ether, 100 ether, STATE_ACTIVE);
        collateralManager.seed(positionId, 80 ether);
        debtLedger.seed(positionId, 100 ether);

        liquidation.executeLiquidation(positionId);
        liquidation.settlePostLiquidation(positionId);

        assertEq(nativeAdapter.calls(), 0, "Rail 1 terminal settlement must not call native adapter");
        assertTrue(debtLedger.closed(positionId), "Rail 1 terminal path should close debt");
        assertEq(
            positionRegistry.getPosition(positionId).state, STATE_CLOSED, "Rail 1 terminal path should close position"
        );
        assertEq(collateralManager.transferCalls(), 1, "Rail 1 should still use escrow collateral movement");
    }

    function test_rail2TerminalSettlementWithConfiguredAdapterRoutesToNativeAdapter() public {
        uint256 positionId = 2;

        liquidation.setNativeSettlementAdapter(address(nativeAdapter));

        positionRegistry.seed(positionId, RAIL_ENFORCEABLE_NATIVE_BTC, 80 ether, 100 ether, STATE_ACTIVE);
        collateralManager.seed(positionId, 80 ether);
        debtLedger.seed(positionId, 100 ether);

        bool ok = _callNativeTerminalSettlement(positionId, TERMINAL_PROOF);

        assertTrue(ok, "Rail 2 terminal settlement should route through configured native adapter");
        assertEq(nativeAdapter.calls(), 1, "Native adapter should be called once");
        assertEq(nativeAdapter.lastPositionId(), positionId, "Adapter should receive position id");
        assertEq(nativeAdapter.lastProofPackRef(), TERMINAL_PROOF, "Adapter should receive proof-pack ref");
        assertEq(collateralManager.transferCalls(), 0, "Rail 2 terminal route must not move escrow collateral");
    }

    function test_rail2TerminalSettlementWithoutAdapterRevertsCleanly() public {
        uint256 positionId = 3;

        positionRegistry.seed(positionId, RAIL_ENFORCEABLE_NATIVE_BTC, 80 ether, 100 ether, STATE_ACTIVE);
        collateralManager.seed(positionId, 80 ether);
        debtLedger.seed(positionId, 100 ether);

        bool ok = _callNativeTerminalSettlement(positionId, TERMINAL_PROOF);

        assertFalse(ok, "Rail 2 terminal settlement without adapter must revert");
    }

    function test_rail2TerminalSettlementCannotBypassProofPackOrObservedRecoveryRules() public {
        uint256 positionId = 4;

        liquidation.setNativeSettlementAdapter(address(nativeAdapter));

        positionRegistry.seed(positionId, RAIL_ENFORCEABLE_NATIVE_BTC, 80 ether, 100 ether, STATE_ACTIVE);
        collateralManager.seed(positionId, 80 ether);
        debtLedger.seed(positionId, 100 ether);

        bool missingProofOk = _callNativeTerminalSettlement(positionId, bytes32(0));
        assertFalse(missingProofOk, "Rail 2 terminal settlement must require proof-pack ref");

        nativeAdapter.setRejectObservedRecovery(true);

        bool missingObservedRecoveryOk = _callNativeTerminalSettlement(positionId, TERMINAL_PROOF);
        assertFalse(
            missingObservedRecoveryOk, "Rail 2 terminal settlement must respect adapter observed-recovery rejection"
        );
    }

    function _callNativeTerminalSettlement(uint256 positionId, bytes32 proofPackRef) internal returns (bool ok) {
        (ok,) = address(liquidation)
            .call(abi.encodeWithSignature("settleNativePostLiquidation(uint256,bytes32)", positionId, proofPackRef));
    }
}
