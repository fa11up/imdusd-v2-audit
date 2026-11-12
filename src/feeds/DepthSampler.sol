// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {IFeed} from "../interfaces/IFeed.sol";

/// @title DepthSampler
/// @notice The market depth of one Uniswap v4 pool, measured ON CHAIN from the pool's own liquidity, kept as hourly
/// buckets, and read as a robust low: the `ROBUST_RANK`-th lowest bucket of the last `WINDOW_HOURS` hours. It replaces the Safe POSTING the depth that the k-rule multiplies
/// (the depth rule): nobody posts it, anyone samples it.
///
/// WHAT IS MEASURED. For each token, the USD value of the OTHER token the pool would pay out while that token is sold
/// until its pool price has fallen `bandBps` below the REFERENCE price: `sellDepth0` (token0 sold, token1 paid out, the
/// pool price falls) and `sellDepth1` (token1 sold, token0 paid out, the pool price rises). That is exactly what a
/// liquidator selling seized collateral can get before the price has moved `bandBps` (gross of the LP fee).
///
/// ANCHORED ON THE FEEDS, NOT ON THE POOL'S PRICE. The band is measured from the reference price implied by the two
/// USD feeds (the type's LOW price for the volatile leg; a stablecoin at $1 when its feed is unset), and the amounts are
/// computed from the pool's liquidity DISTRIBUTION (ticks and their liquidity), walking from the current price to the
/// reference without counting, then counting from the reference to the band edge. So a price push before a sample does
/// not change the reading: only positions do. A sample is refused (reverts, nothing recorded) when the pool's tick is
/// more than `maxDeviationTicks` from the reference tick (stale feed, or a pool far from where the protocol prices the
/// collateral: depth around the reference would not be what a liquidator faces), or when either feed is stale.
/// THE PREMISE HOLDS ONLY WHILE THE FEEDS CANNOT BE MOVED AROUND A SAMPLE: a feed that reads a
/// pool's live price (LivePoolPrice) moves the reference with a push of that pool, so a pushed sample is deflated. An
/// attested/Chainlink reference (for IMD: the attested IMD median x Chainlink ETH/USD) is the stronger choice when it can
/// be kept fresh; a stale feed refuses the sample, so a reference that goes stale reads as zero depth. The beta wires the
/// LIVE reference (DeployConfig `_depthSamplers`): its attested IMD leg has a 1 h max age. With that wiring a push
/// moves the reference with the pool, so `maxDeviationTicks` never fires for a sampler whose reference is its own pool
/// (the beta's sampler 0, on pool 0xb07d; samplers 1 and 2 are measured against 0xb07d's price, so a push of 0xb07d makes
/// them refuse PoolOffReference instead), and a pushed sample reads the thinner liquidity around the pushed price.
/// THE PUSH NEEDS NO CAPITAL HELD (audit wave 1, finding 3-oracles-depth): push the pool and settle, call `sample()`
/// with the PoolManager locked again, push back and settle, all in one transaction (or as three transactions of one
/// builder bundle). The cost is the pool fee both ways plus gas, about 2% of the pushed notional: about $200 per hour
/// for a 25% push at the beta's depth, and four such hours lower the sIMD line for about 8 days. It can only LOWER the
/// reading. No rule built from the samplers' own reads can stop it (sampling is permissionless, so a remembered price
/// can be walked by the same calls, and a bundle is as atomic as a transaction): the fixes are a reference a push cannot
/// move (an attested leg) or a proven end-of-previous-block pool price. Accepted for the beta.
///
/// NOT WHILE THE POOLMANAGER IS UNLOCKED. `sample()` reverts inside any v4 unlock callback, so a sample
/// cannot be taken in the middle of a flash-accounted push. This does NOT stop the push above: v4 clears the unlock
/// flag when `unlock()` returns, so a sample between two unlocks of one transaction is accepted.
///
/// WHY HOURLY BUCKETS OF MINIMA, AND WHY ANYONE MAY SAMPLE AT ANY TIME. Liquidity can be added for one block (JIT) and
/// removed in the next, so one read proves nothing. Each UTC hour has a bucket that keeps the MINIMUM of every sample
/// taken in it, and `depth()` is the `ROBUST_RANK`-th LOWEST bucket of the last `WINDOW_HOURS` hours (the plain
/// minimum let one deflated sample, or one LP's remove-sample-re-add, hold the reading down for the whole window; now a
/// low must be seen in `ROBUST_RANK` separate hours, while inflating still needs the liquidity in place in all the others). A sample can only LOWER
/// its hour's bucket. Our keeper samples at a random minute every hour; an attacker who adds liquidity only around his
/// own samples cannot raise a bucket, because the keeper's honest sample in the same hour sets it. To inflate the
/// figure he must keep the liquidity in the pool whenever anyone may sample, all day: and liquidity held all day IS
/// depth (anyone may trade against it). (A rule of "at most one sample per hour" would let the attacker take each
/// hour's only slot with JIT liquidity: that is why this contract has none.)
/// THIS REQUIRES THE KEEPER'S SAMPLE TO BE SENT PRIVATELY (audit wave 1, panel 3). A sample in the public mempool can be
/// sandwiched (+L before it, -L after it, one bundle), and nothing here can tell one-block liquidity from liquidity held
/// all day (v4 keeps no position age; a later-block confirmation is just as public). The keeper sends only through
/// private relays, so the block of its
/// sample is unknown. Left: a builder that front-runs a private transaction it includes, bounded by `MAX_RISE`, the
/// posted ceiling (Parameters.depthCap) and the Safe's instant `postLowerDepth`.
///
/// RISES ARE CAPPED. A new sample may not record more than `MAX_RISE` x the current `depth()` (when it is non-zero).
/// The window minimum already makes any rise wait a full day; the cap bounds it to doubling per day even if the old
/// minimum was a single thin hour, so a sudden deep pool (one LP, possibly the borrower himself) raises lines in steps
/// the Safe can watch and lower (instantly) before they matter. Falls apply at the next sample.
///
/// Falls show once `ROBUST_RANK` hours have seen them (at most ~4 hours with the keeper sampling hourly).
///
/// FAIL CLOSED. Fewer than `MIN_BUCKETS` filled buckets in the window -> `depth()` is 0 (no new debt on a type whose
/// line it bounds). The tick walk is bounded (`maxSteps` bitmap words + crossings): a pool too fragmented to walk inside
/// the bound reverts the sample rather than record a partial (low) or skipped (high) figure.
///
/// No owner, no parameters after construction.
contract DepthSampler {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant WINDOW_HOURS = 26;
    uint256 public constant BUCKETS = 24;
    uint256 public constant MIN_BUCKETS = 20;
    uint256 public constant MAX_RISE = 2;
    /// @notice `depth()` is this-th lowest of the window's buckets (1 = the minimum).
    uint256 public constant ROBUST_RANK = 4;
    /// @dev v4 Lock.IS_UNLOCKED_SLOT: bytes32(uint256(keccak256("Unlocked")) - 1), read through `exttload`.
    bytes32 internal constant V4_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    IPoolManager public immutable manager;
    PoolId public immutable poolId;
    int24 public immutable tickSpacing;
    /// @notice USD per 1e18 raw units, 1e18-scaled (v2's price unit). Zero address: a stablecoin at $1.
    IFeed public immutable feed0;
    IFeed public immutable feed1;
    /// @dev $1 per token in v2's unit for a token of `decimals`: 10^(36 - decimals). Used when the feed is unset.
    uint256 internal immutable unit0;
    uint256 internal immutable unit1;
    /// @notice How far each token's price is followed down, in bps of the reference price (1500 = to -15%).
    uint256 public immutable bandBps;
    /// @notice The pool tick may be at most this far from the reference tick for a sample to count.
    uint24 public immutable maxDeviationTicks;
    /// @notice Bound on the walk: bitmap words read plus ticks crossed, per side.
    uint256 public immutable maxSteps;
    /// @notice Which side `depth()` reports: true = sales of token0 (`sellDepth0`).
    bool public immutable soldIsToken0;

    struct Bucket {
        uint32 hour; // block.timestamp / 1 hours
        uint112 sell0;
        uint112 sell1;
    }

    Bucket[24] internal _buckets;
    uint64 public lastSampleAt;

    error InvalidConfig();
    error StaleFeed();
    error PoolOffReference(int24 poolTick, int24 referenceTick);
    error WalkTooLong();
    error ManagerUnlocked();

    event Sampled(address indexed caller, uint256 sell0, uint256 sell1, uint256 recorded0, uint256 recorded1);

    struct Walk {
        uint160 sqrtP;
        int24 tick;
        uint128 liquidity;
        uint256 steps;
    }

    constructor(
        IPoolManager manager_,
        PoolKey memory key,
        IFeed feed0_,
        IFeed feed1_,
        uint256 bandBps_,
        uint24 maxDeviationTicks_,
        uint256 maxSteps_,
        bool soldIsToken0_
    ) {
        if (address(manager_).code.length == 0 || bandBps_ == 0 || bandBps_ >= 10_000 || maxSteps_ == 0) {
            revert InvalidConfig();
        }
        manager = manager_;
        poolId = key.toId();
        tickSpacing = key.tickSpacing;
        feed0 = feed0_;
        feed1 = feed1_;
        unit0 = 10 ** (36 - _decimals(key.currency0));
        unit1 = 10 ** (36 - _decimals(key.currency1));
        bandBps = bandBps_;
        maxDeviationTicks = maxDeviationTicks_;
        maxSteps = maxSteps_;
        soldIsToken0 = soldIsToken0_;
        (uint160 sqrtP,,,) = manager_.getSlot0(poolId);
        if (sqrtP == 0) revert InvalidConfig(); // pool not initialised
    }

    // ---------------------------------------------------------------- reads

    /// @notice The reported side's depth: the ROBUST_RANK-th lowest of the window's buckets (USD, 1e18), 0 when too few
    /// are filled.
    function depth() external view returns (uint256) {
        (uint256 d0, uint256 d1) = _depths();
        return soldIsToken0 ? d0 : d1;
    }

    /// @notice Both sides' window readings (ROBUST_RANK-th lowest bucket, USD, 1e18).
    function depths() external view returns (uint256 sell0, uint256 sell1) {
        return _depths();
    }

    /// @notice Seconds since the newest sample (type(uint256).max before the first).
    function sampleAge() external view returns (uint256) {
        return lastSampleAt == 0 ? type(uint256).max : block.timestamp - lastSampleAt;
    }

    /// @notice Buckets filled inside the window.
    function filledBuckets() external view returns (uint256 n) {
        uint256 nowHour = block.timestamp / 1 hours;
        for (uint256 i; i < BUCKETS; ++i) {
            if (_inWindow(_buckets[i].hour, nowHour)) ++n;
        }
    }

    function bucket(uint256 i) external view returns (Bucket memory) {
        return _buckets[i];
    }

    /// @notice What a sample would read now (USD, 1e18), without recording. Reverts as `sample` would.
    function measure() public view returns (uint256 sell0, uint256 sell1) {
        (uint256 p0, uint256 p1) = _prices();
        uint160 sqrtRef = _sqrtRef(p0, p1);
        int24 refTick = TickMath.getTickAtSqrtPrice(sqrtRef);
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(poolId);
        int256 dev = int256(tick) - int256(refTick);
        if (dev < 0) dev = -dev;
        if (uint256(dev) > maxDeviationTicks) revert PoolOffReference(tick, refTick);
        uint128 l = manager.getLiquidity(poolId);

        uint160 factor = uint160(Math.sqrt(Math.mulDiv(10_000 - bandBps, 1 << 192, 10_000))); // sqrt(1 - band) in Q96
        uint160 down = uint160(Math.mulDiv(sqrtRef, factor, 1 << 96));
        uint256 upRaw = Math.mulDiv(sqrtRef, 1 << 96, factor);
        if (down <= TickMath.MIN_SQRT_PRICE) down = TickMath.MIN_SQRT_PRICE + 1;
        uint160 up = upRaw >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE - 1 : uint160(upRaw);

        // Token0 sold: the price falls from the reference to `down`; token1 is paid out.
        uint256 out1 = _side(Walk(sqrtP, tick, l, 0), sqrtRef, down);
        // Token1 sold: the price rises from the reference to `up`; token0 is paid out.
        uint256 out0 = _side(Walk(sqrtP, tick, l, 0), sqrtRef, up);
        sell0 = Math.mulDiv(out1, p1, 1e18);
        sell1 = Math.mulDiv(out0, p0, 1e18);
    }

    // ---------------------------------------------------------------- sample

    /// @notice Measure now and fold the reading into this hour's bucket (a bucket only ever goes down within its hour).
    /// Anyone, any time, except inside a v4 unlock callback.
    function sample() external returns (uint256 recorded0, uint256 recorded1) {
        if (manager.exttload(V4_UNLOCKED_SLOT) != bytes32(0)) revert ManagerUnlocked();
        (uint256 s0, uint256 s1) = measure();
        (uint256 d0, uint256 d1) = _depths();
        recorded0 = d0 != 0 && s0 > MAX_RISE * d0 ? MAX_RISE * d0 : s0;
        recorded1 = d1 != 0 && s1 > MAX_RISE * d1 ? MAX_RISE * d1 : s1;
        if (recorded0 > type(uint112).max) recorded0 = type(uint112).max;
        if (recorded1 > type(uint112).max) recorded1 = type(uint112).max;

        uint32 hour = uint32(block.timestamp / 1 hours);
        Bucket storage b = _buckets[hour % BUCKETS];
        if (b.hour != hour) {
            (b.hour, b.sell0, b.sell1) = (hour, uint112(recorded0), uint112(recorded1));
        } else {
            if (recorded0 < b.sell0) b.sell0 = uint112(recorded0);
            if (recorded1 < b.sell1) b.sell1 = uint112(recorded1);
        }
        lastSampleAt = uint64(block.timestamp);
        emit Sampled(msg.sender, s0, s1, recorded0, recorded1);
    }

    // ---------------------------------------------------------------- internals

    function _depths() internal view returns (uint256 d0, uint256 d1) {
        uint256 nowHour = block.timestamp / 1 hours;
        uint256 n;
        uint256[ROBUST_RANK] memory low0;
        uint256[ROBUST_RANK] memory low1;
        for (uint256 k; k < ROBUST_RANK; ++k) {
            (low0[k], low1[k]) = (type(uint256).max, type(uint256).max);
        }
        for (uint256 i; i < BUCKETS; ++i) {
            Bucket memory b = _buckets[i];
            if (!_inWindow(b.hour, nowHour)) continue;
            ++n;
            _keepLowest(low0, b.sell0);
            _keepLowest(low1, b.sell1);
        }
        if (n < MIN_BUCKETS) return (0, 0);
        return (low0[ROBUST_RANK - 1], low1[ROBUST_RANK - 1]);
    }

    /// @dev Insert `v` into the ascending list of the ROBUST_RANK lowest values seen so far.
    function _keepLowest(uint256[ROBUST_RANK] memory low, uint256 v) internal pure {
        if (v >= low[ROBUST_RANK - 1]) return;
        uint256 k = ROBUST_RANK - 1;
        while (k != 0 && low[k - 1] > v) {
            low[k] = low[k - 1];
            --k;
        }
        low[k] = v;
    }

    function _inWindow(uint32 hour, uint256 nowHour) internal pure returns (bool) {
        return hour != 0 && hour <= nowHour && nowHour - hour < WINDOW_HOURS;
    }

    function _prices() internal view returns (uint256 p0, uint256 p1) {
        p0 = _price(feed0, unit0);
        p1 = _price(feed1, unit1);
    }

    function _price(IFeed f, uint256 unit) internal view returns (uint256 p) {
        if (address(f) == address(0)) return unit;
        if (f.isStale()) revert StaleFeed();
        (p,) = f.latestValue();
        if (p == 0) revert StaleFeed();
    }

    /// @dev The pool price the feeds imply: raw token1 per raw token0 = p0 / p1, as sqrt in Q96.
    function _sqrtRef(uint256 p0, uint256 p1) internal pure returns (uint160) {
        uint256 ratioX192 = Math.mulDiv(p0, 1 << 192, p1);
        uint256 s = Math.sqrt(ratioX192);
        if (s <= TickMath.MIN_SQRT_PRICE || s >= TickMath.MAX_SQRT_PRICE) revert InvalidConfig();
        return uint160(s);
    }

    /// @dev Walk to `sqrtRef` without counting, then from `sqrtRef` to `edge`, counting what the pool pays out on the
    /// way (token1 going down, token0 going up).
    function _side(Walk memory w, uint160 sqrtRef, uint160 edge) internal view returns (uint256 out) {
        _walk(w, sqrtRef, false);
        out = _walk(w, edge, true);
    }

    /// @dev Move the walk to `target`, crossing initialised ticks like a swap would, summing the payout if `count`.
    function _walk(Walk memory w, uint160 target, bool count) internal view returns (uint256 out) {
        bool down = target < w.sqrtP;
        while (w.sqrtP != target) {
            if (++w.steps > maxSteps) revert WalkTooLong();
            (int24 next, bool initialized) = _nextInitialized(w.tick, down);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 sqrtNext = TickMath.getSqrtPriceAtTick(next);
            uint160 stepTo = down ? (sqrtNext < target ? target : sqrtNext) : (sqrtNext > target ? target : sqrtNext);
            if (count && w.liquidity != 0) {
                out += down
                    ? SqrtPriceMath.getAmount1Delta(stepTo, w.sqrtP, w.liquidity, false)
                    : SqrtPriceMath.getAmount0Delta(w.sqrtP, stepTo, w.liquidity, false);
            }
            w.sqrtP = stepTo;
            if (stepTo == sqrtNext) {
                if (initialized) {
                    (, int128 net) = manager.getTickLiquidity(poolId, next);
                    w.liquidity = LiquidityMath.addDelta(w.liquidity, down ? -net : net);
                    if (++w.steps > maxSteps) revert WalkTooLong();
                }
                w.tick = down ? next - 1 : next;
            } else {
                // Stopped inside a tick range: keep the tick consistent with the price for a later walk.
                w.tick = TickMath.getTickAtSqrtPrice(stepTo);
            }
        }
    }

    /// @dev v4's TickBitmap.nextInitializedTickWithinOneWord, reading the bitmap through StateLibrary.
    function _nextInitialized(int24 tick, bool lte) internal view returns (int24 next, bool initialized) {
        int24 spacing = tickSpacing;
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        if (lte) {
            (int16 wordPos, uint8 bitPos) = _position(compressed);
            uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
            uint256 masked = manager.getTickBitmap(poolId, wordPos) & mask;
            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing
                : (compressed - int24(uint24(bitPos))) * spacing;
        } else {
            (int16 wordPos, uint8 bitPos) = _position(compressed + 1);
            uint256 mask = ~((uint256(1) << bitPos) - 1);
            uint256 masked = manager.getTickBitmap(poolId, wordPos) & mask;
            initialized = masked != 0;
            next = initialized
                ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing
                : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * spacing;
        }
    }

    function _position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick) & 0xff);
    }

    function _decimals(Currency c) internal view returns (uint8) {
        address a = Currency.unwrap(c);
        if (a == address(0)) return 18; // native ETH
        uint8 d = IERC20Metadata(a).decimals();
        if (d > 36) revert InvalidConfig();
        return d;
    }
}
