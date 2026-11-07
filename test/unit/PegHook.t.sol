// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta as BalanceDeltaT} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PegSystem, ReentryRouter} from "../utils/PegSystem.sol";
import {PegHook, IKeeperCap} from "../../src/peg/PegHook.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {Governed} from "../../src/Governed.sol";

/// @notice The peg hook against a local v4 PoolManager. Run for both token orders (see the two contracts at the end).
abstract contract PegHookTest is PegSystem {
    using StateLibrary for IPoolManager;

    uint256 constant CAP = 200_000e18;
    address caller = makeAddr("caller");

    function _quoteAddr() internal pure virtual returns (address);

    function setUp() public {
        vm.warp(1_800_000_000);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("USDC", uint8(6)), _quoteAddr());
        _deployPeg(IPoolManager(address(new PoolManager(address(this)))), IERC20(_quoteAddr()), CAP);
        _hold(0, 31 minutes); // a TWAP history at the peg
    }

    function test_order() public view {
        assertEq(hook.stableIsToken0(), address(usd) < address(usdc));
        assertEq(hook.spotTicks(), 0);
    }

    // ------------------------------------------------------------ TWAP gate

    function test_singleBlockManipulationCannotTrigger() public {
        int24 before = hook.twapTicks();
        assertLe(before, 1);
        assertGe(before, -1);
        _moveTo(100); // +1%
        assertEq(hook.twapTicks(), before, "a price moved this block has no weight yet");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PegHook.TwapInBand.selector, before));
        hook.provide();
        // One block later the manipulated tick has 12 s of a 30 min window: still nowhere near the trigger.
        vm.warp(vm.getBlockTimestamp() + 12);
        vm.roll(vm.getBlockNumber() + 1);
        int24 twap = hook.twapTicks();
        assertLt(twap, hook.TRIGGER_TICKS());
        vm.expectRevert(abi.encodeWithSelector(PegHook.TwapInBand.selector, twap));
        hook.provide();
        _moveTo(-100);
        vm.expectRevert();
        hook.withdraw();
        assertEq(hook.outstanding(), 0);
    }

    function test_noTwapBeforeWindow() public {
        // A fresh pool has no checkpoint old enough.
        PegHookFresh f = new PegHookFresh();
        f.check();
    }

    // ------------------------------------------------------------ above the peg

    function test_provideClosesExcursionAbove() public {
        _hold(60, 31 minutes); // +0.6% for the window
        assertGt(hook.twapTicks(), hook.TRIGGER_TICKS());
        uint256 tBefore = usdc.balanceOf(address(treasury));
        vm.prank(caller);
        uint256 minted = hook.provide();
        assertGt(minted, 0);
        assertEq(hook.outstanding(), minted);
        uint256 px = _spotPrice();
        assertLe(px, 1.0006e18, "price back near $1");
        assertGe(px, 1e18, "never sells below $1");
        // Sold above $1: USDC held covers the principal, profit split caller/Treasury.
        uint256 profit = usdc.balanceOf(address(treasury)) - tBefore + usdc.balanceOf(caller);
        assertGt(profit, 0);
        assertApproxEqAbs(usdc.balanceOf(caller), profit * hook.REWARD_BPS() / 10_000, 1);
        assertEq(usdc.balanceOf(address(hook)), hook.principal() + 0, "only the principal stays");
        // The hook's own swap skips its callbacks, so it recorded the new tick itself.
        (, int24 tick,,) = pm.getSlot0(key.toId());
        assertEq(hook.lastTick(), tick);
        _assertKeeperSolvent();
    }

    function test_capEnforced() public {
        _hold(300, 31 minutes); // +3%: more to sell than the cap allows
        uint256 minted = hook.provide();
        assertEq(minted, CAP, "stops at the cap");
        assertGt(hook.spotTicks(), hook.TARGET_TICKS(), "cap left the price above target");
        _hold(300, 31 minutes);
        vm.expectRevert(PegHook.CapReached.selector);
        hook.provide();
        _assertKeeperSolvent();
    }

    function test_lowerCapStopsMintsNotBuybacks() public {
        _hold(60, 31 minutes);
        uint256 minted = hook.provide();
        bytes memory pz = abi.encode(params.SET_KEEPER_CAP(), uint256(0));
        vm.prank(governor);
        params.propose(pz);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        _hold(-60, 31 minutes);
        (uint256 burned,) = hook.withdraw();
        assertGt(burned, 0);
        assertLe(burned, minted);
        _hold(60, 31 minutes);
        vm.expectRevert(PegHook.CapReached.selector);
        hook.provide();
    }

    // ------------------------------------------------------------ below the peg

    function test_withdrawClosesExcursionBelow() public {
        _hold(60, 31 minutes);
        uint256 minted = hook.provide();
        uint256 tAfterProvide = usdc.balanceOf(address(treasury));
        _hold(-60, 31 minutes);
        assertLt(hook.twapTicks(), -hook.TRIGGER_TICKS());
        uint256 supplyBefore = usd.totalSupply();
        vm.prank(caller);
        (uint256 burned,) = hook.withdraw();
        assertGt(burned, 0);
        assertLe(burned, minted, "never burns more than minted");
        assertEq(usd.totalSupply(), supplyBefore - burned);
        assertEq(hook.outstanding(), minted - burned);
        uint256 px = _spotPrice();
        assertGe(px, 0.9994e18, "price back near $1");
        assertLe(px, 1e18, "never buys above $1");
        assertGt(usdc.balanceOf(address(treasury)), tAfterProvide, "buy-back profit to the Treasury");
        _assertKeeperSolvent();
    }

    function test_withdrawWithNothingOutstanding() public {
        _hold(-60, 31 minutes);
        vm.expectRevert(PegHook.NothingToDo.selector);
        hook.withdraw();
    }

    function test_fullRoundTripRetiresEverything() public {
        // Small excursion above, deep one below: the keeper buys back everything it sold.
        _hold(40, 31 minutes);
        uint256 minted = hook.provide();
        _hold(-150, 31 minutes);
        (uint256 burned,) = hook.withdraw();
        assertEq(burned, minted);
        assertEq(hook.outstanding(), 0);
        assertEq(hook.principal(), 0);
        assertEq(usdc.balanceOf(address(hook)), 0, "all USDC paid out: reward + Treasury");
        _assertKeeperSolvent();
    }

    // ------------------------------------------------------------ the quote gate

    function test_quoteGateRefusesProvideWhenDepegged() public {
        _hold(60, 31 minutes); // +0.6%: above the trigger
        assertGt(hook.twapTicks(), hook.TRIGGER_TICKS());
        quoteUsd.set(0.97e8);
        assertFalse(hook.quoteSound());
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.provide();
        quoteUsd.set(0.9799e8);
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.provide();
        quoteUsd.set(0.98e8); // the floor itself is sound
        assertGt(hook.provide(), 0);
        _assertKeeperSolvent();
    }

    function test_quoteGateRefusesProvideWhenStaleOrBroken() public {
        _hold(60, 31 minutes);
        quoteUsd.setAge(QUOTE_MAX_AGE + 1);
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.provide();
        quoteUsd.setAge(0);
        quoteUsd.setBroken(true); // latestRoundData reverts: fail closed
        assertFalse(hook.quoteSound());
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.provide();
        quoteUsd.setBroken(false);
        quoteUsd.set(0);
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.provide();
        quoteUsd.set(1e8);
        quoteUsd.setAge(QUOTE_MAX_AGE); // exactly at the max age is still fresh
        assertGt(hook.provide(), 0);
    }

    function test_quoteGateStopsBufferBuyNotTheBurn() public {
        _setBufferTarget(50_000e6);
        _hold(60, 31 minutes);
        uint256 minted = hook.provide();
        uint256 kept = hook.buffer();
        assertGt(kept, 0);
        _hold(-150, 31 minutes); // deep below: the burn alone leaves the price under target
        quoteUsd.set(0.97e8);
        uint256 supply = usd.totalSupply();
        (uint256 burned, uint256 bought) = hook.withdraw();
        assertEq(burned, minted, "burning outstanding imdUSD is never gated");
        assertEq(usd.totalSupply(), supply - burned);
        assertEq(bought, 0, "the buffer does not buy against a depegged quote");
        assertGe(hook.buffer(), kept, "unspent (the burn's own profit may have topped it up)");
        uint256 afterBurn = hook.buffer();
        assertLt(hook.spotTicks(), -hook.TARGET_TICKS());
        // Nothing outstanding now: a buffer-only call refuses while unsound, buys once sound.
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.withdraw();
        quoteUsd.set(1e8);
        quoteUsd.setAge(QUOTE_MAX_AGE + 1);
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.withdraw();
        quoteUsd.setAge(0);
        (, bought) = hook.withdraw();
        assertGt(bought, 0);
        assertLt(hook.buffer(), afterBurn);
        _assertKeeperSolvent();
    }

    function test_quoteFeedRequired() public {
        vm.expectRevert(PegHook.ZeroAddress.selector);
        new PegHook(pm, address(usd), address(usdc), address(treasury), params_(), address(0), 1 days);
        vm.expectRevert(PegHook.ZeroAddress.selector);
        new PegHook(pm, address(usd), address(usdc), address(treasury), params_(), address(quoteUsd), 0);
    }

    function params_() internal view returns (IKeeperCap) {
        return IKeeperCap(address(params));
    }

    // ------------------------------------------------------------ the buffer

    function test_profitFillsBufferUpToTargetThenTreasury() public {
        _setBufferTarget(100e6);
        _hold(60, 31 minutes);
        uint256 t0 = usdc.balanceOf(address(treasury));
        vm.prank(caller);
        hook.provide();
        uint256 reward = usdc.balanceOf(caller);
        uint256 toTreasury = usdc.balanceOf(address(treasury)) - t0;
        uint256 profit = usdc.balanceOf(address(hook)) - hook.principal() + reward + toTreasury;
        assertGt(profit, 100e6 + profit / 10, "enough profit to fill the target and overflow");
        assertEq(hook.buffer(), 100e6, "the buffer stops at its target");
        assertEq(reward, profit * hook.REWARD_BPS() / 10_000, "the caller still gets 10% of what it realised");
        assertEq(toTreasury, profit - reward - 100e6, "the rest goes to the Treasury");
        assertEq(usdc.balanceOf(address(hook)), hook.principal() + hook.buffer());
        _assertKeeperSolvent();
    }

    function test_zeroTargetKeepsNothing() public {
        _hold(60, 31 minutes);
        hook.provide();
        assertEq(hook.buffer(), 0);
        assertEq(usdc.balanceOf(address(hook)), hook.principal(), "target 0: every unit of profit leaves, as before");
    }

    function test_bufferBuysOnceNothingIsOutstanding() public {
        _setBufferTarget(50_000e6);
        _hold(60, 31 minutes);
        uint256 minted = hook.provide();
        uint256 kept = hook.buffer();
        assertGt(kept, 0);
        _hold(-150, 31 minutes); // a deep fall: buying back what it minted leaves the price low
        uint256 supply = usd.totalSupply();
        uint256 tUsd = usd.balanceOf(address(treasury));
        uint256 t0 = usdc.balanceOf(address(treasury));
        vm.prank(caller);
        (uint256 burned, uint256 bought) = hook.withdraw();
        assertEq(burned, minted, "the outstanding imdUSD is bought back first");
        assertEq(hook.outstanding(), 0);
        assertGt(bought, 0, "then the buffer buys");
        assertEq(usd.balanceOf(address(treasury)) - tUsd, bought, "held by the Treasury");
        assertEq(usd.totalSupply(), supply - burned, "the buffer leg burns nothing");
        assertLt(hook.buffer(), kept, "the buffer was spent");
        assertGe(usdc.balanceOf(address(treasury)), t0, "the Treasury paid nothing");
        assertLe(_spotPrice(), 1e18, "never buys above $1");
        _assertKeeperSolvent();
    }

    function test_bufferPurchasePaysNoReward() public {
        // The same excursion twice, without and with a buffer: the caller earns exactly the same, so the buffer leg
        // adds nothing to the reward.
        uint256 snap = vm.snapshotState();
        uint256 plain = _roundTripReward();
        vm.revertToState(snap);
        _setBufferTarget(50_000e6);
        uint256 withBuffer = _roundTripReward();
        assertEq(withBuffer, plain);
    }

    function _roundTripReward() internal returns (uint256) {
        _hold(60, 31 minutes);
        vm.prank(caller);
        hook.provide();
        _hold(-150, 31 minutes);
        vm.prank(caller);
        hook.withdraw();
        _assertKeeperSolvent();
        return usdc.balanceOf(caller);
    }

    function test_bufferUntouchedInBand() public {
        _setBufferTarget(50_000e6);
        _hold(60, 31 minutes);
        hook.provide();
        uint256 b = hook.buffer();
        _hold(-10, 31 minutes); // inside the trigger
        vm.expectRevert();
        hook.withdraw();
        assertEq(hook.buffer(), b);
    }

    function test_pullBufferGovernorOnlyToTreasury() public {
        _setBufferTarget(50_000e6);
        _hold(60, 31 minutes);
        hook.provide();
        uint256 b = hook.buffer();
        assertGt(b, 1);
        vm.expectRevert(PegHook.NotGovernor.selector);
        hook.pullBuffer(1);
        vm.prank(governor);
        vm.expectRevert(PegHook.ExceedsBuffer.selector);
        hook.pullBuffer(b + 1);
        uint256 t0 = usdc.balanceOf(address(treasury));
        vm.prank(governor);
        hook.pullBuffer(b / 2);
        assertEq(usdc.balanceOf(address(treasury)) - t0, b / 2);
        assertEq(hook.buffer(), b - b / 2);
        _assertKeeperSolvent();
    }

    function test_donationIsNotBuffer() public {
        _setBufferTarget(50_000e6);
        deal(address(usdc), address(hook), 7_000e6);
        assertEq(hook.buffer(), 0);
        assertEq(hook.surplus(), 7_000e6);
    }

    // ------------------------------------------------------------ funding the buffer

    /// @dev Lower the keeper cap to 0 through the timelock: the beta's first week (keeperCap 0 until day 7).
    function _zeroCap() internal {
        bytes memory pz = abi.encode(params.SET_KEEPER_CAP(), uint256(0));
        vm.prank(governor);
        params.propose(pz);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
    }

    /// @notice The beta's failing state: cap 0, target 5,000 USDC, the Safe sends 5,000 USDC to the hook, imdUSD trades at
    /// $0.985 for an hour. `withdraw()` used to revert NothingToDo (the USDC sat as surplus until a provide() happened);
    /// now it folds the surplus into the buffer and the buffer bids at once.
    function test_donationArmsTheBidOnWithdraw() public {
        _zeroCap();
        _setBufferTarget(5_000e6);
        deal(address(usdc), address(hook), 5_000e6);
        assertEq(hook.buffer(), 0, "a transfer is surplus until the hook acts");
        _hold(-150, 31 minutes); // $0.985
        uint256 tUsd = usd.balanceOf(address(treasury));
        uint256 tUsdc = usdc.balanceOf(address(treasury));
        vm.prank(caller);
        (uint256 burned, uint256 bought) = hook.withdraw();
        assertEq(burned, 0, "nothing outstanding at cap 0");
        assertGt(bought, 0, "the donated USDC bought imdUSD below the peg");
        assertEq(usd.balanceOf(address(treasury)) - tUsd, bought, "held by the Treasury");
        assertEq(usdc.balanceOf(address(treasury)), tUsdc, "the Treasury paid nothing");
        assertEq(usdc.balanceOf(caller), 0, "a donation is never a reward");
        assertLt(hook.buffer(), 5_000e6, "the buffer was spent");
        uint256 spent = 5_000e6 - usdc.balanceOf(address(hook)); // principal 0, nothing left over to refill from
        assertEq(hook.buffer() + spent, 5_000e6, "every USDC unit is buffer or spent: the donation was all bid");
        assertGe(bought / 1e12, spent, "bought below $1");
        assertLe(bought / 1e12, spent * 102 / 100, "and not far below it");
        assertLe(_spotPrice(), 1e18, "never buys above $1");
        _assertKeeperSolvent();
    }

    /// @notice A surplus above the target folds only up to the target: the buffer bids that much, is refilled to the
    /// target from what is left, and the rest goes to the Treasury as every surplus after a trade does (no reward: a
    /// donation is not realised profit).
    function test_surplusFoldsOnlyUpToTheTarget() public {
        _zeroCap();
        _setBufferTarget(1_000e6);
        deal(address(usdc), address(hook), 5_000e6);
        _hold(-150, 31 minutes);
        uint256 t = usdc.balanceOf(address(treasury));
        vm.prank(caller);
        (, uint256 bought) = hook.withdraw();
        assertGt(bought, 0);
        uint256 toTreasury = usdc.balanceOf(address(treasury)) - t;
        uint256 spent = 5_000e6 - usdc.balanceOf(address(hook)) - toTreasury;
        assertLe(spent, 1_000e6, "one call bids at most the target");
        assertGe(bought / 1e12, spent, "bought below $1");
        assertEq(hook.buffer(), 1_000e6, "refilled to the target from the surplus, and no further");
        assertEq(usdc.balanceOf(address(hook)), 1_000e6, "nothing else kept");
        assertEq(toTreasury, 4_000e6 - spent, "the rest went to the Treasury");
        assertEq(usdc.balanceOf(caller), 0, "no reward on a donation");
        _assertKeeperSolvent();
    }

    /// @notice The toll a pusher pays in USDC fills the buffer up to its target before anything reaches the Treasury: the
    /// surcharge becomes the bid against him. The stable side of the toll still goes to the Treasury.
    function test_sweepFillsBufferBeforeTreasury() public {
        _setBufferTarget(1_000e6);
        _moveTo(-150); // a sale past the wall: exact-in, so the toll is in the quote (USDC)
        Currency cq = hook.stableIsToken0() ? key.currency1 : key.currency0;
        uint256 claims = pm.balanceOf(address(hook), cq.toId());
        assertGt(claims, 1_000e6, "enough toll to fill the target and overflow");
        uint256 t = usdc.balanceOf(address(treasury));
        uint256 swept = hook.sweep(cq);
        assertEq(swept, claims);
        assertEq(hook.buffer(), 1_000e6, "the buffer took its target");
        assertEq(usdc.balanceOf(address(treasury)) - t, claims - 1_000e6, "the Treasury took the rest");
        assertEq(usdc.balanceOf(address(hook)), hook.principal() + hook.buffer(), "no surplus left behind");
        assertEq(pm.balanceOf(address(hook), cq.toId()), 0, "all claims burned");
        // Full buffer: the next sweep goes to the Treasury in full, as before.
        _moveTo(0);
        _moveTo(-150);
        uint256 more = pm.balanceOf(address(hook), cq.toId());
        t = usdc.balanceOf(address(treasury));
        hook.sweep(cq);
        assertEq(usdc.balanceOf(address(treasury)) - t, more);
        assertEq(hook.buffer(), 1_000e6);
        _assertKeeperSolvent();
    }

    /// @notice Anyone may pay USDC straight into the buffer, up to the room under the target; nothing at target 0.
    function test_fundBufferUpToRoom() public {
        deal(address(usdc), caller, 10_000e6);
        vm.prank(caller);
        usdc.approve(address(hook), type(uint256).max);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PegHook.ExceedsTarget.selector, 0));
        hook.fundBuffer(1e6);
        _setBufferTarget(5_000e6);
        assertEq(hook.bufferRoom(), 5_000e6);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PegHook.ExceedsTarget.selector, 5_000e6));
        hook.fundBuffer(5_000e6 + 1);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PegHook.ExceedsTarget.selector, 5_000e6));
        hook.fundBuffer(0);
        vm.prank(caller);
        hook.fundBuffer(3_000e6);
        assertEq(hook.buffer(), 3_000e6);
        assertEq(hook.bufferRoom(), 2_000e6);
        vm.prank(caller);
        hook.fundBuffer(2_000e6);
        assertEq(hook.buffer(), 5_000e6);
        assertEq(hook.bufferRoom(), 0);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PegHook.ExceedsTarget.selector, 0));
        hook.fundBuffer(1);
        assertEq(usdc.balanceOf(caller), 5_000e6);
        assertEq(hook.surplus(), 0, "funded USDC is buffer, not surplus");
        _assertKeeperSolvent();
        // And it bids like any other buffer.
        _hold(-150, 31 minutes);
        (, uint256 bought) = hook.withdraw();
        assertGt(bought, 0);
        _assertKeeperSolvent();
    }

    function test_bufferTargetBounded() public {
        bytes memory big = abi.encode(params.SET_BUFFER_TARGET(), params.MAX_BUFFER_TARGET() + 1);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(big);
        _setBufferTarget(params.MAX_BUFFER_TARGET());
        assertEq(params.bufferTarget(), params.MAX_BUFFER_TARGET());
    }

    // ------------------------------------------------------------ profit accounting

    function test_profitAccounting() public {
        uint256 tStart = usdc.balanceOf(address(treasury));
        _hold(60, 31 minutes);
        uint256 q0 = usdc.balanceOf(address(hook));
        vm.recordLogs();
        vm.prank(caller);
        hook.provide();
        (uint256 minted, uint256 quoteIn) = (hook.outstanding(), usdc.balanceOf(address(hook)) + usdc.balanceOf(caller)
            + usdc.balanceOf(address(treasury)) - tStart - q0);
        // USDC in = principal + caller reward + Treasury share, exactly.
        uint256 profit = quoteIn - hook.principal();
        assertGt(quoteIn * 1e12, minted, "sold above $1");
        assertEq(usdc.balanceOf(caller), profit * 1000 / 10_000);
        assertEq(usdc.balanceOf(address(treasury)) - tStart, profit - usdc.balanceOf(caller));
    }

    function test_donationGoesToTreasuryNotCaller() public {
        _hold(60, 31 minutes);
        deal(address(usdc), address(hook), 5_000e6);
        vm.prank(caller);
        hook.provide();
        // The caller's reward is a share of what THIS call realised, not of the donation.
        assertLt(usdc.balanceOf(caller), 500e6);
        assertGe(usdc.balanceOf(address(treasury)), 5_000e6);
    }

    // ------------------------------------------------------------ reentrancy and callbacks

    function test_cannotDriveKeeperFromInsideAnUnlock() public {
        ReentryRouter r = new ReentryRouter(pm, hook);
        _fund(address(r), 1_000_000e18, 1_000_000e6);
        SwapParams memory tiny = SwapParams(true, -1e6, TickMath.MIN_SQRT_PRICE + 1);
        // Each mode is tried where the keeper call WOULD succeed outside an unlock, so the revert is the nesting.
        _hold(60, 31 minutes);
        r.setMode(1);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        r.swap(key, tiny);
        hook.provide();
        _hold(-60, 31 minutes);
        r.setMode(2);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        r.swap(key, tiny);
        _moveTo(-150); // surcharge claims to sweep
        r.setMode(3);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        r.swap(key, tiny);
        // And outside an unlock both still work.
        hook.withdraw();
        hook.sweep(hook.stableIsToken0() ? key.currency1 : key.currency0);
    }

    function test_callbacksOnlyFromPoolManager() public {
        vm.expectRevert(PegHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), uint256(1e18)));
        vm.expectRevert(PegHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, 1, 0), BalanceDeltaZero.zero(), "");
        uint160 peg = hook.pegSqrtPriceX96();
        vm.expectRevert(PegHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, peg);
    }

    // ------------------------------------------------------------ toll

    function test_surchargeStillPaidAndSwept() public {
        _moveTo(-150); // a sale to -1.5%: past the wall
        Currency c = hook.stableIsToken0() ? key.currency1 : key.currency0; // exact-in sale: surcharge in the quote
        uint256 claims = pm.balanceOf(address(hook), c.toId());
        assertGt(claims, 0);
        uint256 t = usdc.balanceOf(address(treasury));
        hook.sweep(c);
        assertEq(usdc.balanceOf(address(treasury)) - t, claims);
        // Surcharge claims never count as keeper USDC.
        assertEq(usdc.balanceOf(address(hook)), 0);
    }

    function _sqrtAt(int24 stableTicks) internal view returns (uint160) {
        int24 t = hook.pegTick();
        return TickMath.getSqrtPriceAtTick(hook.stableIsToken0() ? t + stableTicks : t - stableTicks);
    }

    /// @dev zeroForOne for a sale of the stable (pushes it down), or a purchase (pushes it up).
    function _sells(bool sellStable) internal view returns (bool) {
        return sellStable == hook.stableIsToken0();
    }

    function test_tollCurve() public view {
        // Inside ±0.25% (25 ticks ~ 0.25%): free.
        assertEq(hook.surchargeFor(_sqrtAt(-20), _sells(true)), 0);
        assertEq(hook.surchargeFor(_sqrtAt(20), _sells(false)), 0);
        // The soft leg: ~0.62% sits about halfway to 1.5%.
        uint256 mid = hook.surchargeFor(_sqrtAt(-62), _sells(true));
        assertGt(mid, 5_000);
        assertLt(mid, 10_000);
        // Just inside ±1%: under the soft cap. Just past it: the wall, 5% or more.
        assertLe(hook.surchargeFor(_sqrtAt(-99), _sells(true)), hook.SOFT_CAP());
        assertGe(hook.surchargeFor(_sqrtAt(-99), _sells(true)), 14_000);
        assertGe(hook.surchargeFor(_sqrtAt(-101), _sells(true)), hook.WALL_SURCHARGE());
        assertLt(hook.surchargeFor(_sqrtAt(-101), _sells(true)), 55_000);
        // ±2% and beyond: capped at 20%.
        assertEq(hook.surchargeFor(_sqrtAt(-205), _sells(true)), hook.MAX_SURCHARGE());
        assertEq(hook.surchargeFor(_sqrtAt(-900), _sells(true)), hook.MAX_SURCHARGE());
        // ABOVE $1: the same soft leg, then flat at 1.5%: no wall, no 5-20% step.
        uint256 midUp = hook.surchargeFor(_sqrtAt(62), _sells(false));
        assertGt(midUp, 5_000);
        assertLt(midUp, 10_000);
        assertLe(hook.surchargeFor(_sqrtAt(99), _sells(false)), hook.SOFT_CAP());
        assertGe(hook.surchargeFor(_sqrtAt(99), _sells(false)), 14_000);
        assertEq(hook.surchargeFor(_sqrtAt(101), _sells(false)), hook.SOFT_CAP(), "+1%: flat, no wall");
        assertEq(hook.surchargeFor(_sqrtAt(150), _sells(false)), hook.SOFT_CAP());
        assertEq(hook.surchargeFor(_sqrtAt(205), _sells(false)), hook.SOFT_CAP(), "+2%: still 1.5%");
        assertEq(hook.surchargeFor(_sqrtAt(900), _sells(false)), hook.SOFT_CAP(), "+9%: still 1.5%");
        // Toward $1 pays nothing extra, however far out.
        assertEq(hook.surchargeFor(_sqrtAt(-150), _sells(false)), 0);
        assertEq(hook.surchargeFor(_sqrtAt(150), _sells(true)), 0);
        // The pool fee the router sees: the 0.01% base plus the surcharge.
        assertEq(hook.feeFor(_sqrtAt(-150), _sells(true)), hook.BASE_FEE() + hook.surchargeFor(_sqrtAt(-150), _sells(true)));
    }

    function test_tollIsMonotoneAway() public view {
        uint256 last;
        for (int24 t = 0; t <= 250; t += 5) {
            uint256 f = hook.surchargeFor(_sqrtAt(-t), _sells(true));
            assertGe(f, last, "the further from $1, the higher the toll");
            last = f;
        }
        last = 0;
        for (int24 t = 0; t <= 250; t += 5) {
            uint256 f = hook.surchargeFor(_sqrtAt(t), _sells(false));
            assertGe(f, last, "above $1: never falls going away");
            assertLe(f, hook.SOFT_CAP(), "above $1: never past 1.5%");
            last = f;
        }
    }

    // ------------------------------------------------------------ governance

    function test_keeperMinterSetOnceThroughTimelock() public {
        bytes memory pk = abi.encode(params.SET_KEEPER(), address(hook));
        vm.prank(governor);
        params.propose(pk);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(ImdUSD.AlreadySet.selector);
        params.applyPending();
        vm.prank(governor);
        params.cancel();
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        usd.setKeeper(address(this));
        bytes memory big = abi.encode(params.SET_KEEPER_CAP(), params.MAX_KEEPER_CAP() + 1);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(big);
        assertTrue(usd.isMinter(address(hook)));
    }

    // ------------------------------------------------------------ fuzz: random excursions

    /// forge-config: default.fuzz.runs = 64
    /// @dev Not hollow: where the keeper must act it is called directly (a revert fails the run), and only the
    /// ambiguous band between the trigger and ±40 ticks tolerates a revert.
    function testFuzz_randomExcursions(int16[8] memory moves, uint32 seed) public {
        (uint256 acted, uint256 bufferActed) = _excursions(moves, seed);
        emit log_named_uint("keeper actions that had to succeed", acted);
        emit log_named_uint("buffer purchases", bufferActed);
    }

    /// @dev The fuzz body run on fixed inputs: proves the buffer branch is really reached and succeeds.
    function test_excursionsReachTheBuffer() public {
        int16[8] memory moves = [int16(60), -150, 80, -180, 60, -199, 20, -160];
        (uint256 acted, uint256 bufferActed) = _excursions(moves, 25_001);
        assertGt(bufferActed, 1);
        assertGt(acted, bufferActed);
    }

    function _excursions(int16[8] memory moves, uint32 seed) internal returns (uint256 acted, uint256 bufferActed) {
        if (seed % 2 == 1) _setBufferTarget(uint256(seed % 50_000) * 1e6 + 1e6);
        for (uint256 i; i < moves.length; ++i) {
            int24 target = int24(moves[i] % 200);
            _hold(target, 31 minutes);
            if (target >= 40) {
                if (hook.outstanding() < CAP) {
                    assertGt(hook.provide(), 0);
                    ++acted;
                } else {
                    vm.expectRevert(PegHook.CapReached.selector);
                    hook.provide();
                }
            } else if (target <= -40) {
                if (hook.outstanding() > 0 || hook.buffer() > 0) {
                    uint256 b0 = hook.buffer();
                    (uint256 b, uint256 bought) = hook.withdraw();
                    assertGt(b + bought, 0);
                    if (bought != 0) {
                        // A burn in the same call may first top the buffer up with its profit, so only a buffer-only
                        // purchase must leave less than it found (pre-existing flaky assertion, seen 2026-10-28).
                        if (b == 0) assertLt(hook.buffer(), b0, "a buffer purchase spends the buffer");
                        ++bufferActed;
                    }
                    ++acted;
                } else {
                    vm.expectRevert(PegHook.NothingToDo.selector);
                    hook.withdraw();
                }
            } else if (target > 0) {
                try hook.provide() {} catch {}
            } else {
                try hook.withdraw() {} catch {}
            }
            _assertKeeperSolvent();
            assertLe(hook.outstanding(), CAP);
        }
    }
}

library BalanceDeltaZero {
    function zero() internal pure returns (BalanceDeltaT) {
        return BalanceDeltaT.wrap(0);
    }
}

contract PegHookFresh is PegSystem {
    function check() external {
        address q = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("USDC", uint8(6)), q);
        _deployPeg(IPoolManager(address(new PoolManager(address(this)))), IERC20(q), 1e24);
        _moveTo(100);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.expectRevert(PegHook.NoTwap.selector);
        hook.provide();
    }
}

contract PegHookStable0Test is PegHookTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF); // USDC sorts after imdUSD
    }
}

contract PegHookStable1Test is PegHookTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001); // USDC sorts before imdUSD
    }
}
