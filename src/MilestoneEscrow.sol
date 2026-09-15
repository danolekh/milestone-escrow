// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title MilestoneEscrow
/// @author Daniil Olekh
/// @notice Trust-minimised, ownerless escrow that pays a freelancer per milestone in any ERC-20
///         (USDC on Base is the intended token). A client locks the full budget up front; the
///         freelancer submits milestones one at a time; the client releases each one or, if the
///         client goes silent, the freelancer claims it after a fixed review window. Either party
///         can cancel the not-yet-submitted remainder, which is refunded to the client.
/// @dev Design notes:
///      - No owner, no upgradeability, no protocol fee, no arbitration. All authority is derived
///        from the two job parties and the clock.
///      - Milestones are strictly sequential: at most one milestone is "in review" at any time and
///        milestone `i + 1` cannot be submitted before milestone `i` is released or claimed. This
///        keeps the state machine tiny and makes the refund rule on cancel unambiguous.
///      - Fee-on-transfer and rebasing tokens are unsupported. `fund` measures the balance delta and
///        reverts with {UnsupportedToken} if it differs from the requested amount. Rebasing tokens
///        that change the escrow's balance after funding will break accounting; do not use them.
///      - Timestamp slack: `claimExpired` uses `block.timestamp >= submittedAt + reviewWindow`.
///        Sequencers/validators can nudge `block.timestamp` by a few seconds; the minimum review
///        window of one hour makes that irrelevant in practice.
contract MilestoneEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Lifecycle of a job as a whole.
    /// @dev `Cancelled` and `Completed` are terminal for the job, but a milestone that was already
    ///      `Submitted` when the job was cancelled remains releasable/claimable.
    enum JobStatus {
        Created,
        Funded,
        Cancelled,
        Completed
    }

    /// @notice Lifecycle of a single milestone.
    enum MilestoneStatus {
        Pending,
        Submitted,
        Released,
        Claimed,
        Refunded
    }

    /// @notice A single deliverable with a fixed payout.
    /// @param amount Payout in token base units.
    /// @param submittedAt Timestamp of submission; zero until submitted.
    /// @param status Current milestone status.
    struct Milestone {
        uint128 amount;
        uint64 submittedAt;
        MilestoneStatus status;
    }

    /// @dev Storage layout of a job. `milestones` lives in its own array so the fixed part packs.
    struct Job {
        address client;
        uint32 reviewWindow;
        uint32 cursor;
        JobStatus status;
        address freelancer;
        IERC20 token;
        uint256 total;
        Milestone[] milestones;
    }

    /// @notice Read-only projection of a job without the milestone array.
    /// @param client Address that created and funds the job.
    /// @param freelancer Address that submits milestones and receives payouts.
    /// @param token ERC-20 used for payouts.
    /// @param reviewWindow Seconds the client has to review a submitted milestone.
    /// @param status Current job status.
    /// @param cursor Index of the first milestone that is neither released nor claimed.
    /// @param milestoneCount Number of milestones in the job.
    /// @param total Sum of all milestone amounts.
    struct JobInfo {
        address client;
        address freelancer;
        IERC20 token;
        uint32 reviewWindow;
        JobStatus status;
        uint32 cursor;
        uint256 milestoneCount;
        uint256 total;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Shortest review window a job may be created with.
    uint32 public constant MIN_REVIEW_WINDOW = 1 hours;

    /// @notice Longest review window a job may be created with.
    uint32 public constant MAX_REVIEW_WINDOW = 90 days;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    Job[] private _jobs;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice Emitted when a job is created (not yet funded).
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed freelancer,
        IERC20 token,
        uint256[] amounts,
        uint32 reviewWindow
    );

    /// @notice Emitted when the client deposits the full budget.
    event JobFunded(uint256 indexed jobId, uint256 total);

    /// @notice Emitted when the freelancer submits a milestone for review.
    event MilestoneSubmitted(uint256 indexed jobId, uint256 indexed idx, uint64 submittedAt);

    /// @notice Emitted when the client releases a submitted milestone.
    event MilestoneReleased(uint256 indexed jobId, uint256 indexed idx, uint256 amount);

    /// @notice Emitted when the freelancer claims a milestone whose review window elapsed.
    event MilestoneClaimed(uint256 indexed jobId, uint256 indexed idx, uint256 amount);

    /// @notice Emitted when a job is cancelled; `refund` is the amount returned to the client.
    event JobCancelled(uint256 indexed jobId, address indexed by, uint256 refund);

    /// @notice Emitted when the last milestone of a job is released or claimed.
    event JobCompleted(uint256 indexed jobId);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice A required address argument was zero.
    error ZeroAddress();
    /// @notice Client and freelancer must be distinct.
    error SameParty();
    /// @notice `amounts` was empty.
    error NoMilestones();
    /// @notice A milestone amount was zero.
    error ZeroAmount(uint256 idx);
    /// @notice `reviewWindow` is outside [MIN_REVIEW_WINDOW, MAX_REVIEW_WINDOW].
    error ReviewWindowOutOfRange(uint32 reviewWindow);
    /// @notice No job exists with the given id.
    error JobNotFound(uint256 jobId);
    /// @notice Caller is not the job's client.
    error NotClient();
    /// @notice Caller is not the job's freelancer.
    error NotFreelancer();
    /// @notice Caller is neither the client nor the freelancer.
    error NotParty();
    /// @notice The job is not in the status required for this action.
    error InvalidJobStatus(JobStatus actual);
    /// @notice Milestone index is out of range.
    error MilestoneOutOfRange(uint256 idx);
    /// @notice Milestones must be handled strictly in order; `expected` is the current cursor.
    error MilestoneOutOfOrder(uint256 expected, uint256 actual);
    /// @notice The milestone is not in the status required for this action.
    error InvalidMilestoneStatus(MilestoneStatus actual);
    /// @notice The review window has not elapsed yet; `claimableAt` is the first valid timestamp.
    error ReviewWindowNotElapsed(uint64 claimableAt);
    /// @notice The token did not deliver exactly the requested amount (fee-on-transfer / rebasing).
    error UnsupportedToken(uint256 expected, uint256 received);

    // ---------------------------------------------------------------------------------------------
    // Mutating functions
    // ---------------------------------------------------------------------------------------------

    /// @notice Create an unfunded job. The caller becomes the client.
    /// @dev Amounts are stored as `uint128`; values above `type(uint128).max` revert via SafeCast.
    ///      Sum of amounts must fit in `uint256` (checked arithmetic).
    /// @param freelancer Recipient of milestone payouts.
    /// @param token ERC-20 used for the budget. Must not be fee-on-transfer or rebasing.
    /// @param amounts Payout for each milestone, in order; non-empty, each > 0.
    /// @param reviewWindow Seconds the client has to release a submitted milestone before the
    ///        freelancer may claim it; must be within [1 hour, 90 days].
    /// @return jobId Sequential id of the new job.
    function createJob(address freelancer, IERC20 token, uint256[] calldata amounts, uint32 reviewWindow)
        external
        returns (uint256 jobId)
    {
        if (freelancer == address(0) || address(token) == address(0)) revert ZeroAddress();
        if (freelancer == msg.sender) revert SameParty();
        if (amounts.length == 0) revert NoMilestones();
        if (reviewWindow < MIN_REVIEW_WINDOW || reviewWindow > MAX_REVIEW_WINDOW) {
            revert ReviewWindowOutOfRange(reviewWindow);
        }

        jobId = _jobs.length;
        Job storage job = _jobs.push();
        job.client = msg.sender;
        job.freelancer = freelancer;
        job.token = token;
        job.reviewWindow = reviewWindow;
        // status defaults to Created, cursor to 0

        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) revert ZeroAmount(i);
            total += amount;
            job.milestones
                .push(Milestone({amount: amount.toUint128(), submittedAt: 0, status: MilestoneStatus.Pending}));
        }
        job.total = total;

        emit JobCreated(jobId, msg.sender, freelancer, token, amounts, reviewWindow);
    }

    /// @notice Deposit the full budget. Client only; callable once; requires prior ERC-20 approval.
    /// @dev Reverts with {UnsupportedToken} if the escrow's balance does not grow by exactly `total`.
    /// @param jobId Job to fund.
    function fund(uint256 jobId) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.client) revert NotClient();
        if (job.status != JobStatus.Created) revert InvalidJobStatus(job.status);

        job.status = JobStatus.Funded;

        IERC20 token = job.token;
        uint256 total = job.total;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), total);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != total) revert UnsupportedToken(total, received);

        emit JobFunded(jobId, total);
    }

    /// @notice Submit milestone `idx` for review. Freelancer only.
    /// @dev `idx` must equal the job's cursor (strictly sequential) and the milestone must be
    ///      `Pending`. Allowed only while the job is `Funded`; after cancellation the pending
    ///      remainder has been refunded, so nothing further can be submitted.
    /// @param jobId Job the milestone belongs to.
    /// @param idx Milestone index.
    function submit(uint256 jobId, uint256 idx) external {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.freelancer) revert NotFreelancer();
        if (job.status != JobStatus.Funded) revert InvalidJobStatus(job.status);

        Milestone storage m = _milestoneAtCursor(job, idx);
        if (m.status != MilestoneStatus.Pending) revert InvalidMilestoneStatus(m.status);

        uint64 nowTs = uint64(block.timestamp);
        m.status = MilestoneStatus.Submitted;
        m.submittedAt = nowTs;

        emit MilestoneSubmitted(jobId, idx, nowTs);
    }

    /// @notice Release a submitted milestone to the freelancer. Client only.
    /// @dev Allowed while the job is `Funded` or `Cancelled` (a milestone submitted before
    ///      cancellation stays releasable).
    /// @param jobId Job the milestone belongs to.
    /// @param idx Milestone index; must equal the cursor.
    function release(uint256 jobId, uint256 idx) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.client) revert NotClient();

        Milestone storage m = _submittedAtCursor(job, idx);
        uint256 amount = m.amount;
        m.status = MilestoneStatus.Released;
        _advance(job, jobId);

        emit MilestoneReleased(jobId, idx, amount);
        job.token.safeTransfer(job.freelancer, amount);
    }

    /// @notice Claim a submitted milestone after the client's review window elapsed. Freelancer only.
    /// @dev Claimable when `block.timestamp >= submittedAt + reviewWindow` (inclusive boundary).
    ///      Allowed while the job is `Funded` or `Cancelled`.
    /// @param jobId Job the milestone belongs to.
    /// @param idx Milestone index; must equal the cursor.
    function claimExpired(uint256 jobId, uint256 idx) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.freelancer) revert NotFreelancer();

        Milestone storage m = _submittedAtCursor(job, idx);
        uint64 claimableAt = m.submittedAt + job.reviewWindow;
        if (block.timestamp < claimableAt) revert ReviewWindowNotElapsed(claimableAt);

        uint256 amount = m.amount;
        m.status = MilestoneStatus.Claimed;
        _advance(job, jobId);

        emit MilestoneClaimed(jobId, idx, amount);
        job.token.safeTransfer(job.freelancer, amount);
    }

    /// @notice Cancel the job. Either party may call.
    /// @dev Rules:
    ///      - In `Created`: the job is closed so it can never be funded. Nothing is transferred.
    ///      - In `Funded`: every `Pending` milestone becomes `Refunded` and their sum is sent to the
    ///        client. A milestone that is currently `Submitted` is untouched: the client may still
    ///        `release` it and the freelancer may still `claimExpired` it. Refund may be zero if the
    ///        only remaining milestone is the one under review.
    ///      - In `Cancelled` or `Completed`: reverts.
    /// @param jobId Job to cancel.
    function cancel(uint256 jobId) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.client && msg.sender != job.freelancer) revert NotParty();

        JobStatus status = job.status;
        if (status != JobStatus.Created && status != JobStatus.Funded) revert InvalidJobStatus(status);

        job.status = JobStatus.Cancelled;

        uint256 refund = 0;
        if (status == JobStatus.Funded) {
            Milestone[] storage ms = job.milestones;
            uint256 len = ms.length;
            for (uint256 i = job.cursor; i < len; ++i) {
                Milestone storage m = ms[i];
                if (m.status == MilestoneStatus.Pending) {
                    m.status = MilestoneStatus.Refunded;
                    refund += m.amount;
                }
            }
        }

        emit JobCancelled(jobId, msg.sender, refund);
        if (refund != 0) job.token.safeTransfer(job.client, refund);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Number of jobs ever created.
    function jobCount() external view returns (uint256) {
        return _jobs.length;
    }

    /// @notice Fixed-size summary of a job.
    /// @param jobId Job id.
    function getJob(uint256 jobId) external view returns (JobInfo memory) {
        Job storage job = _getJob(jobId);
        return JobInfo({
            client: job.client,
            freelancer: job.freelancer,
            token: job.token,
            reviewWindow: job.reviewWindow,
            status: job.status,
            cursor: job.cursor,
            milestoneCount: job.milestones.length,
            total: job.total
        });
    }

    /// @notice A single milestone of a job.
    /// @param jobId Job id.
    /// @param idx Milestone index.
    function milestone(uint256 jobId, uint256 idx) external view returns (Milestone memory) {
        Job storage job = _getJob(jobId);
        if (idx >= job.milestones.length) revert MilestoneOutOfRange(idx);
        return job.milestones[idx];
    }

    /// @notice All milestones of a job.
    /// @param jobId Job id.
    function getMilestones(uint256 jobId) external view returns (Milestone[] memory) {
        return _getJob(jobId).milestones;
    }

    /// @notice Tokens held by the escrow on behalf of this job: milestone amounts that were funded
    ///         and are not yet released, claimed or refunded.
    /// @dev Zero for `Created` (never funded) and `Completed` jobs. For a `Funded` job this is the sum
    ///      of `Pending` and `Submitted` milestones. For a `Cancelled` job only a `Submitted` milestone
    ///      can still be held: a funded cancel marks every `Pending` milestone `Refunded`, and a cancel
    ///      from `Created` never moved tokens at all (its milestones stay `Pending` but were never
    ///      funded). Summing this over all jobs with the same token equals the escrow's balance of
    ///      that token (assuming nobody sends tokens directly).
    /// @param jobId Job id.
    function fundedUnreleased(uint256 jobId) external view returns (uint256 held) {
        Job storage job = _getJob(jobId);
        JobStatus status = job.status;
        if (status == JobStatus.Created || status == JobStatus.Completed) return 0;

        bool countPending = status == JobStatus.Funded;
        Milestone[] storage ms = job.milestones;
        uint256 len = ms.length;
        for (uint256 i = job.cursor; i < len; ++i) {
            MilestoneStatus s = ms[i].status;
            if (s == MilestoneStatus.Submitted || (countPending && s == MilestoneStatus.Pending)) {
                held += ms[i].amount;
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------------------------

    function _getJob(uint256 jobId) private view returns (Job storage job) {
        if (jobId >= _jobs.length) revert JobNotFound(jobId);
        job = _jobs[jobId];
    }

    /// @dev Enforces `idx == cursor`. Callers check the milestone status themselves.
    function _milestoneAtCursor(Job storage job, uint256 idx) private view returns (Milestone storage) {
        uint256 cursor = job.cursor;
        if (idx >= job.milestones.length) revert MilestoneOutOfRange(idx);
        if (idx != cursor) revert MilestoneOutOfOrder(cursor, idx);
        return job.milestones[idx];
    }

    /// @dev Shared precondition for `release` and `claimExpired`: job funded or cancelled, milestone
    ///      at the cursor and `Submitted`.
    function _submittedAtCursor(Job storage job, uint256 idx) private view returns (Milestone storage m) {
        JobStatus status = job.status;
        if (status != JobStatus.Funded && status != JobStatus.Cancelled) revert InvalidJobStatus(status);
        m = _milestoneAtCursor(job, idx);
        if (m.status != MilestoneStatus.Submitted) revert InvalidMilestoneStatus(m.status);
    }

    /// @dev Moves the cursor past a resolved milestone and completes the job when appropriate.
    function _advance(Job storage job, uint256 jobId) private {
        uint32 next = job.cursor + 1;
        job.cursor = next;
        if (next == job.milestones.length && job.status == JobStatus.Funded) {
            job.status = JobStatus.Completed;
            emit JobCompleted(jobId);
        }
    }
}
