// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StabilizationPool} from "src/vaults/StabilizationPool.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract StabilizationPoolTest is Test {
    StabilizationPool internal pool;
    MockERC20 internal stable;
    MockERC20 internal btc;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal nonAuthorized = address(0xBEEF);
    address internal alice = address(0x1111);
    address internal bob = address(0x2222);

    bytes32 internal constant BTC_ASSET = keccak256("BTC");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 6);
        btc = new MockERC20("Wrapped BTC", "WBTC", 8);

        pool = new StabilizationPool(owner, address(stable), address(btc));
        pool.setAuthorizedWriter(writer, true);
        pool.setSupportedAsset(BTC_ASSET, true);

        stable.mint(alice, 1_000_000e6);
        stable.mint(bob, 1_000_000e6);
        btc.mint(alice, 1_000_000_000);
        btc.mint(bob, 1_000_000_000);
    }

    function test_depositStable_updatesPoolAndShares() external {
        vm.startPrank(alice);
        stable.approve(address(pool), 100e6);
        uint256 shares = pool.depositStable(BTC_ASSET, 100e6);
        vm.stopPrank();

        (uint256 stableLiquidity, uint256 btcLiquidity,,) = pool.pools(BTC_ASSET);
        assertEq(shares, 100e6);
        assertEq(stableLiquidity, 100e6);
        assertEq(btcLiquidity, 0);
        assertEq(pool.depositorShares(BTC_ASSET, alice), 100e6);
        assertEq(pool.totalSharesByAsset(BTC_ASSET), 100e6);
    }

    function test_depositBTC_updatesPoolAndShares() external {
        vm.startPrank(alice);
        btc.approve(address(pool), 1000);
        uint256 shares = pool.depositBTC(BTC_ASSET, 1000);
        vm.stopPrank();

        (uint256 stableLiquidity, uint256 btcLiquidity,,) = pool.pools(BTC_ASSET);
        assertEq(shares, 1000);
        assertEq(stableLiquidity, 0);
        assertEq(btcLiquidity, 1000);
        assertEq(pool.depositorShares(BTC_ASSET, alice), 1000);
        assertEq(pool.totalSharesByAsset(BTC_ASSET), 1000);
    }

    function test_requestWithdraw_returnsProRataAssets() external {
        vm.startPrank(alice);
        stable.approve(address(pool), 100e6);
        btc.approve(address(pool), 1000);
        pool.depositStable(BTC_ASSET, 100e6);
        pool.depositBTC(BTC_ASSET, 1000);
        vm.stopPrank();

        vm.startPrank(bob);
        stable.approve(address(pool), 100e6);
        btc.approve(address(pool), 1000);
        pool.depositStable(BTC_ASSET, 100e6);
        pool.depositBTC(BTC_ASSET, 1000);
        vm.stopPrank();

        vm.prank(alice);
        (uint256 stableOut, uint256 btcOut) = pool.requestWithdraw(BTC_ASSET, 50_000_500);

        assertEq(stableOut, 50e6);
        assertEq(btcOut, 500);
    }

    function test_deployRescueCapital_reducesStableAndRaisesExposure() external {
        vm.startPrank(alice);
        stable.approve(address(pool), 100e6);
        pool.depositStable(BTC_ASSET, 100e6);
        vm.stopPrank();

        pool.deployRescueCapital(BTC_ASSET, 40e6);

        (uint256 stableLiquidity,, uint256 activeRescueExposure,) = pool.pools(BTC_ASSET);
        assertEq(stableLiquidity, 60e6);
        assertEq(activeRescueExposure, 40e6);
    }

    function test_receiveRecovery_reducesExposureAndAddsLiquidity() external {
        vm.startPrank(alice);
        stable.approve(address(pool), 100e6);
        pool.depositStable(BTC_ASSET, 100e6);
        vm.stopPrank();

        pool.deployRescueCapital(BTC_ASSET, 40e6);
        pool.receiveRecovery(BTC_ASSET, 25e6);

        (uint256 stableLiquidity,, uint256 activeRescueExposure, uint256 recoveredProceeds) =
            pool.pools(BTC_ASSET);

        assertEq(stableLiquidity, 85e6);
        assertEq(activeRescueExposure, 15e6);
        assertEq(recoveredProceeds, 25e6);
    }

    function test_receiveRecovery_zeroesExposureIfRecoveryExceedsIt() external {
        vm.startPrank(alice);
        stable.approve(address(pool), 100e6);
        pool.depositStable(BTC_ASSET, 100e6);
        vm.stopPrank();

        pool.deployRescueCapital(BTC_ASSET, 40e6);
        pool.receiveRecovery(BTC_ASSET, 50e6);

        (, , uint256 activeRescueExposure,) = pool.pools(BTC_ASSET);
        assertEq(activeRescueExposure, 0);
    }

    function test_availableRescueLiquidity_returnsStableLiquidity() external {
        vm.startPrank(alice);
        stable.approve(address(pool), 100e6);
        pool.depositStable(BTC_ASSET, 100e6);
        vm.stopPrank();

        assertEq(pool.availableRescueLiquidity(BTC_ASSET), 100e6);
    }

    function test_depositStable_revertsIfUnsupportedAsset() external {
        bytes32 x = keccak256("X");
        vm.startPrank(alice);
        stable.approve(address(pool), 1e6);
        vm.expectRevert(abi.encodeWithSelector(StabilizationPool.AssetNotSupported.selector, x));
        pool.depositStable(x, 1e6);
        vm.stopPrank();
    }

    function test_depositBTC_revertsIfUnsupportedAsset() external {
        bytes32 x = keccak256("X");
        vm.startPrank(alice);
        btc.approve(address(pool), 100);
        vm.expectRevert(abi.encodeWithSelector(StabilizationPool.AssetNotSupported.selector, x));
        pool.depositBTC(x, 100);
        vm.stopPrank();
    }

    function test_requestWithdraw_revertsIfInsufficientShares() external {
        vm.startPrank(alice);
        stable.approve(address(pool), 100e6);
        pool.depositStable(BTC_ASSET, 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                StabilizationPool.InsufficientShares.selector,
                101e6,
                100e6
            )
        );
        pool.requestWithdraw(BTC_ASSET, 101e6);
        vm.stopPrank();
    }

    function test_deployRescueCapital_revertsIfNotAuthorized() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(StabilizationPool.NotAuthorized.selector);
        pool.deployRescueCapital(BTC_ASSET, 1e6);
    }

    function test_deployRescueCapital_revertsIfInsufficientStable() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                StabilizationPool.InsufficientStableLiquidity.selector,
                1e6,
                0
            )
        );
        pool.deployRescueCapital(BTC_ASSET, 1e6);
    }

    function test_receiveRecovery_revertsIfNotAuthorized() external {
        vm.prank(nonAuthorized);
        vm.expectRevert(StabilizationPool.NotAuthorized.selector);
        pool.receiveRecovery(BTC_ASSET, 1e6);
    }

    function test_setAuthorizedWriter_revertsOnZeroAddress() external {
        vm.expectRevert(StabilizationPool.ZeroAddress.selector);
        pool.setAuthorizedWriter(address(0), true);
    }

    function test_setSupportedAsset_revertsOnZeroAssetId() external {
        vm.expectRevert(StabilizationPool.InvalidAssetId.selector);
        pool.setSupportedAsset(bytes32(0), true);
    }
}
