// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IFeed} from "../interfaces/IFeed.sol";

/// @notice The current price of a Uniswap v4 pool, read in the same call: quote raw units per 1e18 raw
/// units of `base`, 1e18-scaled (for IMD/ETH: wei of ETH per 1e18 raw IMD, the unit of v1's swarm feeds).
/// @dev A type's live leg. It is the most manipulable price there is, so it never measures a
/// borrower's health. The Pricer uses it in three ways (Pricer._applyLive): it raises the payout price
/// (`payout = max(high, live)`), so pushing the pool can only shrink a redeemer's collateral, never grow it; a leg
/// reading 0 or stale sets the payout to 0 and clears `agree`; a pool more than `skew` below `low` clears `agree`.
/// `agree` gates the sleeve's standing bid (Liquidator.bite) and a charged rate change (LedgerSettlement.setRate), so
/// a push below the pair can stop both. What the leg buys is that a rally between attested updates no longer pays the
/// redeemer the gap (the rally-stripping finding). The beta's DepthSampler references also read it
/// (DeployConfig `_depthSamplers`): there a push-sample-push-back in one transaction lowers the measured depth, and
/// with it the sIMD line, for the pool fee both ways (DepthSampler header).
/// Never stale: it is the current block. Chained into USD with `ProductFeed` (x Chainlink ETH/USD) and into
/// a share price with `RateFeed`, exactly like the attested legs.
contract LivePoolPrice is IFeed {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PoolId public immutable poolId;
    /// @notice True when the priced token is the pool's currency0 (then price = sqrtP^2 / 2^192).
    bool public immutable baseIsToken0;

    error InvalidPool();

    constructor(IPoolManager manager_, bytes32 poolId_, bool baseIsToken0_) {
        if (address(manager_).code.length == 0) revert InvalidPool();
        manager = manager_;
        poolId = PoolId.wrap(poolId_);
        baseIsToken0 = baseIsToken0_;
        if (_value() == 0) revert InvalidPool();
    }

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        value = _value();
        return (value, value == 0 ? 0 : uint64(block.timestamp));
    }

    /// @notice Only an uninitialised pool (or a price too extreme to express) reads stale.
    function isStale() external view returns (bool) {
        return _value() == 0;
    }

    function maxAge() external pure returns (uint256) {
        return type(uint64).max;
    }

    /// @dev q = sqrtP^2 / 2^64 never overflows (sqrtP < 2^160); token0 base: q * 1e18 / 2^128,
    /// token1 base: 1e18 * 2^128 / q. Returns 0 where the result does not fit or rounds to nothing.
    function _value() private view returns (uint256) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        if (sqrtP == 0) return 0;
        uint256 q = Math.mulDiv(sqrtP, sqrtP, 1 << 64);
        if (q == 0) return 0;
        if (baseIsToken0) return Math.mulDiv(q, 1e18, 1 << 128);
        // q >= 1, so the result is at most 1e18 * 2^128 < 2^188: no overflow.
        return Math.mulDiv(1e18, 1 << 128, q);
    }
}
