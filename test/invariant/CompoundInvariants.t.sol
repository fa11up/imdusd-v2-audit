// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {CompoundLens} from "../../src/dex/CompoundLens.sol";
import {CdxRouter, MockSIMD, MockSINFER} from "../utils/DexMocks.sol";
import {CompoundMockSystem} from "../utils/CompoundMockSystem.sol";

/// @notice Drives one Compound DEX pool with swaps both ways (v4 path exact in/out with and without the share
/// fallback, and the direct path in every raw/staked mix), deposits and withdrawals in either form, drips on
/// either vault, an attacker stamping the hook's sIMD hold, compounding and time warps. Ghosts record every
/// breach of the four properties; the invariants read them.
contract CdxHandler is Test {
    CompoundHook public hook;
    CompoundLens public lens;
    CdxRouter public router;
    PoolKey key;
    MockSIMD public simd;
    MockSINFER public sinfer;
    address public treasury;
    address public attacker;
    address[] public actors; // actors[0] = attacker
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // success counters (the suite is not hollow: test_handlerActionsSucceed drives each one)
    uint256 public ok_swapPM;
    uint256 public ok_swapPMOut;
    uint256 public ok_swapPMShares; // a v4 swap paid in shares because the buffer was short
    uint256 public ok_swapHook;
    uint256 public ok_swapHookStaked; // direct swap with a staked side
    uint256 public ok_deposit;
    uint256 public ok_depositStaked;
    uint256 public ok_withdraw;
    uint256 public ok_withdrawRaw;
    uint256 public ok_drip;
    uint256 public ok_stamp;
    uint256 public ok_warp;
    uint256 public ok_compound;

    // ghosts
    uint256 public epoch; // advances on every time or rate change
    address public lastActor;
    uint256 public baseEpoch;
    uint256 public base0;
    uint256 public base1;
    uint256 public bad_profit; // (b)
    uint256 public bad_treasury; // (c)
    uint256 public bad_centre; // (d)
    int256 public worstCentreExcess;
    uint256 public maxProfit0;
    uint256 public maxProfit1;

    constructor(
        CompoundHook hook_,
        CompoundLens lens_,
        CdxRouter router_,
        PoolKey memory key_,
        MockSIMD simd_,
        MockSINFER sinfer_,
        address treasury_,
        address[] memory actors_
    ) {
        hook = hook_;
        lens = lens_;
        router = router_;
        key = key_;
        simd = simd_;
        sinfer = sinfer_;
        treasury = treasury_;
        actors = actors_;
        attacker = actors_[0];
    }

    // ------------------------------------------------------------ helpers

    function _tok(uint8 i) internal view returns (IERC20) {
        return i == 0 ? hook.token0() : hook.token1();
    }

    function _vlt(uint8 i) internal view returns (IERC4626) {
        return i == 0 ? hook.vault0() : hook.vault1();
    }

    /// @dev The attacker acts three times in five, so its runs of own actions inside an epoch are long.
    function _actor(uint256 seed) internal view returns (address) {
        uint256 r = seed % 5;
        return r < 3 ? attacker : actors[1 + (r - 3) % (actors.length - 1)];
    }

    function worth(address who) public view returns (uint256 v0, uint256 v1) {
        (uint256 l0, uint256 l1) = lens.previewWithdraw(hook, hook.balanceOf(who));
        v0 = _tok(0).balanceOf(who) + _vlt(0).convertToAssets(_vlt(0).balanceOf(who)) + l0;
        v1 = _tok(1).balanceOf(who) + _vlt(1).convertToAssets(_vlt(1).balanceOf(who)) + l1;
    }

    struct Pre {
        uint256 treasury;
        bool yieldPending;
        int256 centre;
        uint32 centreAt;
    }

    function _pre(address who) internal returns (Pre memory p) {
        // (b): a new run of the attacker's own actions starts a new baseline
        if (who == attacker && (lastActor != attacker || baseEpoch != epoch)) {
            (base0, base1) = worth(attacker);
            baseEpoch = epoch;
        }
        lastActor = who;
        p.treasury = hook.balanceOf(treasury);
        p.yieldPending = _vlt(0).convertToAssets(hook.RATE_UNIT()) > hook.rateMark(0)
            || _vlt(1).convertToAssets(hook.RATE_UNIT()) > hook.rateMark(1);
        p.centre = hook.centreMilli();
        p.centreAt = hook.centreAt();
    }

    function _post(address who, Pre memory p, bool feeTaken) internal {
        // (c) Treasury shares only grow, and only from a fee or a rate rise
        uint256 t = hook.balanceOf(treasury);
        if (t < p.treasury || (t > p.treasury && !feeTaken && !p.yieldPending)) bad_treasury++;
        // (d) the centre never outruns 55 milli-ticks per second
        int256 moved = hook.centreMilli() - p.centre;
        if (moved < 0) moved = -moved;
        int256 allowed = int256(uint256(vm.getBlockTimestamp() - p.centreAt)) * hook.CENTRE_MILLITICKS_PER_SECOND();
        if (moved > allowed) {
            bad_centre++;
            if (moved - allowed > worstCentreExcess) worstCentreExcess = moved - allowed;
        }
        // (b) no sequence of one actor's own actions inside one epoch leaves it better off on both sides
        if (who == attacker && baseEpoch == epoch) {
            (uint256 v0, uint256 v1) = worth(attacker);
            if (v0 >= base0 && v1 >= base1 && (v0 > base0 + 2 || v1 > base1 + 2)) {
                bad_profit++;
                if (v0 - base0 > maxProfit0) maxProfit0 = v0 - base0;
                if (v1 - base1 > maxProfit1) maxProfit1 = v1 - base1;
            }
        }
    }

    function _bump() internal {
        epoch++;
        lastActor = address(0);
    }

    // ------------------------------------------------------------ actions

    function swapPM(uint256 actorSeed, bool zeroForOne, uint256 amt, bool exactOut, bool allowShares) public {
        address who = _actor(actorSeed);
        Pre memory p = _pre(who);
        (uint256 h0, uint256 h1) = hook.totals();
        uint8 sIn = zeroForOne ? 0 : 1;
        uint8 sOut = 1 - sIn;
        uint256 hIn = sIn == 0 ? h0 : h1;
        uint256 hOut = sOut == 0 ? h0 : h1;
        if (hIn < 1e12 || hOut < 1e12) return;
        amt = bound(amt, 1e9, exactOut ? hOut / 5 : hIn / 4);
        if (amt > _tok(sIn).balanceOf(who) / 2) amt = _tok(sIn).balanceOf(who) / 2;
        if (amt == 0) return;
        bytes memory hd = allowShares ? abi.encode(true, who) : bytes("");
        uint256 shBefore = _vlt(sOut).balanceOf(who);
        uint256 rawBefore = _tok(sOut).balanceOf(who);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(who);
        try router.swap(key, SwapParams(zeroForOne, exactOut ? int256(amt) : -int256(amt), limit), hd) {
            if (exactOut) ok_swapPMOut++;
            else ok_swapPM++;
            if (_vlt(sOut).balanceOf(who) > shBefore && _tok(sOut).balanceOf(who) == rawBefore) ok_swapPMShares++;
            _post(who, p, true);
        } catch {
            _post(who, p, false);
        }
    }

    function swapHook(uint256 actorSeed, uint8 formSeed, uint256 amt, bool sharesIfShort) public {
        address who = _actor(actorSeed);
        Pre memory p = _pre(who);
        uint8 sIn = formSeed & 1;
        bool stIn = formSeed & 2 != 0;
        bool stOut = formSeed & 4 != 0;
        address tIn = stIn ? address(_vlt(sIn)) : address(_tok(sIn));
        address tOut = stOut ? address(_vlt(1 - sIn)) : address(_tok(1 - sIn));
        (uint256 h0, uint256 h1) = hook.totals();
        uint256 hIn = sIn == 0 ? h0 : h1;
        if (hIn < 1e12) return;
        uint256 cap = IERC20(tIn).balanceOf(who) / 2;
        uint256 maxIn = stIn ? _vlt(sIn).convertToShares(hIn / 4) : hIn / 4;
        if (cap < 1e9) return;
        amt = bound(amt, 1e9, maxIn < cap ? (maxIn < 1e9 ? 1e9 : maxIn) : cap);
        vm.prank(who);
        try hook.swap(tIn, amt, tOut, 0, who, sharesIfShort) {
            ok_swapHook++;
            if (stIn || stOut) ok_swapHookStaked++;
            _post(who, p, true);
        } catch {
            _post(who, p, false);
        }
    }

    function deposit(uint256 actorSeed, uint256 shares, bool staked0, bool staked1) public {
        address who = _actor(actorSeed);
        Pre memory p = _pre(who);
        uint256 s = hook.totalSupply();
        shares = bound(shares, 1e12, s / 3 + 1e12);
        vm.prank(who);
        try hook.deposit(shares, type(uint256).max, type(uint256).max, staked0, staked1, who) {
            ok_deposit++;
            if (staked0 || staked1) ok_depositStaked++;
        } catch {}
        _post(who, p, false);
    }

    function withdraw(uint256 actorSeed, uint256 shares, bool raw0, bool raw1) public {
        address who = _actor(actorSeed);
        Pre memory p = _pre(who);
        uint256 bal = hook.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(who);
        try hook.withdraw(shares, 0, 0, raw0, raw1, who) {
            ok_withdraw++;
            if (raw0 || raw1) ok_withdrawRaw++;
        } catch {}
        _post(who, p, false);
    }

    function drip(bool side0, uint256 bps) public {
        IERC4626 v = _vlt(side0 ? 0 : 1);
        bps = bound(bps, 1, 100); // 0.01% .. 1% of the vault
        uint256 amt = v.totalAssets() * bps / 10_000;
        if (address(v) == address(simd)) simd.drip(amt);
        else sinfer.drip(amt);
        ok_drip++;
        _bump();
    }

    /// @dev The grief: the attacker stamps a hold with 1-wei deposits (sIMD: blocks every redemption by that address
    /// this block; sINFER: holds only that lot): on the hook and every pocket (the whole hold), or on the pocket
    /// this block's stakes land in.
    function stamp(uint8 which) public {
        Pre memory p = _pre(attacker);
        IERC4626 v = which % 2 == 0 ? IERC4626(address(simd)) : IERC4626(address(sinfer));
        uint256 n = which % 4 < 2 ? 1 + hook.POCKETS() : 1;
        for (uint256 k; k < n; ++k) {
            address target = n == 1 ? hook.pocket() : k == 0 ? address(hook) : hook.pockets(k - 1);
            vm.prank(attacker);
            try v.deposit(1, target) {
                ok_stamp++;
            } catch {}
        }
        _post(attacker, p, false);
    }

    function warp(uint256 secs) public {
        secs = bound(secs, 1, 2 hours);
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12 + 1);
        ok_warp++;
        _bump();
    }

    function compound(uint256 actorSeed) public {
        address who = _actor(actorSeed);
        Pre memory p = _pre(who);
        vm.prank(who);
        try hook.compound() {
            ok_compound++;
        } catch {}
        _post(who, p, false);
    }
}

contract CompoundInvariantsTest is CompoundMockSystem {
    CdxHandler handler;
    address lp0 = makeAddr("seedLP");
    address[] actors;

    function setUp() public {
        _deployMock(uint160(1 << 96) * 3 / 2); // price 2.25 token1 per token0
        _seed(lp0, SEED, SEED * 9 / 4);
        _hold(lp0, 31 minutes);
        actors.push(makeAddr("attacker"));
        actors.push(makeAddr("lp2"));
        actors.push(makeAddr("trader2"));
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            _fundRaw(a, 0, 50_000_000e18);
            _fundRaw(a, 1, 50_000_000e18);
            _fundStaked(a, 0, 5_000_000e18);
            _fundStaked(a, 1, 5_000_000e18);
            _approveAll(a);
            vm.startPrank(a);
            imd.approve(address(simd), type(uint256).max);
            infer.approve(address(sinfer), type(uint256).max);
            vm.stopPrank();
        }
        _next();
        handler = new CdxHandler(hook, lens, router, key, simd, sinfer, treasury, actors);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = CdxHandler.swapPM.selector;
        sel[1] = CdxHandler.swapHook.selector;
        sel[2] = CdxHandler.deposit.selector;
        sel[3] = CdxHandler.withdraw.selector;
        sel[4] = CdxHandler.drip.selector;
        sel[5] = CdxHandler.stamp.selector;
        sel[6] = CdxHandler.warp.selector;
        sel[7] = CdxHandler.compound.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](actors.length + 3);
        for (uint256 i; i < actors.length; ++i) {
            h[i] = actors[i];
        }
        h[actors.length] = lp0;
        h[actors.length + 1] = treasury;
        h[actors.length + 2] = 0x000000000000000000000000000000000000dEaD;
    }

    /// @notice (a) The hook's assets, in underlying units, cover what every LP share redeems for, and the curve never
    /// claims more than the hook holds.
    function invariant_a_solvent() public view {
        (uint256 h0, uint256 h1) = hook.totals();
        address[] memory hs = _holders();
        uint256 sum0;
        uint256 sum1;
        uint256 shares;
        for (uint256 i; i < hs.length; ++i) {
            uint256 b = hook.balanceOf(hs[i]);
            shares += b;
            (uint256 a0, uint256 a1) = lens.previewWithdraw(hook, b);
            sum0 += a0;
            sum1 += a1;
        }
        assertEq(shares, hook.totalSupply(), "every share is held by a known holder");
        assertLe(sum0, h0, "side 0 covers all shares");
        assertLe(sum1, h1, "side 1 covers all shares");
        _assertCovered();
    }

    /// @notice (b) No run of one actor's own actions inside one epoch (no time passing, no rate change) ends with
    /// that actor holding more underlying on one side and no less on the other (2-wei valuation tolerance).
    function invariant_b_noRoundTripProfit() public view {
        assertEq(handler.bad_profit(), 0, "round-trip profit");
    }

    /// @notice (c) Treasury shares never fall, and rise only on an action that took a swap fee or found a rate rise.
    function invariant_c_treasuryFromFeesAndYieldOnly() public view {
        assertEq(handler.bad_treasury(), 0, "treasury shares from elsewhere");
    }

    /// @notice (d) The centre never moves faster than 55 milli-ticks a second (198 ticks = 1.98% an hour).
    function invariant_d_centreSpeed() public view {
        assertEq(handler.bad_centre(), 0, "centre too fast");
    }

    /// @notice After any sequence every holder can still exit in full, and nobody's exit reverts.
    function afterInvariant() external {
        address[] memory hs = _holders();
        for (uint256 i; i < hs.length; ++i) {
            uint256 b = hook.balanceOf(hs[i]);
            if (b == 0 || hs[i] == 0x000000000000000000000000000000000000dEaD) continue;
            vm.prank(hs[i]);
            hook.withdraw(b, 0, 0, i % 2 == 0, i % 2 == 1, hs[i]);
        }
        assertEq(
            hook.totalSupply(), hook.balanceOf(0x000000000000000000000000000000000000dEaD), "only dead shares left"
        );
        _assertCovered();
    }

    /// @notice Non-hollow: every handler action succeeds, with the paths that matter (share fallback, staked forms,
    /// raw exits, the stamp grief) each reached at least once.
    function test_handlerActionsSucceed() public {
        address att = actors[0];
        handler.swapPM(0, true, 10_000e18, false, false);
        handler.swapPM(1, false, 10_000e18, true, false);
        handler.swapHook(2, 0, 5_000e18, false); // raw0 -> raw1
        handler.swapHook(0, 7, 5_000e18, false); // staked1 -> staked0
        handler.deposit(1, 1_000e18, false, false);
        handler.deposit(2, 1_000e18, true, true);
        handler.withdraw(1, 500e18, false, false);
        handler.withdraw(2, 500e18, true, true);
        handler.drip(true, 50);
        handler.drip(false, 50);
        handler.compound(1);
        handler.warp(10 minutes);
        // The grief: drain the IMD buffer, stamp the hook's sIMD hold, and an IMD-out swap still completes in sIMD.
        uint8 iImd = _imdSide();
        bool imdOut = iImd == 1; // zeroForOne pays token1
        (uint256 h0, uint256 h1) = hook.totals();
        uint256 otherHeld = iImd == 0 ? h1 : h0;
        handler.stamp(0);
        handler.swapPM(0, imdOut, otherHeld / 5, false, true); // pays out several times the IMD buffer
        assertGt(handler.ok_swapPMShares(), 0, "share fallback reached");
        att;
        assertGt(handler.ok_swapPM(), 0, "swapPM");
        assertGt(handler.ok_swapPMOut(), 0, "swapPM exact out");
        assertGt(handler.ok_swapHook(), 0, "swapHook");
        assertGt(handler.ok_swapHookStaked(), 0, "swapHook staked");
        assertGt(handler.ok_deposit(), 0, "deposit");
        assertGt(handler.ok_depositStaked(), 0, "deposit staked");
        assertGt(handler.ok_withdraw(), 0, "withdraw");
        assertGt(handler.ok_withdrawRaw(), 0, "withdraw raw");
        assertEq(handler.ok_drip(), 2, "drip");
        assertEq(handler.ok_stamp(), 1 + hook.POCKETS(), "stamp (the hook and every pocket, D2)");
        assertEq(handler.ok_warp(), 1, "warp");
        assertEq(handler.ok_compound(), 1, "compound");
        assertEq(handler.bad_profit() + handler.bad_treasury() + handler.bad_centre(), 0, "clean");
        invariant_a_solvent();
    }
}
