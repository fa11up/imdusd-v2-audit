// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../interfaces/IFeed.sol";

/// @notice `a * b / 1e18`: chains a price with a ratio or a cross rate.
/// @dev Uses: WBTC = BTC/USD (per 1e18 raw at 8 decimals) x WBTC/BTC ratio; IMD in USD = v1's
/// IMD/ETH swarm feed (wei per 1e18 IMD raw) x ETH/USD (USD per 1e18 wei). The result is as old as the
/// older leg and stale if either is.
contract ProductFeed is IFeed {
    IFeed public immutable a;
    IFeed public immutable b;

    error InvalidFeed();

    constructor(IFeed a_, IFeed b_) {
        if (address(a_).code.length == 0 || address(b_).code.length == 0) revert InvalidFeed();
        a = a_;
        b = b_;
    }

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        (uint256 va, uint64 ta) = a.latestValue();
        (uint256 vb, uint64 tb) = b.latestValue();
        if (va == 0 || vb == 0) return (0, 0);
        return (va * vb / 1e18, ta < tb ? ta : tb);
    }

    function isStale() external view returns (bool) {
        return a.isStale() || b.isStale();
    }

    function maxAge() external view returns (uint256) {
        uint256 ma = a.maxAge();
        uint256 mb = b.maxAge();
        return ma < mb ? ma : mb;
    }
}
