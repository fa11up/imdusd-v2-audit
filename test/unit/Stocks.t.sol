// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Stock tokens on mocks: the NYSE calendar, the market-hours feed (session, freshness, issuer freezes), valuation, the
/// group cap, the USDG auction, admin burn -> bad debt. Fork rehearsal on the real tokens: test/fork/Robinhood.t.sol.
contract StocksTest is StockSystem {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address taker = makeAddr("taker");

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
    }

    // ------------------------------------------------------------ calendar

    function test_sessionHoursFollowDaylightSavingTime() public view {
        // EDT: 13:30-20:00 UTC
        assertFalse(cal.isOpen(MON_OPEN - 1), "09:29:59 EDT");
        assertTrue(cal.isOpen(MON_OPEN), "09:30 EDT");
        assertTrue(cal.isOpen(FRI_CLOSE - 1), "15:59:59 EDT");
        assertFalse(cal.isOpen(FRI_CLOSE), "16:00 EDT");
        // EST: 14:30-21:00 UTC (US clocks went back on Sun 2026-11-01)
        assertFalse(cal.isOpen(EST_MON_OPEN - 1), "09:29:59 EST");
        assertTrue(cal.isOpen(EST_MON_OPEN), "09:30 EST");
        assertTrue(cal.isOpen(EST_MON_OPEN + 6.5 hours - 1), "15:59:59 EST");
        assertFalse(cal.isOpen(EST_MON_OPEN + 6.5 hours), "16:00 EST");
        assertFalse(cal.isOpen(EST_MON_OPEN - 1 hours), "13:30 UTC is 08:30 in EST");
        // weekend, holiday, early close
        assertFalse(cal.isOpen(SAT_1500), "Saturday");
        assertFalse(cal.isOpen(SAT_1500 + 1 days), "Sunday");
        assertFalse(cal.isOpen(THANKSGIVING_1500), "Thanksgiving");
        assertTrue(cal.isOpen(EARLY_CLOSE - 1), "12:59:59 the day after");
        assertFalse(cal.isOpen(EARLY_CLOSE), "13:00 early close");
    }

    function test_dstSwitchDates() public view {
        // 2027: second Sunday of March = 14th, first Sunday of November = 7th
        assertFalse(cal.isDst(cal.daysFromCivil(2027, 3, 12)), "Fri 12 Mar 2027: EST");
        assertTrue(cal.isDst(cal.daysFromCivil(2027, 3, 15)), "Mon 15 Mar 2027: EDT");
        assertTrue(cal.isDst(cal.daysFromCivil(2027, 11, 5)), "Fri 5 Nov 2027: EDT");
        assertFalse(cal.isDst(cal.daysFromCivil(2027, 11, 8)), "Mon 8 Nov 2027: EST");
        assertEq(cal.daysFromCivil(2026, 11, 26), THANKSGIVING);
    }

    function testFuzz_civilRoundTrip(uint32 day) public view {
        day = uint32(bound(day, 0, 200_000));
        (uint256 y, uint256 m, uint256 d) = cal.civil(day);
        assertEq(cal.daysFromCivil(y, m, d), day);
        assertTrue(m >= 1 && m <= 12 && d >= 1 && d <= 31);
    }

    function test_calendarChangesOnlyFutureWeekdaysThroughTheTimelock() public {
        uint32[] memory list = new uint32[](1);
        list[0] = uint32(vm.getBlockTimestamp() / 1 days); // today
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.BadDay.selector, list[0]));
        cal.propose(abi.encode(uint8(1), uint8(1), list));
        list[0] = uint32(vm.getBlockTimestamp() / 1 days) + 3; // Thursday 10-22
        vm.expectRevert(Governed.NotGovernor.selector);
        cal.propose(abi.encode(uint8(1), uint8(1), list));
        vm.prank(governor);
        cal.propose(abi.encode(uint8(1), uint8(1), list));
        vm.expectRevert();
        cal.applyPending();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        cal.applyPending();
        assertFalse(cal.isOpen(MON_1400 + 3 days), "a new closure");
        // a weekend day is refused at application; a day that has passed by then is refused too
        list[0] = uint32(SAT_1500 / 1 days) + 7;
        vm.prank(governor);
        cal.propose(abi.encode(uint8(1), uint8(1), list));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.BadDay.selector, list[0]));
        cal.applyPending();
    }

    // ------------------------------------------------------------ market-hours feed

    function test_fridayCloseStopsPricingMondayOpenResumes() public {
        assertFalse(mhf.isStale(), "Monday 10:00");
        vm.warp(FRI_CLOSE - 1);
        _price(101e8);
        assertFalse(mhf.isStale(), "Friday 15:59:59");
        vm.warp(FRI_CLOSE);
        assertTrue(mhf.isStale(), "Friday 16:00");
        vm.warp(SAT_1500);
        assertTrue(mhf.isStale(), "Saturday");
        vm.warp(NEXT_MON_OPEN - 13.5 hours); // Sunday 20:00 New York: the feeds restart with the overnight session
        _price(97e8);
        assertTrue(mhf.isStale(), "Sunday night prints never price");
        vm.warp(NEXT_MON_OPEN);
        assertFalse(mhf.isStale(), "Monday 09:30, feed 13.5h old");
        (uint256 v,) = mhf.latestValue();
        assertEq(v, 97e18);
    }

    function test_deadFeedInsideTheSession() public {
        vm.warp(MON_1400 + 25 hours); // Tuesday 11:00, last answer Monday 10:00
        assertFalse(mhf.isStale(), "25h: the heartbeat's own bound");
        vm.warp(MON_1400 + 25 hours + 1);
        assertTrue(mhf.isStale(), "older than the 24h heartbeat allows");
        _price(100e8);
        assertFalse(mhf.isStale());
    }

    function test_holidayAndEarlyCloseAreClosed() public {
        vm.warp(THANKSGIVING_1500);
        _price(100e8);
        assertTrue(mhf.isStale(), "Thanksgiving");
        vm.warp(EARLY_CLOSE - 1);
        _price(100e8);
        assertFalse(mhf.isStale(), "12:59:59 on the early-close day");
        vm.warp(EARLY_CLOSE);
        assertTrue(mhf.isStale(), "13:00 early close");
    }

    function test_issuerActionsFreezeTheType() public {
        assertFalse(mhf.frozen());
        stock.setPaused(true);
        assertTrue(mhf.isStale() && mhf.frozen(), "token pause");
        stock.setPaused(false);
        reg.setPaused(true);
        assertTrue(mhf.frozen(), "global pause");
        reg.setPaused(false);
        stock.setOraclePaused(true);
        assertTrue(mhf.frozen(), "oracle paused for a corporate action");
        stock.setOraclePaused(false);
        reg.setBlocked(address(vault), true);
        assertTrue(mhf.frozen(), "the custody vault is blocklisted");
        reg.setBlocked(address(vault), false);
        reg.setBlocked(address(sjoin), true);
        assertFalse(mhf.frozen(), "only the vault holds stock at rest");
        reg.setBlocked(address(sjoin), false);
        assertFalse(mhf.isStale());
    }

    function test_multiplierChangeFreezesUntilTheFeedRepricesIt() public {
        stock.scheduleMultiplier(2e18, vm.getBlockTimestamp() + 1 days); // a 2:1 split tomorrow
        assertTrue(mhf.frozen(), "scheduled: pending");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertTrue(mhf.frozen(), "in effect, the feed has not published since");
        _price(100e8);
        assertTrue(mhf.frozen(), "an answer in the same second may predate the change");
        vm.warp(vm.getBlockTimestamp() + 1);
        _price(100e8);
        assertFalse(mhf.frozen(), "re-priced at the new multiplier");
    }

    function test_unreadableIssuerStateFailsClosed() public {
        vm.mockCallRevert(address(stock), abi.encodeWithSignature("oraclePaused()"), "");
        assertTrue(mhf.frozen());
        vm.clearMockedCalls();
        vm.mockCall(address(reg), abi.encodeWithSignature("isBlocked(address)", address(vault)), "");
        assertTrue(mhf.frozen(), "short return data");
    }

    function test_valuationIsBalanceTimesPriceNotTimesMultiplier() public {
        stock.scheduleMultiplier(1.05e18, vm.getBlockTimestamp()); // 5% of dividends folded into the multiplier already
        vm.warp(vm.getBlockTimestamp() + 1);
        _price(105e8); // the feed prices the TOKEN: share $100 x 1.05
        _open(alice, 10e18, 0);
        (uint256 v,) = price.latestValue();
        assertEq(v, 105e12, "per token, the feed's answer (read per 1e18 shares = 1e-6 token: StockVault offset, F5)");
        // 10 tokens x $105 = $1,050 of collateral: at mat 150% the most debt is $700, not $735 (x 1.05 again)
        // (the borrow pays its upfront fee, F1: 7 days at 5%, so the most that can be drawn is $700 / 1.00096)
        uint256 most = uint256(700e18) * 365 days / (365 days + 0.05e18 * 7 days / 1e18) / 1e18 * 1e18;
        vm.prank(alice);
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        ledger.open(STK, 0, Adjust(0, int256(most + 1e18), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.prank(alice);
        ledger.open(STK, 0, Adjust(0, int256(most), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        assertLe(ledger.debtOf(_pid(STK, alice)), 700e18);
    }
}
