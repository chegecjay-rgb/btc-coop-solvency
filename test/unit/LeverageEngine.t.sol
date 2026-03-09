// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {LeverageEngine} from "src/core/LeverageEngine.sol";
import {AssetVault} from "src/vaults/AssetVault.sol";
import {LendingLiquidityVault} from "src/vaults/LendingLiquidityVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LeverageEngineTest is Test {
    AssetRegistry internal assetRegistry;
    PositionRegistry internal positionRegistry;
    CollateralManager internal collateralManager;
    DebtLedger internal debtLedger;
    AssetVault internal assetVault;
    LendingLiquidityVault internal lendingVault;
    LeverageEngine internal leverageEngine;

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

        leverageEngine = new LeverageEngine(
            owner,
            address(assetRegistry),
            address(positionRegistry),
            address(collateralManager),
            address(debtLedger),
            address(assetVault),
            address(lendingVault),
            address(0x9999)
        );

        positionRegistry.setAuthorizedWriter(address(leverageEngine), true);
        collateralManager.setAuthorizedWriter(address(leverageEngine), true);
        debtLedger.setAuthorizedWriter(address(leverageEngine), true);
        assetVault.setAuthorizedWriter(address(leverageEngine), true);
        lendingVault.setAuthorizedWriter(address(leverageEngine), true);

        assetRegistry.registerAsset(
            BTC_ASSET,
            address(btc),
            address(0x4444),
            18,
            BTC_INTEREST
        );

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

        uint256 positionId = leverageEngine.openPosition(
            BTC_ASSET,
            10 ether,
            50_000 ether,
            false
        );
        vm.stopPrank();

        assertEq(positionId, 1);

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        assertEq(p.owner, user);
        assertEq(p.assetId, BTC_ASSET);
        assertEq(p.collateralAmount, 10 ether);
        assertEq(p.debtPrincipal, 50_000 ether);
        assertEq(p.hasBuybackCover, false);

        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);
        assertEq(d.principal, 50_000 ether);

        CollateralManager.CollateralRecord memory c =
            collateralManager.getCollateralRecord(positionId);
        assertEq(c.lockedCollateral, 10 ether);

        assertEq(assetVault.lockedByPosition(positionId), 10 ether);
        assertEq(stable.balanceOf(user), 50_000 ether);
    }

    function test_addCollateral_updatesPositionAndLocks() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 20 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 10_000 ether, false);
        leverageEngine.addCollateral(positionId, 5 ether);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        assertEq(p.collateralAmount, 15 ether);

        CollateralManager.CollateralRecord memory c =
            collateralManager.getCollateralRecord(positionId);
        assertEq(c.lockedCollateral, 15 ether);

        assertEq(assetVault.lockedByPosition(positionId), 15 ether);
    }

    function test_borrow_increasesDebtAndTransfersQuote() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 10_000 ether, false);

        leverageEngine.borrow(positionId, 5_000 ether);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(p.debtPrincipal, 15_000 ether);
        assertEq(d.principal, 15_000 ether);
        assertEq(stable.balanceOf(user), 15_000 ether);
    }

    function test_repay_reducesDebt() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 10_000 ether, false);

        stable.approve(address(lendingVault), 4_000 ether);
        leverageEngine.repay(positionId, 4_000 ether);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        DebtLedger.DebtRecord memory d = debtLedger.getDebtRecord(positionId);

        assertEq(p.debtPrincipal, 6_000 ether);
        assertEq(d.principal, 6_000 ether);
    }

    function test_closePosition_releasesCollateralAndClosesDebt() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 10_000 ether, false);

        stable.approve(address(lendingVault), 10_000 ether);
        leverageEngine.closePosition(positionId);
        vm.stopPrank();

        PositionRegistry.Position memory p = positionRegistry.getPosition(positionId);
        assertEq(p.collateralAmount, 0);
        assertEq(p.debtPrincipal, 0);

        CollateralManager.CollateralRecord memory c =
            collateralManager.getCollateralRecord(positionId);
        assertEq(c.lockedCollateral, 0);

        assertEq(assetVault.lockedByPosition(positionId), 0);
        assertEq(btc.balanceOf(user), 100 ether);
    }

    function test_onlyOwnerCanOperateOwnPosition() external {
        vm.startPrank(user);
        btc.approve(address(leverageEngine), 10 ether);
        uint256 positionId = leverageEngine.openPosition(BTC_ASSET, 10 ether, 10_000 ether, false);
        vm.stopPrank();

        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(LeverageEngine.NotPositionOwner.selector, positionId, lender)
        );
        leverageEngine.borrow(positionId, 1_000 ether);
    }
}
