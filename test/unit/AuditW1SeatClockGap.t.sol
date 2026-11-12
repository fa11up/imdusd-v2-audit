// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatJoin} from "src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "src/seats/SeatAccount.sol";
import {SeatFeed} from "src/feeds/SeatFeed.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {ParametersBase} from "src/ParametersBase.sol";

/// @dev A swarm leaf as SeatJoin sees it: `latestValue` returns the attestation's `issuedAt` (SwarmFeed sets
/// `_updatedAt = a.issuedAt`, and accepts an attestation up to `maxAge` after it was issued). `acceptedAt` is the
/// block time of the relay (SwarmFeed keeps it privately as `_acceptedAt`): what a fix needs to read.
contract MockLeaf is IFeed {
    uint256 public value;
    uint64 public updatedAt;
    uint64 public acceptedAt;
    uint256 public figure;
    uint256 public immutable maxAge;

    constructor(uint256 maxAge_) {
        maxAge = maxAge_;
    }

    function set(uint256 v, uint64 issuedAt) external {
        value = v;
        updatedAt = issuedAt;
        acceptedAt = uint64(block.timestamp);
    }

    function setFigure(uint256 f) external {
        figure = f;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, updatedAt);
    }

    function isStale() external view returns (bool) {
        return value == 0 || block.timestamp > uint256(updatedAt) + maxAge;
    }

    function latestFigure() external view returns (uint256) {
        return figure;
    }
}

contract MockParams {
    ParametersBase.Config internal _c;
    address public governor = address(0xA11CE);

    function setMedian(IFeed m) external {
        _c.median = m;
    }

    function config(bytes32) external view returns (ParametersBase.Config memory) {
        return _c;
    }
}

contract MockLedger {
    address public params;
    address public treasury;
    address public token;
    address public liquidator;

    constructor(address p, address t, address tok, address l) {
        params = p;
        treasury = t;
        token = tok;
        liquidator = l;
    }
}

/// @notice SeatJoin._elapsed counts the new attestation's window from its `issuedAt`, which SwarmFeed lets a relayer
/// hold for up to `maxAge` (26 h in BetaConfig) before relaying. Hours in which the chain was STALE (no sale could
/// settle: Liquidator.settle requires `priced`) are then counted as priced time once the held attestation lands,
/// so the Dutch clock jumps and the sale is takeable at the floor, against the documented pause.
contract ProofSeatClockTest is Test {
    uint256 constant T0 = 1_800_000_000;
    address constant LIQUIDATOR = address(0x11);
    address constant MARKER = address(0x22);

    MockLeaf median;
    MockLeaf spot;
    MockLeaf eth;
    SeatFeed feed;
    SeatJoin join;

    function setUp() public {
        vm.warp(T0);
        median = new MockLeaf(26 hours); // SEAT_MAX_AGE in BetaConfig
        spot = new MockLeaf(26 hours);
        eth = new MockLeaf(365 days);
        // The median attestation live at the opening was issued 25 h ago: fresh for one more hour.
        median.set(1e18, uint64(T0 - 25 hours));
        median.setFigure(100);
        spot.set(1e18, uint64(T0));
        eth.set(3000e18, uint64(T0));
        feed = new SeatFeed(median, spot, eth);
        MockParams params = new MockParams();
        params.setMedian(IFeed(address(feed)));
        MockLedger ledger = new MockLedger(address(params), address(0x33), address(0x44), LIQUIDATOR);
        join = new SeatJoin("SEAT", IERC721(address(0x55)), IImdAgentAdapter(address(0x66)), address(this), 25, 3);
        join.wire(address(ledger));
    }

    function test_heldAttestationDoesNotRunTheClockThroughStaleHours() public {
        vm.prank(LIQUIDATOR);
        join.open(1, MARKER);
        uint256 start = join.price(1);
        assertEq(start, 3000e18);

        // One priced hour, then ten hours in which the median leg is stale on chain: no take can settle.
        vm.warp(T0 + 11 hours);
        assertTrue(feed.isStale());
        assertEq(join.elapsed(1), 1 hours, "while stale the clock is paused, as documented");

        // A relayer now relays an attestation ISSUED at T0 + 1 h (10 h old, inside SwarmFeed's maxAge) and takes in
        // the same transaction. The chain was unpriced for those ten hours.
        median.set(1e18, uint64(T0 + 1 hours));
        assertFalse(feed.isStale());
        assertFalse(join.expired(1), "11 h < AUCTION_LIFE: the auction is takeable");

        // Expected: 1 h of priced time, price 0.95 x start. Actual on this commit: 11 h, the floor (0.7 x start).
        assertEq(join.elapsed(1), 1 hours, "priced time must not include the hours the chain was stale");
        assertEq(join.price(1), start * 95 / 100, "the sale must not be at the floor");
    }
}