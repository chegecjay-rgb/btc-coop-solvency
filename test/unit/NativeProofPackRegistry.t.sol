// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {NativeProofPackRegistry} from "src/native/NativeProofPackRegistry.sol";

contract NativeProofPackRegistryTest is Test {
    NativeProofPackRegistry internal registry;

    address internal owner = address(0xA11CE);
    address internal submitter = address(0xB0B);
    address internal stranger = address(0xBAD);

    uint256 internal constant POSITION_ID = 1;
    bytes32 internal constant PLEDGE_ID = keccak256("pledge-id");
    bytes32 internal constant DIGEST = keccak256("proof-pack-digest");
    string internal constant URI = "ipfs://native-proof-pack";

    function setUp() external {
        vm.warp(1_000_000);

        registry = new NativeProofPackRegistry(owner);

        vm.prank(owner);
        registry.setAuthorizedSubmitter(submitter, true);
    }

    function test_submitProofPack_storesProofPackAndIndexesByPosition() external {
        vm.prank(submitter);
        bytes32 proofRef =
            registry.submitProofPack(POSITION_ID, PLEDGE_ID, NativeProofPackRegistry.ProofPackKind.Pledge, DIGEST, URI);

        NativeProofPackRegistry.ProofPack memory proofPack = registry.getProofPack(proofRef);

        assertTrue(registry.hasProofPack(proofRef));

        assertEq(proofPack.proofRef, proofRef);
        assertEq(proofPack.positionId, POSITION_ID);
        assertEq(proofPack.pledgeId, PLEDGE_ID);
        assertEq(uint256(proofPack.kind), uint256(NativeProofPackRegistry.ProofPackKind.Pledge));
        assertEq(proofPack.digest, DIGEST);
        assertEq(keccak256(bytes(proofPack.uri)), keccak256(bytes(URI)));
        assertEq(proofPack.submitter, submitter);
        assertEq(proofPack.submittedAt, uint64(block.timestamp));

        bytes32[] memory refs = registry.proofRefsOfPosition(POSITION_ID);

        assertEq(refs.length, 1);
        assertEq(refs[0], proofRef);
    }

    function test_submitProofPack_rejectsUnauthorizedSubmitter() external {
        vm.prank(stranger);
        vm.expectRevert(NativeProofPackRegistry.NotAuthorized.selector);
        registry.submitProofPack(POSITION_ID, PLEDGE_ID, NativeProofPackRegistry.ProofPackKind.Pledge, DIGEST, URI);
    }

    function test_submitProofPack_rejectsDuplicateProofRef() external {
        vm.prank(submitter);
        bytes32 proofRef =
            registry.submitProofPack(POSITION_ID, PLEDGE_ID, NativeProofPackRegistry.ProofPackKind.Pledge, DIGEST, URI);

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(NativeProofPackRegistry.ProofPackAlreadySubmitted.selector, proofRef));
        registry.submitProofPack(POSITION_ID, PLEDGE_ID, NativeProofPackRegistry.ProofPackKind.Pledge, DIGEST, URI);
    }

    function test_submitProofPack_revertsOnInvalidProofPackData() external {
        vm.prank(submitter);
        vm.expectRevert(NativeProofPackRegistry.InvalidPositionId.selector);
        registry.submitProofPack(0, PLEDGE_ID, NativeProofPackRegistry.ProofPackKind.Pledge, DIGEST, URI);

        vm.prank(submitter);
        vm.expectRevert(NativeProofPackRegistry.InvalidProofPackKind.selector);
        registry.submitProofPack(POSITION_ID, PLEDGE_ID, NativeProofPackRegistry.ProofPackKind.Unset, DIGEST, URI);

        vm.prank(submitter);
        vm.expectRevert(NativeProofPackRegistry.InvalidDigest.selector);
        registry.submitProofPack(POSITION_ID, PLEDGE_ID, NativeProofPackRegistry.ProofPackKind.Pledge, bytes32(0), URI);
    }
}
