// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFeed} from "../interfaces/IFeed.sol";

/// @notice The median leaf's second signed number: the distinct seats sold in its window (SwarmSeatMedianFeed).
interface ISeatFigure {
    function latestFigure() external view returns (uint256);
}

/// @notice The seat type's price: two attested legs (the `nft-sale-median` recipe: a 7-day p25
/// median and a 1-day spot, both in wei per seat) priced into USD by ETH/USD, with the reflexive LTV
/// terms folded into BOTH legs:
///
///     value  = min(median, spot) x factor,   factor = liquidity x trend
///     liquidity = min(1, sales7d / 100)       -- fewer sales, lower LTV
///     trend     = min(1, median / median30dAgo) -- a falling 30-day trend tightens 1:1, a rise never loosens
///
/// Folding the factor into the price is the same inequality as scaling `mat` (collateral x price x factor
/// >= debt x mat), and it needs no change to the Pricer or the Ledger. The skew check is unaffected: both
/// legs carry the same factor. The legs without the factor stay readable (`medianUsd`, `rawSpotUsd`): the
/// auction starts at the (fall-capped) median and the Treasury's floor option is guarded by the raw spot.
///
/// HOW THE REFLEXIVE INPUTS REACH THE CHAIN (design choice):
///  - `sales7d` is the median attestation's signed `figure`: the recipe (plane PR #701) signs the distinct
///    seats sold as the figure of every answer, so the price and its depth arrive in ONE attestation and can
///    never come from two different windows. The median leaf keeps it (`latestFigure`). (Beta seats,
///    2026-10-26: this replaced a separate count feed, one fewer question per refresh.)
///  - `median30dAgo` is a 32-slot daily ring kept HERE by permissionless `poke`. The slot for a day holds
///    the raw USD median first poked that day; `median30dAgo` is the newest slot at least 30 days old. With
///    less than 30 days of history the oldest slot stands in (a rising market then reads trend = 1, a
///    falling one tightens: conservative). An empty ring is trend = 1.
///
/// FALL CAP, PER UPDATE (the wash-trade blocker's fix 4): the attested wei median the
/// leg reads may fall at most `MAX_FALL_PER_UPDATE_BPS` (20%) below the previously ACCEPTED median per new
/// attestation. A lower attestation reads `previous x 0.8`, and that becomes the accepted value the next
/// attestation steps from: a real 40% crash lands at 0.8, then 0.64, then 0.6. No time-based wait. Rises
/// pass through uncapped (the trend term already keeps a rise from loosening the LTV). Only the median leg:
/// the spot leg is hardened in the recipe, and the Pricer collapses to the median when the legs diverge.
///
/// "New attestation" = a strictly newer `updatedAt` on the median feed. SwarmFeed refuses an attestation
/// older than its current one but admits one with an EQUAL `issuedAt`; such a replacement is NOT a new
/// update: it is capped against the same base as the attestation it replaced, so re-submitting, re-reading
/// or re-poking never steps the value down further.
///
/// The cap state is recorded lazily by permissionless `poke` (no keeper needed for correctness): every
/// view computes the accepted value from the recorded state and the feed's live reading, so the Pricer
/// never reads a stale cap. The state holds the last RECORDED attestation (`raw`, `at`) and the accepted
/// value before it (`base`); the live reading is one step from it. The only thing a missing poke changes:
/// two attestations landing with no poke between them count as ONE step (the first is no longer readable),
/// so an unpoked fall is capped harder (the leg falls slower), never looser. Anyone who wants a fall
/// recognised (a liquidator, the relayer) pokes after each attestation.
contract SeatFeed is IFeed {
    struct Point {
        uint192 value;
        uint64 day;
    }

    uint256 public constant RING = 32;
    uint256 public constant TREND_DAYS = 30;
    /// @notice Weekly distinct seats sold at which `liquidity` is 1 (a plain count, the median's figure).
    uint256 public constant FULL_LIQUIDITY = 100;
    /// @notice Largest fall of the accepted median per new attestation, in basis points. Constant by design.
    uint256 public constant MAX_FALL_PER_UPDATE_BPS = 2000;

    /// @notice The last recorded median attestation: its raw wei value, its `updatedAt`, and the accepted
    /// value before it (the base it is capped against). 0 = nothing recorded: the next reading is accepted raw.
    struct Cap {
        uint128 base;
        uint128 raw;
        uint64 at;
    }

    IFeed public immutable median; // attested 7-day p25, wei per seat; its figure = distinct seats sold
    IFeed public immutable spot; // attested 1-day spot, wei per seat
    IFeed public immutable ethUsd; // USD per 1e18 wei

    Point[RING] public ring;
    Cap public cap;
    /// @notice The day of the ring's first point, 0 until then. Lets `median30dAgo` go straight to its slot.
    uint64 public firstDay;

    error InvalidFeed();

    event Poked(uint256 day, uint256 medianUsd);
    event MedianRecorded(uint256 raw, uint64 at, uint256 base);

    constructor(IFeed median_, IFeed spot_, IFeed ethUsd_) {
        if (address(median_).code.length == 0 || address(spot_).code.length == 0 || address(ethUsd_).code.length == 0) {
            revert InvalidFeed();
        }
        median = median_;
        spot = spot_;
        ethUsd = ethUsd_;
        // Anchor the cap on the attestation live at deployment, so the first update after it is capped too. An empty
        // median (a fresh leaf, the beta deploy) records nothing: the first attestation relayed is accepted raw, and
        // the deployment relays and checks it; until both legs hold a value the type prices at 0.
        (uint256 m, uint64 t) = median_.latestValue();
        if (m != 0) cap = Cap({base: uint128(m), raw: uint128(m), at: t});
    }

    // ---------------------------------------------------------------- raw legs

    /// @notice USD per seat from the attested 7-day median as it stands, no fall cap, no reflexive terms.
    function rawMedianUsd() public view returns (uint256) {
        (uint256 m,) = median.latestValue();
        (uint256 e,) = ethUsd.latestValue();
        return m * e / 1e18;
    }

    // ---------------------------------------------------------------- fall cap

    /// @notice The accepted wei median: the live attestation, capped at a 20% fall from the accepted value
    /// before it. Always current (computed from the recorded state and the live reading; no poke needed).
    function acceptedMedian() public view returns (uint256) {
        (uint256 m, uint64 t) = median.latestValue();
        if (m == 0) return 0;
        Cap memory c = cap;
        return t > c.at ? _capped(m, _capped(c.raw, c.base)) : _capped(m, c.base);
    }

    /// @notice USD per seat from the accepted (fall-capped) median, no reflexive terms. The auction's opening
    /// price, and the median the trend term and the ring use.
    function medianUsd() public view returns (uint256) {
        (uint256 e,) = ethUsd.latestValue();
        return acceptedMedian() * e / 1e18;
    }

    /// @dev `raw`, but never below `base x (1 - 20%)`. An empty base accepts `raw` as it is.
    function _capped(uint256 raw, uint256 base) private pure returns (uint256) {
        uint256 lowest = base * (10_000 - MAX_FALL_PER_UPDATE_BPS) / 10_000;
        return raw < lowest ? lowest : raw;
    }

    /// @dev Record the live median attestation in the cap state. A strictly newer one steps the base to the
    /// accepted value of the recorded one; an equal-time replacement only replaces `raw` (same base).
    function _record() private {
        (uint256 m, uint64 t) = median.latestValue();
        if (m == 0) return;
        Cap memory c = cap;
        if (t > c.at) {
            c.base = uint128(_capped(c.raw, c.base));
            c.at = t;
        } else if (t < c.at || m == c.raw) {
            return;
        }
        c.raw = uint128(m);
        cap = c;
        emit MedianRecorded(m, t, c.base);
    }

    /// @notice USD per seat from the 1-day spot, no reflexive terms.
    function rawSpotUsd() public view returns (uint256) {
        (uint256 s,) = spot.latestValue();
        (uint256 e,) = ethUsd.latestValue();
        return s * e / 1e18;
    }

    function rawSpotFresh() external view returns (bool) {
        return !spot.isStale() && !ethUsd.isStale();
    }

    // ---------------------------------------------------------------- reflexive terms

    /// @notice min(1, sales7d / 100), sales7d = the distinct seats sold in the median's window.
    function liquidity() public view returns (uint256) {
        uint256 n = ISeatFigure(address(median)).latestFigure();
        return Math.min(1e18, Math.mulDiv(n, 1e18, FULL_LIQUIDITY));
    }

    function median30dAgo() public view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        uint256 first = firstDay;
        if (first != 0) {
            // Nothing is TREND_DAYS old yet, so the first point is the oldest (a slot is reused only after RING days).
            if (today < first + TREND_DAYS) return ring[first % RING].value;
            // A day has one slot and the first value stands: exactly TREND_DAYS ago is the newest a point can be and qualify.
            Point memory exact = ring[(today - TREND_DAYS) % RING];
            if (exact.day == today - TREND_DAYS && exact.value != 0) return exact.value;
        }
        uint256 bestOld; // newest point at least TREND_DAYS old
        uint256 bestOldDay;
        uint256 oldest; // oldest point of any age
        uint256 oldestDay = type(uint256).max;
        for (uint256 i; i < RING; ++i) {
            Point memory pt = ring[i];
            if (pt.value == 0) continue;
            if (pt.day + TREND_DAYS <= today && pt.day >= bestOldDay) {
                bestOld = pt.value;
                bestOldDay = pt.day;
            }
            if (pt.day < oldestDay) {
                oldest = pt.value;
                oldestDay = pt.day;
            }
        }
        return bestOld != 0 ? bestOld : oldest;
    }

    function trend() public view returns (uint256) {
        uint256 past = median30dAgo();
        uint256 now_ = medianUsd();
        if (past == 0 || now_ == 0) return 1e18;
        return Math.min(1e18, Math.mulDiv(now_, 1e18, past));
    }

    /// @notice liquidity x trend, 1e18.
    function factor() public view returns (uint256) {
        return liquidity() * trend() / 1e18;
    }

    /// @notice Record the live median attestation in the fall cap (every call; a no-op for one already
    /// recorded), then today's accepted median in the ring (once per day, the first value stands; fresh
    /// feeds only). Permissionless, never reverts on a feed's state.
    function poke() external {
        _record();
        if (median.isStale() || ethUsd.isStale()) return;
        uint256 v = medianUsd();
        if (v == 0) return;
        uint256 today = block.timestamp / 1 days;
        Point storage pt = ring[today % RING];
        if (pt.day == today && pt.value != 0) return;
        pt.value = uint192(v);
        pt.day = uint64(today);
        if (firstDay == 0) firstDay = uint64(today);
        emit Poked(today, v);
    }

    // ---------------------------------------------------------------- IFeed (the median leg)

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        (, uint64 tm) = median.latestValue();
        (uint256 e, uint64 te) = ethUsd.latestValue();
        uint256 m = acceptedMedian();
        if (m == 0 || e == 0) return (0, 0);
        value = m * e / 1e18 * factor() / 1e18;
        updatedAt = tm < te ? tm : te;
    }

    function isStale() external view returns (bool) {
        return median.isStale() || ethUsd.isStale();
    }

    function maxAge() external view returns (uint256) {
        return Math.min(median.maxAge(), ethUsd.maxAge());
    }
}

/// @notice The seat type's spot leg: the raw 1-day spot in USD times the same reflexive factor as the
/// median leg, so the Pricer's skew check compares the two markets and not the factor.
contract SeatSpotLeg is IFeed {
    SeatFeed public immutable feed;

    constructor(SeatFeed feed_) {
        feed = feed_;
    }

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        (uint256 s, uint64 ts) = feed.spot().latestValue();
        (uint256 e, uint64 te) = feed.ethUsd().latestValue();
        if (s == 0 || e == 0) return (0, 0);
        value = s * e / 1e18 * feed.factor() / 1e18;
        updatedAt = ts < te ? ts : te;
    }

    function isStale() external view returns (bool) {
        return feed.spot().isStale() || feed.ethUsd().isStale() || feed.median().isStale();
    }

    function maxAge() external view returns (uint256) {
        return Math.min(feed.spot().maxAge(), feed.ethUsd().maxAge());
    }
}
