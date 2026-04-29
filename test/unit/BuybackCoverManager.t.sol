// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
import {ProtocolRevenueRouter} from "src/core/ProtocolRevenueRouter.sol";
import {BuybackCoverManager} from "src/core/BuybackCoverManager.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockInterestRateModelRevenue {
    function stabilizerShareBps(bytes32) external pure returns (uint256) {
        return 0;
    }

    function insuranceShareBps(bytes32) external pure returns (uint256) {
        return 0;
    }

    function treasuryShareBps(bytes32) external pure returns (uint256) {
        return 0;
    }
}

contract BuybackCoverManagerTest is Test {
    PositionRegistry internal positionRegistry;
    ParameterRegistry internal parameterRegistry;
    InsuranceReserve internal insuranceReserve;
    ProtocolRevenueRouter internal revenueRouter;
    BuybackCoverManager internal coverManager;
    MockERC20 internal stable;
    MockInterestRateModelRevenue internal irm;

    address internal owner = address(this);
    address internal user = address(0x1111);
    address internal other = address(0x2222);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 18);
        positionRegistry = new PositionRegistry(owner);
        parameterRegistry = new ParameterRegistry(owner);
        insuranceReserve = new InsuranceReserve(owner, address(stable));
        irm = new MockInterestRateModelRevenue();

        revenueRouter = new ProtocolRevenueRouter(owner, address(irm));
        revenueRouter.setRoute(
            BTC,
            address(stable),
            address(0x1111),
            address(0x2222),
            address(insuranceReserve),
            address(0x3333)
        );
        revenueRouter.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.InsurancePremium,
            0,
            0,
            10_000,
            0
        );

        coverManager = new BuybackCoverManager(
            owner,
            address(positionRegistry),
            address(parameterRegistry),
            address(insuranceReserve),
            address(stable),
            address(revenueRouter)
        );

        revenueRouter.setAuthorizedCollector(address(coverManager), true);
        positionRegistry.setAuthorizedWriter(address(this), true);
        insuranceReserve.setAuthorizedWriter(address(coverManager), true);

        parameterRegistry.setInsuranceParams(
            BTC,
            ParameterRegistry.InsuranceParams({
                baseSystemInsuranceRateBps: 200,
                baseOptionalCoverRateBps: 300,
                maxCoverageBps: 8000
            })
        );

        stable.mint(address(this), 1_000_000 ether);
        stable.mint(user, 1_000_000 ether);

        stable.approve(address(insuranceReserve), type(uint256).max);
        insuranceReserve.depositReserve(500_000 ether);

        positionRegistry.createPosition(user, BTC, 10 ether, 50_000 ether, true); // id 1

        vm.prank(user);
        stable.approve(address(coverManager), type(uint256).max);
    }

    function test_quoteCover_returnsExpectedValues() external view {
        (uint256 premium, uint256 coverageLimit, uint256 expiry) = coverManager.quoteCover(1);

        assertEq(coverageLimit, 40_000 ether);
        assertEq(premium, 1_200 ether);
        assertEq(expiry, block.timestamp + 30 days);
    }

    function test_quoteCover_revertsIfPositionNotEligible() external {
        positionRegistry.createPosition(user, BTC, 10 ether, 50_000 ether, false); // id 2

        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.PositionNotEligible.selector, 2)
        );
        coverManager.quoteCover(2);
    }

    function test_purchaseCover_storesTermsAndReservesInsurance() external {
        uint256 reserveBefore = stable.balanceOf(address(insuranceReserve));

        vm.prank(user);
        coverManager.purchaseCover(1);

        (
            uint256 premiumPaid,
            uint256 coverageLimit,
            uint256 expiry,
            bool active
        ) = coverManager.coverByPosition(1);

        assertEq(premiumPaid, 1_200 ether);
        assertEq(coverageLimit, 40_000 ether);
        assertEq(expiry, block.timestamp + 30 days);
        assertEq(active, true);

        // premium routed to insurance reserve via ProtocolRevenueRouter
        assertEq(stable.balanceOf(address(insuranceReserve)), reserveBefore + 1_200 ether);
        assertEq(insuranceReserve.coverReserveBalance(), 40_000 ether);
    }

    function test_purchaseCover_revertsIfAlreadyPurchased() external {
        vm.prank(user);
        coverManager.purchaseCover(1);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.CoverAlreadyActive.selector, 1)
        );
        coverManager.purchaseCover(1);
    }

    function test_purchaseCover_revertsIfNotPositionOwner() external {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.NotPositionOwner.selector, 1, other)
        );
        coverManager.purchaseCover(1);
    }

    function test_isCovered_trueWhenActiveAndUnexpired() external {
        vm.prank(user);
        coverManager.purchaseCover(1);

        assertEq(coverManager.isCovered(1), true);
    }

    function test_isCovered_falseAfterExpiry() external {
        vm.prank(user);
        coverManager.purchaseCover(1);

        vm.warp(block.timestamp + 31 days);

        assertEq(coverManager.isCovered(1), false);
    }

    function test_markClaimed_setsInactive() external {
        vm.prank(user);
        coverManager.purchaseCover(1);

        coverManager.markClaimed(1);

        (, , , bool active) = coverManager.coverByPosition(1);
        assertEq(active, false);
    }

    function test_markClaimed_revertsIfInactive() external {
        vm.expectRevert(
            abi.encodeWithSelector(BuybackCoverManager.InactiveCover.selector, 1)
        );
        coverManager.markClaimed(1);
    }
}
