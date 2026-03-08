// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionRegistry} from "src/core/PositionRegistry.sol";

contract PositionRegistryTest is Test {
    PositionRegistry internal registry;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);
    address internal user = address(0x1234);

    bytes32 internal constant BTC = keccak256("BTC");
    bytes32 internal constant INTENT_ID = keccak256("REMOTE_INTENT_1");

    function setUp() external {
        registry = new PositionRegistry(owner);
        registry.setAuthorizedWriter(writer, true);
    }

    function test_createPosition_storesValues() external {
        uint256 positionId = registry.createPosition(user, BTC, 10 ether, 5 ether, true);

        PositionRegistry.Position memory p = registry.getPosition(positionId);

        assertEq(p.owner, user);
        assertEq(p.assetId, BTC);
        assertEq(p.collateralAmount, 10 ether);
        assertEq(p.debtPrincipal, 5 ether);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.Healthy));
        assertEq(p.rescueCount, 0);
        assertEq(p.lastRescueTime, 0);
        assertEq(p.hasBuybackCover, true);
        assertEq(p.activeRemoteIntentId, bytes32(0));
    }

    function test_createPosition_incrementsNextPositionId() external {
        uint256 id1 = registry.createPosition(user, BTC, 1 ether, 1 ether, false);
        uint256 id2 = registry.createPosition(user, BTC, 2 ether, 2 ether, false);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(registry.nextPositionId(), 3);
    }

    function test_createPosition_revertsForZeroOwner() external {
        vm.expectRevert(PositionRegistry.ZeroAddress.selector);
        registry.createPosition(address(0), BTC, 1 ether, 1 ether, false);
    }

    function test_createPosition_revertsForZeroAssetId() external {
        vm.expectRevert(PositionRegistry.InvalidAssetId.selector);
        registry.createPosition(user, bytes32(0), 1 ether, 1 ether, false);
    }

    function test_createPosition_revertsIfNotAuthorized() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(PositionRegistry.NotAuthorized.selector);
        registry.createPosition(user, BTC, 1 ether, 1 ether, false);
    }

    function test_authorizedWriter_canCreatePosition() external {
        vm.prank(writer);
        uint256 positionId = registry.createPosition(user, BTC, 3 ether, 1 ether, false);

        PositionRegistry.Position memory p = registry.getPosition(positionId);
        assertEq(p.owner, user);
    }

    function test_setAuthorizedWriter_revertsOnZeroAddress() external {
        vm.expectRevert(PositionRegistry.ZeroAddress.selector);
        registry.setAuthorizedWriter(address(0), true);
    }

    function test_updateState_changesState() external {
        uint256 positionId = _createPosition();

        registry.updateState(positionId, PositionRegistry.PositionState.AtRisk);

        PositionRegistry.Position memory p = registry.getPosition(positionId);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.AtRisk));
    }

    function test_updateAmounts_changesCollateralAndDebt() external {
        uint256 positionId = _createPosition();

        registry.updateAmounts(positionId, 20 ether, 8 ether);

        PositionRegistry.Position memory p = registry.getPosition(positionId);
        assertEq(p.collateralAmount, 20 ether);
        assertEq(p.debtPrincipal, 8 ether);
    }

    function test_incrementRescueCount_updatesCountAndTimestamp() external {
        uint256 positionId = _createPosition();

        vm.warp(123456);
        registry.incrementRescueCount(positionId);

        PositionRegistry.Position memory p = registry.getPosition(positionId);
        assertEq(p.rescueCount, 1);
        assertEq(p.lastRescueTime, 123456);
    }

    function test_setBuybackCover_updatesFlag() external {
        uint256 positionId = _createPosition();

        registry.setBuybackCover(positionId, true);

        PositionRegistry.Position memory p = registry.getPosition(positionId);
        assertEq(p.hasBuybackCover, true);
    }

    function test_bindRemoteIntent_setsIntentAndState() external {
        uint256 positionId = _createPosition();

        registry.bindRemoteIntent(positionId, INTENT_ID);

        PositionRegistry.Position memory p = registry.getPosition(positionId);
        assertEq(p.activeRemoteIntentId, INTENT_ID);
        assertEq(uint256(p.state), uint256(PositionRegistry.PositionState.RemoteFundingPending));
    }

    function test_bindRemoteIntent_revertsOnZeroIntentId() external {
        uint256 positionId = _createPosition();

        vm.expectRevert(PositionRegistry.InvalidState.selector);
        registry.bindRemoteIntent(positionId, bytes32(0));
    }

    function test_bindRemoteIntent_revertsIfAlreadyBound() external {
        uint256 positionId = _createPosition();

        registry.bindRemoteIntent(positionId, INTENT_ID);

        vm.expectRevert(PositionRegistry.RemoteIntentAlreadySet.selector);
        registry.bindRemoteIntent(positionId, keccak256("ANOTHER_INTENT"));
    }

    function test_clearRemoteIntent_clearsIntent() external {
        uint256 positionId = _createPosition();

        registry.bindRemoteIntent(positionId, INTENT_ID);
        registry.clearRemoteIntent(positionId);

        PositionRegistry.Position memory p = registry.getPosition(positionId);
        assertEq(p.activeRemoteIntentId, bytes32(0));
    }

    function test_clearRemoteIntent_revertsIfNoneBound() external {
        uint256 positionId = _createPosition();

        vm.expectRevert(PositionRegistry.NoActiveRemoteIntent.selector);
        registry.clearRemoteIntent(positionId);
    }

    function test_getPosition_revertsIfMissing() external {
        vm.expectRevert(abi.encodeWithSelector(PositionRegistry.PositionNotFound.selector, 999));
        registry.getPosition(999);
    }

    function test_exists_falseForUnknownPosition() external {
        assertEq(registry.exists(999), false);
    }

    function test_exists_trueForCreatedPosition() external {
        uint256 positionId = _createPosition();
        assertEq(registry.exists(positionId), true);
    }

    function test_ownerOfPosition_returnsCorrectOwner() external {
        uint256 positionId = _createPosition();
        assertEq(registry.ownerOfPosition(positionId), user);
    }

    function test_onlyAuthorized_canUpdateState() external {
        uint256 positionId = _createPosition();

        vm.prank(nonAuthorized);
        vm.expectRevert(PositionRegistry.NotAuthorized.selector);
        registry.updateState(positionId, PositionRegistry.PositionState.AtRisk);
    }

    function test_onlyAuthorized_canUpdateAmounts() external {
        uint256 positionId = _createPosition();

        vm.prank(nonAuthorized);
        vm.expectRevert(PositionRegistry.NotAuthorized.selector);
        registry.updateAmounts(positionId, 1 ether, 1 ether);
    }

    function test_onlyAuthorized_canIncrementRescueCount() external {
        uint256 positionId = _createPosition();

        vm.prank(nonAuthorized);
        vm.expectRevert(PositionRegistry.NotAuthorized.selector);
        registry.incrementRescueCount(positionId);
    }

    function test_onlyAuthorized_canSetBuybackCover() external {
        uint256 positionId = _createPosition();

        vm.prank(nonAuthorized);
        vm.expectRevert(PositionRegistry.NotAuthorized.selector);
        registry.setBuybackCover(positionId, true);
    }

    function test_onlyAuthorized_canBindRemoteIntent() external {
        uint256 positionId = _createPosition();

        vm.prank(nonAuthorized);
        vm.expectRevert(PositionRegistry.NotAuthorized.selector);
        registry.bindRemoteIntent(positionId, INTENT_ID);
    }

    function test_onlyAuthorized_canClearRemoteIntent() external {
        uint256 positionId = _createPosition();
        registry.bindRemoteIntent(positionId, INTENT_ID);

        vm.prank(nonAuthorized);
        vm.expectRevert(PositionRegistry.NotAuthorized.selector);
        registry.clearRemoteIntent(positionId);
    }

    function _createPosition() internal returns (uint256) {
        return registry.createPosition(user, BTC, 10 ether, 5 ether, false);
    }
}
