// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Governed} from "../Governed.sol";

/// @notice The NYSE regular session: 09:30-16:00 America/New_York on weekdays, 13:00 on early-close days, closed
/// on exchange holidays. Read by every `MarketHoursFeed` on the chain.
/// @dev What is computed and what is data:
///  - COMPUTED: the weekday and US daylight saving time (second Sunday of March to first Sunday of November, the rule since
///    2007), so the session's UTC hours need no upkeep: 13:30-20:00 UTC in EDT, 14:30-21:00 UTC in EST.
///  - DATA: exchange holidays and early closes, which no rule predicts (Good Friday, national days of mourning). Seeded at
///    construction from NYSE's published calendar; extended or corrected only through the 48h timelock, and only for days
///    that are still in the future when the change applies, so no session that has begun (or has been priced against) is
///    ever reclassified. A wrong entry can only freeze stock types for a day (closed) or leave them to the feed's own
///    freshness rule (open), never move a price.
///  - A calendar that runs out (no entries after the last seeded year) treats every weekday as open: the Chainlink feeds'
///    own heartbeat and the per-feed freshness bound remain. The Safe extends it each year (NYSE publishes ~3 years ahead).
contract MarketCalendar is Governed {
    uint8 public constant OPEN = 0;
    uint8 public constant CLOSED = 1;
    uint8 public constant EARLY_CLOSE = 2; // 13:00 New York
    uint8 public constant SET_DAYS = 1;
    uint256 public constant MAX_DAYS = 64;

    uint256 internal constant OPEN_MINUTE = 9 * 60 + 30;
    uint256 internal constant CLOSE_MINUTE = 16 * 60;
    uint256 internal constant EARLY_MINUTE = 13 * 60;

    /// @notice Status of a day, by its UTC day number (`timestamp / 1 days`; the session never crosses UTC midnight).
    mapping(uint256 day => uint8) public dayStatus;

    error BadDay(uint256 day);
    error BadStatus(uint8 status);

    event DaySet(uint256 indexed day, uint8 status);

    constructor(address governor_, uint32[] memory closed, uint32[] memory early) Governed(governor_) {
        for (uint256 i; i < closed.length; ++i) _set(closed[i], CLOSED);
        for (uint256 i; i < early.length; ++i) _set(early[i], EARLY_CLOSE);
    }

    /// @notice True inside the regular session at `ts`.
    function isOpen(uint256 ts) public view returns (bool) {
        uint256 day = ts / 1 days;
        uint256 wd = (day + 4) % 7; // 0 = Sunday (1970-01-01 was a Thursday)
        if (wd == 0 || wd == 6) return false;
        uint8 status = dayStatus[day];
        if (status == CLOSED) return false;
        uint256 offset = isDst(day) ? 4 * 60 : 5 * 60; // New York is UTC-4 (EDT) or UTC-5 (EST)
        uint256 minute = (ts % 1 days) / 60;
        uint256 close = status == EARLY_CLOSE ? EARLY_MINUTE : CLOSE_MINUTE;
        return minute >= OPEN_MINUTE + offset && minute < close + offset;
    }

    function isOpenNow() external view returns (bool) {
        return isOpen(block.timestamp);
    }

    /// @notice US daylight saving time on this (week)day: from the second Sunday of March to the first Sunday of November.
    /// @dev Exact for every weekday (the switches happen at 02:00 local on a Sunday, when no session runs).
    function isDst(uint256 day) public pure returns (bool) {
        (uint256 y,,) = civil(day);
        uint256 mar1 = daysFromCivil(y, 3, 1);
        uint256 nov1 = daysFromCivil(y, 11, 1);
        uint256 start = mar1 + (7 - (mar1 + 4) % 7) % 7 + 7; // second Sunday of March
        uint256 end = nov1 + (7 - (nov1 + 4) % 7) % 7; // first Sunday of November
        return day >= start && day < end;
    }

    /// @dev Howard Hinnant's days_from_civil / civil_from_days (proleptic Gregorian), for days since 1970-01-01, y >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    function civil(uint256 day) public pure returns (uint256 y, uint256 m, uint256 d) {
        uint256 z = day + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    }

    // ---------------------------------------------------------------- governance

    /// @dev payload = (SET_DAYS, uint8 status, uint32[] days): every day strictly after today, a weekday, at most MAX_DAYS.
    function _validate(bytes memory payload) internal view override {
        (uint8 kind, uint8 status, uint32[] memory list) = abi.decode(payload, (uint8, uint8, uint32[]));
        if (kind != SET_DAYS || status > EARLY_CLOSE) revert BadStatus(status);
        if (list.length == 0 || list.length > MAX_DAYS) revert BadDay(0);
        uint256 today = block.timestamp / 1 days;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] <= today) revert BadDay(list[i]);
        }
    }

    function _apply(bytes memory payload) internal override {
        (, uint8 status, uint32[] memory list) = abi.decode(payload, (uint8, uint8, uint32[]));
        for (uint256 i; i < list.length; ++i) _set(list[i], status);
    }

    function _set(uint256 day, uint8 status) private {
        uint256 wd = (day + 4) % 7;
        if (wd == 0 || wd == 6) revert BadDay(day);
        dayStatus[day] = status;
        emit DaySet(day, status);
    }
}
