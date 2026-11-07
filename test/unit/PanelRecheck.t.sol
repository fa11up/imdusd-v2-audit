// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LiqBase} from "./panel/LiqBase.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {GovernedByKind} from "../../src/GovernedByKind.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Pricer} from "../../src/Pricer.sol";
import {MockFeed} from "../utils/Mocks.sol";
import {console2} from "forge-std/console2.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";

/// @notice Re-check regressions that need the real Ledger, Liquidator, Treasury, Pricer and sleeves together.
contract RecheckWipeTest is LiqBase {
    function _value(address u) private view returns (uint256) {
        return Math.mulDiv(edge.vested(), edge.balanceOf(u), edge.totalSupply());
    }

    /// The real wipe path. A liquidation books more bad debt than the edge sleeve and the Treasury hold; its own cover takes
    /// the sleeve to its residue. Carol's bucket, deposited just before the loss and not yet matured at it, waits: nobody can burn it against the hole. When
    /// the Treasury has been funded and coverBadDebt runs, the bucket converts whole.
    function test_realWipe_bucketWaitsThenConverts() public {
        _fund(bob, edge, 1_000e18, true);
        _open(dave, ETH, 1_000e18, 50_000e18, 0.05e18);
        _fund(carol, edge, 10_000e18, false);
        _open(alice, SIMD, 2_000e18, 5_000e18, 0.1e18);
        simdMedian.set(1e18);
        simdSpot.set(1e18);

        vm.prank(dave);
        liquidator.liquidate(_pidOf(SIMD, alice));
        (,,,, uint128 bad) = ledger.ilkState(SIMD);
        assertGt(bad, 0, "the hole outlives the sleeve and the Treasury");
        assertEq(edge.vested(), 1e18, "wiped to the residue by the liquidation's own cover");

        vm.warp(vm.getBlockTimestamp() + 2 days); // carol's bucket has matured now
        _refresh();
        edge.realize(carol);
        assertEq(edge.balanceOf(carol), 0, "waits");
        assertEq(edge.staged(), 10_000e18, "untouched");
        assertEq(edge.bidRoom(SIMD), 0);
        assertEq(edge.bidRoomNow(SIMD), 0);

        vm.prank(dave);
        usd.transfer(address(treasury), bad);
        treasury.coverBadDebt(SIMD);
        (,,,, bad) = ledger.ilkState(SIMD);
        assertEq(bad, 0);
        edge.realize(carol);
        assertGt(_value(carol), 9_999e18, "carol keeps her deposit");
    }

    // ---------------------------------------------------------------- Backstop.retire through Parameters

    function _retire(bool isEdge, address token, bool on) private {
        uint8 k = params.RETIRE_SLEEVE_TOKEN();
        vm.prank(governor);
        params.propose(abi.encode(k, isEdge, token, on));
        vm.expectPartialRevert(GovernedByKind.TooEarly.selector);
        params.applyPending(k);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(makeAddr("anyone"));
        params.applyPending(k);
    }

    /// The reviewer's F4 on the deployed wiring: the sleeve holds WETH from a bid and the type's feed dies. Conversions wait
    /// until the Safe retires the token through Parameters' 48h timelock, the only way there is; holders still take it in kind.
    function test_M4_retiredTokenUnblocksConversions() public {
        _fund(bob, blue, 50_000e18, true);
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _fund(carol, blue, 5_000e18, false);
        ethMedian.set(1500e18);
        ethSpot.set(1500e18);
        liquidator.liquidate(_pidOf(ETH, alice));
        uint256 held = blue.coll(address(weth));
        assertGt(held, 0, "the sleeve bought");

        ethMedian.set(0); // the feed dies
        vm.warp(vm.getBlockTimestamp() + 2 days);
        blue.realize(carol);
        assertEq(blue.balanceOf(carol), 0, "fails closed while not retired");

        vm.expectRevert(Backstop.Unauthorized.selector);
        blue.retire(address(weth), true); // nobody calls it directly
        vm.prank(governor);
        vm.expectRevert(Backstop.Unauthorized.selector);
        blue.retire(address(weth), true);

        _retire(false, address(weth), true);
        assertTrue(blue.retired(address(weth)));
        blue.realize(carol);
        assertGt(blue.balanceOf(carol), 0, "converts");
        assertEq(blue.staged(), 0);

        uint256 share = Math.mulDiv(held, blue.balanceOf(bob), blue.totalSupply());
        uint256 sb = blue.balanceOf(bob);
        vm.prank(bob);
        blue.requestWithdraw(sb);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 w0 = weth.balanceOf(bob);
        vm.prank(bob);
        blue.withdraw(bob);
        assertEq(weth.balanceOf(bob) - w0, share, "bob takes his WETH share in kind");

        _retire(false, address(weth), false);
        assertFalse(blue.retired(address(weth)), "the same kind undoes it");
    }

    function test_retiredFlagStaysWhileUnpriced() public {
        _heldWeth();
        _open(dave, ETH, 100e18, 10_000e18, 0.05e18);
        ethMedian.set(0);
        _retire(false, address(weth), true);
        vm.prank(dave);
        blue.deposit(10_000e18, dave);
        assertTrue(blue.retired(address(weth)), "no good price: it stays");
    }

    function test_retireValidation() public {
        uint8 k = params.RETIRE_SLEEVE_TOKEN();
        vm.startPrank(governor);
        vm.expectRevert(ParametersBase.BadConfig.selector);
        params.propose(abi.encode(k, false, address(simd), true)); // held by the edge sleeve, not blue
        vm.expectRevert(ParametersBase.BadConfig.selector);
        params.propose(abi.encode(k, true, address(weth), true));
        vm.stopPrank();
        vm.expectRevert(GovernedByKind.NotGovernor.selector);
        params.propose(abi.encode(k, false, address(weth), true));
        _retire(true, address(simd), true);
        assertTrue(edge.retired(address(simd)));
        assertFalse(blue.retired(address(simd)));
    }

    /// Second re-check: a retire is refused while the token has a price, at apply.
    function test_R2_retireRefusedWhilePriced() public {
        uint8 k = params.RETIRE_SLEEVE_TOKEN();
        vm.prank(governor);
        params.propose(abi.encode(k, false, address(weth), true));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _refresh(); // the feed came back
        vm.expectRevert(Backstop.StillPriced.selector);
        params.applyPending(k);
        assertFalse(blue.retired(address(weth)));
    }

    function _heldWeth() private returns (uint256 held) {
        _fund(bob, blue, 50_000e18, true);
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        ethMedian.set(1500e18);
        ethSpot.set(1500e18);
        liquidator.liquidate(_pidOf(ETH, alice));
        held = blue.coll(address(weth));
        assertGt(held, 0);
    }

    /// Second re-check's PoC turned round. A retire from an outage used to stick: any later stale read priced conversions with
    /// the token at 0, dave's 10,000 turned 13,133 at bob's cost. The first conversion step that sees a good price clears
    /// the flag, so the same stale read now makes the bucket wait.
    function test_R2_stickyRetireClearedByAGoodPrice() public {
        _heldWeth();
        _retire(false, address(weth), true); // retired during an outage (the feed is stale after the timelock's warp)
        _refresh(); // the feed has come back
        _fund(dave, blue, 10_000e18, false); // this deposit's own step sees the good price
        assertFalse(blue.retired(address(weth)), "cleared");
        vm.warp(vm.getBlockTimestamp() + 2 days);
        ethMedian.setStale(true); // one stale read
        blue.realize(dave);
        assertEq(blue.balanceOf(dave), 0, "waits, as for a token never retired");
    }

    /// The feed recovers and goes stale again with no sleeve transaction in the gap, so no step
    /// ever saw the good price. Its legs have updated since the retire, so it is not valued at 0.
    function test_retireOvertakenByAnUpdateNobodyTransactedIn() public {
        _heldWeth();
        _fund(dave, blue, 10_000e18, false);
        ethMedian.setStale(true);
        _retire(false, address(weth), true);
        assertTrue(blue.retired(address(weth)));
        vm.warp(vm.getBlockTimestamp() + 1);
        ethMedian.set(ethMedian.value()); // the feed comes back; nobody calls the sleeve
        ethMedian.setStale(true); // and it goes stale again
        vm.warp(vm.getBlockTimestamp() + 2 days);
        (, bool ok) = blue.nav();
        assertFalse(ok, "fails closed, not valued at 0");
        blue.realize(dave);
        assertEq(blue.balanceOf(dave), 0, "waits, as for a token never retired");
        assertFalse(blue.retired(address(weth)), "the flag is cleared by the step");
    }

    /// `bidRoomNow` is what the next bid's room reads: a bucket `_convert` would leave waiting is not in it.
    function test_bidRoomNowLeavesOutABucketThatWouldWait() public {
        _heldWeth();
        _fund(dave, blue, 10_000e18, false);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _refresh();
        uint256 fresh = blue.bidRoomNow(ETH);
        assertGt(fresh, blue.bidRoom(ETH), "matured and able to convert: it counts");
        ethMedian.setStale(true);
        assertEq(blue.bidRoomNow(ETH), blue.bidRoom(ETH), "the held token is unpriced: the bucket waits");
    }

    /// A batch may carry it (the Safe's usual shape) and locks it like any other kind.
    function test_retireInABatch() public {
        uint8 k = params.RETIRE_SLEEVE_TOKEN();
        bytes[] memory items = new bytes[](1);
        items[0] = abi.encode(k, false, address(weth), true);
        uint8 b = params.BATCH();
        vm.startPrank(governor);
        params.propose(abi.encode(b, items));
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        params.propose(items[0]);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending(b);
        assertTrue(blue.retired(address(weth)));
    }
}

/// @notice Variant of the forced-bid finding: the sIMD pair is fresh and agreeing but far from the market. The sleeve must not
/// be forced to buy there: `agree` also needs the live pool within `skew` of `low`. Borrowing and `low` do not read it.
contract RecheckLiveLegTest is LiqBase {
    MockFeed simdLive;

    function _simdLive() internal override returns (IFeed) {
        simdLive = new MockFeed(5e18);
        return IFeed(address(simdLive));
    }

    function _setup() private returns (uint256 id) {
        _fund(bob, edge, 50_000e18, true);
        _open(carol, ETH, 1_000e18, 100_000e18, 0.05e18); // carol can pay as the caller
        _open(alice, SIMD, 10_000e18, 27_000e18, 0.05e18);
        id = _pidOf(SIMD, alice);
        simdMedian.set(4.5e18); // 166.7% of a 170% mat at the pair
        simdSpot.set(4.5e18);
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
    }

    /// The market is 33% under the fresh, agreeing pair: anyone used to be able to make the sleeve buy at -28% at market.
    function test_V1_marketBelowThePairNoForcedBid() public {
        uint256 id = _setup();
        simdLive.set(3e18);
        Pricer.Quote memory q = pricer.quote(SIMD);
        assertFalse(q.agree, "the sleeve stands aside");
        assertEq(q.low, 4.5e18, "low is untouched");
        assertTrue(q.borrowable, "the legs alone decide borrowing");
        vm.prank(carol);
        (uint256 repaid,,) = liquidator.liquidate(id);
        assertGt(repaid, 0, "the caller may still pay it");
        assertEq(edge.coll(address(simd)), 0, "the sleeve did not buy");
        assertApproxEqAbs(edge.vested(), 50_000e18, 1e18, "nor pay");
    }

    /// The other direction is no overpay: a market above the pair means the sleeve buys under the market, so it bids.
    function test_V1_marketAboveThePairStillBids() public {
        uint256 id = _setup();
        simdLive.set(6e18);
        assertTrue(pricer.quote(SIMD).agree);
        vm.prank(dave);
        liquidator.liquidate(id);
        assertGt(edge.coll(address(simd)), 0, "the sleeve bought below the market");
    }

    /// Accepted griefing (second re-check): a one-tx push down past skew sends the liquidation to the caller, who takes the
    /// penalty's value. The sleeve loses that bonus only, never principal.
    function test_R2_pushDownOnlyDivertsTheBonus() public {
        uint256 id = _setup();
        uint256 skew = params.risk(SIMD).skew;
        simdLive.set(4.5e18 - Math.mulDiv(4.5e18, skew, 1e18) - 1e6);
        assertFalse(pricer.quote(SIMD).agree);
        assertEq(pricer.quote(SIMD).low, 4.5e18, "low untouched");
        vm.prank(carol);
        liquidator.liquidate(id);
        assertEq(edge.coll(address(simd)), 0);
        assertApproxEqAbs(edge.vested(), 50_000e18, 1e18, "the sleeve's principal is untouched");
    }

    function test_V1_liveWithinSkewBids() public {
        uint256 id = _setup();
        uint256 skew = params.risk(SIMD).skew;
        simdLive.set(4.5e18 - 4.5e18 * skew / 1e18); // exactly at the edge, below
        assertTrue(pricer.quote(SIMD).agree, "inside skew below");
        simdLive.set(4.5e18 - 4.5e18 * skew / 1e18 - 1e6);
        assertFalse(pricer.quote(SIMD).agree, "just past it, below");
        simdLive.set(4.5e18 + 4.5e18 * skew / 1e18 + 1e6);
        assertTrue(pricer.quote(SIMD).agree, "any distance above");
        simdLive.set(4.5e18);
        vm.prank(dave); // no imdUSD: the sleeve is the payer
        liquidator.liquidate(id);
        assertGt(edge.coll(address(simd)), 0, "the sleeve bought");
    }

    function test_V1_staleOrZeroLiveNoBid() public {
        uint256 id = _setup();
        simdLive.setStale(true);
        assertFalse(pricer.quote(SIMD).agree, "stale live");
        assertTrue(pricer.quote(SIMD).borrowable, "borrowing ignores it");
        simdLive.set(0);
        assertFalse(pricer.quote(SIMD).agree, "zero live");
        vm.prank(carol);
        liquidator.liquidate(id);
        assertEq(edge.coll(address(simd)), 0);
    }

    /// What an atomic push up still buys: the pool at the pair for one transaction reopens the bid. The figures here are the
    /// value moved; what the push costs is the pool's round trip (see Known issues in the README).
    function test_V1_atomicPushUpWhoGains() public {
        uint256 id = _setup();
        simdLive.set(4.5e18); // pushed from a 3.0 market into the pair's skew
        uint256 market = 3e18;
        uint256 aliceColl = ledger.position(id).collateral;
        uint256 debt = ledger.debtOf(id);
        vm.prank(dave);
        (uint256 repaid, uint256 seized,) = liquidator.liquidate(id);
        uint256 got = edge.coll(address(simd));
        console2.log("debt repaid by the sleeve", repaid);
        console2.log("sleeve loss at market", repaid - Math.mulDiv(got, market, 1e18));
        uint256 leftColl = aliceColl - seized;
        uint256 equity0 = Math.mulDiv(aliceColl, market, 1e18) - debt;
        uint256 equity1 = Math.mulDiv(leftColl, market, 1e18) + debt - ledger.debtOf(id) - debt;
        console2.log("borrower equity at market before", equity0);
        console2.log("borrower equity at market after", equity1);
        console2.log("marker chip + Treasury cut at market", Math.mulDiv(seized - got, market, 1e18));
        assertGt(equity1, equity0, "the borrower is the winner of a forced bid");
    }
}

/// @notice What a SET_RATE operator can and cannot do with the rate cooldown.
contract RecheckOperatorRateTest is LiqBase {
    /// Accepted: SET_RATE is the owner's own grant. An operator's change, even of 1 wei or none, restarts the cooldown,
    /// and the owner's next change then pays the premium. Stated here so the behaviour is on record.
    function test_M13_setRateGrantCanRestartTheCooldown() public {
        _open(alice, ETH, 100e18, 10_000e18, 0.05e18);
        uint256 id = _pidOf(ETH, alice);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        _refresh();
        PositionNFT nft = ledger.nft();
        vm.prank(alice);
        nft.approveOperator(id, dave, 4); // SET_RATE only
        (uint256 p, uint256 n) = sorted.findInsertPosition(ETH, 0.05e18 + 1);
        vm.prank(dave);
        ledger.setRate(id, 0.05e18 + 1, p, n);
        uint256 d0 = ledger.debtOf(id);
        (p, n) = sorted.findInsertPosition(ETH, 0.06e18);
        vm.prank(alice);
        ledger.setRate(id, 0.06e18, p, n);
        assertGt(ledger.debtOf(id), d0, "the owner pays the premium");
    }

    function test_M13_operatorRealChangeOutsideCooldownStillWorks() public {
        _open(alice, ETH, 100e18, 10_000e18, 0.05e18);
        uint256 id = _pidOf(ETH, alice);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        _refresh();
        PositionNFT nft = ledger.nft();
        vm.prank(alice);
        nft.approveOperator(id, dave, 4);
        (uint256 p, uint256 n) = sorted.findInsertPosition(ETH, 0.06e18);
        uint256 d0 = ledger.debtOf(id);
        vm.prank(dave);
        ledger.setRate(id, 0.06e18, p, n);
        assertEq(ledger.position(id).rate, 0.06e18);
        assertEq(ledger.debtOf(id), d0);
    }

    function test_M13_ownerSameRateStillAllowed() public {
        _open(alice, ETH, 100e18, 10_000e18, 0.05e18);
        uint256 id = _pidOf(ETH, alice);
        vm.prank(alice);
        ledger.setRate(id, 0.05e18, 0, 0);
        assertEq(ledger.position(id).rate, 0.05e18);
    }
}
