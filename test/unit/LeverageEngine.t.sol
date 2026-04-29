// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {LeverageEngine} from "src/core/LeverageEngine.sol";
import {CircuitBreaker} from "src/core/CircuitBreaker.sol";
import {AssetVault} from "src/vaults/AssetVault.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockRiskEngine {
    struct PositionRiskSnapshot {
        uint256 healthFactor;
        uint256 adjustedCollateral;
        uint256 totalDebt;
        uint256 currentLTVBps;
        uint8 classification;
    }

    PositionRegistry internal immutable positionRegistry;

    mapping(bytes32 => uint256) internal _dynamicCapByAsset;
    mapping(uint256 => uint256) internal _adjustedCollateralByPosition;
    mapping(bytes32 => bool) internal _shouldRouteRemote;

    constructor(address positionRegistry_) {
        positionRegistry = PositionRegistry(positionRegistry_);
    }

    function setDynamicCap(bytes32 assetId, uint256 capBps) external {
        _dynamicCapByAsset[assetId] = capBps;
    }

    function setAdjustedCollateral(uint256 positionId, uint256 adjustedCollateral) external {
        _adjustedCollateralByPosition[positionId] = adjustedCollateral;
    }

    function setShouldRouteRemote(bytes32 assetId, bool shouldRoute) external {
        _shouldRouteRemote[assetId] = shouldRoute;
    }

    function refreshDynamicBorrowCap(bytes32 assetId) external returns (uint256) {
        return _dynamicCapByAsset[assetId];
    }

    function shouldOpenRemoteIntent(bytes32 assetId, uint256, uint8) external returns (bool) {
        return _shouldRouteRemote[assetId];
    }

    function positionRiskSnapshot(uint256 positionId) external view returns (PositionRiskSnapshot memory snapshot) {
        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        uint256 adjustedCollateral = _adjustedCollateralByPosition[positionId];
        uint256 currentLTVBps =
            adjustedCollateral == 0 ? type(uint256).max : (p.debtPrincipal * 10_000) / adjustedCollateral;

        uint8 classification;
        if (currentLTVBps <= 6_000) {
            classification = 0;
        } else if (currentLTVBps <= 8_000) {
            classification = 1;
        } else if (currentLTVBps <= 9_000) {
            classification = 2;
        } else {
            classification = 3;
        }

        snapshot = PositionRiskSnapshot({
            healthFactor: 0,
            adjustedCollateral: adjustedCollateral,
            totalDebt: p.debtPrincipal,
            currentLTVBps: currentLTVBps,
            classification: classification
        });
    }
}

contract MockRemoteIntentCoordinator {
    uint256 internal _callCount;
    uint256 internal _lastPositionId;
    uint256 internal _lastAmountNeeded;
    address internal _lastBeneficiary;
    address internal _lastSettlementAsset;
    bytes32 internal _lastIntentId;

    function requestBorrowFill(uint256 positionId, uint256 amountNeeded, address beneficiary, address settlementAsset)
        external
        returns (bytes32 intentId)
    {
        _callCount += 1;
        _lastPositionId = positionId;
        _lastAmountNeeded = amountNeeded;
        _lastBeneficiary = beneficiary;
        _lastSettlementAsset = settlementAsset;
        _lastIntentId = keccak256(
            abi.encodePacked("BORROW_INTENT", positionId, amountNeeded, beneficiary, settlementAsset, _callCount)
        );
        return _lastIntentId;
    }

    function callCount() external view returns (uint256) {
        return _callCount;
    }

    function lastPositionId() external view returns (uint256) {
        return _lastPositionId;
    }

    function lastAmountNeeded() external view returns (uint256) {
        return _lastAmountNeeded;
    }

    function lastBeneficiary() external view returns (address) {
        return _lastBeneficiary;
    }

    function lastSettlementAsset() external view returns (address) {
        return _lastSettlementAsset;
    }

    function lastIntentId() external view returns (bytes32) {
        return _lastIntentId;
    }
}

contract LeverageEngineTest is Test {
    AssetRegistry internal assetRegistry;
    PositionRegistry internal positionRegistry;
    CollateralManager internal collateralManager;
    DebtLedger internal debtLedger;
    AssetVault internal assetVault;
    LendingLiquidityVault internal lendingVault;
    LeverageEngine internal leverageEngine;
    MockRiskEngine internal riskEngine;
    CircuitBreaker internal circuitBreaker;
    MockRemoteIntentCoordinator internal remoteIntentCoordinator;

    MockERC20 internal btc;
    MockERC20 internal stable;

    address internal owner = address(this);
    address internal lender = address(0x1111);
    address internal user = address(0x2222);

    bytes32 internal constant BTC_ASSET = keccak256("BTC");
    bytes32 internal constant BTC_INTEREST = keccak256("BTC_INTEREST");

    function setUp() external {
        btc = new MockERC20("Wrapped BTC", "WBTC", 18);
        stable = new MockERC20("USD Coin", "USDC", 18);

        assetRegistry = new AssetRegistry(owner);
        positionRegistry = new PositionRegistry(owner);
        collateralManager = new CollateralManager(owner);
        debtLedger = new DebtLedger(owner);
        assetVault = new AssetVault(owner, address(btc), BTC_ASSET);
        lendingVault = new LendingLiquidityVault(owner, address(stable), BTC_ASSET);
        riskEngine = new MockRiskEngine(address(positionRegistry));
        circuitBreaker = new CircuitBreaker(owner, 1_000_000 ether, 1000, 1_000_000 ether, 1 days);
        remoteIntentCoordinator = new MockRemoteIntentCoordinator();

        leverageEngine = new LeverageEngine(
            owner,
            address(assetRegistry),
            address(positionRegistry),
            address(collateralManager),
            address(debtLedger),
            address(assetVault),
            address(lendingVault),
            address(riskEngine),
            address(circuitBreaker),
            address(remoteIntentCoordinator)
        );

        leverageEngine.setAuthorizedSettlementHandler(address(this), true);

        positionRegistry.setAuthorizedWriter(address(leverageEngine), true);
        collateralManager.setAuthorizedWriter(address(leverageEngine), true);
        debtLedger.setAuthorizedWriter(address(leverageEngine), true);
        assetVault.setAuthorizedWriter(address(leverageEngine), true);
        lendingVault.setAuthorizedWriter(address(leverageEngine), true);

        assetRegistry.registerAsset(BTC_ASSET, address(btc), address(0x4444), 18, BTC_INTEREST);

        riskEngine.setDynamicCap(BTC_ASSET, 6_000);
        riskEngine.setAdjustedCollateral(1, 10 ether);
        riskEngine.setShouldRouteRemote(BTC_ASSET, false);

        btc.mint(user, 100 ether);
        stable.mint(lender, 1_000_000 ether);

        vm.startPrank(lender);
        stable.approve(address(lendingVault), type(uint256).max);
        lendingVault.depositLiquidity(500_000 ether, lender);
        vm.stopPrank();
    }

    function test_openPosition_createsPositionAndTransfersBorrow() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);
        vm.stopPrank();

        assertEq(positionId, 1);

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        assertEq(p.owner, user);
        assertEq(p.assetId, BTC_ASSET);
        assertEq(p.collateralAmount, 10 ether);
        assertEq(p.debtPrincipal, 5 ether);
        assertEq(p.hasBuybackCover, false);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);
        assertEq(d.principal, 5 ether);

        CollateralManager.CollateralRecord memory c = collateralManager.getCollateralRecord(positionId);
        assertEq(c.lockedCollateral, 10 ether);
        assertEq(assetVault.lockedByPosition(positionId), 10 ether);
        assertEq(stable.balanceOf(user), 5 ether);
        assertEq(leverageEngine.localBorrowedByPosition(positionId), 5 ether);
        assertEq(leverageEngine.remoteBorrowedByPosition(positionId), 0);
    }

    function test_openPosition_routesRemoteBorrowWhenRiskEngineRequestsIt() external {
        riskEngine.setShouldRouteRemote(BTC_ASSET, true);

        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(positionId, 1);
        assertEq(p.debtPrincipal, 0);
        assertEq(d.principal, 0);
        assertEq(stable.balanceOf(user), 0);

        assertEq(remoteIntentCoordinator.callCount(), 1);
        assertEq(remoteIntentCoordinator.lastPositionId(), positionId);
        assertEq(remoteIntentCoordinator.lastAmountNeeded(), 5 ether);
        assertEq(remoteIntentCoordinator.lastBeneficiary(), user);
        assertEq(remoteIntentCoordinator.lastSettlementAsset(), address(stable));
        assertEq(leverageEngine.localBorrowedByPosition(positionId), 0);
        assertEq(leverageEngine.remoteBorrowedByPosition(positionId), 0);
    }

    function test_openPosition_revertsOnZeroCollateral() external {
        vm.startPrank(user);
        vm.expectRevert(LeverageEngine.CollateralRequired.selector);
        leverageEngine.openPosition(BTC_ASSET, 0, 1 ether, false);
        vm.stopPrank();
    }

    function test_openPosition_revertsWhenBorrowExceedsDynamicCap() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(LeverageEngine.BorrowExceedsDynamicCap.selector, 1, 7_000, 6_000));
        leverageEngine.openPosition(BTC_ASSET, 10 ether, 7 ether, false);
        vm.stopPrank();
    }

    function test_openPosition_revertsWhenBorrowingFrozen() external {
        circuitBreaker.freezeBorrowing(BTC_ASSET);

        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(LeverageEngine.BorrowingFrozen.selector, BTC_ASSET));
        leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);
        vm.stopPrank();
    }

    function test_openPosition_allowsZeroBorrowEvenWhenFrozen() external {
        circuitBreaker.freezeBorrowing(BTC_ASSET);

        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 0, false);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        assertEq(p.collateralAmount, 10 ether);
        assertEq(p.debtPrincipal, 0);
    }

    function test_addCollateral_updatesPositionAndLocks() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 20 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 4 ether, false);
        leverageEngine.addCollateral(positionId, 5 ether);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        assertEq(p.collateralAmount, 15 ether);

        CollateralManager.CollateralRecord memory c = collateralManager.getCollateralRecord(positionId);
        assertEq(c.lockedCollateral, 15 ether);
        assertEq(assetVault.lockedByPosition(positionId), 15 ether);
    }

    function test_borrow_increasesDebtAndTransfersQuote() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 4 ether, false);
        leverageEngine.borrow(positionId, 1 ether);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(p.debtPrincipal, 5 ether);
        assertEq(d.principal, 5 ether);
        assertEq(stable.balanceOf(user), 5 ether);
        assertEq(leverageEngine.localBorrowedByPosition(positionId), 5 ether);
        assertEq(leverageEngine.remoteBorrowedByPosition(positionId), 0);
    }

    function test_borrow_routesRemoteWhenRiskEngineRequestsIt() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 4 ether, false);
        vm.stopPrank();

        riskEngine.setShouldRouteRemote(BTC_ASSET, true);

        vm.prank(user);
        leverageEngine.borrow(positionId, 1 ether);

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(p.debtPrincipal, 4 ether);
        assertEq(d.principal, 4 ether);
        assertEq(stable.balanceOf(user), 4 ether);

        assertEq(remoteIntentCoordinator.callCount(), 1);
        assertEq(remoteIntentCoordinator.lastPositionId(), positionId);
        assertEq(remoteIntentCoordinator.lastAmountNeeded(), 1 ether);
        assertEq(remoteIntentCoordinator.lastBeneficiary(), user);
        assertEq(remoteIntentCoordinator.lastSettlementAsset(), address(stable));
    }

    function test_consumeRemoteBorrowSettlement_updatesDebtAccountingAndProvenance() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 0, false);
        vm.stopPrank();

        leverageEngine.consumeRemoteBorrowSettlement(positionId, 3 ether, false);

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(p.debtPrincipal, 3 ether);
        assertEq(d.principal, 3 ether);
        assertEq(leverageEngine.localBorrowedByPosition(positionId), 0);
        assertEq(leverageEngine.remoteBorrowedByPosition(positionId), 3 ether);
    }

    function test_consumeRemoteBorrowSettlement_supportsMixedLocalAndRemote() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 4 ether, false);
        vm.stopPrank();

        leverageEngine.consumeRemoteBorrowSettlement(positionId, 1 ether, true);

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(p.debtPrincipal, 5 ether);
        assertEq(d.principal, 5 ether);
        assertEq(leverageEngine.localBorrowedByPosition(positionId), 4 ether);
        assertEq(leverageEngine.remoteBorrowedByPosition(positionId), 1 ether);
    }

    function test_borrow_revertsWhenProjectedLtvExceedsCap() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);

        vm.expectRevert(
            abi.encodeWithSelector(LeverageEngine.BorrowExceedsDynamicCap.selector, positionId, 7_000, 6_000)
        );
        leverageEngine.borrow(positionId, 2 ether);
        vm.stopPrank();
    }

    function test_borrow_revertsWhenBorrowingFrozen() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 4 ether, false);
        vm.stopPrank();

        circuitBreaker.freezeBorrowing(BTC_ASSET);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(LeverageEngine.BorrowingFrozen.selector, BTC_ASSET));
        leverageEngine.borrow(positionId, 1 ether);
    }

    function test_borrow_revertsWhenProtocolPaused() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 4 ether, false);
        vm.stopPrank();

        circuitBreaker.pause();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(LeverageEngine.BorrowingFrozen.selector, BTC_ASSET));
        leverageEngine.borrow(positionId, 1 ether);
    }

    function test_repay_reducesDebt() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);
        stable.approve(address(lendingVault), 2 ether);
        leverageEngine.repay(positionId, 2 ether);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(p.debtPrincipal, 3 ether);
        assertEq(d.principal, 3 ether);
    }

    function test_closePosition_releasesCollateralClosesDebtAndMarksClosed() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);
        stable.approve(address(lendingVault), 5 ether);
        leverageEngine.closePosition(positionId);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        assertEq(p.collateralAmount, 0);
        assertEq(p.debtPrincipal, 0);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Closed));

        CollateralManager.CollateralRecord memory c = collateralManager.getCollateralRecord(positionId);
        assertEq(c.lockedCollateral, 0);
        assertEq(assetVault.lockedByPosition(positionId), 0);
        assertEq(btc.balanceOf(user), 100 ether);
    }

    function test_closedPosition_cannotBeMutated() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 20 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);
        stable.approve(address(lendingVault), 5 ether);
        leverageEngine.closePosition(positionId);

        vm.expectRevert(abi.encodeWithSelector(LeverageEngine.PositionClosed.selector, positionId));
        leverageEngine.addCollateral(positionId, 1 ether);
        vm.stopPrank();
    }

    function test_onlyOwnerCanOperateOwnPosition() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 5 ether, false);
        vm.stopPrank();

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(LeverageEngine.NotPositionOwner.selector, positionId, lender));
        leverageEngine.borrow(positionId, 1 ether);
    }
}
