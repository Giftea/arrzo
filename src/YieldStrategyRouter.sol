// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IVeBTC} from "./interfaces/IVeBTC.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {ITroveManager, IPriceFeed} from "./interfaces/ITroveManager.sol";

/// @title  YieldStrategyRouter
/// @notice Aggregates user deposits into a single veBTC position and
///         distributes protocol fees pro-rata via a reward-per-share accumulator.
///
///         Phase 1 scope (everything auditors need to check):
///           - deposit / withdraw principal
///           - harvest fees from FeeDistributor → distribute to share holders
///           - claimFees per user
///           - extendLock (permissionless keeper action)
///           - isRecoveryMode / currentTCR views (read-only protocol health)
///
///         What is explicitly OUT of scope for Phase 1:
///           - opening troves / managing debt
///           - liquid exit / early-unlock mechanics
///           - on-chain governance
contract YieldStrategyRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant PRECISION = 1e18;

    /// Mirrors the protocol's Minimum Collateral Ratio.
    uint256 public constant MCR = 1.1e18; // 110 %

    /// Mirrors the Critical Collateral Ratio that triggers Recovery Mode.
    uint256 public constant CCR = 1.5e18; // 150 %

    uint256 private constant WEEK = 7 days;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    /// Token deposited by users (e.g. WBTC).
    IERC20 public immutable asset;

    IVeBTC public immutable veBTC;
    IFeeDistributor public immutable feeDist;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;

    /// Token in which protocol fees are denominated (must differ from `asset`).
    IERC20 public immutable feeToken;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    /// Total principal locked in veBTC. Tracked explicitly so fee-token balance
    /// can never be mistaken for withdrawable principal.
    uint256 public totalPrincipal;

    /// Synthetix-style accumulated reward per share (scaled by PRECISION).
    uint256 public rewardPerShareStored;
    mapping(address => uint256) public rewardPerSharePaid;
    mapping(address => uint256) public pendingRewards;

    /// Epoch end timestamp (week-aligned). Deposits close; withdrawals open.
    uint256 public lockEnd;

    /// How far ahead the next lock extends when a deposit arrives or extendLock is called.
    uint256 public lockDuration = 365 days;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 amount, uint256 sharesIssued);
    event Withdrawn(address indexed user, uint256 sharesRedeemed, uint256 amount);
    event FeesClaimed(address indexed user, uint256 amount);
    event FeesHarvested(uint256 amount);
    event LockExtended(uint256 newEnd);
    event LockDurationSet(uint256 newDuration);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroAmount();
    error LockStillActive(uint256 unlockTime);
    error EpochClosed();
    error InsufficientShares(uint256 have, uint256 want);
    error FeeTokenEqualsAsset();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _asset,
        address _veBTC,
        address _feeDist,
        address _troveManager,
        address _priceFeed,
        address _initialOwner
    ) Ownable(_initialOwner) {
        // fee-token must differ from asset; otherwise withdrawn principal would
        // get mixed with unclaimed rewards in the accounting below.
        address _feeToken = IFeeDistributor(_feeDist).token();
        if (_feeToken == _asset) revert FeeTokenEqualsAsset();

        asset = IERC20(_asset);
        veBTC = IVeBTC(_veBTC);
        feeDist = IFeeDistributor(_feeDist);
        troveManager = ITroveManager(_troveManager);
        priceFeed = IPriceFeed(_priceFeed);
        feeToken = IERC20(_feeToken);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: deposit
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Lock `amount` of `asset` as veBTC and receive shares.
    ///         Deposits are rejected once the current epoch has ended.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (lockEnd > 0 && block.timestamp >= lockEnd) revert EpochClosed();

        _updateRewards(msg.sender);

        asset.safeTransferFrom(msg.sender, address(this), amount);
        asset.forceApprove(address(veBTC), amount);

        // Round unlock time down to the nearest week (ve-token convention).
        uint256 newEnd = ((block.timestamp + lockDuration) / WEEK) * WEEK;

        if (totalShares == 0) {
            veBTC.create_lock(amount, newEnd);
            lockEnd = newEnd;
        } else if (newEnd > lockEnd) {
            veBTC.increase_amount(amount);
            veBTC.increase_unlock_time(newEnd);
            lockEnd = newEnd;
        } else {
            veBTC.increase_amount(amount);
        }

        // First depositor gets 1:1 shares. Subsequent depositors get shares
        // proportional to their fraction of the total locked principal so that
        // each share always represents an equal claim on the locked pool.
        uint256 issued = totalShares == 0 ? amount : (amount * totalShares) / totalPrincipal;

        shares[msg.sender] += issued;
        totalShares += issued;
        totalPrincipal += amount;

        emit Deposited(msg.sender, amount, issued);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: withdraw
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Redeem `shareAmount` shares for proportional principal after lock expires.
    ///         The first caller after expiry triggers the veBTC unlock for everyone.
    function withdraw(uint256 shareAmount) external nonReentrant {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[msg.sender] < shareAmount) revert InsufficientShares(shares[msg.sender], shareAmount);
        if (block.timestamp < lockEnd) revert LockStillActive(lockEnd);

        _updateRewards(msg.sender);

        // Lazy-unlock: pull assets out of veBTC on the first withdrawal call.
        IVeBTC.LockedBalance memory lb = veBTC.locked(address(this));
        if (lb.amount > 0) {
            veBTC.withdraw();
        }

        uint256 assetAmount = (shareAmount * totalPrincipal) / totalShares;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalPrincipal -= assetAmount;

        asset.safeTransfer(msg.sender, assetAmount);
        emit Withdrawn(msg.sender, shareAmount, assetAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core: harvest & claim fees
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pull accumulated fees from the FeeDistributor and credit all
    ///         current share holders pro-rata. Permissionless — anyone can call.
    function harvest() external nonReentrant returns (uint256 harvested) {
        // Don't pull fees when nobody holds shares — they'd be stuck in the router.
        if (totalShares == 0) return 0;
        harvested = feeDist.claim(address(this));
        if (harvested > 0) {
            rewardPerShareStored += (harvested * PRECISION) / totalShares;
            emit FeesHarvested(harvested);
        }
    }

    /// @notice Transfer all pending fee rewards to the caller.
    function claimFees() external nonReentrant returns (uint256 amount) {
        _updateRewards(msg.sender);
        amount = pendingRewards[msg.sender];
        if (amount > 0) {
            pendingRewards[msg.sender] = 0;
            feeToken.safeTransfer(msg.sender, amount);
            emit FeesClaimed(msg.sender, amount);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Maintenance: extend lock
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Push the lock expiry forward by `lockDuration` from now.
    ///         Permissionless so keepers can call it before the epoch closes.
    function extendLock() external {
        uint256 newEnd = ((block.timestamp + lockDuration) / WEEK) * WEEK;
        if (newEnd > lockEnd) {
            veBTC.increase_unlock_time(newEnd);
            lockEnd = newEnd;
            emit LockExtended(newEnd);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner
    // ─────────────────────────────────────────────────────────────────────────

    function setLockDuration(uint256 _duration) external onlyOwner {
        lockDuration = _duration;
        emit LockDurationSet(_duration);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Claimable fee balance for `user` (including unharvested protocol fees).
    function pendingFees(address user) external view returns (uint256) {
        uint256 accrued = totalShares > 0
            ? (shares[user] * (rewardPerShareStored - rewardPerSharePaid[user])) / PRECISION
            : 0;
        return pendingRewards[user] + accrued;
    }

    /// @notice True when the underlying protocol is in Recovery Mode (TCR < CCR).
    function isRecoveryMode() public view returns (bool) {
        return troveManager.checkRecoveryMode(priceFeed.lastGoodPrice());
    }

    /// @notice Current Total Collateral Ratio of the underlying protocol.
    function currentTCR() public view returns (uint256) {
        return troveManager.getTCR(priceFeed.lastGoodPrice());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _updateRewards(address user) internal {
        uint256 stored = rewardPerShareStored;
        uint256 paid = rewardPerSharePaid[user];
        if (shares[user] > 0 && stored > paid) {
            pendingRewards[user] += (shares[user] * (stored - paid)) / PRECISION;
        }
        rewardPerSharePaid[user] = stored;
    }
}
