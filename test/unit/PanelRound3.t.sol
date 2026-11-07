// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PegPositionsTest} from "./PegPositions.t.sol";
import {PegLPVault} from "../../src/earn/PegLPVault.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";

abstract contract Round3PegBase is PegPositionsTest {
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function _to125() internal {
        ParametersBase.Risk memory r = pegRisk(1_000_000e18);
        r.mat = 1.25e18;
        bytes memory p = abi.encode(params.SET_RISK(), PEG, r);
        vm.prank(governor);
        params.propose(p);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        quoteUsd.set(1e8);
        params.applyPending();
        _hold(0, 31 minutes);
    }

    function _cr(uint256 id) internal view returns (uint256) {
        (uint256 m,) = feed.latestValue();
        return Math.mulDiv(ledger.position(id).collateral, m, 1e18) * 1e18 / ledger.debtOf(id);
    }

    function _bps(uint256 v) internal pure returns (uint256) {
        return v / 1e14;
    }

    function _usdcBps() internal view returns (uint256) {
        (uint256 t0, uint256 t1) = vault.positionAmounts();
        (uint256 st, uint256 q) = hook.stableIsToken0() ? (t0, t1 * 1e12) : (t1, t0 * 1e12);
        return q * 10_000 / (st + q);
    }

    /// Exact gate edges by tick.
    function _gate() internal returns (int24 lo, int24 hi) {
        for (int24 t = 0; t >= -100; --t) {
            _moveTo(t);
            if (!pricer.quote(PEG).borrowable) break;
            lo = t;
        }
        for (int24 t = 0; t <= 100; ++t) {
            _moveTo(t);
            if (!pricer.quote(PEG).borrowable) break;
            hi = t;
        }
        _moveTo(0);
    }

    function _sell(address who, uint256 imd) internal returns (uint256 got) {
        vm.prank(who);
        usd.transfer(address(router), imd);
        uint256 q0 = usdc.balanceOf(address(router));
        bool zeroForOne = hook.stableIsToken0();
        router.swap(key, SwapParams(zeroForOne, -int256(imd), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
        got = usdc.balanceOf(address(router)) - q0;
        vm.prank(address(router));
        usdc.transfer(who, got);
    }

}

/// @notice Re-check regressions: uncollected fees reverted zap.open) and the CR table DeployConfig.pegRisk cites.
abstract contract PanelRound3Base is Round3PegBase {
    /// Failed before the zap collected first: fees above about 5 bps reverted Slippage until someone compounded.
    function test_R3_uncollectedFeesDoNotRevertZapOpen() public {
        _to125();
        for (uint256 i; i < 400; ++i) {
            _moveTo(-9);
            _moveTo(9);
            if (i % 50 != 49) continue;
            _moveTo(0);
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            uint256 id = zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
            console2.log("zap.open with fees accrued: gas", vm.lastCallGas().gasTotalUsed);
            assertGt(ledger.debtOf(id), 0);
            vm.revertToState(snap);
        }
    }

    /// The fees belong to the holders before the open: the new position gets no slice of them.
    function test_R3_feesStayWithExistingHolders() public {
        _to125();
        for (uint256 i; i < 100; ++i) {
            _moveTo(-9);
            _moveTo(9);
        }
        _moveTo(0);
        uint256 snap = vm.snapshotState();
        vault.compound();
        uint256 s = vault.totalSupply();
        (uint256 t0, uint256 t1) = vault.totals();
        uint256 valuePerShare = (hook.stableIsToken0() ? t0 + t1 * 1e12 : t1 + t0 * 1e12) * 1e18 / s;
        vm.revertToState(snap);
        vm.prank(alice);
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
        (t0, t1) = vault.totals();
        uint256 after_ = (hook.stableIsToken0() ? t0 + t1 * 1e12 : t1 + t0 * 1e12) * 1e18 / vault.totalSupply();
        assertApproxEqRel(after_, valuePerShare, 0.0001e18, "the open does not dilute the fees");
        assertGe(after_, valuePerShare, "and takes nothing");
    }

    /// Collecting first reopens no gate: a spot off the TWAP is still refused, by the same check, and outside the two-sided range too.
    function test_R3_gatesHoldWithCompoundFirst() public {
        _to125();
        _moveTo(40);
        vm.prank(alice);
        vm.expectRevert();
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
        _moveTo(-40);
        vm.prank(alice);
        vm.expectRevert();
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
        (int24 lo, int24 hi) = _gate();
        _hold(lo - 1, 31 minutes);
        vm.prank(alice);
        vm.expectRevert();
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
        _hold(hi + 1, 31 minutes);
        vm.prank(alice);
        vm.expectRevert();
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
    }

    /// What collecting first costs: the open with the fee-free compound mocked out, against the real one.
    function test_R3_gasOfCompoundFirst() public {
        _to125();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
        uint256 withIt = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
        vm.mockCall(address(vault), abi.encodeWithSignature("compound()"), "");
        vm.prank(alice);
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
        uint256 without = vm.lastCallGas().gasTotalUsed;
        console2.log("zap.open gas with / without collecting first", withIt, without);
    }

    function test_R3_openAboveBandRevertsDustDebt() public {
        _to125();
        _hold(500, 31 minutes);
        vm.prank(alice);
        vm.expectRevert(LedgerBase.DustDebt.selector);
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
    }

    /// The table cited at DeployConfig.pegRisk: CR of positions opened at each gate edge and the centre, by pool state and USDC.
    function test_R3_crTable() public {
        _to125();
        (int24 lo, int24 hi) = _gate();
        _hold(lo, 31 minutes);
        uint256 a = _open(10_000e6);
        _hold(0, 31 minutes);
        uint256 b = _open(10_000e6);
        _hold(hi, 31 minutes);
        uint256 c = _open(10_000e6);
        int24[5] memory ps = [int24(-500), lo, 0, hi, 500];
        uint256[5] memory us = [uint256(1e8), 0.98e8, 0.95e8, 0.9e8, 0.8e8];
        for (uint256 i; i < ps.length; ++i) {
            _moveTo(ps[i]);
            for (uint256 j; j < us.length; ++j) {
                quoteUsd.set(int256(us[j]));
                console2.log("tick / usdc 1e8 / CR bps open@lo open@0 open@hi");
                console2.logInt(ps[i]);
                console2.log(us[j], _bps(_cr(a)), _bps(_cr(b)));
                console2.log(_bps(_cr(c)));
            }
        }
    }
}

contract PanelRound3Stable0Test is PanelRound3Base {
    function _quoteAddr() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }
}

contract PanelRound3Stable1Test is PanelRound3Base {
    function _quoteAddr() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001);
    }
}
