// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {MockLiveAggregator} from "../utils/Mocks.sol";

/// @dev The shape of Chainlink's EACAggregatorProxy -> OCR aggregator pair: the proxy answers `latestRoundData` and names
/// its current `aggregator()`, which carries `minAnswer`/`maxAnswer` (int192 on chain; a word here).
contract BoundedAggregator {
    int256 public minAnswer;
    int256 public maxAnswer;

    constructor(int256 mn, int256 mx) {
        minAnswer = mn;
        maxAnswer = mx;
    }
}

contract ClampingProxy {
    uint8 public constant decimals = 8;
    address public aggregator;
    int256 public answer;

    constructor(address agg, int256 a) {
        aggregator = agg;
        answer = a;
    }

    function set(int256 a) external {
        answer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice F5 (low): an absurd answer must read unpriced (0, stale), never panic, and an answer
/// sitting on the aggregator's own min/maxAnswer clamp is not a market. The first test FAILED before the fix (arithmetic panic).
contract ChainlinkFeedTest is Test {
    function setUp() public {
        vm.warp(1_800_000_000);
    }

    function test_hugeAnswerReadsUnpricedNotPanic() public {
        MockLiveAggregator agg = new MockLiveAggregator(8, 1e49); // 10 ** (36 - 8) x this overflows a uint256
        ChainlinkFeed f = new ChainlinkFeed(address(agg), 18, 1 hours);
        (uint256 v, uint64 at) = f.latestValue();
        assertEq(v, 0);
        assertEq(at, 0);
        assertTrue(f.isStale());
    }

    function test_sanityCapBoundary() public {
        MockLiveAggregator agg = new MockLiveAggregator(8, 1e26); // exactly $1e18 a token: the last price read
        ChainlinkFeed f = new ChainlinkFeed(address(agg), 18, 1 hours);
        (uint256 v,) = f.latestValue();
        assertEq(v, f.MAX_PER_TOKEN());
        assertFalse(f.isStale());
        agg.set(1e26 + 1);
        (v,) = f.latestValue();
        assertEq(v, 0, "one unit above the cap is garbage");
        assertTrue(f.isStale());
        agg.set(3_000e8); // an ordinary answer still reads
        (v,) = f.latestValue();
        assertEq(v, 3_000e18);
    }

    function test_clampedAnswerReadsUnpriced() public {
        BoundedAggregator bounded = new BoundedAggregator(1e9, 1e14); // $10 .. $1,000,000 at 8 decimals
        ClampingProxy proxy = new ClampingProxy(address(bounded), 3_000e8);
        ChainlinkFeed f = new ChainlinkFeed(address(proxy), 18, 1 hours);
        (uint256 v,) = f.latestValue();
        assertEq(v, 3_000e18, "inside the bounds: a price");
        proxy.set(1e9);
        (v,) = f.latestValue();
        assertEq(v, 0, "at minAnswer: the clamp, not a market");
        proxy.set(1e14);
        (v,) = f.latestValue();
        assertEq(v, 0, "at maxAnswer: the clamp, not a market");
        proxy.set(1e9 + 1);
        (v,) = f.latestValue();
        assertEq(v, (1e9 + 1) * 1e10, "one above minAnswer reads");
    }

    function test_aggregatorWithoutBoundsReadsAsBefore() public {
        MockLiveAggregator agg = new MockLiveAggregator(8, 1); // the smallest answer, no bounds to hit
        ChainlinkFeed f = new ChainlinkFeed(address(agg), 18, 1 hours);
        (uint256 v,) = f.latestValue();
        assertEq(v, 1e10);
        // A proxy whose aggregator exposes bounds of "none" (0) does not clamp either.
        BoundedAggregator none = new BoundedAggregator(0, 0);
        ClampingProxy proxy = new ClampingProxy(address(none), 1);
        f = new ChainlinkFeed(address(proxy), 18, 1 hours);
        (v,) = f.latestValue();
        assertEq(v, 1e10);
    }
}
