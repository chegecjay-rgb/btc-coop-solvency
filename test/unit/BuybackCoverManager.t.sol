// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
import {BuybackCoverManager} from "src/core/BuybackCoverManager.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract BuybackCoverManagerTest is Test {
    PositionRegistry internal positionRegistry;
    ParameterRegistry internal parameterRegistry;
    InsuranceReserve internal insuranceReserve;
    BuybackCoverManager internal coverManager;
    MockERC20 internal stable;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal user = address(0x1111);
    address internal other = address(0x2222);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 18);

        positionRegistry = new PositionRegistry(owner);
        parameterRegistry = new ParameterRegistry(owner);
        insuranceReserve = new InsuranceReserve(owner, address(stable));
        coverManager = new BuybackCoverManager(
            owner,
            address(positionRegistry),
            address(parameterRegistry),
            address(insuranceReserve),
            address(stable)
        );

        positionRegistry.setAuthorizedWriter(address(this), true);
        insuranceReserve.setAuthorizedWriter(address(coverManager), true);
        coverManager.setAuthorizedWriter(writer, true);

        parameterRegistry.setInsuranceParams(
            BTC,
            ParameterRegistry.InsuranceParams({
                baseSystemInsuranceRateBps: 200,
                baseOptionalCoverRateBps: 300,
                maxCoverageBps: 8000
            })
        );

        positionRegistry.createPosition(user, BTC, 10 ether, 50_000 ether, true); // id 1
        positionRegistry.createPosition(user, BTC, 10 ether, 40_000 ether, false); // id 2

        stable.mint(user, 1_000_000 ether);
        stable.mint(address(this), 1_000_000 ether);

        stable.approve(address(insuranceReserve), type(uint256).max);
        insuranceReserve.depositReserve(500_000 ether);
    }

    function test_quoteCover_returnsExpectedValues() external {
        (uint256 premium, uint256 coverageLimit, uint256 expiry) = coverManager.quoteCover(1);

        // 50,000 * 80% = 40,000 coverage
        // premium = 40,000 * 3% = 1,200
        assertEq(coverageLimit, 40_000 ether);
        assertEq(premium, 1_200 ether);
        assertGt(expiry, block.timestamp);
    }

    function test_quoteCover_revertsIfPositionNotEligible() external {
        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.PositionNotEligible.selector, 2)
        );
        coverManager.quoteCover(2);
    }

    function test_purchaseCover_storesTermsAndReservesInsurance() external {
        vm.startPrank(user);
        stable.approve(address(coverManager), type(uint256).max);
        coverManager.purchaseCover(1);
        vm.stopPrank();

        (
            uint256 premiumPaid,
            uint256 coverageLimit,
            uint256 expiry,
            bool active
        ) = coverManager.coverByPosition(1);

        assertEq(premiumPaid, 1_200 ether);
        assertEq(coverageLimit, 40_000 ether);
        assertGt(expiry, block.timestamp);
        assertEq(active, true);

        (
            uint256 coveredClaimAmount,
            ,
            ,
            bool exposureActive
        ) = insuranceReserve.exposureByPosition(1);

        assertEq(coveredClaimAmount, 40_000 ether);
        assertEq(exposureActive, true);
    }

    function test_purchaseCover_revertsIfNotPositionOwner() external {
        vm.startPrank(other);
        stable.approve(address(coverManager), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.NotPositionOwner.selector, 1, other)
        );
        coverManager.purchaseCover(1);
        vm.stopPrank();
    }

    function test_purchaseCover_revertsIfAlreadyPurchased() external {
        vm.startPrank(user);
        stable.approve(address(coverManager), type(uint256).max);
        coverManager.purchaseCover(1);

        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.CoverAlreadyPurchased.selector, 1)
        );
        coverManager.purchaseCover(1);
        vm.stopPrank();
    }

    function test_isCovered_trueWhenActiveAndUnexpired() external {
        vm.startPrank(user);
        stable.approve(address(coverManager), type(uint256).max);
        coverManager.purchaseCover(1);
        vm.stopPrank();

        assertEq(coverManager.isCovered(1), true);
    }

    function test_isCovered_falseAfterExpiry() external {
        vm.startPrank(user);
        stable.approve(address(coverManager), type(uint256).max);
        coverManager.purchaseCover(1);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        assertEq(coverManager.isCovered(1), false);
    }

    function test_markClaimed_setsInactive() external {
        vm.startPrank(user);
        stable.approve(address(coverManager), type(uint256).max);
        coverManager.purchaseCover(1);
        vm.stopPrank();

        vm.prank(writer);
        coverManager.markClaimed(1);

        (, , , bool active) = coverManager.coverByPosition(1);
        assertEq(active, false);
    }

    function test_markClaimed_revertsIfInactive() external {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.CoverNotActive.selector, 1)
        );
        coverManager.markClaimed(1);
    }
}
