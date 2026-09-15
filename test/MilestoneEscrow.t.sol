// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract MilestoneEscrowTest is Test {
    MilestoneEscrow internal escrow;
    MockUSDC internal usdc;

    address internal client = makeAddr("client");
    address internal freelancer = makeAddr("freelancer");
    address internal stranger = makeAddr("stranger");

    uint32 internal constant WINDOW = 3 days;
    uint256[] internal amounts;
    uint256 internal total;

    function setUp() public {
        escrow = new MilestoneEscrow();
        usdc = new MockUSDC();

        amounts.push(100e6);
        amounts.push(250e6);
        amounts.push(50e6);
        total = 400e6;

        usdc.mint(client, 10_000e6);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);

        // Deterministic, non-zero starting time so `submittedAt + window` arithmetic is meaningful.
        vm.warp(1_700_000_000);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _create() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = escrow.createJob(freelancer, IERC20(address(usdc)), amounts, WINDOW);
    }

    function _createFunded() internal returns (uint256 jobId) {
        jobId = _create();
        vm.prank(client);
        escrow.fund(jobId);
    }

    function _submit(uint256 jobId, uint256 idx) internal {
        vm.prank(freelancer);
        escrow.submit(jobId, idx);
    }

    function _release(uint256 jobId, uint256 idx) internal {
        vm.prank(client);
        escrow.release(jobId, idx);
    }

    function _claim(uint256 jobId, uint256 idx) internal {
        vm.prank(freelancer);
        escrow.claimExpired(jobId, idx);
    }

    function _status(uint256 jobId) internal view returns (MilestoneEscrow.JobStatus) {
        return escrow.getJob(jobId).status;
    }

    function _mStatus(uint256 jobId, uint256 idx) internal view returns (MilestoneEscrow.MilestoneStatus) {
        return escrow.milestone(jobId, idx).status;
    }

    // ---------------------------------------------------------------------------------------------
    // createJob
    // ---------------------------------------------------------------------------------------------

    function test_createJob_storesJobAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit MilestoneEscrow.JobCreated(0, client, freelancer, IERC20(address(usdc)), amounts, WINDOW);
        uint256 jobId = _create();

        assertEq(jobId, 0);
        assertEq(escrow.jobCount(), 1);

        MilestoneEscrow.JobInfo memory info = escrow.getJob(jobId);
        assertEq(info.client, client);
        assertEq(info.freelancer, freelancer);
        assertEq(address(info.token), address(usdc));
        assertEq(info.reviewWindow, WINDOW);
        assertEq(uint8(info.status), uint8(MilestoneEscrow.JobStatus.Created));
        assertEq(info.cursor, 0);
        assertEq(info.milestoneCount, 3);
        assertEq(info.total, total);

        MilestoneEscrow.Milestone[] memory ms = escrow.getMilestones(jobId);
        assertEq(ms.length, 3);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(ms[i].amount, amounts[i]);
            assertEq(ms[i].submittedAt, 0);
            assertEq(uint8(ms[i].status), uint8(MilestoneEscrow.MilestoneStatus.Pending));
        }
        assertEq(escrow.fundedUnreleased(jobId), 0, "unfunded job holds nothing");
    }

    function test_createJob_sequentialIds() public {
        assertEq(_create(), 0);
        assertEq(_create(), 1);
        assertEq(_create(), 2);
        assertEq(escrow.jobCount(), 3);
    }

    function test_createJob_acceptsWindowBounds() public {
        vm.startPrank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), amounts, escrow.MIN_REVIEW_WINDOW());
        escrow.createJob(freelancer, IERC20(address(usdc)), amounts, escrow.MAX_REVIEW_WINDOW());
        vm.stopPrank();
        assertEq(escrow.jobCount(), 2);
    }

    function test_createJob_revert_zeroFreelancer() public {
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector);
        vm.prank(client);
        escrow.createJob(address(0), IERC20(address(usdc)), amounts, WINDOW);
    }

    function test_createJob_revert_zeroToken() public {
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector);
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(0)), amounts, WINDOW);
    }

    function test_createJob_revert_sameParty() public {
        vm.expectRevert(MilestoneEscrow.SameParty.selector);
        vm.prank(client);
        escrow.createJob(client, IERC20(address(usdc)), amounts, WINDOW);
    }

    function test_createJob_revert_emptyMilestones() public {
        uint256[] memory empty;
        vm.expectRevert(MilestoneEscrow.NoMilestones.selector);
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), empty, WINDOW);
    }

    function test_createJob_revert_zeroAmount() public {
        uint256[] memory bad = new uint256[](3);
        bad[0] = 1;
        bad[1] = 0;
        bad[2] = 1;
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ZeroAmount.selector, 1));
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), bad, WINDOW);
    }

    function test_createJob_revert_windowTooShort() public {
        uint32 w = 1 hours - 1;
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ReviewWindowOutOfRange.selector, w));
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), amounts, w);
    }

    function test_createJob_revert_windowTooLong() public {
        uint32 w = 90 days + 1;
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ReviewWindowOutOfRange.selector, w));
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), amounts, w);
    }

    function test_createJob_revert_windowZero() public {
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ReviewWindowOutOfRange.selector, uint32(0)));
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), amounts, 0);
    }

    function test_createJob_revert_amountExceedsUint128() public {
        uint256[] memory big = new uint256[](1);
        big[0] = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, big[0]));
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), big, WINDOW);
    }

    function test_createJob_largeAmountsSumWithoutOverflow() public {
        uint256[] memory big = new uint256[](3);
        big[0] = type(uint128).max;
        big[1] = type(uint128).max;
        big[2] = type(uint128).max;
        // Three uint128 max values sum well within uint256, so this must succeed.
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), big, WINDOW);
        assertEq(escrow.getJob(0).total, 3 * uint256(type(uint128).max));
    }

    // ---------------------------------------------------------------------------------------------
    // fund
    // ---------------------------------------------------------------------------------------------

    function test_fund_pullsTotalAndEmits() public {
        uint256 jobId = _create();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.expectEmit(true, false, false, true);
        emit MilestoneEscrow.JobFunded(jobId, total);
        vm.prank(client);
        escrow.fund(jobId);

        assertEq(usdc.balanceOf(client), clientBefore - total);
        assertEq(usdc.balanceOf(address(escrow)), total);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Funded));
        assertEq(escrow.fundedUnreleased(jobId), total);
    }

    function test_fund_revert_notClient() public {
        uint256 jobId = _create();
        vm.expectRevert(MilestoneEscrow.NotClient.selector);
        vm.prank(freelancer);
        escrow.fund(jobId);
    }

    function test_fund_revert_twice() public {
        uint256 jobId = _createFunded();
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Funded)
        );
        vm.prank(client);
        escrow.fund(jobId);
    }

    function test_fund_revert_afterCancel() public {
        uint256 jobId = _create();
        vm.prank(client);
        escrow.cancel(jobId);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Cancelled)
        );
        vm.prank(client);
        escrow.fund(jobId);
    }

    function test_fund_revert_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.JobNotFound.selector, 7));
        vm.prank(client);
        escrow.fund(7);
    }

    function test_fund_revert_withoutApproval() public {
        uint256 jobId = _create();
        vm.prank(client);
        usdc.approve(address(escrow), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, total)
        );
        vm.prank(client);
        escrow.fund(jobId);
    }

    function test_fund_revert_insufficientBalance() public {
        address poor = makeAddr("poor");
        vm.startPrank(poor);
        usdc.approve(address(escrow), type(uint256).max);
        uint256 jobId = escrow.createJob(freelancer, IERC20(address(usdc)), amounts, WINDOW);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, total));
        escrow.fund(jobId);
        vm.stopPrank();
    }

    function test_fund_revert_feeOnTransferToken() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(100); // 1 %
        fee.mint(client, 1000e6);
        vm.startPrank(client);
        fee.approve(address(escrow), type(uint256).max);
        uint256 jobId = escrow.createJob(freelancer, IERC20(address(fee)), amounts, WINDOW);

        uint256 expectedReceived = total - total / 100;
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.UnsupportedToken.selector, total, expectedReceived));
        escrow.fund(jobId);
        vm.stopPrank();

        // Revert rolled everything back: job still Created and no tokens moved.
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Created));
        assertEq(fee.balanceOf(address(escrow)), 0);
        assertEq(fee.balanceOf(client), 1000e6);
    }

    // ---------------------------------------------------------------------------------------------
    // submit
    // ---------------------------------------------------------------------------------------------

    function test_submit_marksSubmittedAndEmits() public {
        uint256 jobId = _createFunded();
        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.MilestoneSubmitted(jobId, 0, uint64(block.timestamp));
        _submit(jobId, 0);

        MilestoneEscrow.Milestone memory m = escrow.milestone(jobId, 0);
        assertEq(uint8(m.status), uint8(MilestoneEscrow.MilestoneStatus.Submitted));
        assertEq(m.submittedAt, block.timestamp);
        assertEq(escrow.getJob(jobId).cursor, 0, "cursor moves only on release/claim");
    }

    function test_submit_revert_notFreelancer() public {
        uint256 jobId = _createFunded();
        vm.expectRevert(MilestoneEscrow.NotFreelancer.selector);
        vm.prank(client);
        escrow.submit(jobId, 0);
        vm.expectRevert(MilestoneEscrow.NotFreelancer.selector);
        vm.prank(stranger);
        escrow.submit(jobId, 0);
    }

    function test_submit_revert_notFunded() public {
        uint256 jobId = _create();
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Created)
        );
        _submit(jobId, 0);
    }

    function test_submit_revert_outOfOrder() public {
        uint256 jobId = _createFunded();
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfOrder.selector, 0, 1));
        _submit(jobId, 1);
    }

    function test_submit_revert_nextWhilePreviousUnderReview() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfOrder.selector, 0, 1));
        _submit(jobId, 1);
    }

    function test_submit_revert_outOfRange() public {
        uint256 jobId = _createFunded();
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfRange.selector, 3));
        _submit(jobId, 3);
    }

    function test_submit_revert_twice() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                MilestoneEscrow.InvalidMilestoneStatus.selector, MilestoneEscrow.MilestoneStatus.Submitted
            )
        );
        _submit(jobId, 0);
    }

    function test_submit_revert_afterCancel() public {
        uint256 jobId = _createFunded();
        vm.prank(client);
        escrow.cancel(jobId);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Cancelled)
        );
        _submit(jobId, 0);
    }

    function test_submit_revert_afterCompleted() public {
        uint256 jobId = _createFunded();
        for (uint256 i = 0; i < 3; ++i) {
            _submit(jobId, i);
            _release(jobId, i);
        }
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Completed)
        );
        _submit(jobId, 2);
    }

    // ---------------------------------------------------------------------------------------------
    // release
    // ---------------------------------------------------------------------------------------------

    function test_release_paysFreelancerAndAdvances() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);

        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.MilestoneReleased(jobId, 0, amounts[0]);
        _release(jobId, 0);

        assertEq(usdc.balanceOf(freelancer), amounts[0]);
        assertEq(usdc.balanceOf(address(escrow)), total - amounts[0]);
        assertEq(uint8(_mStatus(jobId, 0)), uint8(MilestoneEscrow.MilestoneStatus.Released));
        assertEq(escrow.getJob(jobId).cursor, 1);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Funded));
        assertEq(escrow.fundedUnreleased(jobId), total - amounts[0]);
    }

    function test_release_lastMilestoneCompletesJob() public {
        uint256 jobId = _createFunded();
        for (uint256 i = 0; i < 2; ++i) {
            _submit(jobId, i);
            _release(jobId, i);
        }
        _submit(jobId, 2);

        vm.expectEmit(true, false, false, true);
        emit MilestoneEscrow.JobCompleted(jobId);
        _release(jobId, 2);

        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Completed));
        assertEq(escrow.getJob(jobId).cursor, 3);
        assertEq(usdc.balanceOf(freelancer), total);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.fundedUnreleased(jobId), 0);
    }

    function test_release_revert_notClient() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.expectRevert(MilestoneEscrow.NotClient.selector);
        vm.prank(freelancer);
        escrow.release(jobId, 0);
    }

    function test_release_revert_notFunded() public {
        uint256 jobId = _create();
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Created)
        );
        _release(jobId, 0);
    }

    function test_release_revert_notSubmitted() public {
        uint256 jobId = _createFunded();
        vm.expectRevert(
            abi.encodeWithSelector(
                MilestoneEscrow.InvalidMilestoneStatus.selector, MilestoneEscrow.MilestoneStatus.Pending
            )
        );
        _release(jobId, 0);
    }

    function test_release_revert_wrongIndex() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfOrder.selector, 0, 1));
        _release(jobId, 1);
    }

    function test_release_revert_alreadyReleased() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        _release(jobId, 0);
        // Cursor moved to 1, so idx 0 is now "out of order" rather than "already released".
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfOrder.selector, 1, 0));
        _release(jobId, 0);
    }

    function test_release_revert_afterCompleted() public {
        uint256 jobId = _createFunded();
        for (uint256 i = 0; i < 3; ++i) {
            _submit(jobId, i);
            _release(jobId, i);
        }
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Completed)
        );
        _release(jobId, 2);
    }

    function test_release_worksAfterCancel() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.prank(freelancer);
        escrow.cancel(jobId);

        _release(jobId, 0);
        assertEq(usdc.balanceOf(freelancer), amounts[0]);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Cancelled), "stays Cancelled");
    }

    // ---------------------------------------------------------------------------------------------
    // claimExpired
    // ---------------------------------------------------------------------------------------------

    function test_claimExpired_atExactBoundary() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        uint256 submittedAt = block.timestamp;

        vm.warp(submittedAt + WINDOW);
        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.MilestoneClaimed(jobId, 0, amounts[0]);
        _claim(jobId, 0);

        assertEq(usdc.balanceOf(freelancer), amounts[0]);
        assertEq(uint8(_mStatus(jobId, 0)), uint8(MilestoneEscrow.MilestoneStatus.Claimed));
        assertEq(escrow.getJob(jobId).cursor, 1);
    }

    function test_claimExpired_revert_oneSecondEarly() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        uint64 claimableAt = uint64(block.timestamp + WINDOW);

        vm.warp(claimableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ReviewWindowNotElapsed.selector, claimableAt));
        _claim(jobId, 0);
    }

    function test_claimExpired_revert_immediately() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.ReviewWindowNotElapsed.selector, uint64(block.timestamp + WINDOW))
        );
        _claim(jobId, 0);
    }

    function test_claimExpired_revert_notFreelancer() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(MilestoneEscrow.NotFreelancer.selector);
        vm.prank(client);
        escrow.claimExpired(jobId, 0);
    }

    function test_claimExpired_revert_notSubmitted() public {
        uint256 jobId = _createFunded();
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(
            abi.encodeWithSelector(
                MilestoneEscrow.InvalidMilestoneStatus.selector, MilestoneEscrow.MilestoneStatus.Pending
            )
        );
        _claim(jobId, 0);
    }

    function test_claimExpired_revert_notFunded() public {
        uint256 jobId = _create();
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Created)
        );
        _claim(jobId, 0);
    }

    function test_claimExpired_revert_afterRelease() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        _release(jobId, 0);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfOrder.selector, 1, 0));
        _claim(jobId, 0);
    }

    function test_claimExpired_lastMilestoneCompletesJob() public {
        uint256 jobId = _createFunded();
        for (uint256 i = 0; i < 3; ++i) {
            _submit(jobId, i);
            vm.warp(block.timestamp + WINDOW);
            _claim(jobId, i);
        }
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Completed));
        assertEq(usdc.balanceOf(freelancer), total);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_claimExpired_worksAfterCancel() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.prank(client);
        escrow.cancel(jobId);
        assertEq(usdc.balanceOf(client), 10_000e6 - amounts[0], "client refunded the unsubmitted remainder");

        vm.warp(block.timestamp + WINDOW);
        _claim(jobId, 0);
        assertEq(usdc.balanceOf(freelancer), amounts[0]);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Cancelled));
    }

    function test_claimExpired_releaseBeatsClaimWhenClientActsInTime() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        vm.warp(block.timestamp + WINDOW - 1);
        _release(jobId, 0);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfOrder.selector, 1, 0));
        _claim(jobId, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // cancel
    // ---------------------------------------------------------------------------------------------

    function test_cancel_createdByClient_noTransfer() public {
        uint256 jobId = _create();
        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.JobCancelled(jobId, client, 0);
        vm.prank(client);
        escrow.cancel(jobId);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Cancelled));
        assertEq(usdc.balanceOf(address(escrow)), 0);
        // Milestones of a never-funded job are untouched (nothing to refund).
        assertEq(uint8(_mStatus(jobId, 0)), uint8(MilestoneEscrow.MilestoneStatus.Pending));
    }

    function test_cancel_created_holdsNothing() public {
        // Regression: a never-funded job keeps `Pending` milestones after cancel, but they were never
        // deposited, so the view must report zero (caught by the invariant suite).
        uint256 jobId = _create();
        vm.prank(client);
        escrow.cancel(jobId);
        assertEq(escrow.fundedUnreleased(jobId), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_cancel_createdByFreelancer() public {
        uint256 jobId = _create();
        vm.prank(freelancer);
        escrow.cancel(jobId);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Cancelled));
    }

    function test_cancel_fundedNothingSubmitted_fullRefund() public {
        uint256 jobId = _createFunded();
        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.JobCancelled(jobId, client, total);
        vm.prank(client);
        escrow.cancel(jobId);

        assertEq(usdc.balanceOf(client), 10_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.fundedUnreleased(jobId), 0);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(uint8(_mStatus(jobId, i)), uint8(MilestoneEscrow.MilestoneStatus.Refunded));
        }
    }

    function test_cancel_byFreelancer_refundGoesToClient() public {
        uint256 jobId = _createFunded();
        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.JobCancelled(jobId, freelancer, total);
        vm.prank(freelancer);
        escrow.cancel(jobId);
        assertEq(usdc.balanceOf(client), 10_000e6);
        assertEq(usdc.balanceOf(freelancer), 0);
    }

    function test_cancel_afterOneReleased_refundsRest() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);
        _release(jobId, 0);

        vm.prank(client);
        escrow.cancel(jobId);
        assertEq(usdc.balanceOf(client), 10_000e6 - amounts[0]);
        assertEq(usdc.balanceOf(freelancer), amounts[0]);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint8(_mStatus(jobId, 0)), uint8(MilestoneEscrow.MilestoneStatus.Released));
        assertEq(uint8(_mStatus(jobId, 1)), uint8(MilestoneEscrow.MilestoneStatus.Refunded));
        assertEq(uint8(_mStatus(jobId, 2)), uint8(MilestoneEscrow.MilestoneStatus.Refunded));
    }

    function test_cancel_withSubmitted_keepsItInEscrow() public {
        uint256 jobId = _createFunded();
        _submit(jobId, 0);

        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.JobCancelled(jobId, client, amounts[1] + amounts[2]);
        vm.prank(client);
        escrow.cancel(jobId);

        assertEq(usdc.balanceOf(address(escrow)), amounts[0]);
        assertEq(escrow.fundedUnreleased(jobId), amounts[0]);
        assertEq(uint8(_mStatus(jobId, 0)), uint8(MilestoneEscrow.MilestoneStatus.Submitted));
        assertEq(uint8(_mStatus(jobId, 1)), uint8(MilestoneEscrow.MilestoneStatus.Refunded));
        assertEq(uint8(_mStatus(jobId, 2)), uint8(MilestoneEscrow.MilestoneStatus.Refunded));
    }

    function test_cancel_onlySubmittedLeft_zeroRefundNoTransfer() public {
        uint256 jobId = _createFunded();
        for (uint256 i = 0; i < 2; ++i) {
            _submit(jobId, i);
            _release(jobId, i);
        }
        _submit(jobId, 2);
        uint256 clientBefore = usdc.balanceOf(client);

        vm.expectEmit(true, true, false, true);
        emit MilestoneEscrow.JobCancelled(jobId, freelancer, 0);
        vm.prank(freelancer);
        escrow.cancel(jobId);

        assertEq(usdc.balanceOf(client), clientBefore);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Cancelled));
        // The milestone under review still resolves normally.
        _release(jobId, 2);
        assertEq(usdc.balanceOf(freelancer), total);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_cancel_revert_notParty() public {
        uint256 jobId = _createFunded();
        vm.expectRevert(MilestoneEscrow.NotParty.selector);
        vm.prank(stranger);
        escrow.cancel(jobId);
    }

    function test_cancel_revert_twice() public {
        uint256 jobId = _createFunded();
        vm.prank(client);
        escrow.cancel(jobId);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Cancelled)
        );
        vm.prank(freelancer);
        escrow.cancel(jobId);
    }

    function test_cancel_revert_completed() public {
        uint256 jobId = _createFunded();
        for (uint256 i = 0; i < 3; ++i) {
            _submit(jobId, i);
            _release(jobId, i);
        }
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.InvalidJobStatus.selector, MilestoneEscrow.JobStatus.Completed)
        );
        vm.prank(client);
        escrow.cancel(jobId);
    }

    function test_cancel_revert_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.JobNotFound.selector, 0));
        vm.prank(client);
        escrow.cancel(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function test_views_revert_jobNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.JobNotFound.selector, 0));
        escrow.getJob(0);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.JobNotFound.selector, 0));
        escrow.milestone(0, 0);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.JobNotFound.selector, 0));
        escrow.getMilestones(0);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.JobNotFound.selector, 0));
        escrow.fundedUnreleased(0);
    }

    function test_milestone_revert_outOfRange() public {
        uint256 jobId = _create();
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfRange.selector, 3));
        escrow.milestone(jobId, 3);
    }

    function test_constants() public view {
        assertEq(escrow.MIN_REVIEW_WINDOW(), 1 hours);
        assertEq(escrow.MAX_REVIEW_WINDOW(), 90 days);
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------------------------------------

    function test_release_reentrancyBlocked() public {
        ReentrantToken rnt = new ReentrantToken();
        rnt.mint(client, total);
        vm.startPrank(client);
        rnt.approve(address(escrow), type(uint256).max);
        uint256 jobId = escrow.createJob(freelancer, IERC20(address(rnt)), amounts, WINDOW);
        escrow.fund(jobId);
        vm.stopPrank();
        _submit(jobId, 0);

        // During the payout transfer the token re-enters `release(jobId, 0)`. The re-entrant call is
        // made by the token, but the guard trips before any auth check runs.
        rnt.arm(address(escrow), abi.encodeCall(MilestoneEscrow.release, (jobId, 0)));
        _release(jobId, 0);

        assertTrue(rnt.reentered(), "callback fired");
        assertFalse(rnt.reentrySucceeded(), "re-entrant call reverted");
        assertEq(rnt.reentryReturnData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(rnt.balanceOf(freelancer), amounts[0], "paid exactly once");
        assertEq(escrow.getJob(jobId).cursor, 1);
    }

    function test_cancel_reentrancyBlocked() public {
        ReentrantToken rnt = new ReentrantToken();
        rnt.mint(client, total);
        vm.startPrank(client);
        rnt.approve(address(escrow), type(uint256).max);
        uint256 jobId = escrow.createJob(freelancer, IERC20(address(rnt)), amounts, WINDOW);
        escrow.fund(jobId);
        // Re-enter `cancel` during the refund transfer.
        rnt.arm(address(escrow), abi.encodeCall(MilestoneEscrow.cancel, (jobId)));
        escrow.cancel(jobId);
        vm.stopPrank();

        assertTrue(rnt.reentered());
        assertFalse(rnt.reentrySucceeded());
        assertEq(rnt.reentryReturnData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(rnt.balanceOf(client), total, "refunded exactly once");
    }

    // ---------------------------------------------------------------------------------------------
    // Multi-job / multi-token accounting
    // ---------------------------------------------------------------------------------------------

    function test_twoJobsShareEscrowWithoutCrossTalk() public {
        MockUSDC other = new MockUSDC();
        other.mint(client, 1000e6);
        vm.prank(client);
        other.approve(address(escrow), type(uint256).max);

        uint256 a = _createFunded();
        vm.startPrank(client);
        uint256 b = escrow.createJob(freelancer, IERC20(address(other)), amounts, WINDOW);
        escrow.fund(b);
        vm.stopPrank();

        _submit(a, 0);
        _release(a, 0);
        vm.prank(client);
        escrow.cancel(b);

        assertEq(usdc.balanceOf(address(escrow)), total - amounts[0]);
        assertEq(other.balanceOf(address(escrow)), 0);
        assertEq(escrow.fundedUnreleased(a), total - amounts[0]);
        assertEq(escrow.fundedUnreleased(b), 0);
        assertEq(usdc.balanceOf(address(escrow)), escrow.fundedUnreleased(a));
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// @dev Random milestone arrays: totals match, every milestone can be released in order, and the
    ///      escrow ends empty.
    function testFuzz_fullFlow_randomAmounts(uint256[] memory raw, uint32 window) public {
        vm.assume(raw.length > 0);
        uint256 n = raw.length > 12 ? 12 : raw.length;
        window = uint32(bound(window, 1 hours, 90 days));

        uint256[] memory amts = new uint256[](n);
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) {
            amts[i] = bound(raw[i], 1, 1e15); // up to 1e9 USDC per milestone
            sum += amts[i];
        }

        usdc.mint(client, sum);
        vm.startPrank(client);
        uint256 jobId = escrow.createJob(freelancer, IERC20(address(usdc)), amts, window);
        escrow.fund(jobId);
        vm.stopPrank();

        assertEq(escrow.getJob(jobId).total, sum);
        assertEq(escrow.fundedUnreleased(jobId), sum);

        uint256 remaining = sum;
        for (uint256 i = 0; i < n; ++i) {
            _submit(jobId, i);
            // Alternate release and claim so both payout paths are exercised on random shapes.
            if (i % 2 == 0) {
                _release(jobId, i);
            } else {
                vm.warp(block.timestamp + window);
                _claim(jobId, i);
            }
            remaining -= amts[i];
            assertEq(escrow.fundedUnreleased(jobId), remaining);
            assertEq(usdc.balanceOf(address(escrow)), remaining);
        }

        assertEq(usdc.balanceOf(freelancer), sum);
        assertEq(uint8(_status(jobId)), uint8(MilestoneEscrow.JobStatus.Completed));
    }

    /// @dev Any index other than the cursor is rejected by `submit`.
    function testFuzz_submit_rejectsAnyIndexButCursor(uint256 idx) public {
        uint256 jobId = _createFunded();
        vm.assume(idx != 0);
        if (idx >= amounts.length) {
            vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfRange.selector, idx));
        } else {
            vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneOutOfOrder.selector, 0, idx));
        }
        _submit(jobId, idx);
    }

    /// @dev Cancelling after `k` released milestones refunds exactly the sum of the rest.
    function testFuzz_cancel_refundsExactlyUnsubmitted(uint256[] memory raw, uint8 releasedCount, bool submitNext)
        public
    {
        vm.assume(raw.length > 0);
        uint256 n = raw.length > 10 ? 10 : raw.length;
        uint256[] memory amts = new uint256[](n);
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) {
            amts[i] = bound(raw[i], 1, 1e15);
            sum += amts[i];
        }
        uint256 k = bound(releasedCount, 0, n - 1); // leave at least one unresolved

        usdc.mint(client, sum);
        uint256 clientStart = usdc.balanceOf(client);
        vm.startPrank(client);
        uint256 jobId = escrow.createJob(freelancer, IERC20(address(usdc)), amts, WINDOW);
        escrow.fund(jobId);
        vm.stopPrank();

        uint256 paid;
        for (uint256 i = 0; i < k; ++i) {
            _submit(jobId, i);
            _release(jobId, i);
            paid += amts[i];
        }
        uint256 held;
        if (submitNext) {
            _submit(jobId, k);
            held = amts[k];
        }

        vm.prank(client);
        escrow.cancel(jobId);

        uint256 expectedRefund = sum - paid - held;
        assertEq(usdc.balanceOf(client), clientStart - sum + expectedRefund);
        assertEq(usdc.balanceOf(address(escrow)), held);
        assertEq(escrow.fundedUnreleased(jobId), held);
    }

    /// @dev `claimExpired` succeeds iff `block.timestamp >= submittedAt + window`.
    function testFuzz_claimExpired_boundary(uint32 window, uint32 delta) public {
        window = uint32(bound(window, 1 hours, 90 days));
        vm.prank(client);
        uint256 jobId = escrow.createJob(freelancer, IERC20(address(usdc)), amounts, window);
        vm.prank(client);
        escrow.fund(jobId);
        _submit(jobId, 0);

        uint256 submittedAt = block.timestamp;
        vm.warp(submittedAt + delta);

        if (delta < window) {
            vm.expectRevert(
                abi.encodeWithSelector(MilestoneEscrow.ReviewWindowNotElapsed.selector, uint64(submittedAt + window))
            );
            _claim(jobId, 0);
            assertEq(usdc.balanceOf(freelancer), 0);
        } else {
            _claim(jobId, 0);
            assertEq(usdc.balanceOf(freelancer), amounts[0]);
        }
    }

    /// @dev Review-window bounds are enforced exactly.
    function testFuzz_createJob_windowBounds(uint32 window) public {
        bool valid = window >= 1 hours && window <= 90 days;
        if (!valid) {
            vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ReviewWindowOutOfRange.selector, window));
        }
        vm.prank(client);
        escrow.createJob(freelancer, IERC20(address(usdc)), amounts, window);
    }
}
