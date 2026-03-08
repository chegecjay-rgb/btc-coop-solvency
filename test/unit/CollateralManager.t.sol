// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";

contract CollateralManagerTest is Test {
    CollateralManager internal manager;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);

    uint256 internal constant POSITION_ID = 1;

    function setUp() external {
        manager = new CollateralManager(owner);
        manager.setAuthorizedWriter(writer, true);
    }

    function test_initializeCollateralRecord_storesInitialCollateral() external {
        manager.initializeCollateralRecord(POSITION_ID, 10 ether);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.totalCollateral, 10 ether);
        assertEq(record.lockedCollateral, 0);
        assertEq(record.transferredToStabilization, 0);
        assertEq(record.transferredToInsurance, 0);
        assertEq(record.releaseFrozen, false);
        assertEq(manager.totalTrackedCollateral(), 10 ether);
    }

    function test_initializeCollateralRecord_revertsForZeroPositionId() external {
        vm.expectRevert(abi.encodeWithSelector(CollateralManager.PositionNotFound.selector, 0));
        manager.initializeCollateralRecord(0, 1 ether);
    }

    function test_initializeCollateralRecord_revertsIfAlreadyInitialized() external {
        manager.initializeCollateralRecord(POSITION_ID, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(CollateralManager.AlreadyInitialized.selector, POSITION_ID));
        manager.initializeCollateralRecord(POSITION_ID, 1 ether);
    }

    function test_initializeCollateralRecord_revertsIfNotAuthorized() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.initializeCollateralRecord(POSITION_ID, 1 ether);
    }

    function test_authorizedWriter_canInitializeCollateralRecord() external {
        vm.prank(writer);
        manager.initializeCollateralRecord(POSITION_ID, 2 ether);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.totalCollateral, 2 ether);
    }

    function test_addCollateral_updatesTotal() external {
        _init();

        manager.addCollateral(POSITION_ID, 5 ether);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.totalCollateral, 15 ether);
        assertEq(manager.totalTrackedCollateral(), 15 ether);
    }

    function test_addCollateral_revertsOnZeroAmount() external {
        _init();

        vm.expectRevert(CollateralManager.InvalidAmount.selector);
        manager.addCollateral(POSITION_ID, 0);
    }

    function test_lockCollateral_updatesLockedAmount() external {
        _init();

        manager.lockCollateral(POSITION_ID, 4 ether);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.lockedCollateral, 4 ether);
        assertEq(manager.totalLockedCollateral(), 4 ether);
        assertEq(manager.availableCollateral(POSITION_ID), 6 ether);
    }

    function test_lockCollateral_revertsIfInsufficientAvailable() external {
        _init();

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralManager.InsufficientAvailableCollateral.selector,
                11 ether,
                10 ether
            )
        );
        manager.lockCollateral(POSITION_ID, 11 ether);
    }

    function test_releaseCollateral_updatesLockedAmount() external {
        _init();
        manager.lockCollateral(POSITION_ID, 4 ether);

        manager.releaseCollateral(POSITION_ID, 1 ether);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.lockedCollateral, 3 ether);
        assertEq(manager.totalLockedCollateral(), 3 ether);
    }

    function test_releaseCollateral_revertsIfFrozen() external {
        _init();
        manager.lockCollateral(POSITION_ID, 4 ether);
        manager.freezeRelease(POSITION_ID);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralManager.ReleaseFrozen.selector, POSITION_ID)
        );
        manager.releaseCollateral(POSITION_ID, 1 ether);
    }

    function test_releaseCollateral_revertsIfInsufficientLocked() external {
        _init();
        manager.lockCollateral(POSITION_ID, 2 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralManager.InsufficientLockedCollateral.selector,
                3 ether,
                2 ether
            )
        );
        manager.releaseCollateral(POSITION_ID, 3 ether);
    }

    function test_freezeRelease_setsFlag() external {
        _init();

        manager.freezeRelease(POSITION_ID);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.releaseFrozen, true);
    }

    function test_freezeRelease_revertsIfAlreadyFrozen() external {
        _init();
        manager.freezeRelease(POSITION_ID);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralManager.AlreadyFrozen.selector, POSITION_ID)
        );
        manager.freezeRelease(POSITION_ID);
    }

    function test_unfreezeRelease_clearsFlag() external {
        _init();
        manager.freezeRelease(POSITION_ID);

        manager.unfreezeRelease(POSITION_ID);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.releaseFrozen, false);
    }

    function test_unfreezeRelease_revertsIfNotFrozen() external {
        _init();

        vm.expectRevert(
            abi.encodeWithSelector(CollateralManager.NotFrozen.selector, POSITION_ID)
        );
        manager.unfreezeRelease(POSITION_ID);
    }

    function test_transferToStabilization_updatesTracking() external {
        _init();
        manager.lockCollateral(POSITION_ID, 5 ether);

        manager.transferToStabilization(POSITION_ID, 3 ether);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.totalCollateral, 7 ether);
        assertEq(record.lockedCollateral, 2 ether);
        assertEq(record.transferredToStabilization, 3 ether);
        assertEq(manager.totalTrackedCollateral(), 7 ether);
        assertEq(manager.totalLockedCollateral(), 2 ether);
        assertEq(manager.totalTransferredToStabilization(), 3 ether);
    }

    function test_transferToInsurance_updatesTracking() external {
        _init();
        manager.lockCollateral(POSITION_ID, 5 ether);

        manager.transferToInsurance(POSITION_ID, 2 ether);

        CollateralManager.CollateralRecord memory record = manager.getCollateralRecord(POSITION_ID);
        assertEq(record.totalCollateral, 8 ether);
        assertEq(record.lockedCollateral, 3 ether);
        assertEq(record.transferredToInsurance, 2 ether);
        assertEq(manager.totalTrackedCollateral(), 8 ether);
        assertEq(manager.totalLockedCollateral(), 3 ether);
        assertEq(manager.totalTransferredToInsurance(), 2 ether);
    }

    function test_transferToStabilization_revertsIfInsufficientLocked() external {
        _init();
        manager.lockCollateral(POSITION_ID, 2 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralManager.InsufficientLockedCollateral.selector,
                3 ether,
                2 ether
            )
        );
        manager.transferToStabilization(POSITION_ID, 3 ether);
    }

    function test_transferToInsurance_revertsIfInsufficientLocked() external {
        _init();
        manager.lockCollateral(POSITION_ID, 2 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralManager.InsufficientLockedCollateral.selector,
                3 ether,
                2 ether
            )
        );
        manager.transferToInsurance(POSITION_ID, 3 ether);
    }

    function test_exists_falseWhenUnset() external {
        assertEq(manager.exists(POSITION_ID), false);
    }

    function test_exists_trueWhenInitialized() external {
        _init();
        assertEq(manager.exists(POSITION_ID), true);
    }

    function test_getCollateralRecord_revertsWhenMissing() external {
        vm.expectRevert(
            abi.encodeWithSelector(CollateralManager.PositionNotFound.selector, POSITION_ID)
        );
        manager.getCollateralRecord(POSITION_ID);
    }

    function test_onlyAuthorized_canAddCollateral() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.addCollateral(POSITION_ID, 1 ether);
    }

    function test_onlyAuthorized_canLockCollateral() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.lockCollateral(POSITION_ID, 1 ether);
    }

    function test_onlyAuthorized_canReleaseCollateral() external {
        _init();
        manager.lockCollateral(POSITION_ID, 1 ether);

        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.releaseCollateral(POSITION_ID, 1 ether);
    }

    function test_onlyAuthorized_canFreezeRelease() external {
        _init();

        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.freezeRelease(POSITION_ID);
    }

    function test_onlyAuthorized_canUnfreezeRelease() external {
        _init();
        manager.freezeRelease(POSITION_ID);

        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.unfreezeRelease(POSITION_ID);
    }

    function test_onlyAuthorized_canTransferToStabilization() external {
        _init();
        manager.lockCollateral(POSITION_ID, 1 ether);

        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.transferToStabilization(POSITION_ID, 1 ether);
    }

    function test_onlyAuthorized_canTransferToInsurance() external {
        _init();
        manager.lockCollateral(POSITION_ID, 1 ether);

        vm.prank(nonAuthorized);
        vm.expectRevert(CollateralManager.NotAuthorized.selector);
        manager.transferToInsurance(POSITION_ID, 1 ether);
    }

    function _init() internal {
        manager.initializeCollateralRecord(POSITION_ID, 10 ether);
    }
}
