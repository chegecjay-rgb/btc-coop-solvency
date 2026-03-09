// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CircuitBreaker} from "src/core/CircuitBreaker.sol";

contract CircuitBreakerTest is Test {
    CircuitBreaker internal breaker;

    address internal owner = address(this);
    address internal operator = address(0xCAFE);
    address internal other = address(0xBEEF);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        breaker = new CircuitBreaker(
            owner,
            100_000 ether,
            5,
            50_000 ether,
            1 hours
        );

        breaker.setAuthorizedOperator(operator, true);
    }

    function test_constructor_setsValues() external view {
        assertEq(breaker.paused(), false);
        assertEq(breaker.maxRescueVelocity(), 100_000 ether);
        assertEq(breaker.maxTerminalSettlementsPerWindow(), 5);
        assertEq(breaker.maxRemoteIntentVelocity(), 50_000 ether);
        assertEq(breaker.windowDuration(), 1 hours);
    }

    function test_pause_and_unpause() external {
        vm.prank(operator);
        breaker.pause();
        assertEq(breaker.paused(), true);

        vm.prank(operator);
        breaker.unpause();
        assertEq(breaker.paused(), false);
    }

    function test_freezeBorrowing_setsFrozenFlag() external {
        vm.prank(operator);
        breaker.freezeBorrowing(BTC);

        assertEq(breaker.borrowingFrozenByAsset(BTC), true);
        assertEq(breaker.isBorrowingFrozen(BTC), true);
    }

    function test_unfreezeBorrowing_clearsFrozenFlag() external {
        vm.prank(operator);
        breaker.freezeBorrowing(BTC);

        vm.prank(operator);
        breaker.unfreezeBorrowing(BTC);

        assertEq(breaker.borrowingFrozenByAsset(BTC), false);
        assertEq(breaker.isBorrowingFrozen(BTC), false);
    }

    function test_isBorrowingFrozen_trueWhenProtocolPaused() external {
        vm.prank(operator);
        breaker.pause();

        assertEq(breaker.isBorrowingFrozen(BTC), true);
    }

    function test_checkRescueVelocity_passesBelowThreshold() external {
        vm.prank(operator);
        breaker.recordRescue(BTC, 40_000 ether);

        assertEq(breaker.checkRescueVelocity(BTC), true);
    }

    function test_checkRescueVelocity_revertsAboveThreshold() external {
        vm.prank(operator);
        breaker.recordRescue(BTC, 120_000 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CircuitBreaker.RescueVelocityExceeded.selector,
                BTC,
                120_000 ether,
                100_000 ether
            )
        );
        breaker.checkRescueVelocity(BTC);
    }

    function test_checkRemoteIntentVelocity_passesBelowThreshold() external {
        vm.prank(operator);
        breaker.recordRemoteIntent(BTC, 20_000 ether);

        assertEq(breaker.checkRemoteIntentVelocity(BTC), true);
    }

    function test_checkRemoteIntentVelocity_revertsAboveThreshold() external {
        vm.prank(operator);
        breaker.recordRemoteIntent(BTC, 60_000 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CircuitBreaker.RemoteIntentVelocityExceeded.selector,
                BTC,
                60_000 ether,
                50_000 ether
            )
        );
        breaker.checkRemoteIntentVelocity(BTC);
    }

    function test_velocityWindow_resetsAfterDuration() external {
        vm.prank(operator);
        breaker.recordRescue(BTC, 90_000 ether);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(operator);
        breaker.recordRescue(BTC, 20_000 ether);

        assertEq(breaker.checkRescueVelocity(BTC), true);
    }

    function test_recordTerminalSettlement_incrementsCount() external {
        vm.prank(operator);
        breaker.recordTerminalSettlement();

        vm.prank(operator);
        breaker.recordTerminalSettlement();

        assertEq(breaker.terminalSettlementsInWindow(), 2);
    }

    function test_onlyAuthorized_canPause() external {
        vm.prank(other);
        vm.expectRevert(CircuitBreaker.ZeroAddress.selector);
        breaker.pause();
    }
}
