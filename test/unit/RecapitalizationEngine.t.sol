// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PositionRegistry} from "src/core/PositionRegistry.sol";
import {RecapitalizationEngine} from "src/core/RecapitalizationEngine.sol";
import {StabilizationPool} from "src/vaults/StabilizationPool.sol";
import {InsuranceReserve} from "src/vaults/InsuranceReserve.sol";
import {TreasuryVault} from "src/vaults/TreasuryVault.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract RecapitalizationEngineTest is Test {
    PositionRegistry internal positionRegistry;
    StabilizationPool internal stabilizationPool;
    InsuranceReserve internal insuranceReserve;
    TreasuryVault internal treasuryVault;
    RecapitalizationEngine internal recapEngine;

    MockERC20 internal stable;
    MockERC20 internal btc;

    address internal owner = address(this);
    address internal writer = address(0xCAFE);
    address internal stabilizer = address(0x1111);
    address internal insurer = address(0x2222);

    bytes32 internal constant BTC = keccak256("BTC");

    function setUp() external {
        stable = new MockERC20("USD Coin", "USDC", 18);
        btc = new MockERC20("Wrapped BTC", "WBTC", 18);

        positionRegistry = new PositionRegistry(owner);
        stabilizationPool = new StabilizationPool(owner, address(stable), address(btc));
        insuranceReserve = new InsuranceReserve(owner, address(stable));
        treasuryVault = new TreasuryVault(owner, address(stable), address(btc));

        recapEngine = new RecapitalizationEngine(
            owner,
            address(stabilizationPool),
            address(insuranceReserve),
            address(treasuryVault),
            address(positionRegistry),
            address(stable)
        );

        recapEngine.setAuthorizedWriter(writer, true);

        positionRegistry.setAuthorizedWriter(address(this), true);
        stabilizationPool.setAuthorizedWriter(address(recapEngine), true);
        stabilizationPool.setSupportedAsset(BTC, true);
        insuranceReserve.setAuthorizedWriter(address(recapEngine), true);
        insuranceReserve.setAuthorizedWriter(address(this), true);

        stable.mint(stabilizer, 1_000_000 ether);
        stable.mint(insurer, 1_000_000 ether);
        stable.mint(address(recapEngine), 1_000_000 ether);

        vm.startPrank(stabilizer);
        stable.approve(address(stabilizationPool), type(uint256).max);
        stabilizationPool.depositStable(BTC, 100_000 ether);
        vm.stopPrank();

        vm.startPrank(insurer);
        stable.approve(address(insuranceReserve), type(uint256).max);
        insuranceReserve.depositReserve(100_000 ether);
        vm.stopPrank();

        positionRegistry.createPosition(address(0x1234), BTC, 10 ether, 50_000 ether, false); // id 1

        // Needed so InsuranceReserve.receiveRecovery(1, ...) has active exposure
        insuranceReserve.registerRecoveryReceivable(1, 10_000 ether);
    }

    function test_recordRecovery_updatesStorage() external {
        vm.prank(writer);
        recapEngine.recordRecovery(1, 10_000 ether);

        assertEq(recapEngine.recoveryByPosition(1), 10_000 ether);
        assertEq(recapEngine.pendingRecoveryByAsset(BTC), 10_000 ether);
    }

    function test_distributeRecovery_sendsWaterfallShares() external {
        vm.prank(writer);
        recapEngine.recordRecovery(1, 10_000 ether);

        vm.prank(writer);
        recapEngine.distributeRecovery(1);

        (uint256 stableLiquidity, , uint256 activeRescueExposure, uint256 recoveredProceeds) =
            stabilizationPool.pools(BTC);

        assertEq(stableLiquidity, 105_000 ether);
        assertEq(activeRescueExposure, 0);
        assertEq(recoveredProceeds, 5_000 ether);

        assertEq(insuranceReserve.totalReserveBalance(), 103_000 ether);
        assertEq(treasuryVault.stableBalance(), 2_000 ether);

        assertEq(recapEngine.recoveryByPosition(1), 0);
        assertEq(recapEngine.pendingRecoveryByAsset(BTC), 0);
    }

    function test_replenishStabilization_directly() external {
        vm.prank(writer);
        recapEngine.replenishStabilization(BTC, 4_000 ether);

        (uint256 stableLiquidity, , , uint256 recoveredProceeds) = stabilizationPool.pools(BTC);
        assertEq(stableLiquidity, 104_000 ether);
        assertEq(recoveredProceeds, 4_000 ether);
    }

    function test_replenishInsurance_directly() external {
        vm.prank(writer);
        recapEngine.replenishInsurance(1, 3_000 ether);

        assertEq(insuranceReserve.totalReserveBalance(), 103_000 ether);
    }

    function test_sendResidualToTreasury_directly() external {
        vm.prank(writer);
        recapEngine.sendResidualToTreasury(2_500 ether);

        assertEq(treasuryVault.stableBalance(), 2_500 ether);
    }

    function test_distributeRecovery_revertsIfNothingRecorded() external {
        vm.prank(writer);
        vm.expectRevert(
            abi.encodeWithSelector(RecapitalizationEngine.NoRecoveryRecorded.selector, 1)
        );
        recapEngine.distributeRecovery(1);
    }
}
