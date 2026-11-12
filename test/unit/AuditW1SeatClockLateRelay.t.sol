// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatJoin} from "src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "src/seats/SeatAccount.sol";
import {SeatFeed} from "src/feeds/SeatFeed.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {ParametersBase} from "src/ParametersBase.sol";

/// @dev A swarm leaf whose `updatedAt` is the attestation's signed `issuedAt`, settable in the past (as SwarmFeed's
/// `_updatedAt` is: an attestation may be relayed up to `maxAge` after it was issued).
contract W1ClkLeaf2 is IFeed {
    uint256 public value;
    uint64 public at;
    uint256 public maxAge = 26 hours;
    uint256 public latestFigure = 150;

    uint64 public relayedAt;

    function set(uint256 v, uint64 issuedAt) external {
        value = v;
        at = issuedAt;
        relayedAt = uint64(block.timestamp);
    }

    /// As SwarmFeed.acceptedAt: the block time the live value was relayed.
    function acceptedAt() external view returns (uint64) {
        return relayedAt;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, at);
    }

    function isStale() external view returns (bool) {
        return value == 0 || block.timestamp - at > maxAge;
    }
}

contract W1ClkParams2 {
    SeatFeed public feed;

    constructor(SeatFeed f) {
        feed = f;
    }

    function config(bytes32) external view returns (ParametersBase.Config memory c) {
        c.median = IFeed(address(feed));
        c.spot = IFeed(address(feed));
        c.auction = true;
    }

    function governor() external pure returns (address) {
        return address(0xBEEF);
    }
}

contract W1ClkLedger2 {
    address public params;
    address public liquidator;
    address public treasury = address(0xCAFE);
    address public token = address(0xD0D0);

    constructor(address p, address l) {
        params = p;
        liquidator = l;
    }
}

contract AuditW1SeatClockLateRelayTest is Test {
    W1ClkLeaf2 median;
    W1ClkLeaf2 spot;
    W1ClkLeaf2 ethUsd;
    SeatFeed feed;
    SeatJoin join;
    uint256 constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        median = new W1ClkLeaf2();
        spot = new W1ClkLeaf2();
        ethUsd = new W1ClkLeaf2();
        median.set(2e18, uint64(T0)); // attestation A0 issued and relayed at T0
        spot.set(2e18, uint64(T0));
        ethUsd.set(2000e18, uint64(T0));
        feed = new SeatFeed(median, spot, ethUsd);
        W1ClkParams2 p = new W1ClkParams2(feed);
        W1ClkLedger2 l = new W1ClkLedger2(address(p), address(this)); // this test is the "liquidator"
        join = new SeatJoin("SEAT", IERC721(address(0xAAAA)), IImdAgentAdapter(address(0xBBBB)), address(this), 25, 3);
        join.wire(address(l));
    }

    /// The header of `_elapsed` says: "the clock only ever runs slow, never fast". A median attestation issued before
    /// the live one aged out but relayed after it did (SwarmFeed accepts any `issuedAt` within `maxAge`) makes the
    /// priced clock count the whole stale gap as priced time: the auction jumps from 1 hour of decay to the floor.
    function test_lateRelayDoesNotCountTheStaleGap() public {
        vm.warp(T0 + 25 hours); // A0 has one hour of life left
        join.open(1, address(0x1111));
        uint256 start = join.price(1);
        assertEq(start, 4000e18);

        vm.warp(T0 + 26 hours); // A0 ages out: 1 hour of priced time ran
        assertEq(join.elapsed(1), 1 hours);
        ethUsd.set(2000e18, uint64(T0 + 26 hours));

        vm.warp(T0 + 38 hours); // 12 hours with no readable median: the clock is paused
        assertTrue(median.isStale());
        assertEq(join.elapsed(1), 1 hours, "paused while stale");
        uint256 pausedPrice = join.price(1);

        // An attestation issued at T0+20h (inside A0's window) is relayed now, 18 hours after it was signed.
        median.set(2e18, uint64(T0 + 20 hours));
        ethUsd.set(2000e18, uint64(T0 + 38 hours));
        assertFalse(median.isStale());

        // Expected: at most the hour that ran before the gap (plus nothing: the relay just landed).
        // Actual on this commit: 13 hours, the 12-hour stale gap is counted and the price is at the floor.
        uint256 ran = join.elapsed(1);
        emit log_named_uint("priced seconds counted", ran);
        emit log_named_uint("price before the relay", pausedPrice);
        emit log_named_uint("price after the relay", join.price(1));
        assertLe(ran, 1 hours, "the clock ran during the stale gap");
        assertEq(join.price(1), pausedPrice, "the sale price fell while nobody could read a median");
    }
}