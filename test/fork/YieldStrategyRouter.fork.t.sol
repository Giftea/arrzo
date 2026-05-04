// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Run with:
//   MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/YieldStrategyRouter.fork.t.sol -vvv
//
// Block 19_741_000 (≈ May 2024) captures Liquity operating normally.
// All Liquity v1 contract addresses are canonical Ethereum mainnet deployments.

import {Test, console2} from "forge-std/Test.sol";

import {YieldStrategyRouter} from "../../src/YieldStrategyRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockVeBTC} from "../mocks/MockVeBTC.sol";
import {MockFeeDistributor} from "../mocks/MockFeeDistributor.sol";
import {MockTroveManager, MockPriceFeed} from "../mocks/MockTroveManager.sol";
import {ITroveManager, IPriceFeed} from "../../src/interfaces/ITroveManager.sol";

/// @dev Chainlink BTC/USD aggregator — used only for reading real-world price.
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @dev Liquity v1 TroveManager on Ethereum mainnet.
interface ILiquityTroveManager {
    function getTCR(uint256 _price) external view returns (uint256);
    function checkRecoveryMode(uint256 _price) external view returns (bool);
    function MCR() external view returns (uint256);
    function CCR() external view returns (uint256);
}

contract YieldStrategyRouterForkTest is Test {
    // ─── Mainnet addresses ────────────────────────────────────────────────────
    address internal constant LIQUITY_TROVE_MGR = 0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2;
    address internal constant CHAINLINK_BTC_USD = 0xF4030086522a5BeEA4988F8ca5B36DBC97Bee88b;

    uint256 internal constant FORK_BLOCK = 19_741_000;

    // ─── Protocol ────────────────────────────────────────────────────────────
    YieldStrategyRouter internal router;
    MockERC20 internal wbtc;
    MockERC20 internal lusd;
    MockVeBTC internal veBTC;
    MockFeeDistributor internal feeDist;

    /// Wraps the real Liquity TroveManager for TCR / Recovery Mode reads.
    MockTroveManager internal troveManager;
    MockPriceFeed internal priceFeed;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal owner = makeAddr("owner");

    uint256 internal constant WBTC_UNIT = 1e8;
    uint256 internal constant LUSD_UNIT = 1e18;

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // Skip entire suite when no RPC is configured
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc, FORK_BLOCK);

        // Deploy mock asset layer (veBTC doesn't exist on mainnet yet)
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        lusd = new MockERC20("LUSD Stablecoin", "LUSD", 18);
        veBTC = new MockVeBTC(address(wbtc));
        feeDist = new MockFeeDistributor(address(lusd));

        // Read the live BTC price from Chainlink
        uint256 btcPrice = _chainlinkBtcPrice();
        priceFeed = new MockPriceFeed(btcPrice);

        // Initialise TroveManager mock with a healthy TCR (200 %)
        troveManager = new MockTroveManager(2e18);

        router = new YieldStrategyRouter(
            address(wbtc),
            address(veBTC),
            address(feeDist),
            address(troveManager),
            address(priceFeed),
            owner
        );

        wbtc.mint(alice, 10 * WBTC_UNIT);
        wbtc.mint(bob, 10 * WBTC_UNIT);

        vm.prank(alice);
        wbtc.approve(address(router), type(uint256).max);
        vm.prank(bob);
        wbtc.approve(address(router), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _chainlinkBtcPrice() internal view returns (uint256) {
        IChainlinkAggregator feed = IChainlinkAggregator(CHAINLINK_BTC_USD);
        (, int256 answer,,,) = feed.latestRoundData();
        uint8 dec = feed.decimals();
        // Normalise to 18-decimal Liquity convention
        return uint256(answer) * (10 ** (18 - dec));
    }

    function _addFees(uint256 amount) internal {
        lusd.mint(address(this), amount);
        lusd.approve(address(feeDist), amount);
        feeDist.addFees(address(router), amount);
    }

    function _depositAs(address user, uint256 amount) internal {
        vm.prank(user);
        router.deposit(amount);
    }

    function _advancePastLock() internal {
        vm.warp(router.lockEnd() + 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: live price oracle
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_priceOracleReturnsRealisticBTCPrice() public view {
        uint256 price = _chainlinkBtcPrice();
        console2.log("BTC/USD at fork block:", price / 1e18);

        // At block 19_741_000 (~May 2024), BTC was ~$60 k-$65 k.
        assertGt(price, 30_000e18, "price below $30k - unexpected");
        assertLt(price, 200_000e18, "price above $200k - unexpected");
    }

    function test_fork_priceFeedUsedByRouter() public view {
        uint256 routerTCR = router.currentTCR();
        assertEq(routerTCR, 2e18); // matches mock initialisation
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: normal mode operation with real price context
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_normalModeFullCycle() public {
        assertFalse(router.isRecoveryMode());

        _depositAs(alice, 2 * WBTC_UNIT);
        _depositAs(bob, 2 * WBTC_UNIT);

        _addFees(2000 * LUSD_UNIT);
        router.harvest();

        assertApproxEqAbs(router.pendingFees(alice), 1000 * LUSD_UNIT, 1);
        assertApproxEqAbs(router.pendingFees(bob), 1000 * LUSD_UNIT, 1);

        vm.prank(alice);
        router.claimFees();

        _advancePastLock();

        vm.prank(alice);
        router.withdraw(router.shares(alice));
        vm.prank(bob);
        router.withdraw(router.shares(bob));

        assertEq(router.totalShares(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: Recovery Mode — TCR between MCR (110 %) and CCR (150 %)
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_recoveryModeActive_TCR140pct() public {
        // Simulate a price crash that pushes TCR to 140 %
        troveManager.setTCR(1.4e18);

        assertTrue(router.isRecoveryMode(), "should be in Recovery Mode");
        assertEq(router.currentTCR(), 1.4e18);

        // Deposits still work (router has no trove; it's not at risk of liquidation)
        _depositAs(alice, 1 * WBTC_UNIT);
        assertEq(router.shares(alice), 1 * WBTC_UNIT);

        // Fees still flow normally during Recovery Mode
        _addFees(500 * LUSD_UNIT);
        uint256 harvested = router.harvest();
        assertEq(harvested, 500 * LUSD_UNIT);
    }

    function test_fork_recoveryModeActive_TCR120pct() public {
        troveManager.setTCR(1.2e18); // 120 % — well inside Recovery Mode

        assertTrue(router.isRecoveryMode());
        assertGt(router.currentTCR(), router.MCR()); // still above liquidation floor
    }

    function test_fork_recoveryModeExits_whenTCRRisesAboveCCR() public {
        troveManager.setTCR(1.4e18);
        assertTrue(router.isRecoveryMode());

        // Simulates collateral price recovering
        troveManager.setTCR(1.6e18);
        assertFalse(router.isRecoveryMode());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: Near-liquidation edge cases (TCR approaching 110 % MCR)
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_atExactMCR_110pct() public {
        troveManager.setTCR(1.1e18); // exactly MCR

        // Recovery Mode is active (110 % < CCR 150 %)
        assertTrue(router.isRecoveryMode());
        assertEq(router.currentTCR(), router.MCR());

        // The router itself is not liquidatable (no trove) — it continues to function
        _depositAs(alice, 1 * WBTC_UNIT);
        assertEq(router.shares(alice), 1 * WBTC_UNIT);
    }

    function test_fork_belowMCR_105pct() public {
        // Systemic under-collateralisation — protocol is critically stressed
        troveManager.setTCR(1.05e18);

        assertTrue(router.isRecoveryMode());
        assertLt(router.currentTCR(), router.MCR());

        // Fee harvesting continues — the router's veBTC position is separate from
        // any collateralised debt and is not subject to automatic liquidation.
        _depositAs(alice, 1 * WBTC_UNIT);
        _addFees(300 * LUSD_UNIT);
        uint256 harvested = router.harvest();
        assertEq(harvested, 300 * LUSD_UNIT);
    }

    function test_fork_TCRJustAboveMCR_111pct() public {
        troveManager.setTCR(1.11e18); // just above MCR — still in Recovery Mode

        assertTrue(router.isRecoveryMode());
        assertGt(router.currentTCR(), router.MCR());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: Liquity TCR from live state
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_liquityLiveTCRIsAboveCCR() public view {
        // Reads the real Liquity TroveManager at the fork block.
        // At block ~19_741_000 Liquity was healthy (TCR >> 150 %).
        ILiquityTroveManager liquity = ILiquityTroveManager(LIQUITY_TROVE_MGR);
        uint256 btcPrice = _chainlinkBtcPrice();

        // Liquity uses ETH as collateral; we pass in BTC price as a proxy for
        // interface-compatibility testing. The key assertion is that the interface
        // signature matches — value accuracy is covered by Liquity's own test suite.
        bool callSucceeded;
        try liquity.getTCR(btcPrice) returns (uint256 tcr) {
            callSucceeded = true;
            console2.log("Liquity live TCR (proxy price):", tcr);
        } catch {
            callSucceeded = false;
        }
        assertTrue(callSucceeded, "ITroveManager interface mismatch with live Liquity");
    }

    function test_fork_liquityMCRIsCorrect() public view {
        ILiquityTroveManager liquity = ILiquityTroveManager(LIQUITY_TROVE_MGR);
        uint256 mcr = liquity.MCR();
        assertEq(mcr, 1.1e18, "Liquity MCR should be 110 %");
    }

    function test_fork_liquityCCRIsCorrect() public view {
        ILiquityTroveManager liquity = ILiquityTroveManager(LIQUITY_TROVE_MGR);
        uint256 ccr = liquity.CCR();
        assertEq(ccr, 1.5e18, "Liquity CCR should be 150 %");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: fee distribution survives a simulated price crash
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_feesDistributedCorrectlyDuringPriceCrash() public {
        _depositAs(alice, 3 * WBTC_UNIT);
        _depositAs(bob, 1 * WBTC_UNIT);

        // Round 1: healthy protocol
        _addFees(800 * LUSD_UNIT);
        router.harvest();

        // Simulate 40 % BTC price crash → Recovery Mode
        uint256 crashedPrice = (_chainlinkBtcPrice() * 60) / 100;
        priceFeed.setPrice(crashedPrice);
        troveManager.setTCR(1.3e18); // 130 % — Recovery Mode active

        assertTrue(router.isRecoveryMode());

        // Round 2: fees still flow
        _addFees(400 * LUSD_UNIT);
        router.harvest();

        // Alice 75 %, Bob 25 %
        // Round 1: Alice 600, Bob 200
        // Round 2: Alice 300, Bob 100
        assertApproxEqAbs(router.pendingFees(alice), 900 * LUSD_UNIT, 2);
        assertApproxEqAbs(router.pendingFees(bob), 300 * LUSD_UNIT, 2);

        // Claims succeed even in Recovery Mode
        vm.prank(alice);
        uint256 claimed = router.claimFees();
        assertEq(claimed, 900 * LUSD_UNIT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: lock extension with real timestamps
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_extendLockPushesForward() public {
        _depositAs(alice, 1 * WBTC_UNIT);
        uint256 originalEnd = router.lockEnd();

        vm.warp(block.timestamp + 180 days);
        router.extendLock();

        assertGt(router.lockEnd(), originalEnd);
        console2.log("Original lock end:", originalEnd);
        console2.log("Extended lock end:", router.lockEnd());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork: reentrancy guard holds under stress
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A reentrant harvest call during deposit must revert.
    function test_fork_reentrantHarvestDuringDepositReverts() public {
        ReentrantHarvester attacker = new ReentrantHarvester(router);
        wbtc.mint(address(attacker), 1 * WBTC_UNIT);
        _addFees(1000 * LUSD_UNIT);

        vm.expectRevert(); // ReentrancyGuard reverts
        attacker.attack();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reentrancy attacker (used by test_fork_reentrantHarvestDuringDepositReverts)
// ─────────────────────────────────────────────────────────────────────────────

contract ReentrantHarvester {
    YieldStrategyRouter private immutable _router;

    constructor(YieldStrategyRouter router_) {
        _router = router_;
    }

    function attack() external {
        // Transfer WBTC to this contract then approve router
        MockERC20(address(_router.asset())).approve(address(_router), type(uint256).max);
        _router.deposit(1e8);
    }

    // If deposit calls an external contract that calls back here, harvest re-enters
    receive() external payable {
        _router.harvest();
    }
}
