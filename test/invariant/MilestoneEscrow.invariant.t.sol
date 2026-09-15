// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {MilestoneEscrow} from "../../src/MilestoneEscrow.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {Handler} from "./Handler.sol";

/// @dev Stateful fuzzing over random sequences of createJob/fund/submit/release/claimExpired/cancel
///      across three clients, three freelancers and two tokens.
contract MilestoneEscrowInvariantTest is Test {
    MilestoneEscrow internal escrow;
    Handler internal handler;
    MockUSDC[] internal tokens;
    address[] internal clients;
    address[] internal freelancers;

    function setUp() public {
        vm.warp(1_700_000_000);
        escrow = new MilestoneEscrow();

        tokens.push(new MockUSDC());
        tokens.push(new MockUSDC());
        clients.push(makeAddr("client0"));
        clients.push(makeAddr("client1"));
        clients.push(makeAddr("client2"));
        freelancers.push(makeAddr("freelancer0"));
        freelancers.push(makeAddr("freelancer1"));
        freelancers.push(makeAddr("freelancer2"));

        handler = new Handler(escrow, tokens, clients, freelancers);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = Handler.createJob.selector;
        selectors[1] = Handler.fund.selector;
        selectors[2] = Handler.submit.selector;
        selectors[3] = Handler.release.selector;
        selectors[4] = Handler.claimExpired.selector;
        selectors[5] = Handler.cancel.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Escrow balance per token == sum over jobs of funded-but-unresolved milestone amounts,
    ///      checked both against the contract's own view and against handler ghost accounting.
    function invariant_balanceMatchesHeldPerToken() public view {
        for (uint256 t = 0; t < tokens.length; ++t) {
            address token = address(tokens[t]);
            uint256 sumViews;
            uint256 n = escrow.jobCount();
            for (uint256 j = 0; j < n; ++j) {
                if (address(escrow.getJob(j).token) == token) sumViews += escrow.fundedUnreleased(j);
            }
            uint256 bal = tokens[t].balanceOf(address(escrow));
            assertEq(bal, sumViews, "balance != sum(fundedUnreleased)");
            assertEq(bal, handler.ghostHeld(token), "balance != ghost held");
        }
    }

    /// @dev No milestone is ever paid twice, and never both paid and refunded.
    function invariant_noDoublePayout() public view {
        assertLe(handler.maxPayoutCount(), 1, "milestone paid more than once");
        assertFalse(handler.paidAndRefunded(), "milestone both paid and refunded");
    }

    /// @dev Freelancers hold exactly what the ghost says they were paid; clients hold their initial
    ///      balance minus deposits plus refunds. Money never leaks to third parties.
    function invariant_partyBalancesMatchGhost() public view {
        for (uint256 t = 0; t < tokens.length; ++t) {
            address token = address(tokens[t]);
            for (uint256 f = 0; f < freelancers.length; ++f) {
                assertEq(tokens[t].balanceOf(freelancers[f]), handler.ghostPaid(token, freelancers[f]));
            }
            for (uint256 c = 0; c < clients.length; ++c) {
                uint256 expected = handler.INITIAL_CLIENT_BALANCE() - handler.ghostFunded(token, clients[c])
                    + handler.ghostRefunded(token, clients[c]);
                assertEq(tokens[t].balanceOf(clients[c]), expected);
            }
        }
    }

    /// @dev Structural properties of every job: cursor within bounds, all milestones before the cursor
    ///      are resolved (Released/Claimed), at most one milestone is Submitted, milestone statuses
    ///      agree with the job status.
    function invariant_jobStateMachine() public view {
        uint256 n = escrow.jobCount();
        for (uint256 j = 0; j < n; ++j) {
            MilestoneEscrow.JobInfo memory job = escrow.getJob(j);
            MilestoneEscrow.Milestone[] memory ms = escrow.getMilestones(j);
            assertLe(job.cursor, ms.length, "cursor out of bounds");
            assertEq(ms.length, job.milestoneCount);

            uint256 submitted;
            uint256 total;
            for (uint256 i = 0; i < ms.length; ++i) {
                total += ms[i].amount;
                MilestoneEscrow.MilestoneStatus s = ms[i].status;
                if (i < job.cursor) {
                    assertTrue(
                        s == MilestoneEscrow.MilestoneStatus.Released || s == MilestoneEscrow.MilestoneStatus.Claimed,
                        "milestone before cursor not resolved"
                    );
                } else {
                    assertTrue(
                        s != MilestoneEscrow.MilestoneStatus.Released && s != MilestoneEscrow.MilestoneStatus.Claimed,
                        "milestone at/after cursor already resolved"
                    );
                    if (s == MilestoneEscrow.MilestoneStatus.Submitted) {
                        assertEq(i, job.cursor, "submitted milestone not at cursor");
                        ++submitted;
                    }
                    if (s == MilestoneEscrow.MilestoneStatus.Refunded) {
                        assertEq(uint8(job.status), uint8(MilestoneEscrow.JobStatus.Cancelled));
                    }
                }
            }
            assertLe(submitted, 1, "more than one milestone under review");
            assertEq(total, job.total, "total drift");

            if (job.status == MilestoneEscrow.JobStatus.Created) {
                assertEq(job.cursor, 0);
                assertEq(escrow.fundedUnreleased(j), 0);
            } else if (job.status == MilestoneEscrow.JobStatus.Completed) {
                assertEq(job.cursor, ms.length);
                assertEq(escrow.fundedUnreleased(j), 0);
            } else if (job.status == MilestoneEscrow.JobStatus.Funded) {
                assertLt(job.cursor, ms.length, "funded job with everything resolved must be Completed");
            }
        }
    }

    function invariant_callSummary() public view {
        console.log("createJob", handler.calls_createJob());
        console.log("fund", handler.calls_fund());
        console.log("submit", handler.calls_submit());
        console.log("release", handler.calls_release());
        console.log("claimExpired", handler.calls_claimExpired());
        console.log("cancel", handler.calls_cancel());
    }
}
