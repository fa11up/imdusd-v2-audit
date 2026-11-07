// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {MockFeed} from "../utils/Mocks.sol";

/// @dev A rate source whose `convertToAssets` burns `cost` gas before answering (a real vault's read is ~10-30k on Steakhouse
/// USDG), and can be switched to revert.
contract GasHungrySource {
    uint256 public cost;
    uint256 public value = 1.01e18;
    bool public broken;

    function set(uint256 cost_, bool broken_) external {
        cost = cost_;
        broken = broken_;
    }

    function convertToAssets(uint256) external view returns (uint256) {
        require(!broken, "broken");
        uint256 start = gasleft();
        while (start - gasleft() < cost) {}
        return value;
    }
}

/// @notice `RateFeed.poke` cannot succeed as a no-op. Found by the 4663 keeper on a fork against Steakhouse USDG:
/// `eth_estimateGas` settled on the gas at which poke's staticcall ran out (63/64 rule), the tx mined at ~41k gas with no
/// `Poked` and the checkpoint unchanged.
contract RateFeedTest is Test {
    GasHungrySource src;
    RateFeed feed;

    function setUp() public {
        src = new GasHungrySource();
        feed = new RateFeed(address(src), bytes4(keccak256("convertToAssets(uint256)")), true, new MockFeed(1e18), 1e18);
        src.set(200_000, false);
    }

    function test_underGassedPokeRevertsInsteadOfNoOp() public {
        uint256 at = feed.checkpointAt();
        vm.warp(block.timestamp + 1 days);
        // enough to enter poke, not enough for the source's read: the staticcall runs out, the outer frame keeps 1/64
        (bool ok, bytes memory ret) = address(feed).call{gas: 100_000}(abi.encodeCall(RateFeed.poke, ()));
        assertFalse(ok, "an under-gassed poke must fail, not mine as a no-op");
        assertEq(bytes4(ret), RateFeed.RateUnavailable.selector);
        assertEq(feed.checkpointAt(), at, "checkpoint untouched");
        // with the gas it needs, it succeeds and moves the checkpoint
        vm.expectEmit(address(feed));
        emit RateFeed.Poked(1.01e18);
        feed.poke{gas: 1_000_000}();
        assertEq(feed.checkpointAt(), block.timestamp);
        assertEq(feed.checkpointRate(), 1.01e18);
    }

    function test_brokenSourcePokeRevertsAndReadersFailClosed() public {
        src.set(0, true);
        vm.expectRevert(RateFeed.RateUnavailable.selector);
        feed.poke();
        assertEq(feed.rate(), 0, "the view path is unchanged: unpriced");
        (uint256 v,) = feed.latestValue();
        assertEq(v, 0);
        assertTrue(feed.isStale());
    }
}
