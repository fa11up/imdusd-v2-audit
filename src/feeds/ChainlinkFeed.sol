// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../interfaces/IFeed.sol";

/// @notice A Chainlink aggregator in v2's convention: value per 1e18 raw units of a token with
/// `tokenDecimals`, 1e18-scaled. With `tokenDecimals = 18` and a ratio aggregator (WBTC/BTC, stETH/ETH)
/// it yields the plain 1e18-scaled ratio, for `ProductFeed`.
/// @dev Reads with a raw staticcall and decodes defensively, as v1's SharePriceFeed does: a feed that
/// reverts or answers malformed data reads as zero and stale, which values collateral at nothing and
/// blocks new debt. A revert here would instead take down every action that prices this collateral.
contract ChainlinkFeed is IFeed {
    address public immutable aggregator;
    uint8 public immutable tokenDecimals;
    uint8 public immutable aggregatorDecimals;
    uint256 public immutable maxAge;

    error InvalidFeed();


    constructor(address aggregator_, uint8 tokenDecimals_, uint256 maxAge_) {
        if (aggregator_.code.length == 0 || maxAge_ == 0 || tokenDecimals_ > 36) revert InvalidFeed();
        (bool ok, bytes memory data) = aggregator_.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert InvalidFeed();
        uint256 d = abi.decode(data, (uint256));
        if (d > 36) revert InvalidFeed();
        aggregator = aggregator_;
        tokenDecimals = tokenDecimals_;
        aggregatorDecimals = uint8(d);
        maxAge = maxAge_;
    }

    /// @notice The largest 1e18-scaled value per whole token this feed reads as a price: $1e18 a token. Above it the
    /// answer is garbage, not a market, and reads as zero (unpriced) instead of panicking on the scaling below
    /// (v1's UsdPriceFeed capped at 1e36 for the same reason).
    uint256 public constant MAX_PER_TOKEN = 1e36;

    function latestValue() public view returns (uint256 value, uint64 updatedAt) {
        (bool ok, bytes memory data) = aggregator.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!ok || data.length < 160) return (0, 0);
        (, int256 answer,, uint256 at,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || at == 0 || at > block.timestamp) return (0, 0);
        // Garbage, not a price: above the sanity cap (10^(18+dec) raw units = MAX_PER_TOKEN; the product below
        // would overflow long before), or sitting on the aggregator's own minAnswer/maxAnswer clamp (a market outside
        // the aggregator's accepted range is reported AS the bound, the LUNA failure).
        if (uint256(answer) > 10 ** (18 + uint256(aggregatorDecimals)) || _clamped(answer)) return (0, 0);
        // answer -> 1e18-scaled per whole token
        uint256 perToken = uint256(answer) * 10 ** (36 - aggregatorDecimals) / 1e18;
        // per whole token -> per 1e18 raw units
        value = tokenDecimals <= 18 ? perToken * 10 ** (18 - tokenDecimals) : perToken / 10 ** (tokenDecimals - 18);
        updatedAt = uint64(at);
    }

    /// @dev Whether `answer` sits at the aggregator's minAnswer or maxAnswer. Read live from the proxy's current
    /// aggregator (`aggregator()`), so a phase change carries its own bounds; an aggregator that exposes neither (or no
    /// proxy at all) has no clamp to detect and reads as before. A bound of <= 0 (or the int192 maximum) is "none".
    function _clamped(int256 answer) private view returns (bool) {
        (bool ok, bytes memory d) = aggregator.staticcall(abi.encodeWithSignature("aggregator()"));
        address agg = ok && d.length >= 32 ? abi.decode(d, (address)) : aggregator;
        if (agg == address(0) || agg.code.length == 0) return false;
        (bool okMin, bytes memory dMin) = agg.staticcall(abi.encodeWithSignature("minAnswer()"));
        if (okMin && dMin.length >= 32) {
            int256 mn = abi.decode(dMin, (int256));
            if (mn > 0 && answer <= mn) return true;
        }
        (bool okMax, bytes memory dMax) = agg.staticcall(abi.encodeWithSignature("maxAnswer()"));
        if (okMax && dMax.length >= 32) {
            int256 mx = abi.decode(dMax, (int256));
            if (mx > 0 && answer >= mx) return true;
        }
        return false;
    }

    function isStale() public view virtual returns (bool) {
        (uint256 value, uint64 at) = latestValue();
        return value == 0 || block.timestamp - at > maxAge;
    }
}
