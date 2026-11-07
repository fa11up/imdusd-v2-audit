// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CompoundCurve (Compound DEX)
/// @notice The pool's curve: two Uniswap-v3-style layers sharing one price, all amounts in UNDERLYING units.
///
///   core: liquidity L on the sqrt-price range [a, b] = [sqrt(c)/k, sqrt(c)*k] around the centre c
///   tail: liquidity T = L * tau on the full range [MIN_SQRT_PRICE, MAX_SQRT_PRICE]
///
/// tau = (1 - 1/k) / 9 makes the tail exactly 10% of the book's value when the price sits at the centre (a v3
/// position at its range's middle is worth 2*L*sqrt(c)*(1 - 1/k); a full-range one 2*T*sqrt(c)).
///
/// Holdings per unit of state (sp = current sqrt price, Q96):
///   x(sp) = T*(1/sp - 1/MAX) + L*(1/max(sp,a) - 1/b)   [core term only while sp < b]
///   y(sp) = T*(sp - MIN)     + L*(min(sp,b) - a)       [core term only while sp > a]
/// Swaps walk sp through the segments with v4's own SwapMath (liquidity L+T inside [a, b], T outside), so every
/// amount is rounded the way the PoolManager rounds: input up, output down, fee up.
///
/// Re-centring (`solve`) keeps the curve balances (x, y) and finds the price at which the shape around the NEW
/// centre holds exactly that ratio, then the largest liquidity those balances support. x_S/y_S is strictly
/// decreasing in sp, so the root is unique; per region the condition y*x_S(sp) = x*y_S(sp) is the quadratic
///   sp^2 + B*sp - q = 0,   q = y/x (a price, Q192)
///   inside [a,b]: B = (q/b - a) / (1 + tau)
///   below a:      B = -q*(1/a - 1/b) / tau
///   above b:      B = (b - a) / tau
/// solved without cancellation (sp = 2q/(sqrt(B^2+4q)+B) for B >= 0, (sqrt(B^2+4q)-B)/2 otherwise). The tail's
/// 1/MAX and MIN terms are dropped in the solve only (they are below 2^-64 of a price); liquidity is then fitted
/// with the exact amounts, rounded down, so the solved state never claims more than the balances.
library CompoundCurve {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;
    /// @dev Reference liquidity for per-unit amounts.
    uint256 internal constant LREF = 1 << 96;

    error PriceLimit();
    error NoLiquidity();

    struct Shape {
        uint160 a; // core lower sqrt price
        uint160 b; // core upper sqrt price
        uint128 core; // L
        uint128 tail; // T = L * tau
    }

    struct Step {
        uint160 sp; // price after
        uint256 amountIn; // excluding the fee
        uint256 amountOut;
        uint256 fee;
    }

    function shape(int24 centreTick, int24 halfWidth, uint128 l, uint256 tauQ96)
        internal
        pure
        returns (Shape memory s)
    {
        s.a = TickMath.getSqrtPriceAtTick(centreTick - halfWidth);
        s.b = TickMath.getSqrtPriceAtTick(centreTick + halfWidth);
        s.core = l;
        s.tail = uint128(FullMath.mulDiv(l, tauQ96, Q96));
    }

    /// @notice Token amounts the shape holds at `sp` (token0 = x, token1 = y).
    function amounts(uint160 sp, Shape memory s, bool roundUp) internal pure returns (uint256 x, uint256 y) {
        if (s.tail != 0) {
            x = SqrtPriceMath.getAmount0Delta(sp, TickMath.MAX_SQRT_PRICE, s.tail, roundUp);
            y = SqrtPriceMath.getAmount1Delta(TickMath.MIN_SQRT_PRICE, sp, s.tail, roundUp);
        }
        if (s.core != 0) {
            if (sp < s.b) x += SqrtPriceMath.getAmount0Delta(sp > s.a ? sp : s.a, s.b, s.core, roundUp);
            if (sp > s.a) y += SqrtPriceMath.getAmount1Delta(s.a, sp < s.b ? sp : s.b, s.core, roundUp);
        }
    }

    /// @notice The largest core liquidity whose shape at `sp` fits inside (x, y), rounded down with a two-wei margin
    /// per side (the shape's two layers each round their amounts up).
    function liquidityFor(uint160 sp, uint160 a, uint160 b, uint256 tauQ96, uint256 x, uint256 y)
        internal
        pure
        returns (uint128)
    {
        Shape memory u = Shape(a, b, uint128(LREF), uint128(FullMath.mulDiv(LREF, tauQ96, Q96)));
        (uint256 ux, uint256 uy) = amounts(sp, u, true);
        uint256 l = type(uint256).max;
        if (ux != 0) l = _fit(x, ux);
        if (uy != 0) l = Math.min(l, _fit(y, uy));
        if (l == type(uint256).max) return 0;
        return l > type(uint128).max ? type(uint128).max : uint128(l);
    }

    function _fit(uint256 amount, uint256 perRef) private pure returns (uint256 l) {
        l = FullMath.mulDiv(amount, LREF, perRef);
        uint256 margin = FullMath.mulDiv(2, LREF, perRef) + 1;
        l = l > margin ? l - margin : 0;
    }

    /// @notice Swap from `sp` through the shape. `amountSpecified` < 0 is exact input, > 0 exact output (v4's sign).
    /// Reverts PriceLimit if the limit (or the price bound) is reached before the amount is filled: the hook settles
    /// the whole specified amount or nothing.
    function swap(uint160 sp, Shape memory s, bool zeroForOne, int256 amountSpecified, uint160 limit, uint24 feePips)
        internal
        pure
        returns (Step memory r)
    {
        if (s.tail == 0) revert NoLiquidity();
        if (zeroForOne
                ? (limit >= sp || limit <= TickMath.MIN_SQRT_PRICE)
                : (limit <= sp || limit >= TickMath.MAX_SQRT_PRICE)) revert PriceLimit();
        r.sp = sp;
        int256 rem = amountSpecified;
        while (rem != 0) {
            (uint160 target, uint128 liq) = _segment(r.sp, s, zeroForOne, limit);
            if (target == r.sp) revert PriceLimit();
            (uint160 next, uint256 i, uint256 o, uint256 f) = SwapMath.computeSwapStep(r.sp, target, liq, rem, feePips);
            r.sp = next;
            r.amountIn += i;
            r.amountOut += o;
            r.fee += f;
            if (rem < 0) rem += int256(i + f);
            else rem -= int256(o);
        }
    }

    function _segment(uint160 sp, Shape memory s, bool zeroForOne, uint160 limit)
        private
        pure
        returns (uint160 target, uint128 liq)
    {
        uint128 inside = s.core + s.tail;
        if (zeroForOne) {
            if (sp > s.b) (target, liq) = (s.b, s.tail);
            else if (sp > s.a) (target, liq) = (s.a, inside);
            else (target, liq) = (TickMath.MIN_SQRT_PRICE + 1, s.tail);
            if (limit > target) target = limit;
        } else {
            if (sp < s.a) (target, liq) = (s.a, s.tail);
            else if (sp < s.b) (target, liq) = (s.b, inside);
            else (target, liq) = (TickMath.MAX_SQRT_PRICE - 1, s.tail);
            if (limit < target) target = limit;
        }
    }

    /// @notice The price at which a shape on [a, b] holds token amounts in the ratio x : y. Returns 0 when the
    /// ratio is out of the representable range (the caller then keeps its old state).
    function solve(uint256 x, uint256 y, uint160 a, uint160 b, uint256 tauQ96) internal pure returns (uint160) {
        if (x == 0 || y == 0) return 0;
        // q = y/x as a Q192 price; refuse ratios beyond 2^62 either way (mulDiv would overflow, or q would vanish).
        if (y / x >= 1 << 62 || x / y >= 1 << 62) return 0;
        uint256 q = FullMath.mulDiv(y, Q192, x);
        uint256 qb = q / b;
        uint256 inB = FullMath.mulDiv(qb > a ? qb - a : a - qb, Q96, Q96 + tauQ96);
        uint256 sp = _root(qb > a ? int256(inB) : -int256(inB), q);
        if (sp < a) {
            uint256 t = FullMath.mulDiv(q, b - a, a) / b;
            if (t >= 1 << 150) return 0; // a price absurdly far below the centre: keep the old state
            sp = _root(-int256(FullMath.mulDiv(t, Q96, tauQ96)), q);
        } else if (sp > b) {
            sp = _root(int256(FullMath.mulDiv(b - a, Q96, tauQ96)), q);
        }
        if (sp <= TickMath.MIN_SQRT_PRICE) sp = TickMath.MIN_SQRT_PRICE + 1;
        if (sp >= TickMath.MAX_SQRT_PRICE) sp = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sp);
    }

    /// @dev The positive root of sp^2 + B*sp - q = 0 (Q96 sp, Q96 B, Q192 q).
    function _root(int256 bq, uint256 q) private pure returns (uint256) {
        uint256 ab = bq < 0 ? uint256(-bq) : uint256(bq);
        if (ab >= 1 << 127) return bq > 0 ? q / ab : ab + q / ab; // |B| dominates: sp ~ q/B, or ~ |B|
        uint256 d = Math.sqrt(ab * ab + 4 * q);
        return bq >= 0 ? (2 * q) / (d + ab) : (d + ab) / 2;
    }

    // ------------------------------------------------------------ the hook's entry points (linked, external)

    /// @notice tau for a core half-width of `halfWidth` ticks: (1 - 1.0001^(-halfWidth/2)) / 9, Q96.
    function tauFor(int24 halfWidth) external pure returns (uint256) {
        return (Q96 - TickMath.getSqrtPriceAtTick(-halfWidth)) / 9;
    }

    function tickAt(uint160 sp) external pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sp);
    }

    /// @notice `swap` on the shape centred at `ct`.
    function swapAt(
        uint160 sp,
        int24 ct,
        int24 halfWidth,
        uint128 l,
        uint256 tauQ96,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        uint24 feePips
    ) external pure returns (Step memory) {
        return swap(sp, shape(ct, halfWidth, l, tauQ96), zeroForOne, amountSpecified, limit, feePips);
    }

    /// @notice What the shape centred at `ct` holds at `sp`, rounded up.
    function required(uint160 sp, int24 ct, int24 halfWidth, uint128 l, uint256 tauQ96)
        external
        pure
        returns (uint256 x, uint256 y)
    {
        return amounts(sp, shape(ct, halfWidth, l, tauQ96), true);
    }

    /// @notice `liquidityFor` on the shape centred at `ct`.
    function fitAt(uint160 sp, int24 ct, int24 halfWidth, uint256 tauQ96, uint256 x, uint256 y)
        external
        pure
        returns (uint128)
    {
        Shape memory s = shape(ct, halfWidth, 0, tauQ96);
        return liquidityFor(sp, s.a, s.b, tauQ96, x, y);
    }

    /// @notice The centre's whole tick for `milli` (thousandths of a tick), floored and kept where the core's
    /// bounds are valid ticks.
    function centreTickOf(int256 milli, int24 halfWidth) public pure returns (int24) {
        int256 t = milli >= 0 ? milli / 1000 : -((-milli + 999) / 1000);
        int256 lo = int256(TickMath.MIN_TICK + halfWidth);
        int256 hi = int256(TickMath.MAX_TICK - halfWidth);
        return int24(t < lo ? lo : (t > hi ? hi : t));
    }

    /// @notice One lazy step of the centre: it moves from `cm` toward `twapTick` (both in thousandths of a tick for
    /// the centre) by at most `maxMilli`; if its whole tick changes, the curve keeps its balances and is re-solved
    /// around the new range (`recentre`). If the balances cannot be re-solved the centre does not move.
    function step(
        uint160 sp,
        uint128 l,
        int256 cm,
        int24 ct,
        int24 twapTick,
        int256 maxMilli,
        int24 halfWidth,
        uint256 tauQ96
    ) external pure returns (uint160, uint128, int256, int24, bool) {
        int256 target = int256(twapTick) * 1000;
        int256 next = target > cm
            ? (target - cm > maxMilli ? cm + maxMilli : target)
            : (cm - target > maxMilli ? cm - maxMilli : target);
        int24 nt = centreTickOf(next, halfWidth);
        if (nt == ct || l == 0) return (sp, l, next, nt, false);
        (uint256 x, uint256 y) = amounts(sp, shape(ct, halfWidth, l, tauQ96), false);
        Shape memory s = shape(nt, halfWidth, 0, tauQ96);
        uint160 spN = solve(x, y, s.a, s.b, tauQ96);
        if (spN == 0) return (sp, l, cm, ct, false);
        uint128 lN = liquidityFor(spN, s.a, s.b, tauQ96, x, y);
        if (lN == 0) return (sp, l, cm, ct, false);
        return (spN, lN, next, nt, true);
    }
}
