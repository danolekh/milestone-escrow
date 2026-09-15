// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MilestoneEscrow} from "../../src/MilestoneEscrow.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev Stateful fuzzing handler. Every action picks an existing job and only calls the escrow when
///      the preconditions hold, so the invariant suite runs with `fail_on_revert = true`: any revert
///      the handler did not anticipate is a bug in either the contract or the handler's model.
///
///      Ghost state is maintained independently of the contract's views so the invariants are not
///      tautological.
contract Handler is Test {
    MilestoneEscrow public immutable ESCROW;
    MockUSDC[] public tokens;
    address[] public clients;
    address[] public freelancers;

    uint32 internal constant MIN_WINDOW = 1 hours;
    uint32 internal constant MAX_WINDOW = 90 days;
    /// @dev Starting balance minted to every client for every token.
    uint256 public constant INITIAL_CLIENT_BALANCE = type(uint128).max;

    // ---- ghost state ---------------------------------------------------------------------------

    /// @dev Expected escrow balance per token: funded minus paid out minus refunded.
    mapping(address token => uint256) public ghostHeld;
    /// @dev Total ever paid to each freelancer per token.
    mapping(address token => mapping(address freelancer => uint256)) public ghostPaid;
    /// @dev Total ever refunded to each client per token.
    mapping(address token => mapping(address client => uint256)) public ghostRefunded;
    /// @dev Total ever deposited by each client per token.
    mapping(address token => mapping(address client => uint256)) public ghostFunded;
    /// @dev Number of times a milestone has been paid out (released or claimed). Must never exceed 1.
    mapping(uint256 jobId => mapping(uint256 idx => uint256)) public payoutCount;
    /// @dev Tracks whether a milestone was ever refunded, to prove it is never also paid.
    mapping(uint256 jobId => mapping(uint256 idx => bool)) public refunded;

    uint256 public jobCount;
    uint256 public maxPayoutCount;
    bool public paidAndRefunded;

    // ---- call counters (for suite sanity, printed by the invariant test) ------------------------

    uint256 public calls_createJob;
    uint256 public calls_fund;
    uint256 public calls_submit;
    uint256 public calls_release;
    uint256 public calls_claimExpired;
    uint256 public calls_cancel;

    constructor(MilestoneEscrow escrow_, MockUSDC[] memory tokens_, address[] memory clients_, address[] memory frs_) {
        ESCROW = escrow_;
        tokens = tokens_;
        clients = clients_;
        freelancers = frs_;

        for (uint256 c = 0; c < clients.length; ++c) {
            for (uint256 t = 0; t < tokens.length; ++t) {
                tokens[t].mint(clients[c], INITIAL_CLIENT_BALANCE);
                vm.prank(clients[c]);
                tokens[t].approve(address(escrow_), type(uint256).max);
            }
        }
    }

    // ---- actions -------------------------------------------------------------------------------

    function createJob(uint256 seed, uint8 count, uint256 amountSeed, uint32 window) external {
        address client = clients[seed % clients.length];
        address freelancer = freelancers[(seed >> 8) % freelancers.length];
        MockUSDC token = tokens[(seed >> 16) % tokens.length];
        uint256 n = bound(count, 1, 6);
        window = uint32(bound(window, MIN_WINDOW, MAX_WINDOW));

        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, 1e12);
        }

        vm.prank(client);
        ESCROW.createJob(freelancer, IERC20(address(token)), amounts, window);
        ++jobCount;
        ++calls_createJob;
    }

    function fund(uint256 seed) external {
        if (jobCount == 0) return;
        uint256 jobId = seed % jobCount;
        MilestoneEscrow.JobInfo memory job = ESCROW.getJob(jobId);
        if (job.status != MilestoneEscrow.JobStatus.Created) return;

        vm.prank(job.client);
        ESCROW.fund(jobId);
        ghostHeld[address(job.token)] += job.total;
        ghostFunded[address(job.token)][job.client] += job.total;
        ++calls_fund;
    }

    function submit(uint256 seed) external {
        if (jobCount == 0) return;
        uint256 jobId = seed % jobCount;
        MilestoneEscrow.JobInfo memory job = ESCROW.getJob(jobId);
        if (job.status != MilestoneEscrow.JobStatus.Funded) return;
        uint256 idx = job.cursor;
        if (ESCROW.milestone(jobId, idx).status != MilestoneEscrow.MilestoneStatus.Pending) return;

        vm.prank(job.freelancer);
        ESCROW.submit(jobId, idx);
        ++calls_submit;
    }

    function release(uint256 seed) external {
        if (jobCount == 0) return;
        uint256 jobId = seed % jobCount;
        MilestoneEscrow.JobInfo memory job = ESCROW.getJob(jobId);
        if (job.status != MilestoneEscrow.JobStatus.Funded && job.status != MilestoneEscrow.JobStatus.Cancelled) {
            return;
        }
        if (job.cursor >= job.milestoneCount) return;
        uint256 idx = job.cursor;
        MilestoneEscrow.Milestone memory m = ESCROW.milestone(jobId, idx);
        if (m.status != MilestoneEscrow.MilestoneStatus.Submitted) return;

        vm.prank(job.client);
        ESCROW.release(jobId, idx);
        _recordPayout(jobId, idx, address(job.token), job.freelancer, m.amount);
        ++calls_release;
    }

    function claimExpired(uint256 seed, uint32 warpBy) external {
        if (jobCount == 0) return;
        uint256 jobId = seed % jobCount;
        MilestoneEscrow.JobInfo memory job = ESCROW.getJob(jobId);
        if (job.status != MilestoneEscrow.JobStatus.Funded && job.status != MilestoneEscrow.JobStatus.Cancelled) {
            return;
        }
        if (job.cursor >= job.milestoneCount) return;
        uint256 idx = job.cursor;
        MilestoneEscrow.Milestone memory m = ESCROW.milestone(jobId, idx);
        if (m.status != MilestoneEscrow.MilestoneStatus.Submitted) return;

        // Sometimes wait exactly to the boundary, sometimes beyond it, sometimes not enough.
        uint256 claimableAt = uint256(m.submittedAt) + job.reviewWindow;
        vm.warp(block.timestamp + bound(warpBy, 0, MAX_WINDOW + 1 days));
        if (block.timestamp < claimableAt) {
            vm.expectRevert(
                abi.encodeWithSelector(MilestoneEscrow.ReviewWindowNotElapsed.selector, uint64(claimableAt))
            );
            vm.prank(job.freelancer);
            ESCROW.claimExpired(jobId, idx);
            return;
        }

        vm.prank(job.freelancer);
        ESCROW.claimExpired(jobId, idx);
        _recordPayout(jobId, idx, address(job.token), job.freelancer, m.amount);
        ++calls_claimExpired;
    }

    function cancel(uint256 seed, bool byFreelancer) external {
        if (jobCount == 0) return;
        uint256 jobId = seed % jobCount;
        MilestoneEscrow.JobInfo memory job = ESCROW.getJob(jobId);
        if (job.status != MilestoneEscrow.JobStatus.Created && job.status != MilestoneEscrow.JobStatus.Funded) {
            return;
        }

        uint256 expectedRefund;
        if (job.status == MilestoneEscrow.JobStatus.Funded) {
            for (uint256 i = job.cursor; i < job.milestoneCount; ++i) {
                MilestoneEscrow.Milestone memory m = ESCROW.milestone(jobId, i);
                if (m.status == MilestoneEscrow.MilestoneStatus.Pending) {
                    expectedRefund += m.amount;
                    refunded[jobId][i] = true;
                    if (payoutCount[jobId][i] != 0) paidAndRefunded = true;
                }
            }
        }

        vm.prank(byFreelancer ? job.freelancer : job.client);
        ESCROW.cancel(jobId);

        ghostHeld[address(job.token)] -= expectedRefund;
        ghostRefunded[address(job.token)][job.client] += expectedRefund;
        ++calls_cancel;
    }

    // ---- internals -----------------------------------------------------------------------------

    function _recordPayout(uint256 jobId, uint256 idx, address token, address freelancer, uint256 amount) internal {
        uint256 c = ++payoutCount[jobId][idx];
        if (c > maxPayoutCount) maxPayoutCount = c;
        if (refunded[jobId][idx]) paidAndRefunded = true;
        ghostHeld[token] -= amount;
        ghostPaid[token][freelancer] += amount;
    }

    // ---- views for the invariant contract ------------------------------------------------------

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function clientCount() external view returns (uint256) {
        return clients.length;
    }

    function freelancerCount() external view returns (uint256) {
        return freelancers.length;
    }
}
