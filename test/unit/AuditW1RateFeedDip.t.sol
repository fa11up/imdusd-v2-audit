// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RateFeed} from "src/feeds/RateFeed.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

/// @dev An ERC-4626-like rate source whose rate can be set (a loss realised and reversed, a transient misreport).
contract W1RateSource {
    uint256 public r = 1e18;

    function set(uint256 v) external {
        r = v;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * r / 1e18;
    }
}

contract W1UnderlyingFeed is IFeed {
    function latestValue() external view returns (uint256, uint64) {
        return (1e18, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }

    function maxAge() external pure returns (uint256) {
        return 1 hours;
    }
}

/// @notice A one-block dip of the source rate, poked once, pins RateFeed to the dipped level: the recovery back to a
/// level the feed had ALREADY accepted is rate-limited by the growth cap (BetaConfig CAP = 0.1%/day), so a 10% dip
/// is read for ~100 days after the source has recovered. The cap is meant to bound NEW value (a donation), not the
/// return to a level already seen.
/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 3; the math specialist's proof): a poke during a
/// transient dip no longer pins the feed below a rate it already accepted.
contract AuditW1RateFeedDipTest is Test {
    W1RateSource src;
    RateFeed feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        src = new W1RateSource();
        feed = new RateFeed(address(src), bytes4(keccak256("convertToAssets(uint256)")), true, new W1UnderlyingFeed(), uint256(0.001e18) / 1 days);
        assertEq(feed.rate(), 1e18);
    }

    function test_pokeAfterADipDoesNotPinTheFeed() public {
        // block N: the source reads 10% lower for one block and anyone pokes (poke is permissionless)
        src.set(0.9e18);
        feed.poke();
        // block N+1: the source is back where it was
        vm.warp(vm.getBlockTimestamp() + 12);
        src.set(1e18);
        emit log_named_uint("live rate", feed.rate());
        vm.warp(vm.getBlockTimestamp() + 30 days);
        emit log_named_uint("rate read 30 days later (1e18)", feed.rate());
        // Expected: the feed follows the source back to the 1.0 it had already accepted (a return is not new value).
        // Actual: 0.9 x (1 + 0.001 x 30) = 0.927 after 30 days; 1.0 only after ~111 days.
        assertGe(feed.rate(), 0.99e18, "a transient dip, poked once, is read for months");
    }
}