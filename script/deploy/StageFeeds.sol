// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {LivePoolPrice} from "../../src/feeds/LivePoolPrice.sol";
import {
    SwarmPriceFeed, SwarmSpotFeed, SwarmNhiFeed, SwarmSeatMedianFeed, SwarmSeatSpotFeed
} from "../../src/feeds/SwarmFeeds.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";

/// @notice Stage 2, the feeds: every node of `cfg.feeds`, in node order (a node only uses earlier nodes).
abstract contract StageFeeds is DeployBase {
    function _stageFeeds(DeployTypes.Config memory cfg, Deployed memory d) internal {
        IFeed[] memory recorded = d.feeds;
        d.feeds = new IFeed[](cfg.feeds.length);
        for (uint256 i; i < cfg.feeds.length; ++i) {
            address r = i < recorded.length ? address(recorded[i]) : address(0);
            if (cfg.feeds[i].kind != DeployTypes.EXISTING && _has(r) && _ok(_feedIs(cfg.feeds[i], r, d.feeds), "feed")) {
                d.feeds[i] = IFeed(r);
                continue;
            }
            uint256 g = gasleft();
            d.feeds[i] = _feed(cfg.feeds[i], d.feeds, i);
            if (cfg.feeds[i].kind != DeployTypes.EXISTING) _rec("feed node", g, 3_000);
        }
    }

    function _feed(DeployTypes.FeedNode memory n, IFeed[] memory built, uint256 i) internal returns (IFeed) {
        if (n.kind == DeployTypes.EXISTING) {
            if (n.source.code.length == 0) revert BadNode(i);
            if (!_allowanceCapped(n.source)) revert UncappedExistingFeed(i, n.source);
            return IFeed(n.source);
        }
        if (n.kind == DeployTypes.CHAINLINK) return new ChainlinkFeed(n.source, n.decimals, n.maxAge);
        if (n.kind == DeployTypes.PRODUCT) {
            if (n.a >= i || n.b >= i) revert BadNode(i);
            return new ProductFeed(built[n.a], built[n.b]);
        }
        if (n.kind == DeployTypes.RATE) {
            if (n.a >= i) revert BadNode(i);
            return new RateFeed(n.source, n.selector, n.passOneE18, built[n.a], n.cap);
        }
        // Deployed empty: each is priced 0 until its first attestation is relayed (see the README's trust model).
        if (n.kind == DeployTypes.SWARM_PRICE) return new SwarmPriceFeed(n.maxAge, n.cap);
        if (n.kind == DeployTypes.SWARM_SPOT) return new SwarmSpotFeed(n.maxAge, n.cap);
        if (n.kind == DeployTypes.SWARM_NHI) return new SwarmNhiFeed(n.maxAge, n.cap);
        if (n.kind == DeployTypes.SWARM_SEAT_MEDIAN) return new SwarmSeatMedianFeed(n.maxAge, n.cap);
        if (n.kind == DeployTypes.SWARM_SEAT_SPOT) return new SwarmSeatSpotFeed(n.maxAge, n.cap);
        if (n.kind == DeployTypes.LIVE_POOL) {
            if (n.source.code.length == 0) revert BadNode(i);
            return new LivePoolPrice(IPoolManager(n.source), n.poolId, n.passOneE18);
        }
        revert BadNode(i);
    }
}
