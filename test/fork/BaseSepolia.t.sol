// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MilestoneEscrow} from "../../src/MilestoneEscrow.sol";

/// @dev End-to-end flow against the real USDC (Circle FiatTokenV2) on Base Sepolia.
///      Skipped unless `BASE_SEPOLIA_RPC_URL` is set. Balances are seeded with `deal`.
contract BaseSepoliaForkTest is Test {
    IERC20 internal constant USDC = IERC20(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    MilestoneEscrow internal escrow;
    address internal client = makeAddr("client");
    address internal freelancer = makeAddr("freelancer");
    uint256[] internal amounts;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID, "not Base Sepolia");

        escrow = new MilestoneEscrow();
        amounts.push(120e6);
        amounts.push(80e6);

        deal(address(USDC), client, 1000e6);
        vm.prank(client);
        USDC.approve(address(escrow), type(uint256).max);
    }

    function test_fork_usdcHasSixDecimals() public view {
        assertEq(IERC20Metadata(address(USDC)).decimals(), 6);
    }

    function test_fork_fullFlowWithRealUsdc() public {
        vm.startPrank(client);
        uint256 jobId = escrow.createJob(freelancer, USDC, amounts, 2 days);
        escrow.fund(jobId);
        vm.stopPrank();
        assertEq(USDC.balanceOf(address(escrow)), 200e6);
        assertEq(USDC.balanceOf(client), 800e6);

        // Milestone 0: released by the client.
        vm.prank(freelancer);
        escrow.submit(jobId, 0);
        vm.prank(client);
        escrow.release(jobId, 0);
        assertEq(USDC.balanceOf(freelancer), 120e6);

        // Milestone 1: client goes silent, freelancer claims after the window.
        vm.prank(freelancer);
        escrow.submit(jobId, 1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(freelancer);
        escrow.claimExpired(jobId, 1);

        assertEq(USDC.balanceOf(freelancer), 200e6);
        assertEq(USDC.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.getJob(jobId).status), uint8(MilestoneEscrow.JobStatus.Completed));
    }

    function test_fork_cancelRefundsRealUsdc() public {
        vm.startPrank(client);
        uint256 jobId = escrow.createJob(freelancer, USDC, amounts, 2 days);
        escrow.fund(jobId);
        vm.stopPrank();

        vm.prank(freelancer);
        escrow.submit(jobId, 0);
        vm.prank(client);
        escrow.cancel(jobId);

        assertEq(USDC.balanceOf(client), 1000e6 - 120e6, "only the unsubmitted milestone refunded");
        assertEq(USDC.balanceOf(address(escrow)), 120e6);
        assertEq(escrow.fundedUnreleased(jobId), 120e6);
    }
}
