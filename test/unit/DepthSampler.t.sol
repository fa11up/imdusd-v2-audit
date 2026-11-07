// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PegRouter} from "../utils/PegSystem.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";

/// @notice DepthSampler against a local v4 PoolManager (fee 0, so a swap to the band edge pays out exactly the depth).
/// A volatile token X (18 dec, $2,000) against a stablecoin S (6 dec, $1, no feed). Both token orders.
abstract contract DepthSamplerTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager pm;
    PegRouter router;
    PoolKey key;
    MockERC20 x;
    MockERC20 s;
    MockFeed fx;
    DepthSampler sampler;
    bool xIs0;
    int24 constant SPACING = 10;
    uint256 constant BAND = 1500; // to -15%
    uint256 constant PX = 2000e18; // USD per 1e18 raw X
    uint256 constant PS = 1e30; // USD per 1e18 raw S (6 dec, $1)

    function _sDecimalsAddress() internal pure virtual returns (address);

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        router = new PegRouter(pm);
        x = new MockERC20("X", 18);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("S", uint8(6)), _sDecimalsAddress());
        s = MockERC20(_sDecimalsAddress());
        xIs0 = address(x) < address(s);
        (address c0, address c1) = xIs0 ? (address(x), address(s)) : (address(s), address(x));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, SPACING, IHooks(address(0)));
        fx = new MockFeed(PX);
        pm.initialize(key, _sqrtRef());
        x.mint(address(router), 1e40);
        s.mint(address(router), 1e40);
        _seedLiquidity();
        sampler = _sampler(500, 4096);
    }

    // ---------------------------------------------------------------- helpers

    function _prices() internal view returns (uint256 p0, uint256 p1) {
        (p0, p1) = xIs0 ? (fx.value(), PS) : (PS, fx.value());
    }

    function _sqrtRef() internal view returns (uint160) {
        (uint256 p0, uint256 p1) = _prices();
        return uint160(Math.sqrt(Math.mulDiv(p0, 1 << 192, p1)));
    }

    function _sampler(uint24 maxDev, uint256 maxSteps) internal returns (DepthSampler) {
        (IFeed f0, IFeed f1) = xIs0 ? (IFeed(address(fx)), IFeed(address(0))) : (IFeed(address(0)), IFeed(address(fx)));
        // depth() = sales of X (the collateral a liquidator sells)
        return new DepthSampler(pm, key, f0, f1, BAND, maxDev, maxSteps, xIs0);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = pm.getSlot0(key.toId());
    }

    function _align(int24 t) internal pure returns (int24) {
        int24 a = (t / SPACING) * SPACING;
        if (t < 0 && t % SPACING != 0) a -= SPACING;
        return a;
    }

    function _add(int24 lo, int24 hi, int256 l) internal {
        router.addLiquidity(key, ModifyLiquidityParams(_align(lo), _align(hi), l, bytes32(0)));
    }

    function _seedLiquidity() internal {
        int24 t = _tick();
        _add(t - 2400, t + 2400, 1e15); // wide, past both band edges
        _add(t - 300, t + 110, 3e15); // around the price
        _add(t + 50, t + 900, 2e15); // above only
        _add(t - 1500, t - 200, 4e15); // below only
        _add(t + 1400, t + 1800, 5e15); // straddles the upper band edge
    }

    /// @dev Swap as far as the band edge from the CURRENT price and return the USD the pool paid out.
    function _swapOut(bool zeroForOne, uint160 limit) internal returns (uint256 usd) {
        BalanceDelta d = router.swap(key, SwapParams(zeroForOne, -int256(1e38), limit));
        (uint256 p0, uint256 p1) = _prices();
        if (zeroForOne) usd = Math.mulDiv(uint256(int256(d.amount1())), p1, 1e18);
        else usd = Math.mulDiv(uint256(int256(d.amount0())), p0, 1e18);
    }

    function _edges() internal view returns (uint160 down, uint160 up) {
        uint160 r = _sqrtRef();
        uint160 f = uint160(Math.sqrt(Math.mulDiv(10_000 - BAND, 1 << 192, 10_000)));
        down = uint160(Math.mulDiv(r, f, 1 << 96));
        up = uint160(Math.mulDiv(r, 1 << 96, f));
    }

    function _fill(uint256 hours_) internal {
        for (uint256 i; i < hours_; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            fx.set(fx.value());
            sampler.sample();
        }
    }

    function _xSell() internal view returns (uint256) {
        (uint256 s0, uint256 s1) = sampler.measure();
        return xIs0 ? s0 : s1;
    }

    // ---------------------------------------------------------------- measurement

    /// The reading equals what a real fee-free swap to the band edge pays out, on both sides.
    function test_measureEqualsSwapToBandEdge() public {
        (uint256 sell0, uint256 sell1) = sampler.measure();
        assertGt(sell0, 0);
        assertGt(sell1, 0);
        (uint160 down, uint160 up) = _edges();
        uint256 snap = vm.snapshotState();
        uint256 out1 = _swapOut(true, down);
        vm.revertToState(snap);
        uint256 out0 = _swapOut(false, up);
        assertApproxEqAbs(sell0, out1, 1e12, "sell0 = token1 paid to -band");
        assertApproxEqAbs(sell1, out0, 1e12, "sell1 = token0 paid to +band");
    }

    /// A price push (within the deviation bound) does not change the reading: only positions do.
    function test_pricePushDoesNotChangeReading() public {
        (uint256 a0, uint256 a1) = sampler.measure();
        // push the price ~300 ticks (inside the 500-tick bound) each way
        uint160 r = _sqrtRef();
        router.swap(key, SwapParams(true, -int256(1e38), uint160(Math.mulDiv(r, 9860, 10_000))));
        assertLt(_tick(), TickMath.getTickAtSqrtPrice(r));
        (uint256 b0, uint256 b1) = sampler.measure();
        router.swap(key, SwapParams(false, -int256(1e38), uint160(Math.mulDiv(r, 10_140, 10_000))));
        (uint256 c0, uint256 c1) = sampler.measure();
        assertApproxEqRel(b0, a0, 1e9);
        assertApproxEqRel(b1, a1, 1e9);
        assertApproxEqRel(c0, a0, 1e9);
        assertApproxEqRel(c1, a1, 1e9);
    }

    function test_refusesPoolOffReference() public {
        fx.set(PX * 110 / 100); // feed 10% away from the pool: ~950 ticks > 500
        vm.expectRevert();
        sampler.sample();
    }

    function test_refusesStaleFeed() public {
        fx.setStale(true);
        vm.expectRevert(DepthSampler.StaleFeed.selector);
        sampler.sample();
    }

    function test_boundedWalkFailsSafe() public {
        DepthSampler tiny = _sampler(500, 2);
        vm.expectRevert(DepthSampler.WalkTooLong.selector);
        tiny.measure();
    }

    function test_constructorChecks() public {
        vm.expectRevert(DepthSampler.InvalidConfig.selector);
        new DepthSampler(pm, key, IFeed(address(0)), IFeed(address(0)), 0, 100, 10, true);
        vm.expectRevert(DepthSampler.InvalidConfig.selector);
        new DepthSampler(pm, key, IFeed(address(0)), IFeed(address(0)), 10_000, 100, 10, true);
        PoolKey memory k2 = key;
        k2.tickSpacing = 60; // a pool that does not exist
        vm.expectRevert(DepthSampler.InvalidConfig.selector);
        new DepthSampler(pm, k2, IFeed(address(0)), IFeed(address(0)), 100, 100, 10, true);
    }

    // ---------------------------------------------------------------- buckets, window, rise cap

    function test_failsClosedUntilEnoughBuckets() public {
        _fill(19);
        assertEq(sampler.filledBuckets(), 19);
        assertEq(sampler.depth(), 0);
        _fill(1);
        assertEq(sampler.depth(), _xSell());
    }

    function test_oldBucketsAgeOut() public {
        _fill(24);
        assertGt(sampler.depth(), 0);
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        // 26h window: 7 more hours leave only 19 of the 24 hourly buckets inside it
        assertLt(sampler.filledBuckets(), sampler.MIN_BUCKETS());
        assertEq(sampler.depth(), 0);
    }

    /// JIT liquidity around one's own sample cannot raise the hour's bucket: an honest sample the same hour sets it.
    function test_jitAroundOwnSampleIsUndone() public {
        _fill(24);
        uint256 honest = _xSell();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        fx.set(PX);
        int24 t = _tick();
        _add(t - 2000, t + 2000, 1e18); // huge JIT
        sampler.sample();
        _add(t - 2000, t + 2000, -1e18); // removed again
        sampler.sample(); // the keeper's sample, same hour
        DepthSampler.Bucket memory b = sampler.bucket((vm.getBlockTimestamp() / 1 hours) % 24);
        assertEq(xIs0 ? b.sell0 : b.sell1, honest);
        assertEq(sampler.depth(), honest);
    }

    /// A deeper pool raises the figure at most x2 per sample against the window minimum, and only after a day.
    function test_riseCappedAndWaitsADay() public {
        _fill(24);
        uint256 d = sampler.depth();
        int24 t = _tick();
        _add(t - 2400, t + 2400, 1e17); // ~100x deeper, held from now on
        _fill(1);
        assertEq(sampler.depth(), d, "one deep hour does not move the window minimum");
        _fill(24);
        assertLe(sampler.depth(), 2 * d, "capped at 2x the old minimum after a day");
        assertGt(sampler.depth(), d);
    }

    /// A shallower pool shows once ROBUST_RANK hours have seen it (one low hour no longer sets the window).
    function test_fallAppliesAtNextSample() public {
        _fill(24);
        uint256 d = sampler.depth();
        int24 t = _tick();
        _add(t - 300, t + 110, -3e15);
        _fill(sampler.ROBUST_RANK() - 1);
        assertEq(sampler.depth(), d, "fewer than ROBUST_RANK low hours: unchanged");
        _fill(1);
        assertLt(sampler.depth(), d);
        assertEq(sampler.depth(), _xSell());
    }

    function test_sampleAge() public {
        assertEq(sampler.sampleAge(), type(uint256).max);
        sampler.sample();
        vm.warp(vm.getBlockTimestamp() + 123);
        assertEq(sampler.sampleAge(), 123);
    }
}

contract DepthSamplerXIs0Test is DepthSamplerTest {
    function _sDecimalsAddress() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }
}

contract DepthSamplerXIs1Test is DepthSamplerTest {
    function _sDecimalsAddress() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001);
    }
}
