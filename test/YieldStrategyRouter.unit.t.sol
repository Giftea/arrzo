// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {YieldStrategyRouter} from "../src/YieldStrategyRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVeBTC} from "./mocks/MockVeBTC.sol";
import {MockFeeDistributor} from "./mocks/MockFeeDistributor.sol";
import {MockTroveManager, MockPriceFeed} from "./mocks/MockTroveManager.sol";

contract YieldStrategyRouterTest is Test {
    // ─── Protocol ────────────────────────────────────────────────────────────
    YieldStrategyRouter internal router;
    MockERC20 internal wbtc;
    MockERC20 internal lusd;
    MockVeBTC internal veBTC;
    MockFeeDistributor internal feeDist;
    MockTroveManager internal troveManager;
    MockPriceFeed internal priceFeed;

    // ─── Actors ──────────────────────────────────────────────────────────────
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal owner = makeAddr("owner");

    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 internal constant WBTC_UNIT = 1e8; // 8-decimal token
    uint256 internal constant LUSD_UNIT = 1e18;
    uint256 internal constant BTC_PRICE = 60_000e18; // $60 k
    uint256 internal constant NORMAL_TCR = 2e18; // 200 % — healthy

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        lusd = new MockERC20("LUSD Stablecoin", "LUSD", 18);
        veBTC = new MockVeBTC(address(wbtc));
        feeDist = new MockFeeDistributor(address(lusd));
        troveManager = new MockTroveManager(NORMAL_TCR);
        priceFeed = new MockPriceFeed(BTC_PRICE);

        router = new YieldStrategyRouter(
            address(wbtc),
            address(veBTC),
            address(feeDist),
            address(troveManager),
            address(priceFeed),
            owner
        );

        // Seed actors with WBTC
        wbtc.mint(alice, 10 * WBTC_UNIT);
        wbtc.mint(bob, 10 * WBTC_UNIT);
        wbtc.mint(carol, 10 * WBTC_UNIT);

        vm.prank(alice);
        wbtc.approve(address(router), type(uint256).max);
        vm.prank(bob);
        wbtc.approve(address(router), type(uint256).max);
        vm.prank(carol);
        wbtc.approve(address(router), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _depositAs(address user, uint256 amount) internal {
        vm.prank(user);
        router.deposit(amount);
    }

    function _advancePastLock() internal {
        vm.warp(router.lockEnd() + 1);
    }

    function _addFees(uint256 amount) internal {
        lusd.mint(address(this), amount);
        lusd.approve(address(feeDist), amount);
        feeDist.addFees(address(router), amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit
    // ─────────────────────────────────────────────────────────────────────────

    function test_firstDepositCreatesLockAndIssues1to1Shares() public {
        _depositAs(alice, 1 * WBTC_UNIT);

        assertEq(router.shares(alice), 1 * WBTC_UNIT);
        assertEq(router.totalShares(), 1 * WBTC_UNIT);
        assertEq(router.totalPrincipal(), 1 * WBTC_UNIT);
        assertTrue(router.lockEnd() > block.timestamp);
    }

    function test_subsequentDepositIssuesProportionalShares() public {
        _depositAs(alice, 2 * WBTC_UNIT);
        _depositAs(bob, 2 * WBTC_UNIT);

        // Equal deposits → equal shares
        assertEq(router.shares(bob), router.shares(alice));
        assertEq(router.totalShares(), 4 * WBTC_UNIT);
    }

    function test_depositProportionalShares_unequalAmounts() public {
        _depositAs(alice, 3 * WBTC_UNIT);
        _depositAs(bob, 1 * WBTC_UNIT);

        // Alice has 3x, bob has 1x
        assertEq(router.shares(alice), 3 * router.shares(bob));
    }

    function test_depositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(YieldStrategyRouter.ZeroAmount.selector);
        router.deposit(0);
    }

    function test_depositAfterEpochClosedReverts() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _advancePastLock();

        vm.prank(bob);
        vm.expectRevert(YieldStrategyRouter.EpochClosed.selector);
        router.deposit(1 * WBTC_UNIT);
    }

    function test_depositExtendsLockWhenFarther() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        uint256 firstEnd = router.lockEnd();

        // Warp forward so new deposit would produce a later end
        vm.warp(block.timestamp + 30 days);
        _depositAs(bob, 1 * WBTC_UNIT);

        assertGt(router.lockEnd(), firstEnd);
    }

    function test_depositDoesNotExtendLockWhenEarlier() public {
        // Deploy a router with a very long lockDuration first
        _depositAs(alice, 1 * WBTC_UNIT);
        uint256 firstEnd = router.lockEnd();

        // Make lockDuration shorter so the next deposit's target end < current end
        vm.prank(owner);
        router.setLockDuration(7 days);

        _depositAs(bob, 1 * WBTC_UNIT);

        // Lock should not have moved backward
        assertEq(router.lockEnd(), firstEnd);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Withdraw
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdrawBeforeLockExpiryReverts() public {
        _depositAs(alice, 1 * WBTC_UNIT);

        uint256 lockEndTime = router.lockEnd();
        uint256 aliceShares = router.shares(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(YieldStrategyRouter.LockStillActive.selector, lockEndTime)
        );
        router.withdraw(aliceShares);
    }

    function test_withdrawZeroReverts() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _advancePastLock();

        vm.prank(alice);
        vm.expectRevert(YieldStrategyRouter.ZeroAmount.selector);
        router.withdraw(0);
    }

    function test_withdrawInsufficientSharesReverts() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _advancePastLock();

        uint256 aliceShares = router.shares(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                YieldStrategyRouter.InsufficientShares.selector, aliceShares, aliceShares + 1
            )
        );
        router.withdraw(aliceShares + 1);
    }

    function test_withdrawSingleUserGetsAllPrincipal() public {
        uint256 amount = 1 * WBTC_UNIT;
        _depositAs(alice, amount);
        _advancePastLock();

        uint256 aliceShares = router.shares(alice);
        uint256 before = wbtc.balanceOf(alice);
        vm.prank(alice);
        router.withdraw(aliceShares);

        assertEq(wbtc.balanceOf(alice) - before, amount);
        assertEq(router.totalShares(), 0);
        assertEq(router.totalPrincipal(), 0);
    }

    function test_withdrawProportionalPrincipalTwoUsers() public {
        _depositAs(alice, 3 * WBTC_UNIT);
        _depositAs(bob, 1 * WBTC_UNIT);
        _advancePastLock();

        uint256 aliceShares = router.shares(alice);
        uint256 bobShares = router.shares(bob);

        uint256 aliceBefore = wbtc.balanceOf(alice);
        vm.prank(alice);
        router.withdraw(aliceShares);

        uint256 bobBefore = wbtc.balanceOf(bob);
        vm.prank(bob);
        router.withdraw(bobShares);

        assertEq(wbtc.balanceOf(alice) - aliceBefore, 3 * WBTC_UNIT);
        assertEq(wbtc.balanceOf(bob) - bobBefore, 1 * WBTC_UNIT);
    }

    function test_partialWithdrawReducesSharesCorrectly() public {
        _depositAs(alice, 4 * WBTC_UNIT);
        _advancePastLock();

        uint256 half = router.shares(alice) / 2;
        vm.prank(alice);
        router.withdraw(half);

        assertEq(router.shares(alice), half);
        assertApproxEqAbs(router.totalPrincipal(), 2 * WBTC_UNIT, 1);
    }

    function test_withdrawDoesNotDrainFeeTokenBalance() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _addFees(1000 * LUSD_UNIT);
        router.harvest();
        _advancePastLock();

        uint256 aliceShares = router.shares(alice);
        vm.prank(alice);
        router.withdraw(aliceShares);

        // Fee-token balance stays in router for claiming
        assertEq(lusd.balanceOf(address(router)), 1000 * LUSD_UNIT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Harvest & fee distribution
    // ─────────────────────────────────────────────────────────────────────────

    function test_harvestWithNoSharesIsNoop() public {
        _addFees(500 * LUSD_UNIT);
        uint256 harvested = router.harvest();
        // Returns 0 and leaves fees in the distributor — prevents stuck funds.
        assertEq(harvested, 0);
        assertEq(router.rewardPerShareStored(), 0);
        // Fees remain claimable in the distributor.
        assertEq(feeDist.claimable(address(router)), 500 * LUSD_UNIT);
    }

    function test_harvestCreditsFeesSingleUser() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _addFees(1000 * LUSD_UNIT);

        uint256 harvested = router.harvest();
        assertEq(harvested, 1000 * LUSD_UNIT);
        assertGt(router.rewardPerShareStored(), 0);
        assertEq(router.pendingFees(alice), 1000 * LUSD_UNIT);
    }

    function test_harvestSplitsFeesBetweenUsersProportionally() public {
        _depositAs(alice, 3 * WBTC_UNIT); // 75 %
        _depositAs(bob, 1 * WBTC_UNIT); //  25 %

        _addFees(1000 * LUSD_UNIT);
        router.harvest();

        assertApproxEqAbs(router.pendingFees(alice), 750 * LUSD_UNIT, 1);
        assertApproxEqAbs(router.pendingFees(bob), 250 * LUSD_UNIT, 1);
    }

    function test_harvestMultipleRoundsAccumulate() public {
        _depositAs(alice, 1 * WBTC_UNIT);

        _addFees(400 * LUSD_UNIT);
        router.harvest();

        _addFees(600 * LUSD_UNIT);
        router.harvest();

        assertApproxEqAbs(router.pendingFees(alice), 1000 * LUSD_UNIT, 1);
    }

    function test_lateDepositorDoesNotCapturePriorFees() public {
        _depositAs(alice, 1 * WBTC_UNIT);

        _addFees(1000 * LUSD_UNIT);
        router.harvest();

        // Bob deposits AFTER the harvest — should not receive the prior 1000 LUSD
        _depositAs(bob, 1 * WBTC_UNIT);

        assertEq(router.pendingFees(bob), 0);
        assertEq(router.pendingFees(alice), 1000 * LUSD_UNIT);
    }

    function test_harvestAfterLateDepositSplitsFairly() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _addFees(1000 * LUSD_UNIT);
        router.harvest(); // Round 1: alice gets 1000 LUSD

        _depositAs(bob, 1 * WBTC_UNIT); // Joins at equal weight after round 1
        _addFees(1000 * LUSD_UNIT);
        router.harvest(); // Round 2: alice + bob split 1000 LUSD equally

        assertApproxEqAbs(router.pendingFees(alice), 1000 * LUSD_UNIT + 500 * LUSD_UNIT, 1);
        assertApproxEqAbs(router.pendingFees(bob), 500 * LUSD_UNIT, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // claimFees
    // ─────────────────────────────────────────────────────────────────────────

    function test_claimFeesTransfersPendingRewards() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _addFees(1000 * LUSD_UNIT);
        router.harvest();

        uint256 before = lusd.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = router.claimFees();

        assertEq(claimed, 1000 * LUSD_UNIT);
        assertEq(lusd.balanceOf(alice) - before, 1000 * LUSD_UNIT);
        assertEq(router.pendingFees(alice), 0);
    }

    function test_claimFeesZeroWhenNothingPending() public {
        _depositAs(alice, 1 * WBTC_UNIT);

        vm.prank(alice);
        uint256 claimed = router.claimFees();

        assertEq(claimed, 0);
    }

    function test_claimFeesIdempotent() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _addFees(1000 * LUSD_UNIT);
        router.harvest();

        vm.prank(alice);
        router.claimFees();

        vm.prank(alice);
        uint256 secondClaim = router.claimFees();
        assertEq(secondClaim, 0);
    }

    function test_claimFeesDoesNotAffectOtherUsers() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        _depositAs(bob, 1 * WBTC_UNIT);
        _addFees(1000 * LUSD_UNIT);
        router.harvest();

        vm.prank(alice);
        router.claimFees();

        // Bob's fees untouched
        assertApproxEqAbs(router.pendingFees(bob), 500 * LUSD_UNIT, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Interleaved deposit → harvest → withdraw scenario
    // ─────────────────────────────────────────────────────────────────────────

    function test_fullLifecycleThreeUsers() public {
        // Alice deposits 3, Bob deposits 1
        _depositAs(alice, 3 * WBTC_UNIT);
        _depositAs(bob, 1 * WBTC_UNIT);

        // Round-1 fees: 800 LUSD → Alice 600, Bob 200
        _addFees(800 * LUSD_UNIT);
        router.harvest();

        // Carol joins after round 1 (no entitlement to past fees)
        _depositAs(carol, 2 * WBTC_UNIT);

        // Round-2 fees: 600 LUSD → proportional across 6 WBTC total
        // Alice (3/6=50%) → 300, Bob (1/6≈17%) → 100, Carol (2/6≈33%) → 200
        _addFees(600 * LUSD_UNIT);
        router.harvest();

        assertApproxEqAbs(router.pendingFees(alice), 600 * LUSD_UNIT + 300 * LUSD_UNIT, 2);
        assertApproxEqAbs(router.pendingFees(bob), 200 * LUSD_UNIT + 100 * LUSD_UNIT, 2);
        assertApproxEqAbs(router.pendingFees(carol), 200 * LUSD_UNIT, 2);

        // All claim
        vm.prank(alice);
        router.claimFees();
        vm.prank(bob);
        router.claimFees();
        vm.prank(carol);
        router.claimFees();

        assertEq(router.pendingFees(alice), 0);
        assertEq(router.pendingFees(bob), 0);
        assertEq(router.pendingFees(carol), 0);

        // Advance past lock, all withdraw principal
        _advancePastLock();

        uint256 aliceShares = router.shares(alice);
        uint256 bobShares = router.shares(bob);
        uint256 carolShares = router.shares(carol);

        vm.prank(alice);
        router.withdraw(aliceShares);
        vm.prank(bob);
        router.withdraw(bobShares);
        vm.prank(carol);
        router.withdraw(carolShares);

        assertEq(router.totalShares(), 0);
        assertEq(router.totalPrincipal(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // extendLock
    // ─────────────────────────────────────────────────────────────────────────

    function test_extendLockPushesLockEnd() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        uint256 originalEnd = router.lockEnd();

        vm.warp(block.timestamp + 30 days);
        router.extendLock();

        assertGt(router.lockEnd(), originalEnd);
    }

    function test_extendLockIsPermissionless() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        vm.warp(block.timestamp + 30 days);

        vm.prank(keeper);
        router.extendLock(); // must not revert
    }

    function test_extendLockNoopWhenNotFarther() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        uint256 originalEnd = router.lockEnd();

        // warp only 1 second — computed new end would not exceed current end
        vm.warp(block.timestamp + 1);
        router.extendLock();

        assertEq(router.lockEnd(), originalEnd);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Protocol health views
    // ─────────────────────────────────────────────────────────────────────────

    function test_isRecoveryModeFalseInNormalMode() public view {
        // TCR = 200 % > CCR 150 %
        assertFalse(router.isRecoveryMode());
    }

    function test_isRecoveryModeTrueWhenTCRBelowCCR() public {
        troveManager.setTCR(1.4e18); // 140 % < 150 % CCR
        assertTrue(router.isRecoveryMode());
    }

    function test_isRecoveryModeBoundaryAtExactCCR() public {
        troveManager.setTCR(1.5e18); // exactly CCR — not in Recovery Mode
        assertFalse(router.isRecoveryMode());
    }

    function test_currentTCRMatchesTroveManager() public view {
        assertEq(router.currentTCR(), NORMAL_TCR);
    }

    function test_currentTCRNearLiquidationThreshold() public {
        // 110 % MCR boundary
        troveManager.setTCR(1.1e18);
        assertEq(router.currentTCR(), 1.1e18);
        assertTrue(router.isRecoveryMode()); // 110 % < CCR 150 %
    }

    function test_currentTCRBelowMCR() public {
        // Underwater position
        troveManager.setTCR(1.05e18);
        assertEq(router.currentTCR(), 1.05e18);
        assertTrue(router.isRecoveryMode());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Access control
    // ─────────────────────────────────────────────────────────────────────────

    function test_setLockDurationOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // Ownable: caller is not owner
        router.setLockDuration(180 days);
    }

    function test_setLockDurationByOwner() public {
        vm.prank(owner);
        router.setLockDuration(180 days);
        assertEq(router.lockDuration(), 180 days);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_constructorRevertsWhenFeeTokenEqualsAsset() public {
        // Both asset and feeToken are wbtc
        MockFeeDistributor sameFee = new MockFeeDistributor(address(wbtc));

        vm.expectRevert(YieldStrategyRouter.FeeTokenEqualsAsset.selector);
        new YieldStrategyRouter(
            address(wbtc),
            address(veBTC),
            address(sameFee),
            address(troveManager),
            address(priceFeed),
            owner
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Any two non-zero deposits must produce shares proportional to amount.
    function testFuzz_shareRatioMatchesDepositRatio(uint96 a, uint96 b) public {
        a = uint96(bound(uint256(a), 1, 5 * WBTC_UNIT));
        b = uint96(bound(uint256(b), 1, 5 * WBTC_UNIT));

        wbtc.mint(alice, a);
        wbtc.mint(bob, b);

        _depositAs(alice, a);
        _depositAs(bob, b);

        // shares(alice) / shares(bob) ≈ a / b  (within 1 wei due to integer div)
        uint256 lhs = router.shares(alice) * uint256(b);
        uint256 rhs = router.shares(bob) * uint256(a);
        assertApproxEqAbs(lhs, rhs, router.totalShares());
    }

    /// @dev Fee distribution must be conserved: sum of pending == total harvested.
    function testFuzz_feeConservation(uint96 aliceAmt, uint96 bobAmt, uint96 feeAmt) public {
        aliceAmt = uint96(bound(uint256(aliceAmt), 1, 5 * WBTC_UNIT));
        bobAmt = uint96(bound(uint256(bobAmt), 1, 5 * WBTC_UNIT));
        feeAmt = uint96(bound(uint256(feeAmt), 1, 1_000_000 * LUSD_UNIT));

        wbtc.mint(alice, aliceAmt);
        wbtc.mint(bob, bobAmt);

        _depositAs(alice, aliceAmt);
        _depositAs(bob, bobAmt);

        _addFees(feeAmt);
        router.harvest();

        uint256 total = router.pendingFees(alice) + router.pendingFees(bob);
        // Loss up to 1 wei per share holder due to integer division
        assertApproxEqAbs(total, feeAmt, 2);
    }

    /// @dev Withdraw after lock must return exactly the deposited principal.
    function testFuzz_withdrawReturnsPrincipal(uint96 amount) public {
        amount = uint96(bound(uint256(amount), 1, 5 * WBTC_UNIT));
        wbtc.mint(alice, amount);

        _depositAs(alice, amount);
        _advancePastLock();

        uint256 aliceShares = router.shares(alice);
        uint256 before = wbtc.balanceOf(alice);
        vm.prank(alice);
        router.withdraw(aliceShares);

        assertEq(wbtc.balanceOf(alice) - before, amount);
    }
}
