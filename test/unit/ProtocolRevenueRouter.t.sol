// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolRevenueRouter} from "src/core/ProtocolRevenueRouter.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract MockInterestRateModelRevenue {
    mapping(bytes32 => uint256) public stabilizerShare;
    mapping(bytes32 => uint256) public insuranceShare;
    mapping(bytes32 => uint256) public treasuryShare;

    function setShares(
        bytes32 assetId,
        uint256 stabilizerBps,
        uint256 insuranceBps,
        uint256 treasuryBps
    ) external {
        stabilizerShare[assetId] = stabilizerBps;
        insuranceShare[assetId] = insuranceBps;
        treasuryShare[assetId] = treasuryBps;
    }

    function stabilizerShareBps(bytes32 assetId) external view returns (uint256) {
        return stabilizerShare[assetId];
    }

    function insuranceShareBps(bytes32 assetId) external view returns (uint256) {
        return insuranceShare[assetId];
    }

    function treasuryShareBps(bytes32 assetId) external view returns (uint256) {
        return treasuryShare[assetId];
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

contract MockStabilizationPoolRevenue {
    MockERC20 public immutable token;
    mapping(bytes32 => uint256) public totalByAsset;

    constructor(address token_) {
        token = MockERC20(token_);
    }

    function depositStable(bytes32 assetId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalByAsset[assetId] += amount;
    }
}

contract MockInsuranceReserveRevenue {
    MockERC20 public immutable token;
    uint256 public totalReceived;

    constructor(address token_) {
        token = MockERC20(token_);
    }

    function depositReserve(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
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

contract ProtocolRevenueRouterTest is Test {
    ProtocolRevenueRouter internal router;
    MockERC20 internal stable;
    MockInterestRateModelRevenue internal irm;
    MockLendingLiquidityVaultRevenue internal lendingVault;
    MockStabilizationPoolRevenue internal stabilizationPool;
    MockInsuranceReserveRevenue internal insuranceReserve;
    MockTreasuryVaultRevenue internal treasuryVault;

    address internal owner = address(this);
    address internal collector = address(0xCAFE);
    address internal payer = address(0xBEEF);
    address internal other = address(0xDEAD);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockInterestRateModelRevenue();
        lendingVault = new MockLendingLiquidityVaultRevenue(address(stable));
        stabilizationPool = new MockStabilizationPoolRevenue(address(stable));
        insuranceReserve = new MockInsuranceReserveRevenue(address(stable));
        treasuryVault = new MockTreasuryVaultRevenue(address(stable));

        router = new ProtocolRevenueRouter(owner, address(irm));

        router.setAuthorizedCollector(collector, true);
        router.setRoute(
            BTC,
            address(stable),
            address(lendingVault),
            address(stabilizationPool),
            address(insuranceReserve),
            address(treasuryVault)
        );

        irm.setShares(BTC, 1000, 500, 500); // lender gets residual 8000

        stable.mint(payer, 1_000_000 ether);
        vm.prank(payer);
        stable.approve(address(router), type(uint256).max);
    }

    function test_previewDistribution_borrowInterest_usesInterestRateModel()
        external
        view
    {
        (
            uint256 lenderAmount,
            uint256 stabilizerAmount,
            uint256 insuranceAmount,
            uint256 treasuryAmount
        ) = router.previewDistribution(
                ProtocolRevenueRouter.FeeKind.BorrowInterest,
                BTC,
                100 ether
            );

        assertEq(lenderAmount, 80 ether);
        assertEq(stabilizerAmount, 10 ether);
        assertEq(insuranceAmount, 5 ether);
        assertEq(treasuryAmount, 5 ether);
    }

    function test_routeRevenueFrom_borrowInterest_routesExpectedAmounts() external {
        vm.prank(collector);
        router.routeRevenueFrom(
            ProtocolRevenueRouter.FeeKind.BorrowInterest,
            BTC,
            payer,
            100 ether
        );

        assertEq(lendingVault.totalReceived(), 80 ether);
        assertEq(stabilizationPool.totalByAsset(BTC), 10 ether);
        assertEq(insuranceReserve.totalReceived(), 5 ether);
        assertEq(treasuryVault.totalReceived(), 5 ether);
        assertEq(stable.balanceOf(address(router)), 0);
    }

    function test_setFeeSplit_andPreviewDistribution_forRescueFee() external {
        router.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.RescueFee,
            0,
            7000,
            2000,
            1000
        );

        (
            uint256 lenderAmount,
            uint256 stabilizerAmount,
            uint256 insuranceAmount,
            uint256 treasuryAmount
        ) = router.previewDistribution(
                ProtocolRevenueRouter.FeeKind.RescueFee,
                BTC,
                100 ether
            );

        assertEq(lenderAmount, 0);
        assertEq(stabilizerAmount, 70 ether);
        assertEq(insuranceAmount, 20 ether);
        assertEq(treasuryAmount, 10 ether);
    }

    function test_routeHeldRevenue_rescueFee_routesConfiguredSplit() external {
        router.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.RescueFee,
            0,
            7000,
            2000,
            1000
        );

        stable.mint(address(router), 100 ether);

        vm.prank(collector);
        router.routeHeldRevenue(
            ProtocolRevenueRouter.FeeKind.RescueFee,
            BTC,
            100 ether
        );

        assertEq(lendingVault.totalReceived(), 0);
        assertEq(stabilizationPool.totalByAsset(BTC), 70 ether);
        assertEq(insuranceReserve.totalReceived(), 20 ether);
        assertEq(treasuryVault.totalReceived(), 10 ether);
        assertEq(stable.balanceOf(address(router)), 0);
    }

    function test_routeHeldRevenue_insurancePremium_canBe100PercentInsurance() external {
        router.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.InsurancePremium,
            0,
            0,
            10_000,
            0
        );

        stable.mint(address(router), 50 ether);

        vm.prank(collector);
        router.routeHeldRevenue(
            ProtocolRevenueRouter.FeeKind.InsurancePremium,
            BTC,
            50 ether
        );

        assertEq(lendingVault.totalReceived(), 0);
        assertEq(stabilizationPool.totalByAsset(BTC), 0);
        assertEq(insuranceReserve.totalReceived(), 50 ether);
        assertEq(treasuryVault.totalReceived(), 0);
    }

    function test_routeHeldRevenue_settlementCost_canBe100PercentTreasury() external {
        router.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.SettlementCost,
            0,
            0,
            0,
            10_000
        );

        stable.mint(address(router), 25 ether);

        vm.prank(collector);
        router.routeHeldRevenue(
            ProtocolRevenueRouter.FeeKind.SettlementCost,
            BTC,
            25 ether
        );

        assertEq(treasuryVault.totalReceived(), 25 ether);
    }

    function test_routeRevenueFrom_revertsIfNotAuthorizedCollector() external {
        vm.prank(other);
        vm.expectRevert(ProtocolRevenueRouter.NotAuthorizedCollector.selector);
        router.routeRevenueFrom(
            ProtocolRevenueRouter.FeeKind.BorrowInterest,
            BTC,
            payer,
            100 ether
        );
    }

    function test_routeRevenueFrom_revertsIfRouteNotConfigured() external {
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolRevenueRouter.RouteNotConfigured.selector,
                bytes32("ETH")
            )
        );
        router.routeRevenueFrom(
            ProtocolRevenueRouter.FeeKind.BorrowInterest,
            bytes32("ETH"),
            payer,
            100 ether
        );
    }

    function test_routeHeldRevenue_revertsIfSplitNotConfiguredForNonBorrow() external {
        stable.mint(address(router), 100 ether);

        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolRevenueRouter.SplitNotConfigured.selector,
                BTC,
                uint8(ProtocolRevenueRouter.FeeKind.RescueFee)
            )
        );
        router.routeHeldRevenue(
            ProtocolRevenueRouter.FeeKind.RescueFee,
            BTC,
            100 ether
        );
    }

    function test_setFeeSplit_revertsIfTotalIsInvalid() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolRevenueRouter.InvalidSplitBps.selector,
                uint256(9000)
            )
        );
        router.setFeeSplit(
            BTC,
            ProtocolRevenueRouter.FeeKind.RemoteLiquidityFee,
            0,
            4000,
            2000,
            3000
        );
    }

    function test_routeRevenueFrom_revertsOnZeroAmount() external {
        vm.prank(collector);
        vm.expectRevert(ProtocolRevenueRouter.InvalidAmount.selector);
        router.routeRevenueFrom(
            ProtocolRevenueRouter.FeeKind.BorrowInterest,
            BTC,
            payer,
            0
        );
    }

    function test_routeRevenueFrom_revertsOnZeroPayer() external {
        vm.prank(collector);
        vm.expectRevert(ProtocolRevenueRouter.ZeroAddress.selector);
        router.routeRevenueFrom(
            ProtocolRevenueRouter.FeeKind.BorrowInterest,
            BTC,
            address(0),
            1 ether
        );
    }
}
