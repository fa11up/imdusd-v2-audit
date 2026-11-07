// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {DepthSamplerTest} from "./DepthSampler.t.sol";
import {DepthMeasuredTest, MockDepth} from "./DepthMeasured.t.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";

/// @dev Samples from inside a v4 unlock callback: the zero-capital push-sample-poke shape.
contract UnlockedSampler is IUnlockCallback {
    IPoolManager immutable pm;
    DepthSampler immutable sampler;

    constructor(IPoolManager pm_, DepthSampler s) {
        (pm, sampler) = (pm_, s);
    }

    function go() external {
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        sampler.sample();
        return "";
    }
}

/// @dev A second sampler claiming an already-listed pool.
contract SamePoolDepth {
    address public manager;
    bytes32 public poolId;
    uint256 public depth;

    constructor(address m, bytes32 id) {
        (manager, poolId) = (m, id);
    }
}

/// @notice Regressions from the 2026-11 internal review: a single deflated sample or poke no longer holds the
/// depth down, a sample inside a v4 unlock is refused, and one pool cannot be listed twice. Each failed before the fix.
abstract contract PanelDepthSamplerBase is DepthSamplerTest {
    function test_M6_noSampleInsideUnlock() public {
        UnlockedSampler u = new UnlockedSampler(pm, sampler);
        vm.expectRevert(DepthSampler.ManagerUnlocked.selector);
        u.go();
    }

    /// An LP removes his liquidity, samples, re-adds, in one hour: one low bucket no longer moves the window.
    function test_M6_oneLowHourDoesNotMoveTheWindow() public {
        _fill(24);
        uint256 d = sampler.depth();
        int24 t = _tick();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        fx.set(fx.value());
        _add(t - 300, t + 110, -3e15);
        sampler.sample(); // the hour's bucket is now low
        _add(t - 300, t + 110, 3e15);
        sampler.sample();
        assertEq(sampler.depth(), d, "one low hour is not the window's reading");
        _fill(24);
        assertEq(sampler.depth(), d);
    }
}

contract PanelDepthSamplerXIs0Test is PanelDepthSamplerBase {
    function _sDecimalsAddress() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }
}

contract PanelDepthSamplerXIs1Test is PanelDepthSamplerBase {
    function _sDecimalsAddress() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001);
    }
}

contract PanelImdDepthTest is DepthMeasuredTest {
    function _hour(uint256 usd) internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        s1.set(usd);
        depthOracle.poke();
    }

    /// At the aggregate: one poke at a deflated moment held the whole week down; now a day needs ROBUST_RANK low hours.
    function test_M6_oneLowPokeDoesNotSetTheDay() public {
        s1.set(80_100e18);
        _days(7); // pokes at 08:xx UTC each day
        _hour(80_100e18);
        _hour(80_100e18);
        _hour(80_100e18);
        _hour(20_000e18); // 12:xx: the deflated poke
        _hour(80_100e18);
        (, uint256 today) = depthOracle.lowOf(0);
        assertEq(today, 80_100e18, "one low hour is not the day's figure");
        assertEq(depthOracle.depth(), 80_100e18);
        assertEq(params.depthIMD(), 80_100e18);
        // Three more low hours: now the day's 4th-lowest hour is low, and it holds for the week.
        _hour(20_000e18);
        _hour(20_000e18);
        _hour(20_000e18);
        s1.set(80_100e18);
        assertEq(depthOracle.depth(), 20_000e18);
    }

    /// A lower reading in an hour already counted replaces that hour's entry (an hour keeps its lowest).
    function test_M6_anHourKeepsItsLowest() public {
        s1.set(80_100e18);
        _days(7);
        for (uint256 i; i < 3; ++i) _hour(80_100e18);
        s1.set(10_000e18);
        depthOracle.poke(); // same hour, lower
        depthOracle.poke(); // and again
        s1.set(80_100e18);
        (, uint256 today) = depthOracle.lowOf(0);
        assertEq(today, 80_100e18, "repeated pokes in one hour count once");
    }

    /// One sampler per pool.
    function test_D7_onePoolCannotBeListedTwice() public {
        SamePoolDepth dup = new SamePoolDepth(s1.manager(), s1.poolId());
        vm.prank(address(params));
        vm.expectRevert(ImdDepth.BadSampler.selector);
        depthOracle.addSampler(address(dup));
        SamePoolDepth other = new SamePoolDepth(s1.manager(), bytes32(uint256(7)));
        vm.prank(address(params));
        depthOracle.addSampler(address(other));
    }
}
