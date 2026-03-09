// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";
import {BuybackCoverManager} from "src/core/BuybackCoverManager.sol";
import {BuybackClaimLedger} from "src/core/BuybackClaimLedger.sol";
import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract BuybackClaimLedgerTest is Test {
    PositionRegistry internal positionRegistry;
    DebtLedger internal debtLedger;
    CollateralManager internal collateralManager;
    BuybackCoverManager internal coverManager;
    BuybackClaimLedger internal claimLedger;
    ParameterRegistry internal parameterRegistry;
    InsuranceReserve internal insuranceReserve;
    MockERC20 internal stable;

    address internal owner = address(this);
    address internal issuer = address(0xCAFE);
    address internal user = address(0x1111);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 18);

        positionRegistry = new PositionRegistry(owner);
        debtLedger = new DebtLedger(owner);
        collateralManager = new CollateralManager(owner);
        parameterRegistry = new ParameterRegistry(owner);
        insuranceReserve = new InsuranceReserve(owner, address(stable));

        coverManager = new BuybackCoverManager(
            owner,
            address(positionRegistry),
            address(parameterRegistry),
            address(insuranceReserve),
            address(stable)
        );

        claimLedger = new BuybackClaimLedger(
            owner,
            address(debtLedger),
            address(collateralManager),
            address(positionRegistry),
            address(coverManager)
        );

        claimLedger.setAuthorizedIssuer(issuer, true);

        positionRegistry.setAuthorizedWriter(address(this), true);
        debtLedger.setAuthorizedWriter(address(this), true);
        collateralManager.setAuthorizedWriter(address(this), true);
        insuranceReserve.setAuthorizedWriter(address(coverManager), true);

        parameterRegistry.setInsuranceParams(
            BTC,
            ParameterRegistry.InsuranceParams({
                baseSystemInsuranceRateBps: 200,
                baseOptionalCoverRateBps: 300,
                maxCoverageBps: 8000
            })
        );

        stable.mint(user, 1_000_000 ether);
        stable.mint(address(this), 1_000_000 ether);

        stable.approve(address(insuranceReserve), type(uint256).max);
        insuranceReserve.depositReserve(500_000 ether);

        positionRegistry.createPosition(user, BTC, 10 ether, 50_000 ether, true); // id 1
        debtLedger.initializeDebtRecord(1, 50_000 ether);
        debtLedger.recordRescueUsage(1, 5_000 ether, 100 ether);
        debtLedger.recordInsuranceUsage(1, 2_000 ether, 50 ether);
        debtLedger.recordSettlementCost(1, 25 ether);

        collateralManager.initializeCollateralRecord(1, 10 ether);
        collateralManager.lockCollateral(1, 10 ether);

        vm.startPrank(user);
        stable.approve(address(coverManager), type(uint256).max);
        coverManager.purchaseCover(1);
        vm.stopPrank();
    }

    function test_issueClaim_storesComputedClaim() external {
        vm.prank(issuer);
        claimLedger.issueClaim(1);

        (
            uint256 debtOutstanding,
            uint256 accruedInterest,
            uint256 rescueCapitalUsed,
            uint256 rescueFees,
            uint256 insuranceCapitalUsed,
            uint256 insuranceCharges,
            uint256 settlementCosts,
            uint256 totalRepaymentRequired,
            uint256 collateralEntitlement,
            uint256 expiry,
            bool covered,
            bool settled
        ) = claimLedger.claimByPosition(1);

        assertEq(debtOutstanding, 50_000 ether);
        assertEq(accruedInterest, 0);
        assertEq(rescueCapitalUsed, 5_000 ether);
        assertEq(rescueFees, 100 ether);
        assertEq(insuranceCapitalUsed, 2_000 ether);
        assertEq(insuranceCharges, 50 ether);
        assertEq(settlementCosts, 25 ether);
        assertEq(totalRepaymentRequired, 57_175 ether);
        assertEq(collateralEntitlement, 10 ether);
        assertGt(expiry, block.timestamp);
        assertEq(covered, true);
        assertEq(settled, false);
    }

    function test_issueClaim_revertsIfAlreadyIssued() external {
        vm.prank(issuer);
        claimLedger.issueClaim(1);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackClaimLedger.ClaimAlreadyIssued.selector, 1)
        );
        claimLedger.issueClaim(1);
    }

    function test_getTotalRequired_returnsExpectedValue() external {
        vm.prank(issuer);
        claimLedger.issueClaim(1);

        assertEq(claimLedger.getTotalRequired(1), 57_175 ether);
    }

    function test_settleClaim_marksSettled() external {
        vm.prank(issuer);
        claimLedger.issueClaim(1);

        vm.prank(issuer);
        claimLedger.settleClaim(1, 57_175 ether);

        (, , , , , , , , , , , bool settled) = claimLedger.claimByPosition(1);
        assertEq(settled, true);
    }

    function test_settleClaim_revertsIfAmountTooLow() external {
        vm.prank(issuer);
        claimLedger.issueClaim(1);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackClaimLedger.InvalidSettlementAmount.selector,
                57_000 ether,
                57_175 ether
            )
        );
        claimLedger.settleClaim(1, 57_000 ether);
    }

    function test_expireClaim_afterExpiry() external {
        vm.prank(issuer);
        claimLedger.issueClaim(1);

        vm.warp(block.timestamp + 31 days);

        vm.prank(issuer);
        claimLedger.expireClaim(1);
    }
}
