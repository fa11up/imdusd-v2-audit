// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChainlinkFeed} from "./ChainlinkFeed.sol";
import {MarketCalendar} from "./MarketCalendar.sol";

/// @notice A Chainlink Robinhood equity feed on 4663, priced only inside the NYSE regular session and frozen by any issuer
/// action on the token.
/// @dev VALUE: the feed's answer per whole token, as `ChainlinkFeed` (USD per 1e18 raw units). The answer ALREADY INCLUDES the
/// token's ERC-8056 `uiMultiplier` (SGOV's feed = share price x 1.00719 to 0.01%, and it stepped with
/// the multiplier at the 2026-10-01 dividend), so collateral is valued `balance x price`, never `balance x uiMultiplier x
/// price` (that would count every dividend twice).
///
/// STALE (no new debt, no liquidation, no redemption; repayment and debt-free withdrawals never read it) when ANY of:
///  - the answer is unreadable or older than `maxAge`. The feeds push on a 0.5% deviation with a 24h heartbeat, measured on
///    chain at 23 updates in 16 days for SPY: an age bound tighter than the heartbeat (e.g. 15 minutes) would leave
///    quiet tickers unpriced most of every session, so the deviation trigger is what keeps a live feed within 0.5% and
///    `maxAge` only detects a dead one (25h);
///  - the NYSE regular session is closed (`MarketCalendar`): weekends, holidays, nights. The feeds also publish in Robinhood's
///    24/5 overnight session, where SGOV printed +1.9% for 13 minutes on 2026-10-20 (a T-bill fund): those hours never price;
///  - the token is paused (`paused()`, which also reports the registry's global pause, checked again here), the issuer has
///    paused its oracle for a corporate action (`oraclePaused()`, a flag on the TOKEN), or the registry blocklists `holder`
///    (the vault that custodies every unit of the type: a blocked vault can move nothing, so nothing may be priced off it);
///  - a multiplier change is scheduled (`newUIMultiplier() != uiMultiplier()`), or took effect after the feed's last answer
///    (the feed has not yet re-priced the token at its new multiplier: SGOV read 0.2% low for 24h after its October dividend).
/// Any of these reads failing counts as frozen (fail closed).
contract MarketHoursFeed is ChainlinkFeed {
    address public immutable stock;
    address public immutable registry;
    address public immutable holder;
    MarketCalendar public immutable calendar;

    constructor(address aggregator_, address stock_, address holder_, MarketCalendar calendar_, uint256 maxAge_)
        ChainlinkFeed(aggregator_, 18, maxAge_)
    {
        (bool ok, uint256 reg) = _word(stock_, abi.encodeWithSignature("ACCESS_CONTROLLED_REGISTRY()"));
        if (!ok || address(uint160(reg)).code.length == 0 || holder_ == address(0) || address(calendar_).code.length == 0) {
            revert InvalidFeed();
        }
        stock = stock_;
        registry = address(uint160(reg));
        holder = holder_;
        calendar = calendar_;
    }

    function isStale() public view override returns (bool) {
        return super.isStale() || !calendar.isOpen(block.timestamp) || frozen();
    }

    /// @notice True while an issuer action holds the type: pause, oracle pause, blocked custody, or a multiplier change the
    /// feed has not caught up with.
    function frozen() public view returns (bool) {
        if (
            _flag(stock, abi.encodeWithSignature("paused()")) || _flag(stock, abi.encodeWithSignature("oraclePaused()"))
                || _flag(registry, abi.encodeWithSignature("paused()"))
                || _flag(registry, abi.encodeWithSignature("isBlocked(address)", holder))
        ) return true;
        (bool ok1, uint256 current) = _word(stock, abi.encodeWithSignature("uiMultiplier()"));
        (bool ok2, uint256 next) = _word(stock, abi.encodeWithSignature("newUIMultiplier()"));
        (bool ok3, uint256 effectiveAt) = _word(stock, abi.encodeWithSignature("effectiveAt()"));
        if (!ok1 || !ok2 || !ok3 || current != next) return true;
        (, uint64 updatedAt) = latestValue();
        return effectiveAt != 0 && updatedAt <= effectiveAt;
    }

    /// @dev True unless the call succeeds and returns false.
    function _flag(address target, bytes memory data) private view returns (bool) {
        (bool ok, uint256 v) = _word(target, data);
        return !ok || v != 0;
    }

    function _word(address target, bytes memory data) private view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
