// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {CompoundCurve} from "../../src/dex/CompoundCurve.sol";
import {CompoundMockSystem} from "../utils/CompoundMockSystem.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {MockSIMD, DexTreasuryStub} from "../utils/DexMocks.sol";
import {PegRouter} from "../utils/PegSystem.sol";

/// @notice Compound DEX unit tests on a local PoolManager with mock vaults that reproduce both hold models.
/// Run for both token orders (the two contracts at the end).
abstract contract CompoundHookTest is CompoundMockSystem {
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address eve = makeAddr("eve");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint8 iImd;
    uint8 iInf;

    function setUp() public virtual {
        _deployMock(uint160(1 << 96));
        _seed(lp, SEED, SEED);
        _hold(lp, 31 minutes);
        iImd = _imdSide();
        iInf = 1 - iImd;
        for (uint8 i; i < 2; ++i) {
            _fundRaw(alice, i, 100_000_000e18);
            _fundStaked(alice, i, 10_000_000e18);
            _fundRaw(eve, i, 1_000e18);
        }
        _approveAll(alice);
        _approveAll(eve);
        vm.startPrank(eve);
        imd.approve(address(simd), type(uint256).max);
        infer.approve(address(sinfer), type(uint256).max);
        vm.stopPrank();
        _next();
    }

    // ------------------------------------------------------------ helpers

    /// @dev zeroForOne for a swap paying side `out`.
    function _z(uint8 sideOut) internal pure returns (bool) {
        return sideOut == 1;
    }

    function _held(uint8 i) internal view returns (uint256) {
        (uint256 h0, uint256 h1) = hook.totals();
        return i == 0 ? h0 : h1;
    }

    /// @dev A share count's value in token1 units at the curve's price.
    function _shareValue1(uint256 shares) internal view returns (uint256) {
        (uint256 h0, uint256 h1) = hook.totals();
        uint256 sp = hook.sqrtPriceX96();
        uint256 book = FullMath.mulDiv(FullMath.mulDiv(h0, sp, 1 << 96), sp, 1 << 96) + h1;
        return Math.mulDiv(book, shares, hook.totalSupply());
    }

    function _value1(uint8 i, uint256 amount) internal view returns (uint256) {
        if (i == 1) return amount;
        uint256 sp = hook.sqrtPriceX96();
        return FullMath.mulDiv(FullMath.mulDiv(amount, sp, 1 << 96), sp, 1 << 96);
    }

    /// @dev D2: the hook's sIMD sits at the hook and its pockets; stamping it whole takes one 1-wei deposit at each.
    function _stampHook() internal {
        vm.startPrank(eve);
        simd.deposit(1, address(hook));
        for (uint256 k; k < hook.POCKETS(); ++k) {
            simd.deposit(1, hook.pockets(k));
        }
        vm.stopPrank();
    }

    /// @dev Underlying redeemable now across the hook and its pockets.
    function _redeemable(IERC4626 v) internal view returns (uint256 n) {
        n = v.convertToAssets(v.maxRedeem(address(hook)));
        for (uint256 k; k < hook.POCKETS(); ++k) {
            n += v.convertToAssets(v.maxRedeem(hook.pockets(k)));
        }
    }

    // ------------------------------------------------------------ construction and guards

    function test_seedState() public view {
        assertEq(hook.balanceOf(DEAD), hook.DEAD_SHARES(), "dead shares");
        assertEq(hook.totalSupply(), hook.balanceOf(lp) + hook.DEAD_SHARES() + hook.balanceOf(treasury), "supply");
        assertGt(hook.liquidity(), 0);
        // tau makes the tail 10% of the book at the centre: (1 - 1.0001^-1000)/9
        assertEq(hook.tauQ96(), ((1 << 96) - uint256(TickMath.getSqrtPriceAtTick(-2000))) / 9, "tau");
        // Raw buffer: staked down to twice the 2.5% target, the rest staked
        for (uint8 i; i < 2; ++i) {
            uint256 raw = _tok(i).balanceOf(address(hook));
            assertApproxEqRel(raw, _held(i) * 5 / 100, 0.01e18, "buffer at twice the target");
        }
    }

    function test_tailIsTenPercentAtCentre() public pure {
        // At the centre a core of liquidity L is worth 2L*sqrt(c)*(1-1/k) and the tail 2T*sqrt(c): T = L(1-1/k)/9.
        uint256 L = 1e30;
        uint256 tau = CompoundCurve.tauFor(2000);
        CompoundCurve.Shape memory s = CompoundCurve.shape(0, 2000, uint128(L), tau);
        uint160 c = TickMath.getSqrtPriceAtTick(0);
        (uint256 x, uint256 y) = CompoundCurve.amounts(c, s, false);
        CompoundCurve.Shape memory tailOnly = CompoundCurve.Shape(s.a, s.b, 0, s.tail);
        (uint256 tx_, uint256 ty) = CompoundCurve.amounts(c, tailOnly, false);
        assertApproxEqRel((tx_ + ty) * 1e18 / (x + y), 0.1e18, 1e12, "tail = 10% of value at the centre");
    }

    function test_constructorChecks() public {
        IERC4626 v0 = hook.vault0();
        IERC4626 v1 = hook.vault1();
        uint160 p = uint160(1 << 96);
        vm.expectRevert(CompoundHook.ZeroAddress.selector);
        new CompoundHook(IPoolManager(address(0)), v0, v1, treasury, p);
        vm.expectRevert(CompoundHook.ZeroAddress.selector);
        new CompoundHook(pm, v0, v1, address(0), p);
        vm.expectRevert(CompoundHook.ZeroAddress.selector);
        new CompoundHook(pm, IERC4626(address(0)), v1, treasury, p);
        // An address without exactly the four flags
        vm.expectRevert(CompoundHook.HookAddressMismatch.selector);
        new CompoundHook(pm, v0, v1, treasury, p);
        // Mined addresses past the flag check: same asset twice, and an out-of-range price
        _expectMinedRevert(v0, v0, p, CompoundHook.SameAsset.selector);
        _expectMinedRevert(v0, v1, TickMath.MIN_SQRT_PRICE, CompoundHook.WrongPrice.selector);
        _expectMinedRevert(v0, v1, TickMath.MAX_SQRT_PRICE, CompoundHook.WrongPrice.selector);
    }

    function _expectMinedRevert(IERC4626 a, IERC4626 b, uint160 p, bytes4 err) internal {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(CompoundHook).creationCode, abi.encode(pm, a, b, treasury, p)));
        uint160 flags = hook.FLAGS(); // read once: a long mining run must not pay a call per salt
        for (uint256 salt = 1 << 32;; ++salt) {
            address at = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(at) & Hooks.ALL_HOOK_MASK == flags) {
                vm.expectRevert(err);
                new CompoundHook{salt: bytes32(salt)}(pm, a, b, treasury, p);
                return;
            }
        }
    }

    /// @notice D3: a side whose underlying is imdUSD (the SavingsVault) or a vault of
    /// imdUSD (a wrapper of sImdUSD) is refused; imdUSD is read from the Treasury's `token()`. Ordinary sides pass.
    function test_review_D3_refusesImdUsdSides() public {
        MockERC20 usd = new MockERC20("imdUSD", 18);
        MockSIMD savings = new MockSIMD(IERC20(address(usd))); // stands in for the SavingsVault (asset = imdUSD)
        MockSIMD wrapped = new MockSIMD(IERC20(address(savings))); // a vault of sImdUSD shares
        address tr = address(new DexTreasuryStub(address(usd)));
        uint160 p = uint160(1 << 96);
        _expectMinedRevertFor(savings, sinfer, tr, p, CompoundHook.ImdUsdSide.selector);
        _expectMinedRevertFor(simd, savings, tr, p, CompoundHook.ImdUsdSide.selector);
        _expectMinedRevertFor(wrapped, sinfer, tr, p, CompoundHook.ImdUsdSide.selector);
        // a Treasury without token() is refused too (no silent skip of the check)
        _expectMinedRevertFor(simd, sinfer, makeAddr("eoaTreasury"), p, bytes4(0));
        // control: the first pool's sides construct under the same Treasury
        assertEq(address(_mineHookFor(simd, sinfer, tr, p).vault0().asset()) != address(0), true);
    }

    function _expectMinedRevertFor(IERC4626 a, IERC4626 b, address tr, uint160 p, bytes4 err) internal {
        bytes32 initHash = keccak256(abi.encodePacked(type(CompoundHook).creationCode, abi.encode(pm, a, b, tr, p)));
        uint160 flags = hook.FLAGS();
        for (uint256 salt = 1 << 33;; ++salt) {
            address at = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(at) & Hooks.ALL_HOOK_MASK == flags) {
                if (err == bytes4(0)) vm.expectRevert();
                else vm.expectRevert(err);
                new CompoundHook{salt: bytes32(salt)}(pm, a, b, tr, p);
                return;
            }
        }
    }

    function _mineHookFor(IERC4626 a, IERC4626 b, address tr, uint160 p) internal returns (CompoundHook h) {
        bytes32 initHash = keccak256(abi.encodePacked(type(CompoundHook).creationCode, abi.encode(pm, a, b, tr, p)));
        uint160 flags = hook.FLAGS();
        for (uint256 salt = 1 << 34;; ++salt) {
            address at = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(at) & Hooks.ALL_HOOK_MASK == flags) return new CompoundHook{salt: bytes32(salt)}(pm, a, b, tr, p);
        }
    }

    function test_vaultsSortedByUnderlying() public view {
        assertLt(uint160(address(hook.token0())), uint160(address(hook.token1())));
        assertEq(hook.vault0().asset(), address(hook.token0()));
        assertEq(hook.vault1().asset(), address(hook.token1()));
    }

    function test_onlyPoolManager() public {
        SwapParams memory sp = SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(CompoundHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(CompoundHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        vm.expectRevert(CompoundHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_initializeGuards() public {
        // the same key again: the PoolManager refuses
        vm.expectRevert();
        pm.initialize(key, uint160(1 << 96));
        // any other key on this hook (a different fee) is refused by the hook
        PoolKey memory k2 = key;
        k2.fee = 500;
        vm.expectRevert();
        pm.initialize(k2, uint160(1 << 96));
        k2 = key;
        k2.tickSpacing = 1;
        vm.expectRevert();
        pm.initialize(k2, uint160(1 << 96));
    }

    function test_freshPoolRefusesWrongOpeningPrice() public {
        CompoundHook h = _mineHook(simd, sinfer, uint160(1 << 96) * 2);
        PoolKey memory k = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(h)));
        vm.expectRevert();
        pm.initialize(k, uint160(1 << 96));
        pm.initialize(k, uint160(1 << 96) * 2);
        assertTrue(h.initialized());
    }

    function test_noLiquidityInThePoolManager() public {
        PegRouter r = new PegRouter(pm);
        vm.expectRevert();
        r.addLiquidity(key, ModifyLiquidityParams(-600, 600, 1e18, 0));
    }

    // ------------------------------------------------------------ swaps

    function test_pmSwapsMatchQuote() public {
        for (uint8 out; out < 2; ++out) {
            bool z = _z(out);
            CompoundCurve.Step memory q = lens.quote(hook, z, -10_000e18);
            uint256 b = _tok(out).balanceOf(alice);
            _swapPM(alice, z, -10_000e18, "");
            assertEq(_tok(out).balanceOf(alice) - b, q.amountOut, "exact in = quote");
            assertEq(q.amountIn + q.fee, 10_000e18, "fee inside the input");
            _assertCovered();
            // exact output
            q = lens.quote(hook, z, 5_000e18);
            uint8 inSide = 1 - out;
            uint256 bi = _tok(inSide).balanceOf(alice);
            b = _tok(out).balanceOf(alice);
            _swapPM(alice, z, 5_000e18, "");
            assertEq(_tok(out).balanceOf(alice) - b, 5_000e18, "exact out delivered");
            assertEq(bi - _tok(inSide).balanceOf(alice), q.amountIn + q.fee, "exact out paid = quote");
            _assertCovered();
        }
    }

    function test_priceLimitRespected() public {
        uint160 sp = hook.sqrtPriceX96();
        // a limit already passed
        vm.prank(alice);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -1e18, sp + 1), "");
        // a limit inside the trade: the hook fills all or nothing
        vm.prank(alice);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -100_000e18, sp - sp / 1000), "");
    }

    /// @notice D4 checked and NOT reproduced: the PoolManager's own pool never moves, but the hook
    /// returns the whole delta, so `Pool.swap` runs with amountSpecified 0 and returns before its price-limit check
    /// (v4-core Pool.sol: `if (params.amountSpecified == 0) return`). A limit between the pinned opening price and the
    /// hook's live price therefore works in both directions; only the hook's own check (against its live price) applies.
    function test_review_D4_tightLimitsWorkThroughThePoolManager() public {
        int24 open = TickMath.getTickAtSqrtPrice(hook.initialSqrtPriceX96());
        _moveTo(alice, open + 1500); // the hook ~16% above the PM's pinned slot0
        (uint160 sp,,,,) = hook.pendingState();
        int24 live = TickMath.getTickAtSqrtPrice(sp);
        assertGt(live, open + 1400);
        // zeroForOne with a limit ABOVE the pinned slot0 (the PM would refuse it if it checked) but below the live price
        uint160 lim = TickMath.getSqrtPriceAtTick(open + 700);
        vm.prank(alice);
        router.swap(key, SwapParams(true, -1e18, lim), "");
        // oneForZero with a limit just above the live price
        lim = TickMath.getSqrtPriceAtTick(live + 50);
        vm.prank(alice);
        router.swap(key, SwapParams(false, -1e18, lim), "");
        // and the hook still enforces its own side: a zeroForOne limit above the live price is refused
        lim = TickMath.getSqrtPriceAtTick(live + 50);
        vm.prank(alice);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -1e18, lim), "");
        _assertCovered();
    }

    function test_directSwapEveryForm() public {
        for (uint8 f; f < 8; ++f) {
            uint8 sIn = f & 1;
            bool stIn = f & 2 != 0;
            bool stOut = f & 4 != 0;
            address tIn = stIn ? address(_vlt(sIn)) : address(_tok(sIn));
            address tOut = stOut ? address(_vlt(1 - sIn)) : address(_tok(1 - sIn));
            uint256 amt = stIn ? _vlt(sIn).convertToShares(1_000e18) : 1_000e18;
            uint256 assetsIn = stIn ? _vlt(sIn).convertToAssets(amt) : amt;
            CompoundCurve.Step memory q = lens.quote(hook, sIn == 0, -int256(assetsIn));
            uint256 b = IERC20(tOut).balanceOf(alice);
            vm.prank(alice);
            (address paidToken, uint256 paid, uint256 paidValue) = hook.swap(tIn, amt, tOut, 0, alice, false);
            assertEq(paidToken, tOut, "form asked for");
            assertEq(IERC20(tOut).balanceOf(alice) - b, paid);
            if (stOut) {
                assertEq(paid, _vlt(1 - sIn).convertToShares(q.amountOut), "shares out at convertToShares, floor");
                assertLe(paidValue, q.amountOut, "share output never worth more than the curve's output");
            } else {
                assertEq(paid, q.amountOut);
            }
            _assertCovered();
            _next();
        }
    }

    function test_directSwapSlippageAndSameSide() public {
        (address t0, address t1, address v0) = (address(_tok(0)), address(_tok(1)), address(_vlt(0)));
        CompoundCurve.Step memory q = lens.quote(hook, true, -1e18);
        vm.startPrank(alice);
        vm.expectRevert(CompoundHook.SameSide.selector);
        hook.swap(t0, 1e18, v0, 0, alice, false);
        vm.expectRevert(CompoundHook.UnknownToken.selector);
        hook.swap(address(0xBEEF), 1e18, t0, 0, alice, false);
        vm.expectRevert(CompoundHook.Slippage.selector);
        hook.swap(t0, 1e18, t1, q.amountOut + 1, alice, false);
        hook.swap(t0, 1e18, t1, q.amountOut, alice, false);
        vm.stopPrank();
    }

    /// @dev Staked input is valued at convertToAssets, rounded down (against the trader).
    function testFuzz_stakedInputRoundsDown(uint256 shares, bool side0) public {
        uint8 sIn = side0 ? 0 : 1;
        IERC4626 v = _vlt(sIn);
        shares = bound(shares, 1e6, v.balanceOf(alice) / 100);
        uint256 a = v.convertToAssets(shares);
        // the exact value is shares * (A+1) / (S+1e6); the hook uses the floor
        assertLe(a * (v.totalSupply() + 1e6), shares * (v.totalAssets() + 1), "floor");
        vm.assume(a > 1e6);
        CompoundCurve.Step memory q = lens.quote(hook, sIn == 0, -int256(a));
        address tOut = address(_tok(1 - sIn));
        vm.prank(alice);
        (,, uint256 paidValue) = hook.swap(address(v), shares, tOut, 0, alice, false);
        assertEq(paidValue, q.amountOut, "priced on the rounded-down value");
    }

    /// @dev A round trip through the curve never returns more than went in.
    function testFuzz_roundTripNoGain(uint256 amt, bool z, bool exactOutBack) public {
        amt = bound(amt, 1e6, 300_000e18);
        uint8 sIn = z ? 0 : 1;
        uint256 b0 = _tok(sIn).balanceOf(alice);
        uint256 o0 = _tok(1 - sIn).balanceOf(alice);
        _swapPM(alice, z, -int256(amt), "");
        uint256 got = _tok(1 - sIn).balanceOf(alice) - o0;
        if (got == 0) return;
        if (exactOutBack) {
            // buy back exactly the input with the output: must cost more than `got`
            try lens.quote(hook, !z, int256(amt)) returns (CompoundCurve.Step memory q) {
                assertGt(q.amountIn + q.fee, got, "buying the input back costs more than it paid out");
            } catch {}
        } else {
            _swapPM(alice, !z, -int256(got), "");
            assertLt(_tok(sIn).balanceOf(alice), b0, "round trip loses");
            assertEq(_tok(1 - sIn).balanceOf(alice), o0);
        }
        _assertCovered();
    }

    /// @dev Exact output never delivers more than asked and charges at least what an exact input of the same result
    /// would.
    function testFuzz_exactOutCostsAtLeastExactIn(uint256 out, bool z) public view {
        uint8 sOut = z ? 1 : 0;
        out = bound(out, 1e6, _held(sOut) / 5);
        CompoundCurve.Step memory qo = lens.quote(hook, z, int256(out));
        assertEq(qo.amountOut, out);
        CompoundCurve.Step memory qi = lens.quote(hook, z, -int256(qo.amountIn + qo.fee));
        assertGe(qi.amountOut + 1, out, "paying the exact-out price buys the output (1 wei of rounding)");
        if (qo.amountIn + qo.fee > 1) {
            CompoundCurve.Step memory qless = lens.quote(hook, z, -int256(qo.amountIn + qo.fee - 1));
            assertLe(qless.amountOut, out, "one wei less never buys more");
        }
    }

    function test_tailQuotesBeyondTheCore() public {
        // push the price far past the core's top (+22%): the full-range tail keeps quoting
        uint160 b = TickMath.getSqrtPriceAtTick(hook.centreTick() + hook.CORE_TICKS());
        _swapPM(alice, false, -1_500_000e18, "");
        assertGt(hook.sqrtPriceX96(), b, "beyond the core");
        CompoundCurve.Step memory q = lens.quote(hook, false, -10_000e18);
        assertGt(q.amountOut, 0, "still quotes");
        _swapPM(alice, false, -10_000e18, "");
        _swapPM(alice, true, -10_000e18, "");
        _assertCovered();
    }

    // ------------------------------------------------------------ buffer and holds

    /// @dev sIMD's whole-address hold: a stamped hook cannot unstake; an IMD output beyond the buffer is paid in sIMD
    /// when allowed and reverts otherwise; the next unstamped block pays raw and refills the buffer.
    function test_wholeHold_fallbackAndRefill() public {
        uint256 big = _held(iImd) / 8; // > the 5% buffer
        _stampHook();
        assertEq(_redeemable(simd), 0, "stamped (the hook and every pocket)");
        CompoundCurve.Step memory q = lens.quote(hook, _z(iImd), -int256(big));
        // v4 path, no opt-in: reverts
        vm.prank(alice);
        vm.expectRevert();
        router.swap(
            key,
            SwapParams(_z(iImd), -int256(big), _z(iImd) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            ""
        );
        // exact output cannot opt into shares
        vm.prank(alice);
        vm.expectRevert();
        router.swap(
            key,
            SwapParams(
                _z(iImd), int256(q.amountOut), _z(iImd) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            abi.encode(true, alice)
        );
        // v4 path, opted in: paid in sIMD to the named recipient, raw output 0
        uint256 shB = simd.balanceOf(alice);
        uint256 rawB = imd.balanceOf(alice);
        _swapPM(alice, _z(iImd), -int256(big), abi.encode(true, alice));
        assertEq(imd.balanceOf(alice), rawB, "no raw IMD");
        assertEq(simd.balanceOf(alice) - shB, simd.convertToShares(q.amountOut), "sIMD worth the output, rounded down");
        // direct path: raw asked, no fallback: reverts; with fallback: shares
        address tInf = address(_tok(iInf));
        vm.startPrank(alice);
        vm.expectRevert(CompoundHook.BufferShort.selector);
        hook.swap(tInf, big, address(imd), 0, alice, false);
        (address pt,,) = hook.swap(tInf, big, address(imd), 0, alice, true);
        assertEq(pt, address(simd));
        vm.stopPrank();
        _assertCovered();
        // next block, unstamped: raw again, buffer refilled toward 5%
        _next();
        rawB = imd.balanceOf(alice);
        _swapPM(alice, _z(iImd), -int256(big), "");
        assertGt(imd.balanceOf(alice), rawB, "raw IMD paid");
        uint256 raw = imd.balanceOf(address(hook));
        assertGe(raw, _held(iImd) * 25 / 2000, "buffer at least half its target");
        assertLe(raw, _held(iImd) * 75 / 1000, "and at most three times it");
    }

    /// @dev sINFER's per-lot hold: stamping the hook with a new lot does not stop it redeeming its older shares.
    function test_perLotHold_doesNotBlockRefill() public {
        vm.startPrank(eve);
        sinfer.deposit(1, address(hook));
        for (uint256 k; k < hook.POCKETS(); ++k) {
            sinfer.deposit(1, hook.pockets(k));
        }
        vm.stopPrank();
        assertGt(sinfer.lockedShares(address(hook)), 0, "a fresh lot is held");
        assertGt(_redeemable(sinfer), _held(iInf) / 2, "older shares redeem");
        uint256 big = _held(iInf) / 8;
        uint256 rawB = infer.balanceOf(alice);
        _swapPM(alice, _z(iInf), -int256(big), ""); // no opt-in needed
        assertGt(infer.balanceOf(alice), rawB, "raw INFER paid past the buffer");
    }

    function test_buffer_restakesSurplus() public {
        // a large IMD-in swap arrives as a PoolManager claim; the next action turns it into tokens and stakes the
        // surplus above twice the target, back down to the target
        uint256 big = _held(iImd) / 5;
        _swapPM(alice, !_z(iImd), -int256(big), "");
        assertGe(pm.balanceOf(address(hook), uint256(uint160(address(imd)))), big, "input held as a claim");
        _next();
        _swapPM(alice, _z(iImd), -1e18, ""); // any action (an INFER-in one, so no new IMD claim)
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(imd)))), 0, "claims redeemed");
        uint256 raw = imd.balanceOf(address(hook));
        assertLe(raw, _held(iImd) * 5 / 100 + 1, "surplus staked down to twice the target");
        _assertCovered();
    }

    /// @dev Two opposite large swaps in one block do not collide: the IMD the first brings in is staked into the
    /// pocket, so the hook's own address stays redeemable for the second's IMD output.
    function test_oppositeSwapsInOneBlock() public {
        uint256 big = _held(iImd) / 3;
        _swapPM(alice, !_z(iImd), -int256(big), ""); // IMD in (a claim)
        _swapPM(alice, _z(iInf), -1e18, ""); // the claim becomes tokens, the surplus is staked to the pocket
        assertGt(simd.balanceOf(hook.pocket()), 0, "staked to the pocket");
        assertGt(_redeemable(simd), 0, "the reserve outside this block's pocket is not stamped");
        uint256 rawB = imd.balanceOf(alice);
        _swapPM(alice, _z(iImd), -int256(_held(iInf) / 4), ""); // a large IMD output, same block, no opt-in
        assertGt(imd.balanceOf(alice), rawB, "paid raw");
        // and the other order: IMD out first (unstakes), then IMD in (stakes), then IMD out again
        _next();
        _swapPM(alice, _z(iImd), -int256(_held(iInf) / 5), "");
        _swapPM(alice, !_z(iImd), -int256(_held(iImd) / 2), "");
        _swapPM(alice, _z(iInf), -1e18, "");
        _swapPM(alice, _z(iImd), -int256(_held(iInf) / 5), "");
        _assertCovered();
    }

    /// @dev D2 changed this: at a block's first action the current pocket's redeemable shares and the hook's own are
    /// spread over the other pockets (never while held), so this block's stakes never stamp the reserve. A stranger
    /// stamping a pocket only keeps its shares in place; holdings are unchanged and every pocket's shares count and pay.
    function test_pocketSweep() public {
        uint256 big = _held(iImd) / 3;
        _swapPM(alice, !_z(iImd), -int256(big), "");
        _swapPM(alice, _z(iInf), -1e18, "");
        address pk = hook.pocket();
        uint256 inPocket = simd.balanceOf(pk);
        assertGt(inPocket, 0);
        // a staked input lands on the hook itself
        vm.prank(alice);
        hook.swap(address(simd), 1_000e18, address(infer), 0, alice, false);
        assertGt(simd.balanceOf(address(hook)), 0, "staked input held by the hook");
        (uint256 h0, uint256 h1) = hook.totals();
        // four blocks on, the same pocket is current again, but stamped by a stranger: its shares stay put
        for (uint256 n; n < hook.POCKETS(); ++n) {
            _next();
        }
        assertEq(hook.pocket(), pk);
        vm.prank(eve);
        simd.deposit(1, pk);
        _swapPM(alice, _z(iInf), -1e18, "");
        assertGe(simd.balanceOf(pk), inPocket, "not moved while held");
        assertEq(simd.balanceOf(address(hook)), 0, "the hook's own shares spread out");
        // four blocks later, unstamped: the pocket's shares are spread over the others before it takes new stakes
        for (uint256 n; n < hook.POCKETS(); ++n) {
            _next();
        }
        _swapPM(alice, _z(iInf), -1e18, "");
        assertLe(simd.balanceOf(pk), 1, "spread to the other pockets");
        (uint256 g0, uint256 g1) = hook.totals();
        assertGe(g0 + g1 + 1e20, h0 + h1, "holdings unchanged by the moves (small trades aside)");
        _assertCovered();
    }

    /// @dev The grief, every block for 20 blocks: a stranger stamps the hook's sIMD hold (the hook and every pocket) with 1 wei each. Swaps that allow
    /// shares never revert, and the stranger extracts nothing: it loses exactly its dust, which the LPs keep.
    function test_griefEveryBlock() public {
        (uint256 e0, uint256 e1) = _worth(eve);
        uint256 heldBefore = _held(iImd);
        for (uint256 n; n < 20; ++n) {
            _stampHook();
            uint256 big = _held(iInf) / 20;
            _swapPM(alice, _z(iImd), -int256(big), abi.encode(true, alice));
            address tIn = address(_tok(iInf));
            vm.prank(alice);
            hook.swap(tIn, big, address(imd), 0, alice, true);
            // and the other way, so the book does not run dry of IMD
            _swapPM(alice, !_z(iImd), -int256(big * 2), "");
            _next();
        }
        (uint256 f0, uint256 f1) = _worth(eve);
        uint256 spent = (iImd == 0 ? e0 - f0 : e1 - f1);
        assertEq(iImd == 0 ? e1 : e0, iImd == 0 ? f1 : f0, "the other side untouched");
        assertEq(spent, 20 * (1 + hook.POCKETS()), "the stranger lost exactly its dust (one wei per address per block)");
        assertGt(_held(iImd), heldBefore / 2, "the book still holds IMD");
        _assertCovered();
    }

    /// @notice D2: a stranger stamps the hook AND a pocket with 1 wei every block (before the fix
    /// the only pocket: every stake landed there and the sweep stopped, so the hook's own sIMD drained and raw IMD
    /// outputs above the buffer reverted BufferShort for every router that does not opt in). With four rotating
    /// pockets, un-opted IMD-out swaps several times the buffer still pay raw, block after block.
    function test_review_D2_stampedPocketDoesNotBlockRawOutputs() public {
        address p0 = hook.pockets(0);
        for (uint256 n; n < 12; ++n) {
            vm.startPrank(eve);
            simd.deposit(1, address(hook));
            simd.deposit(1, p0);
            vm.stopPrank();
            // a large IMD out with no hookData: above the 7.5% top of the raw band, so it must unstake
            uint256 out = _held(iImd) / 8;
            uint256 b = imd.balanceOf(alice);
            _swapPM(alice, _z(iImd), -int256(out), "");
            assertGt(imd.balanceOf(alice), b, "paid raw IMD");
            // IMD back in, turned into tokens and staked into this block's pocket by a small trade
            _swapPM(alice, !_z(iImd), -int256(out * 2), "");
            _swapPM(alice, _z(iInf), -1e18, "");
            _next();
        }
        assertEq(simd.balanceOf(address(hook)) + simd.balanceOf(hook.pockets(1)) + simd.balanceOf(hook.pockets(2))
            + simd.balanceOf(hook.pockets(3)) + simd.balanceOf(p0), _pocketShares(simd), "share count covers all pockets");
        _assertCovered();
    }

    /// @notice D5: a side's vault that refuses deposits (paused, at a cap) must not brick the pool:
    /// the surplus stays raw, and withdrawals and swaps complete. Before the fix every action's re-stake reverted.
    function test_review_D5_pausedVaultDepositsDoNotBlockWithdrawals() public {
        _swapPM(alice, !_z(iInf), -int256(_held(iInf) / 3), ""); // INFER in: a large raw surplus to re-stake
        sinfer.pauseDeposits(true);
        _next();
        uint256 s = hook.balanceOf(lp) / 2;
        vm.prank(lp);
        (uint256 o0, uint256 o1) = hook.withdraw(s, 0, 0, false, false, lp);
        assertGt(o0 + o1, 0, "withdrew");
        assertGt(infer.balanceOf(address(hook)), _held(iInf) * 3 * 250 / 10_000, "the surplus stays raw");
        _swapPM(alice, _z(iImd), -1e18, "");
        _swapPM(alice, !_z(iInf), -1e21, "");
        sinfer.pauseDeposits(false);
        _next();
        _swapPM(alice, _z(iImd), -1e18, ""); // reopened: the surplus is staked again
        assertLe(infer.balanceOf(address(hook)), _held(iInf) * 3 * 250 / 10_000 + 1, "re-staked once allowed");
        _assertCovered();
    }

    // ------------------------------------------------------------ LP

    function test_depositGate() public {
        // push the price 1%+ off the TWAP: deposits and compound refuse, withdrawals do not
        _swapPM(alice, true, -40_000e18, "");
        int24 spot = lens.spotTick(hook);
        int24 tw = hook.twapTick();
        assertGt(tw - spot, hook.GATE_TICKS());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CompoundHook.OffTwap.selector, spot, tw));
        hook.deposit(1e18, type(uint256).max, type(uint256).max, false, false, alice);
        vm.expectRevert(abi.encodeWithSelector(CompoundHook.OffTwap.selector, spot, tw));
        hook.compound();
        uint256 bal = hook.balanceOf(lp);
        vm.prank(lp);
        hook.withdraw(bal / 10, 0, 0, false, false, lp);
        // once the TWAP has caught up with the (arbitraged) price, deposits reopen
        _holdAt(alice, lens.spotTick(hook), 40 minutes);
        vm.prank(alice);
        hook.deposit(1e18, type(uint256).max, type(uint256).max, false, false, alice);
    }

    function testFuzz_depositWithdrawNoGain(uint256 shares, bool st0, bool st1, bool r0, bool r1) public {
        shares = bound(shares, 1, hook.totalSupply());
        (uint256 w0, uint256 w1) = _worth(alice);
        vm.prank(alice);
        (, uint256 a0, uint256 a1) = hook.deposit(shares, type(uint256).max, type(uint256).max, st0, st1, alice);
        (uint256 p0, uint256 p1) = lens.previewDeposit(hook, shares);
        p0;
        p1;
        vm.prank(alice);
        (uint256 o0, uint256 o1) = hook.withdraw(shares, 0, 0, r0, r1, alice);
        assertLe(o0, a0, "side 0 out <= in");
        assertLe(o1, a1, "side 1 out <= in");
        (uint256 v0, uint256 v1) = _worth(alice);
        // (valuing staked holdings at convertToAssets floors each holding: 2 wei of measurement tolerance)
        assertLe(v0, w0 + 2, "no gain side 0");
        assertLe(v1, w1 + 2, "no gain side 1");
        _assertCovered();
    }

    function testFuzz_depositPaysProportionalRoundedUp(uint256 shares) public {
        uint256 s = hook.totalSupply();
        shares = bound(shares, 1, s);
        (uint256 h0, uint256 h1) = hook.totals();
        vm.prank(alice);
        (, uint256 a0, uint256 a1) = hook.deposit(shares, type(uint256).max, type(uint256).max, false, false, alice);
        assertGe(a0 * s, h0 * shares, "ceil 0");
        assertGe(a1 * s, h1 * shares, "ceil 1");
        assertLt(a0 * s, h0 * shares + s, "at most one wei over 0");
        assertLt(a1 * s, h1 * shares + s, "at most one wei over 1");
    }

    function testFuzz_withdrawFloorAndPreview(uint256 shares, bool raw0, bool raw1) public {
        uint256 bal = hook.balanceOf(lp);
        shares = bound(shares, 1, bal);
        (uint256 h0, uint256 h1) = hook.totals();
        uint256 s = hook.totalSupply();
        (uint256 p0, uint256 p1) = lens.previewWithdraw(hook, shares);
        vm.prank(lp);
        (uint256 o0, uint256 o1) = hook.withdraw(shares, p0, p1, raw0, raw1, lp);
        assertEq(o0, p0, "preview 0");
        assertEq(o1, p1, "preview 1");
        // per component floors: at most one wei over the slice of the (already floored) total
        assertLe(o0 * s, h0 * shares + s, "floor 0");
        assertLe(o1 * s, h1 * shares + s, "floor 1");
        _assertCovered();
    }

    function test_withdrawRawAndStakedForms() public {
        uint256 sh = hook.balanceOf(lp) / 4;
        uint256 raw0 = _tok(0).balanceOf(lp);
        uint256 st1 = _vlt(1).balanceOf(lp);
        vm.prank(lp);
        hook.withdraw(sh, 0, 0, true, false, lp);
        assertEq(_vlt(0).balanceOf(lp), 0, "side 0 all raw");
        assertGt(_tok(0).balanceOf(lp), raw0);
        assertGt(_vlt(1).balanceOf(lp), st1, "side 1 staked");
        // raw asked while the hook is stamped: paid staked instead, never blocked
        _stampHook();
        uint256 simdB = simd.balanceOf(lp);
        vm.prank(lp);
        hook.withdraw(sh, 0, 0, true, true, lp);
        assertGt(simd.balanceOf(lp), simdB, "sIMD paid while the hook may not redeem");
    }

    function test_withdrawSlippage() public {
        uint256 sh = hook.balanceOf(lp) / 4;
        (uint256 p0,) = lens.previewWithdraw(hook, sh);
        vm.prank(lp);
        vm.expectRevert(CompoundHook.Slippage.selector);
        hook.withdraw(sh, p0 + 1, 0, false, false, lp);
    }

    function test_depositMaxEnforced() public {
        (uint256 a0,) = lens.previewDeposit(hook, 1e18);
        vm.prank(alice);
        vm.expectRevert(CompoundHook.Slippage.selector);
        hook.deposit(1e18, a0 - 1, type(uint256).max, false, false, alice);
    }

    // ------------------------------------------------------------ revenue

    /// @dev A drip changes neither the price, the depth nor any quote (in underlying units).
    function test_dripCreatesNoArbitrage() public {
        CompoundCurve.Step memory q0 = lens.quote(hook, true, -50_000e18);
        CompoundCurve.Step memory q1 = lens.quote(hook, false, -50_000e18);
        CompoundCurve.Step memory q2 = lens.quote(hook, true, 20_000e18);
        uint160 sp = hook.sqrtPriceX96();
        uint128 l = hook.liquidity();
        (uint256 h0, uint256 h1) = hook.totals();
        _drip(0, _vlt(0).totalAssets() / 50); // +2% rate
        _drip(1, _vlt(1).totalAssets() / 50);
        (uint256 g0, uint256 g1) = hook.totals();
        assertGt(g0, h0, "reserves grew");
        assertGt(g1, h1, "reserves grew");
        _assertEqStep(lens.quote(hook, true, -50_000e18), q0);
        _assertEqStep(lens.quote(hook, false, -50_000e18), q1);
        _assertEqStep(lens.quote(hook, true, 20_000e18), q2);
        // the next action (in the same block) takes the yield fee and still trades at the same quote
        uint256 b = _tok(1).balanceOf(alice);
        _swapPM(alice, true, -50_000e18, "");
        assertEq(_tok(1).balanceOf(alice) - b, q0.amountOut, "trade after the drip = quote before it");
        assertEq(hook.liquidity(), l);
        sp;
    }

    function _assertEqStep(CompoundCurve.Step memory a, CompoundCurve.Step memory b) internal pure {
        assertEq(a.sp, b.sp);
        assertEq(a.amountIn, b.amountIn);
        assertEq(a.amountOut, b.amountOut);
        assertEq(a.fee, b.fee);
    }

    /// @dev The yield fee is exactly 10% of the reserves' growth from the rate rise, minted as LP shares.
    function test_yieldFeeExactlyTenPercent() public {
        for (uint8 i; i < 2; ++i) {
            IERC4626 v = _vlt(i);
            uint256 sh = _pocketShares(v);
            uint256 r0 = v.convertToAssets(1e36);
            _drip(i, v.totalAssets() / 100);
            uint256 r1 = v.convertToAssets(1e36);
            uint256 expectY = Math.mulDiv(sh, r1 - r0, 1e36);
            uint256 actual = v.convertToAssets(sh) - (sh * (v.totalAssets() - v.totalAssets() / 101) / v.totalSupply());
            actual;
            uint256 t0 = hook.balanceOf(treasury);
            uint256 y0 = hook.yieldCollected(i);
            hook.compound(); // any action accrues
            assertEq(hook.yieldCollected(i) - y0, expectY, "yield = shares x rate rise");
            uint256 minted = hook.balanceOf(treasury) - t0;
            assertGt(minted, 0);
            // the minted shares are worth 10% of the yield's value (rounded down by under one share)
            uint256 v1 = _value1(i, expectY) / 10;
            assertApproxEqAbs(_shareValue1(minted), v1, _shareValue1(1) + 2, "treasury worth 10% of the yield");
            assertLe(_shareValue1(minted), v1, "never more than 10%");
            _next();
        }
    }

    function test_yieldIsRateGrowthOnly() public {
        // donating shares, swapping and depositing are not yield
        uint256 t0 = hook.balanceOf(treasury);
        uint256 gift = simd.balanceOf(alice) / 100;
        vm.prank(alice);
        IERC20(address(simd)).transfer(address(hook), gift);
        vm.prank(alice);
        hook.deposit(1e18, type(uint256).max, type(uint256).max, true, false, alice);
        assertEq(hook.balanceOf(treasury), t0, "a share donation and a deposit mint the Treasury nothing");
        assertEq(hook.yieldCollected(0) + hook.yieldCollected(1), 0);
    }

    /// @dev 10% of every swap fee to the Treasury, as shares worth exactly that (rounded down by under one share).
    function test_swapFeeSplitExact() public {
        for (uint8 out; out < 2; ++out) {
            CompoundCurve.Step memory q = lens.quote(hook, _z(out), -100_000e18);
            uint256 t0 = hook.balanceOf(treasury);
            uint256 f0 = hook.feesCollected(1 - out);
            _swapPM(alice, _z(out), -100_000e18, "");
            assertEq(hook.feesCollected(1 - out) - f0, q.fee, "fee recorded");
            assertEq(q.fee, Math.mulDiv(100_000e18, 3000, 1e6, Math.Rounding.Ceil), "0.30% of the input, up");
            uint256 minted = hook.balanceOf(treasury) - t0;
            uint256 v1 = _value1(1 - out, q.fee) / 10;
            assertApproxEqAbs(_shareValue1(minted), v1, _shareValue1(1) + 2, "treasury worth 10% of the fee");
            assertLe(_shareValue1(minted), v1);
            _next();
        }
    }

    /// @dev An LP who joins, sits through trades and drips, and leaves takes its fees and 90% of its yield.
    function test_lpExitFeesAndNinetyPercentYield() public {
        address lp2 = makeAddr("lp2");
        for (uint8 i; i < 2; ++i) {
            _fundRaw(lp2, i, 2_000_000e18);
        }
        _approveAll(lp2);
        uint256 sh = hook.totalSupply(); // doubles the pool
        vm.prank(lp2);
        (, uint256 in0, uint256 in1) = hook.deposit(sh, type(uint256).max, type(uint256).max, false, false, lp2);
        uint256 frac = hook.balanceOf(lp2) * 1e18 / hook.totalSupply();
        // yield only: drip both vaults by 1%, no trades
        (uint256 h0, uint256 h1) = hook.totals();
        _drip(0, _vlt(0).totalAssets() / 100);
        _drip(1, _vlt(1).totalAssets() / 100);
        (uint256 g0, uint256 g1) = hook.totals();
        uint256 all = hook.balanceOf(lp2);
        vm.prank(lp2);
        (uint256 o0, uint256 o1) = hook.withdraw(all, 0, 0, false, false, lp2);
        // lp2 owned `frac` of the growth, minus the Treasury's 10% (valued at the price, here ~1:1)
        uint256 gain = _value1(0, o0) + o1 - (_value1(0, in0) + in1);
        uint256 growth = _value1(0, g0 - h0) + (g1 - h1);
        assertApproxEqRel(gain, growth * frac / 1e18 * 9 / 10, 0.001e18, "LP keeps 90% of its yield");
    }

    function test_lpExitWithFees() public {
        address lp2 = makeAddr("lp2");
        for (uint8 i; i < 2; ++i) {
            _fundRaw(lp2, i, 2_000_000e18);
        }
        _approveAll(lp2);
        uint256 sup = hook.totalSupply();
        vm.prank(lp2);
        (, uint256 in0, uint256 in1) = hook.deposit(sup, type(uint256).max, type(uint256).max, false, false, lp2);
        uint256 fee1;
        for (uint256 n; n < 10; ++n) {
            _swapPM(alice, true, -20_000e18, "");
            _swapPM(alice, false, -20_000e18, "");
        }
        fee1 = _value1(0, hook.feesCollected(0)) + hook.feesCollected(1);
        uint256 all = hook.balanceOf(lp2);
        vm.prank(lp2);
        (uint256 o0, uint256 o1) = hook.withdraw(all, 0, 0, false, false, lp2);
        uint256 vin = _value1(0, in0) + in1;
        uint256 vout = _value1(0, o0) + o1;
        assertGt(vout, vin, "fees earned");
        // about half the LP fees (90% of all fees), less what the round-trip trades moved
        assertApproxEqRel(vout - vin, fee1 * 9 / 10 / 2, 0.05e18);
    }

    // ------------------------------------------------------------ dead shares and inflation

    function test_donationInflationIsHarmless() public {
        // a fresh pool: the attacker makes the smallest first deposit, then donates a fortune
        CompoundHook h = _mineHook(simd, sinfer, uint160(1 << 96));
        PoolKey memory k = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(h)));
        pm.initialize(k, uint160(1 << 96));
        CompoundHook saved = hook;
        hook = h;
        _approveAll(eve);
        _fundRaw(eve, 0, 1_000_000e18);
        _fundRaw(eve, 1, 1_000_000e18);
        vm.prank(eve);
        (uint256 m,,) = h.deposit(0, 1e6, 1e6, false, false, eve);
        assertGt(m, 0);
        assertEq(h.balanceOf(DEAD), 1000);
        vm.startPrank(eve);
        _tok(0).transfer(address(h), 1_000_000e18);
        _tok(1).transfer(address(h), 1_000_000e18);
        vm.stopPrank();
        _hold(eve, 31 minutes);
        // the victim buys one share-unit's worth at a time: pays at most a wei over the proportional amount
        _approveAll(alice);
        (uint256 w0, uint256 w1) = _worth(alice);
        vm.prank(alice);
        (, uint256 a0, uint256 a1) = h.deposit(1, type(uint256).max, type(uint256).max, false, false, alice);
        vm.prank(alice);
        (uint256 o0, uint256 o1) = h.withdraw(1, 0, 0, false, false, alice);
        (uint256 v0, uint256 v1) = _worth(alice);
        assertLe(a0 - o0, 2, "victim loses at most rounding on side 0");
        assertLe(a1 - o1, 2, "victim loses at most rounding on side 1");
        assertLe(w0 - v0, 2);
        assertLe(w1 - v1, 2);
        hook = saved;
    }

    function test_firstDepositTooSmall() public {
        CompoundHook h = _mineHook(simd, sinfer, uint160(1 << 96));
        PoolKey memory k = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(h)));
        pm.initialize(k, uint160(1 << 96));
        vm.startPrank(alice);
        _tok(0).approve(address(h), type(uint256).max);
        _tok(1).approve(address(h), type(uint256).max);
        vm.expectRevert(CompoundHook.ZeroShares.selector);
        h.deposit(0, 10, 10, false, false, alice);
        vm.stopPrank();
    }

    function test_secondDepositNeedsTwap() public {
        CompoundHook h = _mineHook(simd, sinfer, uint160(1 << 96));
        PoolKey memory k = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(h)));
        pm.initialize(k, uint160(1 << 96));
        vm.startPrank(alice);
        _tok(0).approve(address(h), type(uint256).max);
        _tok(1).approve(address(h), type(uint256).max);
        h.deposit(0, 1e21, 1e21, false, false, alice);
        vm.expectRevert(CompoundHook.NoTwap.selector);
        h.deposit(1e18, type(uint256).max, type(uint256).max, false, false, alice);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ centre

    /// @dev Held 8% away, the centre walks toward the TWAP at no more than 198 ticks an hour and catches up; the
    /// curve stays covered throughout.
    function test_centreFollowsTwapAtBoundedSpeed() public {
        int24 c0 = hook.centreTick();
        int24 target = c0 + 800; // the market moves up ~8%; an arbitrageur keeps the pool there
        _moveTo(alice, target);
        int256 lastMilli = hook.centreMilli();
        uint256 lastT = vm.getBlockTimestamp();
        for (uint256 n; n < 72; ++n) {
            vm.warp(vm.getBlockTimestamp() + 300);
            vm.roll(vm.getBlockNumber() + 25);
            _moveTo(alice, target);
            int256 m = hook.centreMilli();
            assertLe(m - lastMilli, int256(vm.getBlockTimestamp() - lastT) * 55, "speed limit");
            assertGe(m, lastMilli, "moves toward the TWAP only");
            lastMilli = m;
            lastT = vm.getBlockTimestamp();
            _assertCovered();
        }
        int24 c1 = hook.centreTick();
        assertGt(c1 - c0, 500, "it moved");
        assertLe(c1 - c0, int24(int256(6 hours * 55 / 1000)) + 1, "within six hours' allowance");
        int24 gap = c1 > target ? c1 - target : target - c1;
        assertLt(gap, 30, "caught up with the market");
    }

    /// @notice D1: the market moves +15% (an arbitrageur trades the pool there), then the pool
    /// idles 10 h. The TWAP converges to the spot by itself; before the fix the first action re-solved the book by the
    /// whole 1,500-tick centre step (~1,410 ticks of price: ~2% of the book to the first swapper). Now one action
    /// moves the centre at most 10 minutes' allowance (33 ticks) and the price by no more than about the fee.
    function test_review_D1_idleCatchUpCappedPerAction() public {
        int24 c0 = hook.centreTick();
        _moveTo(alice, c0 + 1500);
        (uint160 spA,,,,) = hook.pendingState();
        int24 tA = TickMath.getTickAtSqrtPrice(spA);
        vm.warp(vm.getBlockTimestamp() + 10 hours);
        vm.roll(vm.getBlockNumber() + 3000);
        assertGt(hook.twapTick(), c0 + 1400, "TWAP converged to the spot while idle");
        (uint160 spB,, int256 cmB,,) = hook.pendingState();
        int24 tB = TickMath.getTickAtSqrtPrice(spB);
        assertLe(cmB - hook.centreMilli(), int256(hook.MAX_STEP_SECONDS()) * 55, "centre step capped");
        int24 dp = tB > tA ? tB - tA : tA - tB;
        assertLe(dp, 40, "price re-solve within about the fee");
        // The allowance is forfeited: the next action, 1 s later, may move the centre only 1 s worth.
        _poke(alice);
        int256 m1 = hook.centreMilli();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        _poke(alice);
        assertLe(hook.centreMilli() - m1, 55, "no carried allowance");
        _assertCovered();
    }

    function test_recentreKeepsCurveBalances() public {
        _swapPM(alice, false, -80_000e18, "");
        (uint256 x0, uint256 y0) = lens.curveBalances(hook);
        _hold(alice, 1 hours);
        (uint256 x1, uint256 y1) = lens.curveBalances(hook);
        // the balances only change by the pokes' trades and their fees: re-solving neither adds nor loses value
        uint256 v0 = _value1(0, x0) + y0;
        uint256 v1 = _value1(0, x1) + y1;
        assertApproxEqRel(v1, v0, 0.01e18);
        _assertCovered();
    }
}

contract CompoundHookImdToken1Test is CompoundHookTest {}

contract CompoundHookImdToken0Test is CompoundHookTest {
    function _imdIsToken0() internal pure override returns (bool) {
        return true;
    }
}

/// @notice The curve's maths in isolation.
contract CompoundCurveTest is Test {
    /// @dev The shape's own balances at a price re-solve to that price (and at most that liquidity).
    function testFuzz_solveRecoversPrice(int24 tick, int24 offset, uint128 l) public pure {
        int24 ct = int24(bound(tick, -200_000, 200_000));
        int24 pt = int24(bound(offset, -6000, 6000)) + ct;
        l = uint128(bound(l, 1e18, 1e30));
        uint256 tau = CompoundCurve.tauFor(2000);
        CompoundCurve.Shape memory s = CompoundCurve.shape(ct, 2000, l, tau);
        uint160 sp = TickMath.getSqrtPriceAtTick(pt);
        (uint256 x, uint256 y) = CompoundCurve.amounts(sp, s, false);
        uint160 got = CompoundCurve.solve(x, y, s.a, s.b, tau);
        if (got == 0) return; // out of the representable ratio range
        assertApproxEqRel(got, sp, 1e9, "price recovered (1e-9)");
        uint128 fit = CompoundCurve.liquidityFor(got, s.a, s.b, tau, x, y);
        assertLe(fit, l + l / 1e8, "never more liquidity than the balances hold");
        (uint256 fx, uint256 fy) = CompoundCurve.amounts(got, CompoundCurve.shape(ct, 2000, fit, tau), true);
        assertLe(fx, x, "fits x");
        assertLe(fy, y, "fits y");
    }

    function testFuzz_liquidityForFits(int24 tick, int24 offset, uint256 x, uint256 y) public pure {
        int24 ct = int24(bound(tick, -100_000, 100_000));
        int24 pt = int24(bound(offset, -8000, 8000)) + ct;
        x = bound(x, 1e6, 1e30);
        y = bound(y, 1e6, 1e30);
        uint256 tau = CompoundCurve.tauFor(2000);
        CompoundCurve.Shape memory s = CompoundCurve.shape(ct, 2000, 0, tau);
        uint160 sp = TickMath.getSqrtPriceAtTick(pt);
        uint128 l = CompoundCurve.liquidityFor(sp, s.a, s.b, tau, x, y);
        (uint256 rx, uint256 ry) = CompoundCurve.amounts(sp, CompoundCurve.shape(ct, 2000, l, tau), true);
        assertLe(rx, x);
        assertLe(ry, y);
    }

    /// @dev Swap rounding: input rounded up, output down; a swap of v4 sizes on a fixed shape is never a gain.
    function testFuzz_swapStepRounding(uint256 amt, bool z, int24 offset) public pure {
        uint256 tau = CompoundCurve.tauFor(2000);
        CompoundCurve.Shape memory s = CompoundCurve.shape(0, 2000, 1e24, tau);
        uint160 sp = TickMath.getSqrtPriceAtTick(int24(bound(offset, -3000, 3000)));
        amt = bound(amt, 1, 1e23);
        (uint256 x0, uint256 y0) = CompoundCurve.amounts(sp, s, false);
        CompoundCurve.Step memory r = CompoundCurve.swap(
            sp, s, z, -int256(amt), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, 3000
        );
        (uint256 x1, uint256 y1) = CompoundCurve.amounts(r.sp, s, false);
        assertEq(r.amountIn + r.fee, amt, "exact input consumed");
        if (z) {
            assertGe(x0 + r.amountIn + 1, x1, "token0 paid covers the curve's need");
            assertLe(r.amountOut, y0 - y1 + 1, "token1 out within the curve's release");
        } else {
            assertGe(y0 + r.amountIn + 1, y1);
            assertLe(r.amountOut, x0 - x1 + 1);
        }
    }
}
