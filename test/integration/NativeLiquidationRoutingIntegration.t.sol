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

contract NativeLiquidationRoutingIntegrationTest is Test {
    uint8 internal constant RAIL_PROTOCOL_ESCROWED_WRAPPED_BTC = 0;
    uint8 internal constant RAIL_ENFORCEABLE_NATIVE_BTC = 1;

    uint8 internal constant STATE_ACTIVE = 1;
    uint8 internal constant STATE_LIQUIDATABLE = 7;

    bytes32 internal constant WBTC_ASSET_ID = bytes32("WBTC");
    bytes32 internal constant PROOF_REF = keccak256("native-proof-pack");

    MockPositionRegistry internal positions;
    MockCollateralManager internal collateral;
    MockDebtLedger internal debt;
    MockRiskEngine internal risk;
    MockRecapitalizationEngine internal recap;
    RecordingNativeSettlementAdapter internal nativeAdapter;
    LiquidationEngine internal liquidation;

    function setUp() public {
        positions = new MockPositionRegistry();
        collateral = new MockCollateralManager();
        debt = new MockDebtLedger();
        risk = new MockRiskEngine();
        recap = new MockRecapitalizationEngine();
        nativeAdapter = new RecordingNativeSettlementAdapter();

        liquidation = new LiquidationEngine(
            address(this),
            address(positions),
            address(collateral),
            address(debt),
            address(risk),
            address(recap),
            1_000, // 10% liquidation penalty
            1 days
        );

        liquidation.setNativeSettlementAdapter(address(nativeAdapter));
    }

    function test_rail2LiquidationWithConfiguredAdapterRoutesToNativeAdapter() public {
        uint256 positionId = 1;

        positions.seed(positionId, RAIL_ENFORCEABLE_NATIVE_BTC, 80 ether, 100 ether, STATE_LIQUIDATABLE);

        collateral.seed(positionId, 80 ether);
        debt.seed(positionId, 100 ether);
        risk.setClassification(3);

        liquidation.executeNativeLiquidation(positionId, PROOF_REF);

        assertEq(nativeAdapter.callCount(), 1, "native adapter should be called once");
        assertEq(nativeAdapter.lastPositionId(), positionId, "position id should be forwarded");
        assertEq(nativeAdapter.lastProofRef(), PROOF_REF, "proof ref should be forwarded");

        assertEq(
            collateral.transferToStabilizationCalls(positionId),
            0,
            "native rail must not use escrow collateral transfer path"
        );

        assertEq(
            debt.settlementCosts(positionId),
            0,
            "native rail liquidation should not record escrow settlement cost directly"
        );

        assertEq(
            recap.recoveries(positionId), 0, "native rail liquidation should leave recovery accounting to adapter path"
        );
    }

    function test_rail1LiquidationRemainsOnEscrowPathEvenWhenNativeAdapterConfigured() public {
        uint256 positionId = 2;

        positions.seed(positionId, RAIL_PROTOCOL_ESCROWED_WRAPPED_BTC, 120 ether, 100 ether, STATE_LIQUIDATABLE);

        collateral.seed(positionId, 120 ether);
        debt.seed(positionId, 100 ether);
        risk.setClassification(3);

        liquidation.executeLiquidation(positionId);

        assertEq(nativeAdapter.callCount(), 0, "rail 1 must not call native adapter");
        assertEq(collateral.transferToStabilizationCalls(positionId), 1, "escrow collateral should move");
        assertEq(collateral.transferredToStabilization(positionId), 120 ether, "escrow collateral moved");
        assertEq(debt.settlementCosts(positionId), 10 ether, "10% liquidation penalty recorded");
        assertEq(recap.recoveries(positionId), 100 ether, "principal recovery recorded");
        assertTrue(liquidation.liquidatedPosition(positionId), "rail 1 position should be marked liquidated");
    }
}

contract RecordingNativeSettlementAdapter {
    uint256 public callCount;
    bytes4 public lastSelector;
    uint256 public lastPositionId;
    bytes32 public lastProofRef;

    fallback(bytes calldata) external returns (bytes memory) {
        callCount += 1;

        bytes4 selector;
        uint256 positionId;
        bytes32 proofRef;

        assembly {
            selector := calldataload(0)
            positionId := calldataload(4)
            proofRef := calldataload(36)
        }

        lastSelector = selector;
        lastPositionId = positionId;
        lastProofRef = proofRef;

        return "";
    }
}

contract MockPositionRegistry {
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

    function getPosition(uint256 positionId) external view returns (IPositionRegistryForLiquidation.Position memory) {
        return positions[positionId];
    }

    function collateralRailOf(uint256 positionId) external view returns (uint8) {
        return rails[positionId];
    }

    function updateState(uint256 positionId, uint8 newState) external {
        positions[positionId].state = newState;
    }

    function updateAmounts(uint256 positionId, uint256 collateralAmount, uint256 debtPrincipal) external {
        positions[positionId].collateralAmount = collateralAmount;
        positions[positionId].debtPrincipal = debtPrincipal;
    }
}

contract MockCollateralManager {
    mapping(uint256 => ICollateralManagerForLiquidation.CollateralRecord) internal records;
    mapping(uint256 => uint256) public transferToStabilizationCalls;
    mapping(uint256 => uint256) public transferredToStabilization;

    function seed(uint256 positionId, uint256 collateralAmount) external {
        records[positionId] = ICollateralManagerForLiquidation.CollateralRecord({
            totalCollateral: collateralAmount,
            lockedCollateral: collateralAmount,
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
        transferToStabilizationCalls[positionId] += 1;
        transferredToStabilization[positionId] += amount;

        records[positionId].lockedCollateral -= amount;
        records[positionId].transferredToStabilization += amount;
    }
}

contract MockDebtLedger {
    mapping(uint256 => IDebtLedgerForLiquidation.DebtRecord) internal records;
    mapping(uint256 => uint256) public settlementCosts;
    mapping(uint256 => bool) public closed;

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
        settlementCosts[positionId] += amount;
        records[positionId].settlementCosts += amount;
    }

    function closeDebt(uint256 positionId) external {
        closed[positionId] = true;
        records[positionId].principal = 0;
    }
}

contract MockRiskEngine {
    uint8 internal classification;

    function setClassification(uint8 classification_) external {
        classification = classification_;
    }

    function positionRiskSnapshot(uint256)
        external
        view
        returns (IRiskEngineForLiquidation.PositionRiskSnapshot memory)
    {
        return IRiskEngineForLiquidation.PositionRiskSnapshot({
            healthFactor: 0, adjustedCollateral: 0, totalDebt: 0, currentLTVBps: 0, classification: classification
        });
    }
}

contract MockRecapitalizationEngine {
    mapping(uint256 => uint256) public recoveries;

    function recordRecovery(uint256 positionId, uint256 amount) external {
        recoveries[positionId] += amount;
    }
}
