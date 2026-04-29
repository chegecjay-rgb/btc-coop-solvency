// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {DebtLedger} from "src/core/DebtLedger.sol";
import {CollateralManager} from "src/core/CollateralManager.sol";
import {BuybackCoverManager} from "src/core/BuybackCoverManager.sol";
import {BuybackClaimLedger} from "src/core/BuybackClaimLedger.sol";
import {BuybackFlashRouter} from "src/core/BuybackFlashRouter.sol";
import {ParameterRegistry} from "src/core/ParameterRegistry.sol";
import {ProtocolRevenueRouter} from "src/core/ProtocolRevenueRouter.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
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

contract MockLendingLiquidityVaultRevenue {
    MockERC20 public immutable token;
    uint256 public totalReceived;
    address public lastPayer;

    constructor(address token_) {
        token = MockERC20(token_);
    }

    function receiveRepaymentFrom(address payer, uint256 amount) external {
        token.transferFrom(payer, address(this), amount);
        totalReceived += amount;
        lastPayer = payer;
    }
}

contract MockStabilizationPoolRecovery {
    MockERC20 public immutable token;
    mapping(bytes32 => uint256) public totalRecoveredByAsset;

    constructor(address token_) {
        token = MockERC20(token_);
    }

    function receiveRecovery(bytes32 assetId, uint256 amount) external {
        totalRecoveredByAsset[assetId] += amount;
    }
}

contract MockInsuranceReserveRecovery {
    MockERC20 public immutable token;
    mapping(uint256 => uint256) public totalRecoveredByPosition;

    constructor(address token_) {
        token = MockERC20(token_);
    }

    function receiveRecovery(uint256 positionId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalRecoveredByPosition[positionId] += amount;
    }
}

contract MockTreasuryVaultRevenue {
    MockERC20 public immutable token;
    uint256 public totalReceived;

    constructor(address token_) {
        token = MockERC20(token_);
    }

    function receiveProtocolRevenue(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
    }
}

contract BuybackFlashRouterTest is Test {
    PositionRegistry internal positionRegistry;
    DebtLedger internal debtLedger;
    CollateralManager internal collateralManager;
    BuybackCoverManager internal coverManager;
    BuybackClaimLedger internal claimLedger;
    BuybackFlashRouter internal flashRouter;
    ParameterRegistry internal parameterRegistry;
    ProtocolRevenueRouter internal revenueRouter;
    InsuranceReserve internal insuranceReserve;
    MockERC20 internal stable;
    MockInterestRateModelRevenue internal irm;

    MockLendingLiquidityVaultRevenue internal lendingVault;
    MockStabilizationPoolRecovery internal stabilizationPool;
    MockInsuranceReserveRecovery internal insuranceRecovery;
    MockTreasuryVaultRevenue internal treasuryVault;

    address internal owner = address(this);
    address internal issuer = address(0xCAFE);
    address internal settler = address(0xBEEF);
    address internal user = address(0x1111);

    address internal flashProvider = address(0xAAA1);
    address internal swapAdapter = address(0xAAA2);
    address internal refinanceAdapter = address(0xAAA3);
    address internal badProvider = address(0xBAD1);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 18);

        positionRegistry = new PositionRegistry(owner);
        debtLedger = new DebtLedger(owner);
        collateralManager = new CollateralManager(owner);
        parameterRegistry = new ParameterRegistry(owner);
        insuranceReserve = new InsuranceReserve(owner, address(stable));
        irm = new MockInterestRateModelRevenue();

        lendingVault = new MockLendingLiquidityVaultRevenue(address(stable));
        stabilizationPool = new MockStabilizationPoolRecovery(address(stable));
        insuranceRecovery = new MockInsuranceReserveRecovery(address(stable));
        treasuryVault = new MockTreasuryVaultRevenue(address(stable));

        revenueRouter = new ProtocolRevenueRouter(owner, address(irm));
        revenueRouter.setRoute(
            BTC,
            address(stable),
            address(lendingVault),
            address(stabilizationPool),
            address(insuranceReserve), // used for premium routing
            address(treasuryVault)
        );
        revenueRouter.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.InsurancePremium,
            0,
            0,
            10_000,
            0
        );
        revenueRouter.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.RescueFee,
            0,
            0,
            0,
            10_000
        );
        revenueRouter.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.InsuranceCharge,
            0,
            0,
            0,
            10_000
        );
        revenueRouter.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.SettlementCost,
            0,
            0,
            0,
            10_000
        );

        coverManager = new BuybackCoverManager(
            owner,
            address(positionRegistry),
            address(parameterRegistry),
            address(insuranceReserve),
            address(stable),
            address(revenueRouter)
        );

        claimLedger = new BuybackClaimLedger(
            owner,
            address(debtLedger),
            address(collateralManager),
            address(positionRegistry),
            address(coverManager)
        );

        flashRouter = new BuybackFlashRouter(
            owner,
            address(claimLedger),
            address(collateralManager),
            address(positionRegistry)
        );

        flashRouter.setSettlementRouting(
            address(revenueRouter),
            address(lendingVault),
            address(stabilizationPool),
            address(insuranceRecovery)
        );

        revenueRouter.setAuthorizedCollector(address(coverManager), true);
        revenueRouter.setAuthorizedCollector(address(flashRouter), true);

        claimLedger.setAuthorizedIssuer(issuer, true);
        claimLedger.setAuthorizedIssuer(address(flashRouter), true);
        flashRouter.setAuthorizedSettler(settler, true);

        flashRouter.setApprovedFlashLoanProvider(flashProvider, true);
        flashRouter.setApprovedSwapAdapter(swapAdapter, true);
        flashRouter.setApprovedRefinanceAdapter(refinanceAdapter, true);

        positionRegistry.setAuthorizedWriter(address(this), true);
        debtLedger.setAuthorizedWriter(address(this), true);
        collateralManager.setAuthorizedWriter(address(this), true);
        collateralManager.setAuthorizedWriter(address(flashRouter), true);
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
        stable.mint(settler, 1_000_000 ether);

        stable.approve(address(insuranceReserve), type(uint256).max);
        insuranceReserve.depositReserve(500_000 ether);

        vm.prank(settler);
        stable.approve(address(flashRouter), type(uint256).max);

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

        vm.prank(issuer);
        claimLedger.issueClaim(1);
    }

    function test_quoteClosePath_returnsClaimData() external view {
        (
            uint256 totalRequired,
            uint256 collateralEntitlement,
            bool covered,
            bool settled,
            uint256 expiry
        ) = flashRouter.quoteClosePath(1);

        assertEq(totalRequired, 57_175 ether);
        assertEq(collateralEntitlement, 10 ether);
        assertEq(covered, true);
        assertEq(settled, false);
        assertGt(expiry, block.timestamp);
    }

    function test_closeWithFlashLoan_acceptsApprovedRoute() external {
        bytes memory params = abi.encode(
            flashProvider,
            swapAdapter,
            refinanceAdapter,
            57_175 ether
        );

        vm.prank(user);
        flashRouter.closeWithFlashLoan(1, params);
    }

    function test_closeWithFlashLoan_revertsIfProviderNotApproved() external {
        bytes memory params = abi.encode(
            badProvider,
            swapAdapter,
            refinanceAdapter,
            57_175 ether
        );

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackFlashRouter.FlashProviderNotApproved.selector,
                badProvider
            )
        );
        flashRouter.closeWithFlashLoan(1, params);
    }

    function test_closeWithFlashLoan_revertsIfNotPositionOwner() external {
        bytes memory params = abi.encode(
            flashProvider,
            swapAdapter,
            refinanceAdapter,
            57_175 ether
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackFlashRouter.NotPositionOwner.selector,
                1,
                address(this)
            )
        );
        flashRouter.closeWithFlashLoan(1, params);
    }

    function test_settleAndRelease_settlesClaimAndReleasesCollateral() external {
        vm.prank(settler);
        flashRouter.settleAndRelease(1);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool settled
        ) = claimLedger.claimByPosition(1);

        assertEq(settled, true);

        // terminal settlement decomposition
        assertEq(lendingVault.totalReceived(), 50_000 ether);
        assertEq(stabilizationPool.totalRecoveredByAsset(BTC), 5_000 ether);
        assertEq(insuranceRecovery.totalRecoveredByPosition(1), 2_000 ether);
        assertEq(treasuryVault.totalReceived(), 175 ether);

        // collateral released
        CollateralManager.CollateralRecord memory c =
            collateralManager.getCollateralRecord(1);

        assertEq(c.lockedCollateral, 0);
    }

    function test_settleAndRelease_revertsAfterExpiry() external {
        vm.warp(block.timestamp + 31 days);

        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(BuybackFlashRouter.ClaimExpired.selector, 1)
        );
        flashRouter.settleAndRelease(1);
    }
}
