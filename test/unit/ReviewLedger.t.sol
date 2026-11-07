// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../../src/Treasury.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CoreTest, RateDropper} from "./Core.t.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {Pricer} from "../../src/Pricer.sol";
import {SavingsVault} from "../../src/SavingsVault.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Regressions from an earlier internal review (ledger): L1, L2, I8, F3, M1, C1, C2, C4, liq L3, peg F2.
/// Each test FAILS before the fixes and PASSES after them.
contract ReviewLedgerTest is CoreTest {
    // ------------------------------------------------------------ L1: solvency before penalty

    /// In the band 100% <= CR < 1 + chop the collateral covers the debt: no bad debt, the bonus is what is left.
    function test_review_L1_shortfallBandBooksNoBadDebt() public {
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(dave, ETH, 200e18, 50_000e18, 0.05e18);
        uint256 debt = ledger.debtOf(_pid(ETH, alice));
        ethMedian.set(1470e18);
        ethSpot.set(1470e18); // 10 ETH = $14,700 > debt (CR ~104.9%) but < debt x 1.1
        uint256 worth = Math.mulDiv(10e18, 1470e18, 1e18);
        assertGt(worth, debt);
        uint256 dBefore = weth.balanceOf(dave);
        vm.prank(dave);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(_pid(ETH, alice));
        assertEq(seized, 10e18, "whole position seized");
        assertEq(repaid, debt, "the collateral's worth repays the debt first");
        assertEq(bad, 0, "no bad debt while collateral >= debt");
        (,,,, uint128 badDebt) = ledger.ilkState(ETH);
        assertEq(badDebt, 0);
        assertEq(ledger.totalBadDebt(), 0);
        // The bonus is only what is left over the debt: seized - debt/price, split cut/chip/payer as usual.
        uint256 bonus = seized - Math.mulDiv(debt, 1e18, 1470e18);
        uint256 cut = weth.balanceOf(address(treasury));
        assertApproxEqAbs(cut, bonus / 2, 2, "Treasury takes its cut of the LEFTOVER only");
        assertEq(weth.balanceOf(dave) - dBefore, seized - cut, "payer + marker get the rest");
        // The liquidator still gains: worth - debt - cut, well above zero.
        assertGt(Math.mulDiv(seized - cut, 1470e18, 1e18), repaid);
        _assertSupply();
    }

    /// Below 100% the Treasury is paid nothing: its cut would be collateral it cannot burn against the hole.
    function test_review_L1_underwaterPaysNoTreasuryCut() public {
        uint256 fee = _uf(ETH, 14_000e18, 0.05e18);
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(dave, ETH, 200e18, 50_000e18, 0.05e18);
        ethMedian.set(1200e18);
        ethSpot.set(1200e18);
        uint256 dBefore = weth.balanceOf(dave);
        vm.prank(dave);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(_pid(ETH, alice));
        assertEq(repaid, 12_000e18, "min(debt, collateral x price)");
        assertEq(bad, 14_000e18 + fee - 12_000e18);
        assertEq(seized, 10e18);
        assertEq(weth.balanceOf(address(treasury)), 0, "no cut");
        assertEq(weth.balanceOf(dave) - dBefore, 10e18, "payer takes everything for the $12,000 he burned");
        assertLe(ledger.totalBadDebt(), bad, "booked, then covered in the same tx as far as the Treasury could");
        _assertSupply();
    }

    // ------------------------------------------------------------ M1: seal() is one-shot

    function test_review_M1_sealTwiceReverts() public {
        assertTrue(params.sealed_());
        uint256 at = params.sealedAt();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(ParametersBase.Sealed.selector);
        params.seal();
        assertEq(params.sealedAt(), at, "listedAt (and every type's base-rate start) unchanged");
    }

    // ------------------------------------------------------------ L2: clear does not renew the grace

    function test_review_L2_clearDoesNotRenewTheGrace() public {
        _open(alice, SIMD, 1_000e18, 2_900e18, 0.05e18); // $5,000 vs 2,900: CR 172%
        _open(dave, ETH, 100e18, 50_000e18, 0.05e18);
        simdFeed.set(4e18); // CR 138% < 170%
        vm.prank(dave);
        liquidator.bark(_pid(SIMD, alice));
        uint256 t0 = vm.getBlockTimestamp();
        (, uint64 end,) = liquidator.graces(_pid(SIMD, alice));
        assertEq(end, t0 + 6 hours);
        vm.warp(t0 + 6 hours - 1);
        _refresh();
        // Alice tops up to exactly healthy and clears the mark.
        vm.prank(alice);
        ledger.open(SIMD, 0, Adjust(240e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        liquidator.clear(_pid(SIMD, alice));
        (uint64 at,) = liquidator.marks(_pid(SIMD, alice));
        assertEq(at, 0, "mark gone");
        // A hair lower and she is unhealthy again; the new mark inherits the OLD grace end (t0 + 6h).
        simdFeed.set(3.9e18);
        vm.warp(t0 + 6 hours);
        _refresh();
        vm.prank(dave);
        liquidator.bark(_pid(SIMD, alice));
        (, end,) = liquidator.graces(_pid(SIMD, alice));
        assertEq(end, t0 + 6 hours, "inherited: the grace already ran");
        vm.prank(dave);
        (uint256 repaid,,) = liquidator.bite(_pid(SIMD, alice));
        assertGt(repaid, 0, "bitten at once, no second 6h");
    }

    /// The memory lasts a mark's lifetime: a position unmarked for 24h gets a fresh grace.
    function test_review_L2_graceMemoryExpiresWithTheMark() public {
        _open(alice, SIMD, 1_000e18, 2_900e18, 0.05e18);
        _open(dave, ETH, 100e18, 50_000e18, 0.05e18);
        simdFeed.set(4e18);
        vm.prank(dave);
        liquidator.bark(_pid(SIMD, alice));
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(alice);
        ledger.open(SIMD, 0, Adjust(240e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        liquidator.clear(_pid(SIMD, alice));
        vm.warp(t0 + 24 hours + 1);
        _refresh();
        simdFeed.set(3.9e18);
        vm.prank(dave);
        liquidator.bark(_pid(SIMD, alice));
        uint256 t1 = vm.getBlockTimestamp();
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(Liquidator.InGrace.selector, t1 + 6 hours));
        liquidator.bite(_pid(SIMD, alice));
    }

    // ------------------------------------------------------------ I8: the mark's 24h count priced time only

    function test_review_I8_markClockPausesWhileUnpriced() public {
        _open(alice, SIMD, 1_000e18, 2_900e18, 0.05e18);
        _open(dave, ETH, 100e18, 50_000e18, 0.05e18);
        simdFeed.set(4e18);
        vm.prank(dave);
        liquidator.bark(_pid(SIMD, alice));
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(liquidator.markExpiresAt(_pid(SIMD, alice)), t0 + 24 hours);
        uint256 snap = vm.snapshotState();

        // Feeds stale from t0+1h to t0+23h, recorded by `tick`: the mark lives 22h longer.
        vm.warp(t0 + 1 hours);
        simdFeed.setStale(true);
        liquidator.tick(SIMD);
        (uint64 since,) = liquidator.clocks(SIMD);
        assertEq(since, t0 + 1 hours);
        vm.warp(t0 + 23 hours);
        _refresh();
        liquidator.tick(SIMD);
        (since, ) = liquidator.clocks(SIMD);
        assertEq(since, 0);
        assertEq(liquidator.markExpiresAt(_pid(SIMD, alice)), t0 + 24 hours + 22 hours);
        vm.warp(t0 + 25 hours);
        _refresh();
        vm.prank(dave);
        (uint256 repaid,,) = liquidator.bite(_pid(SIMD, alice));
        assertGt(repaid, 0, "25h of wall clock, 3h of priced time: the mark is live");

        // Control: with nobody ticking, the same wall clock expires the mark.
        vm.revertToState(snap);
        vm.warp(t0 + 25 hours);
        _refresh();
        vm.prank(dave);
        vm.expectRevert(Liquidator.MarkExpired.selector);
        liquidator.bite(_pid(SIMD, alice));
    }

    // ------------------------------------------------------------ F3: bad debt keeps its line room, unbacked() + brake

    function _makeBadDebt() internal returns (uint256 bad) {
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(dave, ETH, 200e18, 50_000e18, 0.05e18);
        ethMedian.set(1200e18);
        ethSpot.set(1200e18);
        vm.prank(dave);
        (,, bad) = liquidator.liquidate(_pid(ETH, alice));
        assertGt(bad, 0);
        // The liquidation already covered what the Treasury could; the hole left is what is still booked.
        bad = ledger.totalBadDebt();
        assertGt(bad, 0);
        ethMedian.set(2000e18);
        ethSpot.set(2000e18);
    }

    /// Anyone may call retireReserve, so it must not burn the balance that covers booked bad debt.
    function test_retireReserveRefusedWhileBadDebtIsBooked() public {
        _makeBadDebt();
        deal(address(usd), address(treasury), 100e18, true);
        vm.expectRevert(Treasury.BadDebtOutstanding.selector);
        treasury.retireReserve(100e18);
        treasury.coverBadDebt(ETH);
        if (ledger.totalBadDebt() == 0) treasury.retireReserve(1); // covered: retiring is allowed again
    }

    function test_review_F3_badDebtKeepsItsLineRoom() public {
        uint256 bad = _makeBadDebt();
        // Lower the line to just above the type's debt so the hole binds: governor, instant.
        (uint128 d,,,,) = ledger.ilkState(ETH);
        uint128 line = uint128(uint256(d) + bad + 1_000e18);
        vm.prank(governor);
        params.lowerLine(ETH, line);
        // 1,000 of room less the hole: borrowing 1,000 (plus its fee) is refused although debt alone stays under the line.
        vm.prank(dave);
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        ledger.open(ETH, 0, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        (d,,,,) = ledger.ilkState(ETH);
        assertLt(uint256(d) + 1_000e18 + _uf(ETH, 1_000e18, 0), line, "debt alone would have fitted");
        // Cover the hole and the room is back.
        vm.prank(dave);
        ledger.cover(ETH, bad);
        assertEq(ledger.totalBadDebt(), 0);
        vm.prank(dave);
        ledger.open(ETH, 0, Adjust(0, 900e18, 0, 0, 0, false, type(uint256).max, address(0)));
        _assertSupply();
    }

    function test_review_F3_unbackedAndBrakeStopEveryType() public {
        uint256 bad = _makeBadDebt();
        uint256 tUsd = usd.balanceOf(address(treasury));
        assertLt(tUsd, bad, "the Treasury's interest to date does not cover the hole");
        assertEq(ledger.unbacked(), bad - tUsd);
        // unbacked ~2k on a ~62k supply > the 1% brake: no new debt on ANY type.
        assertGt(ledger.unbacked() * 1e18 / usd.circulating(), params.unbackedBrake());
        // (The upfront fee is minted to the Treasury before the brake reads, so the error's figures move by it.)
        vm.prank(bob);
        vm.expectPartialRevert(LedgerBase.Braked.selector);
        ledger.open(SIMD, 0, Adjust(1_000e18, 1_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.prank(dave);
        vm.expectPartialRevert(LedgerBase.Braked.selector);
        ledger.open(ETH, 0, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        // Repaying, depositing and withdrawing are never braked.
        vm.prank(dave);
        ledger.open(ETH, 0, Adjust(1e18, -1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        // The Treasury covers what it can; the rest is covered by a holder: the brake releases.
        treasury.coverBadDebt(ETH);
        assertEq(ledger.unbacked(), bad - tUsd, "Treasury imdUSD was already netted in the view");
        vm.prank(dave);
        ledger.cover(ETH, bad);
        assertEq(ledger.unbacked(), 0);
        vm.prank(bob);
        ledger.open(SIMD, 0, Adjust(1_000e18, 1_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        _assertSupply();
    }

    function test_review_F3_brakeIsGovernedRaise48hLowerInstant() public {
        assertEq(params.unbackedBrake(), 0.01e18);
        bytes memory tooHigh = abi.encode(params.SET_UNBACKED_BRAKE(), uint64(0.05e18 + 1));
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(tooHigh);
        bytes memory raise = abi.encode(params.SET_UNBACKED_BRAKE(), uint64(0.05e18));
        vm.prank(governor);
        params.propose(raise);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, block.timestamp + 48 hours));
        params.applyPending();
        vm.warp(block.timestamp + 48 hours);
        params.applyPending();
        assertEq(params.unbackedBrake(), 0.05e18);
        // Lowering is instant, governor only, strictly lowering.
        vm.expectRevert(Governed.NotGovernor.selector);
        params.lowerUnbackedBrake(0.02e18);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerUnbackedBrake(0.05e18);
        vm.prank(governor);
        params.lowerUnbackedBrake(0.02e18);
        assertEq(params.unbackedBrake(), 0.02e18);
    }

    function test_review_F3_lowerLineInstantForEveryType() public {
        uint128 before = params.risk(SIMD).line;
        vm.expectRevert(Governed.NotGovernor.selector);
        params.lowerLine(SIMD, before - 1);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerLine(SIMD, before);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.UnknownIlk.selector);
        params.lowerLine("NOPE", 0);
        vm.prank(governor);
        params.lowerLine(SIMD, 0);
        assertEq(params.risk(SIMD).line, 0);
        vm.prank(bob);
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        ledger.open(SIMD, 0, Adjust(1_000e18, 1_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        assertEq(params.risk(ETH).line, 1_000_000e18, "other types untouched");
    }

    // ------------------------------------------------------------ gov L2: a stale proposal cannot be applied

    function test_review_govL2_staleProposalExpires() public {
        bytes memory raise = abi.encode(params.SET_UNBACKED_BRAKE(), uint64(0.02e18));
        vm.prank(governor);
        params.propose(raise);
        uint256 eta = params.pendingEta();
        assertEq(eta, block.timestamp + 48 hours);
        // Applicable through the whole 14 days past the ETA...
        vm.warp(eta + 14 days);
        uint256 snap = vm.snapshotState();
        params.applyPending();
        assertEq(params.unbackedBrake(), 0.02e18);
        // ...and not one second later.
        vm.revertToState(snap);
        vm.warp(eta + 14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.Expired.selector, eta));
        params.applyPending();
        assertEq(params.unbackedBrake(), 0.01e18, "unchanged");
        assertEq(params.pendingEta(), eta, "still occupies the slot: the governor must cancel it");
        vm.prank(governor);
        vm.expectRevert(Governed.ProposalPending.selector);
        params.propose(raise);
        vm.prank(governor);
        params.cancel();
        assertEq(params.pendingEta(), 0);
        vm.prank(governor);
        params.propose(raise);
        vm.warp(vm.getBlockTimestamp() + 48 hours); // (via_ir caches block.timestamp across the warps above)
        params.applyPending();
        assertEq(params.unbackedBrake(), 0.02e18, "a fresh proposal runs its own 48h and applies");
    }

    // ------------------------------------------------------------ peg F2: keeper cap lowers at once

    function test_review_pegF2_lowerKeeperCapInstant() public {
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerKeeperCap(0); // nothing to lower yet
        bytes memory setCap = abi.encode(params.SET_KEEPER_CAP(), uint256(1_000e18));
        vm.prank(governor);
        params.propose(setCap);
        vm.warp(block.timestamp + 48 hours);
        params.applyPending();
        assertEq(params.keeperCap(), 1_000e18);
        vm.expectRevert(Governed.NotGovernor.selector);
        params.lowerKeeperCap(500e18);
        vm.prank(governor);
        params.lowerKeeperCap(500e18);
        assertEq(params.keeperCap(), 500e18);
    }

    // ------------------------------------------------------------ C1: upfront fee after the last borrower closes

    function test_review_C1_upfrontFeeSurvivesTheLastClose() public {
        _open(bob, ETH, 10e18, 10_000e18, 0.10e18);
        vm.warp(block.timestamp + 1 days);
        _refresh();
        uint256 owed = ledger.debtOf(_pid(ETH, bob));
        deal(address(usd), bob, owed, true);
        vm.prank(bob);
        ledger.open(ETH, 0, Adjust(0, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        (uint128 d,, uint256 w,,) = ledger.ilkState(ETH);
        assertEq(w, 0, "no borrower left");
        assertGt(d, 0, "the aggregate keeps its rounding residue");
        // The fee must read the opener's own rate, not residue-average zero.
        assertEq(ledger.upfrontFeeFor(ETH, 10_000e18, 0.05e18), _premium(10_000e18, 0.05e18));
        uint256 t0 = usd.balanceOf(address(treasury));
        _open(carol, ETH, 10e18, 10_000e18, 0.05e18);
        assertEq(usd.balanceOf(address(treasury)) - t0, _premium(10_000e18, 0.05e18));
    }

    // ------------------------------------------------------------ C4: a raise inside the cooldown is charged

    function test_review_C4_raiseInsideCooldownPaysPremium() public {
        _open(bob, ETH, 100e18, 100_000e18, 0.01e18); // the market sits at 1%
        _open(alice, ETH, 10e18, 10_000e18, 0.01e18);
        uint256 d0 = ledger.debtOf(_pid(ETH, alice));
        uint256 avg0 = _avgRate(ETH);
        vm.prank(alice);
        ledger.setRate(_pid(ETH, alice), 1e18, 0, 0); // to 100%: on main free, and the type's average jumps 10x
        assertEq(ledger.debtOf(_pid(ETH, alice)), d0 + _premium(d0, 0.01e18), "7 days at the old rate on the debt");
        assertGt(_avgRate(ETH), avg0 * 9, "the average still moves: the raise is priced, not refused");
        // After the cooldown a raise is free (as before).
        _open(carol, ETH, 10e18, 1_000e18, 0.02e18);
        vm.warp(block.timestamp + 7 days);
        _refresh();
        uint256 c0 = ledger.debtOf(_pid(ETH, carol));
        vm.prank(carol);
        ledger.setRate(_pid(ETH, carol), 0.5e18, 0, 0);
        assertEq(ledger.debtOf(_pid(ETH, carol)), c0, "no cooldown running: free");
    }

    // ------------------------------------------------------------ C2: the premium follows top-ups through the cooldown

    function test_review_C2_topUpInsideCooldownPaysTheOldRate() public {
        _open(bob, ETH, 100e18, 100_000e18, 0.01e18); // market at 1%
        _open(alice, ETH, 20e18, 10_000e18, 0.10e18);
        uint256 d0 = ledger.debtOf(_pid(ETH, alice));
        vm.prank(alice);
        ledger.setRate(_pid(ETH, alice), 0.01e18, 0, 0); // charged: 7 days at 10%
        uint256 d1 = ledger.debtOf(_pid(ETH, alice));
        assertEq(d1, d0 + _premium(d0, 0.10e18));
        assertEq(ledger.position(_pid(ETH, alice)).premiumRate, 0.10e18);
        // Topping up inside the cooldown pays the upfront fee AND 7 days at the OLD 10% on the addition.
        uint256 fee = _uf(ETH, 5_000e18, 0);
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(0, 5_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(ledger.debtOf(_pid(ETH, alice)), d1 + 5_000e18 + fee + _premium(5_000e18, 0.10e18));
        // Past the cooldown the memory is spent.
        vm.warp(block.timestamp + 7 days);
        _refresh();
        ledger.accrue(ETH); // the fee view reads the average at the last accrual, as adjust will
        uint256 d2 = ledger.debtOf(_pid(ETH, alice));
        uint256 fee2 = _uf(ETH, 1_000e18, 0);
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(ledger.debtOf(_pid(ETH, alice)), d2 + 1_000e18 + fee2, "only the upfront fee");
        _assertSupply();
    }

    /// The PoC's shape: a dust reopen at the lower rate, then a top-up, costs what one reopen of the whole amount does.
    function test_review_C2_dustReopenThenTopUpPaysTheWholePremium() public {
        RateDropper x = _dropper(0.10e18);
        uint256 d0 = ledger.debtOf(_pid(ETH, address(x)));
        // The dropper needs its upfront fee's worth of imdUSD to repay in full: from another borrower at 1% (the market).
        _open(dave, ETH, 10e18, 1_000e18, 0.01e18);
        uint256 short = d0 - usd.balanceOf(address(x));
        vm.prank(dave);
        usd.transfer(address(x), short);
        uint256 t0 = usd.balanceOf(address(treasury));
        // Repay to zero and reopen 100 (dust) at 1%, then top up the rest, all inside the cooldown.
        vm.startPrank(address(x));
        ledger.open(ETH, 0, Adjust(0, -int256(d0), 0, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(ETH, 0, Adjust(0, 100e18, 0.01e18, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(ETH, 0, Adjust(0, int256(d0 - 100e18), 0, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        uint256 premium = _premium(100e18, 0.10e18) + _premium(d0 - 100e18, 0.10e18);
        assertApproxEqAbs(premium, _premium(d0, 0.10e18), 2, "~ the premium on the whole amount");
        uint256 upfront = _premium(100e18, 0.01e18); // both the reopen and the top-up pay the type's average (~1%)
        uint256 minted = usd.balanceOf(address(treasury)) - t0;
        assertGe(minted, premium, "at least the whole premium was minted");
        assertLt(minted, premium + _premium(d0, 0.01e18) + upfront + 2, "plus the upfront fees at ~1%, nothing more");
        _assertSupply();
    }

    // ------------------------------------------------------------ liq L3: payout on a type without a live leg

    function test_review_L3_payoutKeepsTheHigherOracleLegPastSkew() public {
        _open(alice, ETH, 10e18, 10_000e18, 0.02e18);
        _open(bob, ETH, 10e18, 10_000e18, 0.05e18);
        ethSpot.set(2200e18); // 10% above the median: past the 5% skew
        Pricer.Quote memory q = pricer.quote(ETH);
        assertTrue(q.priced);
        assertFalse(q.borrowable, "divergence still stops borrowing");
        assertEq(q.low, 2000e18, "liquidation on the median");
        assertEq(q.high, 2000e18);
        assertEq(q.payout, 2200e18, "redemption pays at the higher fresh oracle leg");
        // A redemption of 2,200 imdUSD hands out 1 ETH less the fee, not 1.1 ETH.
        vm.prank(bob);
        usd.transfer(dave, 2_200e18);
        uint256 fee = redeemer.feeFor(ETH, 2_200e18);
        vm.prank(dave);
        (, uint256 out) = redeemer.redeem(ETH, 2_200e18, fee, 10, 0);
        assertEq(out, Math.mulDiv(1e18, 1e18 - fee, 1e18));
        // A stale spot falls back to the median.
        ethSpot.setStale(true);
        q = pricer.quote(ETH);
        assertEq(q.payout, 2000e18);
        // A LOWER diverging spot never lowers the payout.
        ethSpot.set(1700e18);
        q = pricer.quote(ETH);
        assertEq(q.payout, 2000e18);
    }

    // ------------------------------------------------------------ cross-stream (integration of the earlier review's fix streams)

    /// F3 x peg keeper (characterisation, decision OPEN): the brake lives in `Ledger.adjust`; the peg keeper mints through
    /// `ImdUSD.mint` under its minter role and is bounded only by `Parameters.keeperCap`. So while every type is braked,
    /// the keeper still mints. Pinned here so a change either way is deliberate.
    function test_review_cross_F3_brakeDoesNotStopTheKeeperMint() public {
        KeeperStub keeper = new KeeperStub(usd);
        bytes memory pk = abi.encode(params.SET_KEEPER(), address(keeper));
        vm.prank(governor);
        params.propose(pk);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        _refresh();
        assertTrue(usd.isMinter(address(keeper)));

        _makeBadDebt();
        assertGt(ledger.unbacked() * 1e18 / usd.circulating(), params.unbackedBrake(), "the brake binds");
        vm.prank(dave);
        vm.expectPartialRevert(LedgerBase.Braked.selector);
        ledger.open(ETH, 0, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));

        uint256 unbacked0 = ledger.unbacked();
        keeper.mint(address(this), 5_000e18); // not braked
        assertEq(usd.balanceOf(address(this)), 5_000e18);
        assertEq(ledger.unbacked(), unbacked0, "a keeper mint is outstanding supply, not bad debt");
        _assertSupply();
    }
}

/// @dev Flash-mints `flash`, then redeems `amount` against `ilk` INSIDE the loan.
contract FlashRedeemer is IERC3156FlashBorrower {
    ImdUSD immutable usd;
    Redeemer immutable redeemer;
    bytes32 immutable ilk;
    uint256 public feeSeen;
    uint256 public out;
    uint256 public circulatingSeen;
    uint256 public roomSeen;

    constructor(ImdUSD usd_, Redeemer redeemer_, bytes32 ilk_) {
        (usd, redeemer, ilk) = (usd_, redeemer_, ilk_);
    }

    function run(uint256 flash, uint256 amount) external {
        usd.flashLoan(this, address(usd), flash, abi.encode(amount));
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes32) {
        uint256 redeemAmt = abi.decode(data, (uint256));
        circulatingSeen = usd.circulating();
        roomSeen = usd.maxFlashLoan(address(usd));
        feeSeen = redeemer.feeFor(ilk, redeemAmt);
        if (redeemAmt != 0) (, out) = redeemer.redeem(ilk, redeemAmt, 0.05e18, 10, 0);
        usd.approve(address(usd), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev Flash-mints `flash`; optionally parks it in the SavingsVault; calls `accrue` while the supply (and the vault) are inflated.
contract FlashAccruer is IERC3156FlashBorrower {
    ImdUSD immutable usd;
    Ledger immutable ledger;
    SavingsVault immutable savings;
    bytes32 immutable ilk;

    constructor(ImdUSD usd_, Ledger ledger_, SavingsVault savings_, bytes32 ilk_) {
        (usd, ledger, savings, ilk) = (usd_, ledger_, savings_, ilk_);
    }

    function run(uint256 flash, bool park) external {
        usd.flashLoan(this, address(usd), flash, abi.encode(park));
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes32) {
        bool park = abi.decode(data, (bool));
        if (park) {
            usd.approve(address(savings), amount);
            savings.deposit(amount, address(this));
        }
        ledger.accrue(ilk);
        if (park) savings.redeem(savings.balanceOf(address(this)), address(this), address(this));
        usd.approve(address(usd), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev Nests `flashLoan` on itself `depth` times at `each`.
contract NestedFlasher is IERC3156FlashBorrower {
    ImdUSD immutable usd;
    uint256 depth;
    uint256 public peakSupply;
    uint256 public peakOutstanding;

    constructor(ImdUSD usd_) {
        usd = usd_;
        usd.approve(address(usd), type(uint256).max);
    }

    function run(uint256 n, uint256 each) external {
        depth = n;
        usd.flashLoan(this, address(usd), each, "");
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata data) external returns (bytes32) {
        peakSupply = usd.totalSupply();
        peakOutstanding = usd.flashOutstanding();
        if (--depth > 0) usd.flashLoan(this, address(usd), amount, data);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice Regressions for solv F1 (self-redemption now costs the fee) and T1 / solv F2 / T4 (flash mints bound per
/// transaction, nothing supply-denominated is flash-inflatable), from the review's own PoCs.
contract ReviewScenariosTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant STABLE = "USDX";

    MockERC20 weth;
    MockERC20 usdx;
    MockFeed ethFeed;
    MockFeed usdxFeed;
    SavingsVault savings;

    address carol = makeAddr("carol"); // honest stablecoin borrower, opened first
    address eve = makeAddr("eve"); // attacker: newest position at the floor rate
    address whale = makeAddr("whale"); // ETH borrower, source of imdUSD
    address bob = makeAddr("bob"); // saver
    address dave = makeAddr("dave"); // honest redeemer

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        usdx = new MockERC20("USDX", 18);
        ethFeed = new MockFeed(2000e18);
        usdxFeed = new MockFeed(1e18);
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        ParametersBase.Risk memory er = _risk(1.4e18, 50_000e18);
        er.redeemDivisor = 4;
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, er);
        ParametersBase.Risk memory sr = _risk(1.08e18, 200_000e18);
        sr.chop = 0.05e18;
        sr.rateFloor = 0.005e18;
        sr.redeemFloor = 0.001e18;
        sr.redeemDivisor = 8;
        _addIlk(STABLE, address(usdx), usdxFeed, usdxFeed, IFeed(address(0)), address(0), address(0), true, sr);
        savings = new SavingsVault(IERC20(address(usd)));
        params.setGenesisSavings(address(savings), 0.35e18);
        params.seal();

        address[5] memory us = [carol, eve, whale, bob, dave];
        for (uint256 i; i < 5; ++i) {
            weth.mint(us[i], 1_000e18);
            usdx.mint(us[i], 1_000_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usdx.approve(address(ledger), type(uint256).max);
            usd.approve(address(savings), type(uint256).max);
            vm.stopPrank();
        }
        _open(carol, STABLE, 110_000e18, 100_000e18, 0.005e18);
        _open(whale, ETH, 100e18, 30_000e18, 0.01e18);
        _open(eve, STABLE, 25_000e18, 20_000e18, 0.005e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _fresh();
    }

    function _fresh() internal {
        ethFeed.set(2000e18);
        usdxFeed.set(1e18);
    }

    function _open(address u, bytes32 ilk, uint256 coll, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        vm.prank(u);
        ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _wealth(address u) internal view returns (int256) {
        Ledger.Position memory p = ledger.position(_pid(STABLE, u));
        return int256(usdx.balanceOf(u)) + int256(uint256(p.collateral)) + int256(usd.balanceOf(u))
            - int256(ledger.debtOf(_pid(STABLE, u)));
    }

    // ------------------------------------------------------------ F1

    /// The PoC: three self-redemption cycles cost under 10 imdUSD on main. Now every cycle costs the fee's collateral,
    /// which leaves the position for the Treasury, so pinning the fee at the cap costs the attacker the cap.
    function test_review_F1_selfRedemptionCostsTheFee() public {
        int256 eveBefore = _wealth(eve);
        uint256 feesPaid;
        uint256 tBefore = usdx.balanceOf(address(treasury));
        for (uint256 i; i < 3; ++i) {
            assertEq(sorted.first(STABLE), _pid(STABLE, eve));
            vm.startPrank(eve);
            (uint256 redeemed, uint256 out) = redeemer.redeem(STABLE, 20_000e18, 0.05e18, 1, 0);
            (uint256 p, uint256 n) = sorted.findInsertPosition(STABLE, 0.005e18);
            ledger.open(STABLE, 0, Adjust(int256(usdx.balanceOf(eve)), 20_000e18, 0.005e18, p, n, false, type(uint256).max, address(0)));
            vm.stopPrank();
            feesPaid += redeemed - out; // at $1: the fee's collateral is what the redeemer did not get back
        }
        int256 cost = eveBefore - _wealth(eve);
        assertGe(uint256(cost), feesPaid, "the cycles cost at least the redemption fees");
        assertGt(feesPaid, 1_000e18, "the third cycle alone pays ~5% of 20k");
        assertApproxEqAbs(usdx.balanceOf(address(treasury)) - tBefore, feesPaid, 3, "the fee's collateral is the Treasury's");
        assertEq(redeemer.feeFor(STABLE, 1e18), 0.05e18, "the ramp still works (the fee rose to the cap)");
    }

    /// An honest redemption's accounting: the position gives up $1 of collateral per imdUSD, the redeemer gets it less
    /// the fee, the Treasury the fee.
    function test_review_F1_feeLeavesThePosition() public {
        uint256 c0 = ledger.position(_pid(STABLE, eve)).collateral;
        uint256 d0 = ledger.debtOf(_pid(STABLE, eve));
        vm.prank(whale);
        usd.transfer(dave, 1_000e18);
        uint256 fee = redeemer.feeFor(STABLE, 1_000e18);
        vm.prank(dave);
        (uint256 redeemed, uint256 out) = redeemer.redeem(STABLE, 1_000e18, 0.05e18, 5, 0);
        assertEq(redeemed, 1_000e18);
        assertEq(out, Math.mulDiv(1_000e18, 1e18 - fee, 1e18));
        assertEq(ledger.position(_pid(STABLE, eve)).collateral, c0 - 1_000e18, "whole on the principal: $1 per imdUSD");
        assertEq(ledger.debtOf(_pid(STABLE, eve)), d0 - 1_000e18);
        assertEq(usdx.balanceOf(address(treasury)), 1_000e18 - out);
    }

    // ------------------------------------------------------------ T1 / F2 / T4

    function test_review_T1_flashMintDoesNotDiluteRedemption() public {
        uint256 plainFee = redeemer.feeFor(STABLE, 20_000e18);
        uint256 supply = usd.totalSupply();
        FlashRedeemer fr = new FlashRedeemer(usd, redeemer, STABLE);
        vm.prank(carol);
        usd.transfer(address(fr), 20_000e18);
        fr.run(100_000e18, 20_000e18);
        assertEq(fr.circulatingSeen(), supply, "circulating() ignores the loan in flight");
        assertEq(fr.roomSeen(), usd.flashCap() - 100_000e18, "the cap is per transaction");
        assertEq(fr.feeSeen(), plainFee, "fee unchanged inside the flash");
        (uint192 base,) = redeemer.rates(STABLE);
        assertApproxEqAbs(base, Math.mulDiv(20_000e18, 1e18, supply) / 8, 1e13, "base-rate rise on the real supply (+ the decayed launch base)");
        assertEq(usd.flashOutstanding(), 0);
    }

    function test_review_T1_nestedFlashCannotPassTheCap() public {
        NestedFlasher f = new NestedFlasher(usd);
        uint256 cap = usd.flashCap();
        f.run(1, cap);
        assertEq(f.peakOutstanding(), cap);
        vm.expectRevert(abi.encodeWithSelector(ERC20FlashMint.ERC3156ExceededMaxLoan.selector, 0));
        f.run(2, cap);
        // Two halves nest fine; a third does not.
        f.run(2, cap / 2);
        assertEq(f.peakOutstanding(), cap);
        vm.expectRevert(abi.encodeWithSelector(ERC20FlashMint.ERC3156ExceededMaxLoan.selector, 0));
        f.run(3, cap / 2);
        assertEq(usd.flashOutstanding(), 0, "clear between transactions");
        assertEq(usd.maxFlashLoan(address(usd)), cap);
    }

    function test_review_F2_flashMintDoesNotMoveTheSavingsShare() public {
        vm.prank(carol);
        usd.transfer(bob, 15_000e18);
        vm.prank(bob);
        savings.deposit(15_000e18, bob);
        uint256 natural = _accrueShare(address(0), false);
        FlashAccruer fa = new FlashAccruer(usd, ledger, savings, STABLE);
        vm.prank(carol);
        usd.transfer(address(fa), 1e18);
        uint256 griefed = _accrueShare(address(fa), false);
        uint256 boosted = _accrueShare(address(fa), true);
        assertApproxEqRel(natural, 0.10e18, 0.02e18, "15k saved of ~150k: 10%");
        assertApproxEqRel(griefed, natural, 0.01e18, "a flash in the supply changes nothing");
        assertApproxEqRel(boosted, natural, 0.01e18, "a flash parked in the vault counts for nothing");
    }

    /// T4: an empty vault, or one whose only deposit is from this block, is paid nothing (not even to dead shares).
    function test_review_T4_sameBlockDepositEarnsNoUptake() public {
        assertEq(savings.totalSupply(), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _fresh();
        ledger.accrue(STABLE);
        assertEq(usd.balanceOf(address(savings)), 0, "empty vault: all to the Treasury");
        vm.prank(carol);
        usd.transfer(bob, 15_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _fresh();
        vm.prank(bob);
        savings.deposit(15_000e18, bob);
        assertEq(savings.settledAssets(), 0, "this block's deposit is not uptake yet");
        ledger.accrue(STABLE);
        assertEq(usd.balanceOf(address(savings)), 15_000e18, "nothing minted to a vault only just filled");
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(savings.settledAssets(), 15_000e18, "counts from the next block");
    }

    /// T3: interest vests from the moment it arrives, without waiting for a deposit to sync it.
    function test_review_T3_interestVestsFromArrival() public {
        vm.prank(carol);
        usd.transfer(bob, 15_000e18);
        vm.prank(bob);
        savings.deposit(15_000e18, bob);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _fresh();
        ledger.accrue(STABLE);
        uint256 arrived = usd.balanceOf(address(savings)) - 15_000e18;
        assertGt(arrived, 0);
        assertEq(savings.tracked(), 15_000e18 + arrived, "synced on arrival");
        assertEq(savings.streamEnd(), vm.getBlockTimestamp() + 7 days, "the 7-day stream started now");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(savings.totalAssets(), 15_000e18 + arrived, 1, "fully vested a week later, nobody touched it");
    }

    function _accrueShare(address who, bool park) internal returns (uint256) {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _fresh();
        uint256 s0 = usd.balanceOf(address(savings));
        uint256 t0 = usd.balanceOf(address(treasury));
        if (who == address(0)) ledger.accrue(STABLE);
        else FlashAccruer(who).run(100_000e18, park);
        uint256 toSavings = usd.balanceOf(address(savings)) - s0;
        uint256 total = toSavings + usd.balanceOf(address(treasury)) - t0;
        return Math.mulDiv(toSavings, 1e18, total);
    }

    // ------------------------------------------------------------ cross-stream (integration of the earlier review's fix streams)

    /// F1 x Treasury cover: the redemption fee reaches the Treasury as COLLATERAL (the type's token), not as imdUSD. It is
    /// not interest, so it credits no `surplusOf` (coverBadDebt's surplus-first ordering is untouched) and adds nothing
    /// `coverBadDebt` can burn: `unbacked()` does not move. Turning it into cover is a Safe sale.
    function test_review_cross_F1_feeIsCollateralNotCover() public {
        uint256 surplus0 = treasury.surplusOf(STABLE);
        uint256 tUsd0 = usd.balanceOf(address(treasury));
        uint256 tCol0 = usdx.balanceOf(address(treasury));
        uint256 unbacked0 = ledger.unbacked();
        vm.prank(whale);
        usd.transfer(dave, 1_000e18);
        vm.prank(dave);
        (uint256 redeemed, uint256 out) = redeemer.redeem(STABLE, 1_000e18, 0.05e18, 5, 0);
        assertGt(redeemed - out, 0, "a fee was charged");
        assertEq(usdx.balanceOf(address(treasury)) - tCol0, redeemed - out, "the fee arrives as collateral");
        // The only imdUSD that arrives is the position's accrued interest, every unit of it noted as surplus: the fee
        // adds no imdUSD and no surplus credit.
        assertEq(
            usd.balanceOf(address(treasury)) - tUsd0,
            treasury.surplusOf(STABLE) - surplus0,
            "imdUSD arriving == interest noted as surplus (the fee adds none)"
        );
        assertEq(ledger.unbacked(), unbacked0, "nothing coverBadDebt could burn was added");
    }
}

/// @dev A stand-in peg keeper: mints under the keeper role and reports its outstanding for the supply equation.
contract KeeperStub {
    ImdUSD public immutable usd;
    uint256 public outstanding;

    constructor(ImdUSD usd_) {
        usd = usd_;
    }

    function mint(address to, uint256 amount) external {
        outstanding += amount;
        usd.mint(to, amount);
    }
}
