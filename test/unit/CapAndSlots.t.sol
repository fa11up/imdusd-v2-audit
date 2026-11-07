// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {System} from "../utils/System.sol";
import {SeatSystem} from "../utils/SeatSystem.sol";
import {MockERC20, MockFeed, MockSeatFeed} from "../utils/Mocks.sol";
import {MockSeatNFT, MockAgentAdapter} from "../utils/SeatMocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {GovernedByKind} from "../../src/GovernedByKind.sol";
import {Ledger, Adjust} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {_pid} from "../utils/Pid.sol";
import {Pricer} from "../../src/Pricer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";

/// @notice A per-type BORROW price ceiling, and one pending proposal per kind.
contract CapAndSlotsTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";

    MockERC20 weth;
    MockERC20 simd;
    MockFeed ethMedian;
    MockFeed ethSpot;
    MockFeed simdFeed;
    MockFeed nhi;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dave = makeAddr("dave");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        simd = new MockERC20("sIMD", 18);
        ethMedian = new MockFeed(2000e18);
        ethSpot = new MockFeed(2000e18);
        simdFeed = new MockFeed(5e18);
        nhi = new MockFeed(0.98e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethMedian, ethSpot, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1_000_000e18));
        ParametersBase.Risk memory ir = _risk(1.7e18, 1_000_000e18);
        ir.chop = 0.2e18;
        _addIlk(SIMD, address(simd), simdFeed, simdFeed, nhi, address(0), address(0), true, ir);
        params.seal();
        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, dave][i];
            weth.mint(u, 1000e18);
            simd.mint(u, 100_000e18);
            vm.startPrank(u);
            weth.approve(address(ledger), type(uint256).max);
            simd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _refresh() internal {
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
        simdFeed.set(simdFeed.value());
        nhi.set(nhi.value());
    }

    mapping(uint256 => bool) internal _opened;

    function _adjust(address u, bytes32 ilk, int256 coll, int256 debt, uint64 rate) internal {
        Adjust memory a = Adjust(coll, debt, rate, 0, 0, false, type(uint256).max, address(0));
        uint256 id = _pid(ilk, u);
        bool exists = _opened[id]; // no extra external call: a caller's vm.expectRevert must hit the action itself
        vm.prank(u);
        if (exists) ledger.adjust(id, a);
        else ledger.open(ilk, 0, a);
        _opened[id] = ledger.ilkOf(id) != bytes32(0); // read after the action, so an expected revert is not counted
    }

    function _propose(bytes memory payload) internal {
        vm.prank(governor);
        params.propose(payload);
    }

    function _ethTo(uint256 p) internal {
        ethMedian.set(p);
        ethSpot.set(p);
    }

    // ================================================================ A2: the cap

    function test_cap_setOrLowerInstantByGovernorOnly() public {
        assertEq(params.cap(ETH), 0);
        vm.expectRevert(GovernedByKind.NotGovernor.selector);
        params.lowerCap(ETH, 1500e18);
        vm.startPrank(governor);
        params.lowerCap(ETH, 1500e18); // from none: instant
        assertEq(params.cap(ETH), 1500e18);
        params.lowerCap(ETH, 1200e18); // lower: instant
        assertEq(params.cap(ETH), 1200e18);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerCap(ETH, 1200e18); // not lower
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerCap(ETH, 1300e18); // a raise is not instant
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerCap(ETH, 0); // never removed
        vm.expectRevert(ParametersBase.UnknownIlk.selector);
        params.lowerCap("NOPE", 1e18);
        vm.stopPrank();
    }

    function test_cap_raiseNeeds48hAndAtMostDouble() public {
        vm.prank(governor);
        params.lowerCap(ETH, 1000e18);
        uint8 k = params.SET_CAP();
        // More than x2, not a raise, or a type with no cap: refused at propose.
        vm.startPrank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, ETH, uint256(2000e18 + 1)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, ETH, uint256(900e18)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, SIMD, uint256(10e18)));
        params.propose(abi.encode(k, ETH, uint256(2000e18)));
        vm.stopPrank();
        (, uint256 eta) = params.pendingOf(k);
        vm.expectRevert(abi.encodeWithSelector(GovernedByKind.TooEarly.selector, eta));
        params.applyPending(k);
        vm.warp(eta);
        params.applyPending(k);
        assertEq(params.cap(ETH), 2000e18);
    }

    function test_cap_instantLowerInWindowShrinksAPendingRaise() public {
        vm.prank(governor);
        params.lowerCap(ETH, 1000e18);
        _propose(abi.encode(params.SET_CAP(), ETH, uint256(2000e18)));
        vm.prank(governor);
        params.lowerCap(ETH, 600e18); // the window does not freeze the instant path
        _skip(48 hours);
        uint8 k = params.SET_CAP();
        // The instant lower cancelled the pending raise of the same type's cap.
        vm.expectRevert(GovernedByKind.NothingPending.selector);
        params.applyPending(k);
        assertEq(params.cap(ETH), 600e18);
    }

    function test_cap_quoteCapsBorrowOnly() public {
        vm.prank(governor);
        params.lowerCap(ETH, 1500e18);
        Pricer.Quote memory q = pricer.quote(ETH);
        assertEq(q.low, 2000e18, "low uncapped");
        assertEq(q.high, 2000e18);
        assertEq(q.payout, 2000e18);
        assertEq(q.borrow, 1500e18, "borrow = min(low, cap)");
        assertTrue(q.borrowable, "the cap does not stop borrowing by itself");
        // A cap above the market changes nothing.
        _ethTo(1200e18);
        q = pricer.quote(ETH);
        assertEq(q.borrow, 1200e18);
        // No cap: borrow == low.
        q = pricer.quote(SIMD);
        assertEq(q.borrow, q.low);
    }

    function test_cap_borrowAndWithdrawRefusedAboveCapPrice() public {
        _adjust(alice, ETH, 10e18, 10_000e18, 0.05e18); // $20,000 / ~$10,010: 200% at market
        vm.prank(governor);
        params.lowerCap(ETH, 1500e18); // $15,000 at the cap: ~150% > 140%
        // At market there would be room for ~$4,200 more; at the cap there is ~$700 (before the upfront fee).
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, 0, 1_000e18, 0);
        _adjust(alice, ETH, 0, 500e18, 0);
        // Withdrawing collateral is measured at the cap too.
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, -1e18, 0, 0);
        // Deposits and repayment are never refused for the cap.
        _adjust(alice, ETH, 1e18, 0, 0);
        _adjust(alice, ETH, 0, -500e18, 0);
        _adjust(alice, ETH, -0.5e18, 0, 0); // 10.5 ETH x $1,500 = $15,750 / ~$10,010 > 140%
        (bool ok, bool priced) = ledger.healthy(_pid(ETH, alice));
        assertTrue(ok && priced, "healthy at market");
    }

    /// The cap never makes a position liquidatable: a position under the line only AT THE CAP stays safe.
    function test_cap_doesNotCondemnAHealthyPosition() public {
        _adjust(alice, ETH, 10e18, 10_000e18, 0.05e18);
        vm.prank(governor);
        params.lowerCap(ETH, 500e18); // at the cap: $5,000 vs $10,000 of debt
        (bool ok,) = ledger.healthy(_pid(ETH, alice));
        assertTrue(ok, "healthy at the uncapped low");
        vm.expectRevert();
        liquidator.liquidate(_pid(ETH, alice));
    }

    /// ...and never shelters an unhealthy one: liquidation and redemption pay at the uncapped prices, exactly as
    /// with no cap at all.
    function test_cap_liquidationAndRedemptionUseUncappedPrices() public {
        _adjust(alice, ETH, 10e18, 10_000e18, 0.02e18);
        _adjust(bob, ETH, 10e18, 10_000e18, 0.05e18);
        _adjust(dave, ETH, 200e18, 50_000e18, 0.05e18); // the liquidator's own imdUSD (safe at $1,300: 520%)
        uint256 base = vm.snapshotState();

        // Redemption: the same collateral out with and without a cap.
        uint256 fee = redeemer.feeFor(ETH, 2_000e18);
        vm.prank(dave);
        (, uint256 outNoCap) = redeemer.redeem(ETH, 2_000e18, fee, 10, 0);
        vm.revertToState(base);
        vm.prank(governor);
        params.lowerCap(ETH, 800e18);
        vm.prank(dave);
        (, uint256 outCap) = redeemer.redeem(ETH, 2_000e18, fee, 10, 0);
        assertEq(outCap, outNoCap, "redemption pays at the uncapped payout");

        // Liquidation: under water at market (ETH $1,300: 130% < 140%), with a cap far below.
        vm.revertToState(base);
        _ethTo(1300e18);
        vm.prank(dave);
        (uint256 r0, uint256 s0, uint256 b0) = liquidator.liquidate(_pid(ETH, alice));
        vm.revertToState(base);
        vm.prank(governor);
        params.lowerCap(ETH, 500e18);
        _ethTo(1300e18);
        vm.prank(dave);
        (uint256 r1, uint256 s1, uint256 b1) = liquidator.liquidate(_pid(ETH, alice));
        assertEq(r1, r0, "repaid");
        assertEq(s1, s0, "seized at the uncapped price");
        assertEq(b1, b0, "bad debt");
        assertGt(s0, 0);
    }

    function test_cap_onSimd() public {
        // sIMD at $5, NHI 0.98: mat 170%. 10,000 sIMD = $50,000.
        _adjust(alice, SIMD, 10_000e18, 10_000e18, 0.05e18);
        vm.prank(governor);
        params.lowerCap(SIMD, 2e18); // a pump-resistant ceiling: $20,000 at the cap
        Pricer.Quote memory q = pricer.quote(SIMD);
        assertEq(q.low, 5e18);
        assertEq(q.borrow, 2e18);
        // $20,000 / 12,000+ < 170%: refused, though at market it would be ~415%.
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, SIMD, 0, 2_000e18, 0);
        // $20,000 / ~11,511 ≈ 174%: allowed.
        _adjust(alice, SIMD, 0, 1_500e18, 0);
        // A pump of the feed does not lift the borrow price past the cap.
        simdFeed.set(50e18);
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, SIMD, 0, 1_000e18, 0);
    }

    function test_cap_genesisSetterOnlyBeforeSeal() public {
        vm.expectRevert(ParametersBase.Sealed.selector);
        params.setGenesisCap(ETH, 1e18);
    }

    /// A rate change is not a borrow. Its premium is measured at the market low, so a cap cannot stop a borrower
    /// stepping back in the redemption order; a position the premium would really make unhealthy is still refused.
    function test_cap_chargedRateChangeMeasuredAtLowNotCap() public {
        _adjust(alice, ETH, 10e18, 10_000e18, 0.05e18);
        _adjust(bob, ETH, 10e18, 14_262e18, 0.05e18); // ~140.1% at $2,000: a premium takes it under the line
        vm.prank(governor);
        params.lowerCap(ETH, 1400e18); // $14,000 at the cap vs ~$10,010 + a premium: under 140% there
        _refresh();
        vm.prank(alice);
        ledger.setRate(_pid(ETH, alice), 0.06e18, 0, 0); // inside the cooldown: charged, healthy at $2,000
        assertGt(ledger.position(_pid(ETH, alice)).debt, 10_010e18, "premium charged");

        vm.prank(bob);
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        ledger.setRate(_pid(ETH, bob), 0.5e18, 0, 0);
    }

    /// Withdraw + a larger repay in one call raises the ratio, so the cap must not refuse it.
    function test_panelM9_deRiskingWithdrawNotMeasuredAtCap() public {
        _adjust(alice, ETH, 10e18, 13_300e18, 0.05e18); // ~150% at $2,000
        vm.prank(governor);
        params.lowerCap(ETH, 1700e18); // ~128% at the cap, under the 140% line
        _refresh();
        // Lowers the ratio (150% -> ~144%): healthy at market, but still leverage, so the cap refuses it.
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, -0.5e18, -100e18, 0);
        // A plain withdrawal is refused as before, and so is a plain borrow.
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, -0.1e18, 0, 0);
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, 0, 1e18, 0);
        // Raises it (150% -> ~159%): passes although ~135% at the cap.
        _adjust(alice, ETH, -1e18, -2_000e18, 0);
        assertEq(ledger.position(_pid(ETH, alice)).collateral, 9e18);
    }

    /// The exemption is from the cap only. A shrink that leaves the position under the line at market is refused.
    function test_panelM9_deRiskingStillHealthyAtMarket() public {
        _adjust(alice, ETH, 10e18, 13_300e18, 0.05e18);
        _ethTo(1800e18); // ~135%: under the 140% line
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, -0.1e18, -200e18, 0); // the ratio rises, to ~136%, still under
        _adjust(alice, ETH, -1e18, -3_000e18, 0); // ~157%
    }

    // ================================================================ A4: one slot per kind

    function test_slots_twoKindsPendingAtOnceAppliedIndependently() public {
        uint8 brake = params.SET_UNBACKED_BRAKE();
        uint8 lull = params.SET_MAX_LULL();
        _propose(abi.encode(brake, uint64(0.02e18)));
        _skip(1 days);
        _propose(abi.encode(lull, uint64(1 hours)));
        assertEq(params.pendingKinds(), (uint256(1) << brake) | (uint256(1) << lull));
        // The no-argument forms refuse to guess.
        _skip(1 days);
        vm.expectRevert(GovernedByKind.SeveralPending.selector);
        params.applyPending();
        vm.prank(governor);
        vm.expectRevert(GovernedByKind.SeveralPending.selector);
        params.cancel();
        // The views name the lowest kind's slot.
        (bytes memory p, uint256 eta) = params.pendingOf(brake);
        assertEq(keccak256(params.pending()), keccak256(p));
        assertEq(params.pendingEta(), eta);
        // brake's ETA has run, lull's has not: they apply on their own clocks.
        params.applyPending(brake);
        assertEq(params.unbackedBrake(), 0.02e18);
        (, uint256 lullEta) = params.pendingOf(lull);
        vm.expectRevert(abi.encodeWithSelector(GovernedByKind.TooEarly.selector, lullEta));
        params.applyPending(lull);
        _skip(1 days);
        params.applyPending(); // one left: the no-argument form works again
        assertEq(params.maxLull(), 1 hours);
        assertEq(params.pendingKinds(), 0);
        assertEq(params.pendingEta(), 0);
        assertEq(params.pending().length, 0);
    }

    function test_slots_sameKindCannotBeDoublePending() public {
        ParametersBase.Risk memory r = params.risk(ETH);
        r.line = 2_000_000e18;
        _propose(abi.encode(params.SET_RISK(), ETH, r));
        // Another SET_RISK, even for another type, waits for the slot.
        ParametersBase.Risk memory s = params.risk(SIMD);
        s.line = 2_000_000e18;
        bytes memory other = abi.encode(params.SET_RISK(), SIMD, s);
        uint8 lull = params.SET_MAX_LULL();
        uint8 setRisk = params.SET_RISK();
        vm.prank(governor);
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        params.propose(other);
        // Cancelling that kind frees it; other kinds were never blocked.
        _propose(abi.encode(params.SET_UNBACKED_BRAKE(), uint64(0.02e18)));
        vm.prank(governor);
        params.cancel(setRisk);
        _propose(other);
        vm.prank(governor);
        vm.expectRevert(GovernedByKind.NothingPending.selector);
        params.cancel(lull);
    }

    function test_slots_expiryIsPerSlot() public {
        uint8 brake = params.SET_UNBACKED_BRAKE();
        uint8 lull = params.SET_MAX_LULL();
        _propose(abi.encode(brake, uint64(0.02e18)));
        (, uint256 brakeEta) = params.pendingOf(brake);
        _skip(10 days);
        _propose(abi.encode(lull, uint64(1 hours)));
        (, uint256 lullEta) = params.pendingOf(lull);
        vm.warp(brakeEta + 14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(GovernedByKind.Expired.selector, brakeEta));
        params.applyPending(brake);
        assertLe(block.timestamp, lullEta + 14 days);
        params.applyPending(lull); // its own clock: still live
        assertEq(params.maxLull(), 1 hours);
        // The expired one keeps its slot (and lock) until cancelled.
        vm.prank(governor);
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        params.propose(abi.encode(brake, uint64(0.03e18)));
        vm.prank(governor);
        params.cancel(brake);
        _propose(abi.encode(brake, uint64(0.03e18)));
    }

    function test_slots_batchLocksItsKinds() public {
        uint8 cap = params.SET_KEEPER_CAP();
        uint8 brake = params.SET_UNBACKED_BRAKE();
        uint8 lull = params.SET_MAX_LULL();
        uint8 batch = params.BATCH();
        ParametersBase.Risk memory r = params.risk(ETH);
        r.line = 2_000_000e18;

        // A kind pending alone cannot also ride in a batch.
        _propose(abi.encode(cap, uint256(1_000e18)));
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(cap, uint256(2_000e18));
        items[1] = abi.encode(brake, uint64(0.02e18));
        vm.prank(governor);
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        params.propose(abi.encode(batch, items));

        // A batch of other kinds is fine, and then locks them against lone proposals.
        uint8 setRisk = params.SET_RISK();
        items[0] = abi.encode(setRisk, ETH, r);
        _propose(abi.encode(batch, items));
        assertEq(params.locked(), (uint256(1) << cap) | (uint256(1) << batch) | (uint256(1) << setRisk) | (uint256(1) << brake));
        vm.startPrank(governor);
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        params.propose(abi.encode(brake, uint64(0.03e18)));
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        params.propose(abi.encode(setRisk, ETH, r));
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        params.propose(abi.encode(batch, items)); // one batch at a time
        params.propose(abi.encode(lull, uint64(1 hours))); // an unrelated kind is free
        vm.stopPrank();

        _skip(48 hours);
        params.applyPending(batch);
        assertEq(params.risk(ETH).line, 2_000_000e18);
        assertEq(params.unbackedBrake(), 0.02e18);
        // Its locks are released; the lone keeper cap and lull are still pending on their own.
        assertEq(params.locked(), (uint256(1) << cap) | (uint256(1) << lull));
        _propose(abi.encode(brake, uint64(0.03e18)));
        params.applyPending(cap);
        params.applyPending(lull);
        assertEq(params.keeperCap(), 1_000e18);
    }

    function test_slots_batchMayCarryTheSameKindTwice() public {
        ParametersBase.Risk memory e = params.risk(ETH);
        e.line = 2_000_000e18;
        ParametersBase.Risk memory s = params.risk(SIMD);
        s.line = 3_000_000e18;
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(params.SET_RISK(), ETH, e);
        items[1] = abi.encode(params.SET_RISK(), SIMD, s);
        _propose(abi.encode(params.BATCH(), items));
        _skip(48 hours);
        params.applyPending();
        assertEq(params.risk(ETH).line, 2_000_000e18);
        assertEq(params.risk(SIMD).line, 3_000_000e18);
    }

    function test_slots_capKindInBatchAndLowersStayInstant() public {
        vm.prank(governor);
        params.lowerCap(ETH, 1000e18);
        bytes[] memory items = new bytes[](1);
        items[0] = abi.encode(params.SET_CAP(), ETH, uint256(1500e18));
        _propose(abi.encode(params.BATCH(), items));
        // Instant lowers are never blocked by pending slots. Lowers of fields the batch does not touch leave it pending;
        // a lower of a field it carries cancels it.
        vm.startPrank(governor);
        params.lowerUnbackedBrake(0.005e18);
        params.lowerLine(ETH, 500_000e18);
        assertEq(params.pendingKinds(), uint256(1) << params.BATCH(), "untouched fields: batch kept");
        params.lowerCap(ETH, 900e18);
        vm.stopPrank();
        assertEq(params.pendingKinds(), 0, "the batch carried SET_CAP on ETH: cancelled");
        assertEq(params.cap(ETH), 900e18);
    }
}

/// @notice The cap on a seat type (04): the seat's USD price is capped for borrowing only.
contract SeatCapTest is SeatSystem {
    bytes32 constant ETH = "ETH";

    MockSeatNFT nft;
    MockFeed ethFeed;
    MockSeatFeed median;
    MockFeed spot;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockSeatNFT();
        MockAgentAdapter adapter = new MockAgentAdapter();
        ethFeed = new MockFeed(2000e18);
        median = new MockSeatFeed(2e18, 150); // $4,000 a seat
        median.setMaxAge(26 hours);
        spot = new MockFeed(2e18);
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        _addIlk(ETH, address(new MockERC20("WETH", 18)), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        _addSeatIlk(IERC721(address(nft)), IImdAgentAdapter(address(adapter)), median, spot, ethFeed, 40_000e18);
        params.seal();
        nft.mint(alice, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(seatJoin), true);
    }

    function _net(uint256 max) internal pure returns (uint256) {
        return max * 365 days / (365 days + 0.08e18 * 7 days / 1e18) / 1e18 * 1e18;
    }

    function test_cap_onSeatType() public {
        vm.prank(governor);
        params.lowerCap(SEAT, 2_000e18); // $2,000 a seat for borrowing, market $4,000
        Pricer.Quote memory q = pricer.quote(SEAT);
        assertEq(q.borrow, 2_000e18);
        assertGt(q.low, q.borrow);
        vm.startPrank(alice);
        seatJoin.deposit(1);
        // 40% of $4,000 would be $1,600; at the cap it is $800.
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        ledger.open(SEAT, 0, Adjust(1e18, int256(_net(1_600e18)), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(SEAT, 0, Adjust(1e18, int256(_net(800e18)), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        (bool ok,) = ledger.healthy(_pid(SEAT, alice));
        assertTrue(ok);
    }
}
