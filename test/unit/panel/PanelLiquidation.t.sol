// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LiqBase} from "./LiqBase.sol";
import {Pricer} from "../../../src/Pricer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regressions from the 2026-11 internal review (liquidation side).
contract PanelLiquidationTest is LiqBase {
    /// With the legs apart past `skew` the standing bid must NOT buy at the lagging
    /// median; the caller path (a caller who chooses to pay) takes it instead.
    function test_M1_noStandingBidWhileLegsDisagree() public {
        _fund(bob, edge, 50_000e18, true);
        _open(carol, ETH, 100e18, 40_000e18, 0.05e18); // the caller's imdUSD
        _open(alice, SIMD, 10_000e18, 27_000e18, 0.05e18);
        uint256 id = _pidOf(SIMD, alice);
        uint256 debt = ledger.debtOf(id);
        simdMedian.set(4.5e18);
        simdSpot.set(3.6e18); // 20% below: legs disagree
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
        Pricer.Quote memory q = pricer.quote(SIMD);
        assertTrue(q.priced && !q.agree, "priced, legs apart");
        uint256 collBefore = edge.coll(address(simd));
        uint256 carolBefore = simd.balanceOf(carol);
        vm.prank(carol);
        (uint256 repaid,,) = liquidator.liquidate(id);
        assertEq(repaid, debt);
        assertEq(edge.coll(address(simd)), collBefore, "the edge sleeve did not buy");
        assertGt(simd.balanceOf(carol), carolBefore, "the caller paid and took the collateral");
    }

    /// With the legs in agreement the standing bid still runs.
    function test_M1_standingBidWhileLegsAgree() public {
        _fund(bob, edge, 50_000e18, true);
        _open(alice, SIMD, 10_000e18, 27_000e18, 0.05e18);
        uint256 id = _pidOf(SIMD, alice);
        simdMedian.set(4.5e18);
        simdSpot.set(4.4e18);
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
        assertTrue(pricer.quote(SIMD).agree);
        vm.prank(carol);
        liquidator.liquidate(id);
        assertGt(edge.coll(address(simd)), 0, "the sleeve bought");
    }

    /// A marker the collateral token refuses (blocklisted) no longer freezes the liquidation; its chip goes to
    /// the Treasury.
    function test_L2_blockedMarkerDoesNotFreezeLiquidation() public {
        _open(carol, ETH, 100e18, 40_000e18, 0.05e18); // the caller's imdUSD
        _open(alice, ETH, 10e18, 13_000e18, 0.05e18);
        uint256 id = _pidOf(ETH, alice);
        ethMedian.set(1700e18);
        ethSpot.set(1700e18);
        vm.prank(dave);
        liquidator.bark(id); // dave is the marker
        // the token now refuses any transfer to dave (a blocklist)
        vm.mockCallRevert(address(weth), abi.encodeWithSelector(IERC20.transfer.selector, dave), "blocked");
        uint256 tBefore = weth.balanceOf(address(treasury));
        uint256 dBefore = weth.balanceOf(dave);
        vm.prank(carol);
        (uint256 repaid,,) = liquidator.bite(id);
        assertGt(repaid, 0, "liquidated despite the blocked marker");
        assertEq(weth.balanceOf(dave), dBefore, "marker got nothing");
        assertGt(weth.balanceOf(address(treasury)), tBefore, "the chip went to the Treasury");
    }

    /// Core side: bad debt is covered inside the liquidation, edge sleeve first, so a depositor with a
    /// matured request cannot leave between the loss and its cover, and the Treasury does not pay the sleeve's first loss.
    function test_M4_badDebtCoveredInTheLiquidation() public {
        _fund(bob, edge, 50_000e18, true);
        _open(carol, ETH, 100e18, 30_000e18, 0.05e18);
        vm.prank(carol);
        usd.transfer(address(treasury), 5_000e18);
        _open(alice, SIMD, 1_000e18, 2_000e18, 0.1e18);
        simdMedian.set(1e18);
        simdSpot.set(1e18);
        uint256 tBefore = usd.balanceOf(address(treasury));
        vm.prank(carol);
        liquidator.liquidate(_pidOf(SIMD, alice));
        (,,,, uint128 bad) = ledger.ilkState(SIMD);
        assertEq(bad, 0, "covered in the same transaction");
        assertEq(usd.balanceOf(address(treasury)), tBefore, "the edge sleeve paid, not the Treasury");
    }
}
