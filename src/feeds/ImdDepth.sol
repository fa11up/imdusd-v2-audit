// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../interfaces/IFeed.sol";

interface IDepthReading {
    function depth() external view returns (uint256);
}

/// @dev What identifies a sampler's pool (DepthSampler's immutables): one sampler per pool.
interface IDepthPool {
    function manager() external view returns (address);
    function poolId() external view returns (bytes32);
}

/// @title ImdDepth
/// @notice IMD's market depth for the k-rule (Parameters D1: line x (1 + chop) + redeemCap <= k x depth), measured, not
/// posted. The depth rule defines it as the USD all IMD exit pools pay a seller of IMD before IMD falls 15%, taken as
/// a 7-DAY LOW. Here:
///   sampled = Σ DepthSampler.depth() over the listed exit-pool samplers (each already the 4th-lowest of its last ~24
///             hourly buckets, rises capped at 2x per day, 0 when it has too few buckets);
///   depth   = min(sampled now, the recorded daily figures of the previous 6 UTC days, and today's figure);
///   and, once a swarm leg is configured, min(depth, the attested depth in USD).
/// A DAY'S FIGURE IS ROBUST: each poke records `sampled()` as its UTC hour's reading (an hour keeps its
/// lowest), and the day's figure is the `ROBUST_RANK`-th lowest hour of that day (the highest hour when fewer were poked).
/// The plain minimum let any single poke at a deflated moment hold the line down for a week; a low must now be seen in
/// `ROBUST_RANK` separate hours of a day. One sampler per pool: a second sampler on a listed pool is refused.
/// A previous day with no recorded low counts as 0: the keeper `poke`s hourly, and a week of silence must not read as
/// depth. So a fresh deployment reads 0 for its first 6 days (deploy it at least 8 days before a depth-gated line opens).
///
/// FAIL CLOSED AND NEVER REVERTS. A sampler or leg that reverts or is stale contributes 0 (the leg: when configured, its
/// staleness makes depth 0). Readers (Parameters.risk for the depth-gated type, read only where a line is checked:
/// liquidation reads storedRisk) therefore never revert through this contract: a broken input only lowers the line, which only stops
/// new debt. Listing and removal are Parameters' (timelocked listing, instant removal); no owner, no other knob.
contract ImdDepth {
    uint256 public constant MAX_SAMPLERS = 6;
    uint256 public constant DAYS = 7;

    address public immutable params;

    address[] internal _samplers;
    /// @notice The swarm leg (zero: none): a SwarmImdDepthFeed (wei of ETH) and the ETH/USD feed that values it.
    IFeed public leg;
    IFeed public legPrice;

    /// @notice A day's figure is this-th lowest of its hourly readings.
    uint256 public constant ROBUST_RANK = 4;

    /// @dev The day's ROBUST_RANK lowest hourly readings, ascending (`n` filled), each tagged with its hour of the day.
    struct Low {
        uint32 day; // block.timestamp / 1 days
        uint8 n;
        uint8[4] hours_;
        uint112[4] usd;
    }

    Low[7] internal _lows;

    error Unauthorized();
    error BadSampler();
    error TooManySamplers();

    event SamplerAdded(address sampler);
    event SamplerRemoved(address sampler);
    event LegSet(address leg, address price);
    event Poked(uint256 day, uint256 low);

    constructor(address params_) {
        if (params_ == address(0)) revert Unauthorized();
        params = params_;
    }

    modifier onlyParams() {
        if (msg.sender != params) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------- Parameters only

    function addSampler(address sampler) external onlyParams {
        if (sampler.code.length == 0 || _index(sampler) != type(uint256).max) revert BadSampler();
        if (_samplers.length >= MAX_SAMPLERS) revert TooManySamplers();
        (address m, bytes32 id) = (IDepthPool(sampler).manager(), IDepthPool(sampler).poolId());
        for (uint256 i; i < _samplers.length; ++i) {
            if (IDepthPool(_samplers[i]).poolId() == id && IDepthPool(_samplers[i]).manager() == m) revert BadSampler();
        }
        _samplers.push(sampler);
        emit SamplerAdded(sampler);
    }

    function removeSampler(address sampler) external onlyParams {
        uint256 i = _index(sampler);
        if (i == type(uint256).max) revert BadSampler();
        _samplers[i] = _samplers[_samplers.length - 1];
        _samplers.pop();
        emit SamplerRemoved(sampler);
    }

    /// @notice Set (or, with zeros, clear) the swarm leg.
    function setLeg(address leg_, address price_) external onlyParams {
        if ((leg_ == address(0)) != (price_ == address(0))) revert BadSampler();
        if (leg_ != address(0) && (leg_.code.length == 0 || price_.code.length == 0)) revert BadSampler();
        (leg, legPrice) = (IFeed(leg_), IFeed(price_));
        emit LegSet(leg_, price_);
    }

    // ---------------------------------------------------------------- anyone

    /// @notice Fold the sampled depth now into this hour's reading (an hour keeps its lowest) and return today's figure.
    /// The keeper calls this hourly, after sampling the pools.
    function poke() external returns (uint256 low) {
        uint32 day = uint32(block.timestamp / 1 days);
        uint8 hour = uint8((block.timestamp % 1 days) / 1 hours);
        Low storage l = _lows[day % DAYS];
        if (l.day != day) {
            l.day = day;
            l.n = 0;
        }
        uint256 v = sampled();
        if (v > type(uint112).max) v = type(uint112).max;
        uint256 n = l.n;
        uint256 at = n; // where `v` enters (n = append)
        for (uint256 k; k < n; ++k) {
            if (l.hours_[k] == hour) {
                if (v >= l.usd[k]) return _figure(l); // the hour already holds a lower reading
                at = k; // replace this hour's entry
                break;
            }
        }
        if (at == n) {
            if (n == ROBUST_RANK) {
                if (v >= l.usd[n - 1]) return _figure(l); // not among the day's lowest hours
                at = n - 1; // evict the highest
            } else {
                l.n = uint8(++n);
            }
        }
        // Move entry `at` down to keep the list ascending (only lower values ever enter).
        while (at != 0 && l.usd[at - 1] > v) {
            (l.usd[at], l.hours_[at]) = (l.usd[at - 1], l.hours_[at - 1]);
            --at;
        }
        (l.usd[at], l.hours_[at]) = (uint112(v), hour);
        low = _figure(l);
        emit Poked(day, low);
    }

    // ---------------------------------------------------------------- reads

    /// @notice The depth the k-rule uses (USD, 1e18). Never reverts.
    function depth() external view returns (uint256 d) {
        d = sampled();
        uint32 today = uint32(block.timestamp / 1 days);
        for (uint256 back; back < DAYS; ++back) {
            Low storage l = _lows[(today - back) % DAYS]; // storage: reads only day/n and one value slot
            if (l.day != today - back || l.n == 0) {
                if (back != 0) return 0; // a past day with no low: fail closed
                continue; // today not poked yet: the live reading stands for it
            }
            uint256 f = _figure(l);
            if (f < d) d = f;
        }
        if (address(leg) != address(0)) {
            uint256 a = attested();
            if (a < d) d = a;
        }
    }

    /// @notice Σ sampler depth now (USD, 1e18); a reverting sampler contributes 0.
    function sampled() public view returns (uint256 sum) {
        uint256 n = _samplers.length;
        for (uint256 i; i < n; ++i) {
            try IDepthReading(_samplers[i]).depth() returns (uint256 v) {
                sum += v;
            } catch {}
        }
    }

    /// @notice The swarm leg in USD (1e18): 0 when unset, stale, unreadable, or its price is.
    function attested() public view returns (uint256) {
        if (address(leg) == address(0)) return 0;
        (bool okA, uint256 wei_) = _fresh(leg);
        (bool okP, uint256 usdPerEth) = _fresh(legPrice);
        if (!okA || !okP) return 0;
        return wei_ * usdPerEth / 1e18;
    }

    function samplers() external view returns (address[] memory) {
        return _samplers;
    }

    /// @notice The figure recorded for the day `back` days ago (the slot's own day is returned: compare it).
    function lowOf(uint256 back) external view returns (uint32 day, uint256 usd) {
        Low storage l = _lows[(block.timestamp / 1 days - back) % DAYS];
        return (l.day, l.n == 0 ? 0 : _figure(l));
    }

    /// @dev The day's figure: its ROBUST_RANK-th lowest hourly reading, or its highest when fewer hours were poked.
    function _figure(Low storage l) private view returns (uint256) {
        return l.usd[l.n - 1];
    }

    function _fresh(IFeed f) private view returns (bool ok, uint256 v) {
        try f.isStale() returns (bool stale) {
            if (stale) return (false, 0);
        } catch {
            return (false, 0);
        }
        try f.latestValue() returns (uint256 value, uint64) {
            return (true, value);
        } catch {
            return (false, 0);
        }
    }

    function _index(address sampler) private view returns (uint256) {
        for (uint256 i; i < _samplers.length; ++i) {
            if (_samplers[i] == sampler) return i;
        }
        return type(uint256).max;
    }
}
