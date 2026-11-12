// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParametersBase} from "./ParametersBase.sol";
import {Parameters} from "./Parameters.sol";
import {IFeed} from "./interfaces/IFeed.sol";

/// @notice Turns a type's feed pair, NHI and depeg breaker into one quote. Stateless.
/// @dev Which price each action uses, and why:
///  - `low  = min(median, spot)`: borrowing, withdrawing and liquidation health. A borrower is measured
///    at the less favourable price.
///  - `high = max(median, spot)`: redemption payout. A redeemer receives collateral at the MORE
///    favourable-to-borrower price, so a spot dip cannot be used to take extra collateral.
///  - `payout = max(high, live)`: redemption payout where the type has a `liveSpot`. The live pool
///    price is read in this call, so a rally between attested updates is not paid to the redeemer. Pushing
///    the pool only raises the payout price, which only shrinks what a redeemer receives. An unreadable live
///    leg on such a type sets `payout = 0`: redemption against it waits (fail closed).
///  - When the legs diverge past `skew`, `low` and `high` collapse to the median: the spot is the manipulable leg.
///    Borrowing stops (`borrowable = false`); liquidation continues on the median. The redemption `payout` on a
///    type WITHOUT a live leg keeps `max(median, spot)` while the spot is fresh: both legs are
///    oracles there (cbBTC/USD vs BTC/USD), and a stalled median in a rally must not hand the redeemer collateral
///    5%+ below market. A higher payout only shrinks what a redeemer receives, so pushing it cannot pay.
///  - A stale median, or a stale NHI on an NHI-linked type, stops everything except repayment and
///    deposits (`priced = false`). Refusing to act is the only safe answer to not knowing a price (v1).
///  - A depegged stablecoin (pegAggregator below pegFloor) stops borrowing only; it is valued at the
///    reading, never at $1, and stays liquidatable.
///  - `borrow = min(low, cap)`: the price new debt, withdrawals and a charged rate change are measured
///    at. `Parameters.cap` is a governed ceiling (0 = none). Only `borrow` is capped: liquidation health and liquidation
///    prices use the uncapped `low`, and redemption the uncapped `payout`, so a ceiling below market can only refuse new
///    borrowing; it can never make a position that is healthy at market liquidatable, nor shelter one that is not.
contract Pricer {
    struct Quote {
        uint256 low;
        uint256 high;
        uint256 payout; // redemption price: max(high, live) where the type has a live leg, else high; 0 = do not redeem
        uint256 mat; // 1e18
        uint256 lull; // seconds of grace between mark and bite
        bool priced; // median (and NHI) fresh: liquidation, redemption, harvest may use it
        bool borrowable; // priced, legs agree, not depegged: new debt and withdrawals may use it
        uint256 borrow; // min(low, Parameters.cap): the price new debt and withdrawals are measured at
        /// priced, the spot leg fresh and within `skew` of the median, and (a type with a live leg) the live pool fresh and
        /// not below `low` by more than `skew`. Two readers: the standing bid (failing it sends a liquidation to the
        /// caller path, so pushing the pool away can only make the sleeve stand aside), and a charged rate change, which needs
        /// both `borrowable` and `agree`. `borrowable` and `low` do not read the live leg.
        bool agree;
    }

    Parameters public immutable params;

    constructor(Parameters params_) {
        params = params_;
    }

    function quote(bytes32 ilk) external view returns (Quote memory q) {
        ParametersBase.Config memory c = params.config(ilk);
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        if (c.token == address(0)) return q;

        (uint256 m,) = c.median.latestValue();
        bool medianOk = m != 0 && !c.median.isStale();

        q.mat = r.mat;
        if (address(c.nhi) != address(0)) {
            (uint256 nhi,) = c.nhi.latestValue();
            if (c.nhi.isStale() || nhi == 0) medianOk = false;
            q.mat = _mat(nhi);
            q.lull = Math.min(_lull(nhi), params.maxLull()); // the beta caps it at 0 (Parameters.maxLull)
        }
        if (!medianOk) return q;

        // One feed in both slots: the median read above is the spot read, and `medianOk` already holds for it.
        bool same = address(c.spot) == address(c.median);
        uint256 s = m;
        if (!same) (s,) = c.spot.latestValue();
        bool spotOk = same || (s != 0 && !c.spot.isStale());
        bool agree = spotOk && Math.mulDiv(m > s ? m - s : s - m, 1e18, m) <= r.skew;
        q.low = agree ? Math.min(m, s) : m;
        q.high = agree ? Math.max(m, s) : m;
        q.payout = q.high;
        q.agree = agree;
        q.priced = true;
        q.borrowable = agree && !_depegged(c.pegAggregator, r.pegFloor);
        uint256 ceiling = params.cap(ilk);
        q.borrow = ceiling != 0 && ceiling < q.low ? ceiling : q.low;
        if (address(c.liveSpot) != address(0)) {
            _applyLive(q, c.liveSpot, r.skew);
        } else if (spotOk && s > m) {
            q.payout = s; // L3: no live leg, so the fresh higher oracle leg sets the payout even past `skew`
        }
    }

    function _applyLive(Quote memory q, IFeed f, uint256 skew) private view {
        (uint256 live,) = f.latestValue();
        // Variant: a fresh pair can agree with itself far above the market; the sleeve is not forced to overpay there.
        // One-sided: a market above the pair means it buys under the market, which is no overpay.
        if (live == 0 || f.isStale()) {
            q.payout = 0;
            q.agree = false;
        } else {
            q.payout = Math.max(q.high, live);
            if (live < q.low && Math.mulDiv(q.low - live, 1e18, q.low) > skew) q.agree = false;
        }
    }

    /// @dev True when the stablecoin's Chainlink answer is below the floor, or unreadable.
    function _depegged(address aggregator, uint256 floor) private view returns (bool) {
        if (aggregator == address(0) || floor == 0) return false;
        (bool ok, bytes memory data) = aggregator.staticcall(abi.encodeWithSignature("latestRoundData()"));
        (bool okd, bytes memory dd) = aggregator.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || !okd || data.length < 160 || dd.length < 32) return true;
        (, int256 answer,,,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        uint256 dec = abi.decode(dd, (uint256));
        if (answer <= 0 || dec > 36) return true;
        return uint256(answer) * 10 ** (36 - dec) / 1e18 < floor;
    }

    /// @dev v1's `_mat`, in 1e18: 170% at NHI >= 0.85, 200% at <= 0.60, linear between (rounded up).
    function _mat(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 1.7e18;
        if (nhi <= 0.6e18) return 2e18;
        return 1.7e18 + Math.mulDiv(0.85e18 - nhi, 0.3e18, 0.25e18, Math.Rounding.Ceil);
    }

    /// @dev v1's `_lull`: 6h of grace at NHI >= 0.85 down to none at <= 0.60.
    function _lull(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 6 hours;
        if (nhi <= 0.6e18) return 0;
        return (nhi - 0.6e18) * 6 hours / 0.25e18;
    }
}
