// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientReentrancyGuard} from "./TransientReentrancyGuard.sol";
import {Ledger, IPulse} from "./Ledger.sol";
import {Pricer} from "./Pricer.sol";
import {ParametersBase} from "./ParametersBase.sol";
import {Parameters} from "./Parameters.sol";
import {IAuctionJoin} from "./interfaces/IPositions.sol";
import {IBackstop} from "./backstop/IBackstop.sol";

interface ITreasuryCover {
    function coverBadDebt(bytes32 ilk) external;
}

interface IPulseView {
    function inGrace() external view returns (bool);
}


/// @notice Mark (`bark`) an unhealthy position (by id), then close it (`bite`) once its grace has run.
/// Marks and grace memory belong to the position, not its owner: a transfer mid-grace changes nothing.
/// @dev v1's two-step liquidation, per type. The grace (`lull`) is non-zero only on NHI-linked types
/// (sIMD: up to 6h while the network is healthy, giving its borrowers time to repair); every other type
/// has none, and `liquidate` marks and bites in one call. A mark expires after `MARK_TTL` of PRICED time, and a
/// position that recovers can have its mark cleared by anyone.
/// GRACE MEMORY: the grace a mark grants is remembered per position (`graces`), and `clear` does not
/// erase it. A new mark set while the previous one would still have been alive (within `MARK_TTL` of it) inherits the
/// earlier grace end, so a borrower cannot top up to mat for one block, clear, and start a fresh 6h on every dip.
/// PRICED CLOCK: `MARK_TTL` counts only time the type was priced. `tick(ilk)` (permissionless; every
/// mark and bite runs it) records when the type's quote turns unpriced and when it is priced again; the unpriced span
/// extends every mark's expiry. Nobody ticking during an outage is the only way a mark ages through one, so the keeper
/// ticks whenever a feed goes stale or returns.
/// Price: the quote's `low`, which collapses to the median when the legs disagree, so a manipulated spot
/// cannot start a liquidation the median does not support.
/// AUCTION TYPES (`Config.auction`, seats): `bite` does not close the position. It opens a Dutch
/// auction in the type's join, and the join calls `settle` with the price a taker paid; the Ledger then
/// seizes the whole position at that price. The position must still be unhealthy when it settles, so a
/// borrower who repairs it during the auction keeps it.
/// PULSE (chains with no sequencer-uptime feed): every mark and bite pokes the Ledger's Pulse first. While its grace
/// runs (a silence longer than its gap has just ended), marking proceeds but seizing does not: `bite` returns zeros and keeps
/// the mark (it must not revert, or the grace its own poke started would be undone), and an auction cannot settle.
contract Liquidator is TransientReentrancyGuard {
    struct Mark {
        uint64 at;
        address marker;
    }

    uint256 public constant MARK_TTL = 24 hours;
    /// @notice How long a type must have read unpriced before a mark on it stops counting against the edge capacity.
    uint256 public constant EDGE_MARK_MAX_UNPRICED = 7 days;

    Ledger public immutable ledger;
    Pricer public immutable pricer;
    Parameters public immutable params;
    /// @notice The Ledger's Pulse; zero where the chain does not use one.
    IPulse public immutable pulse;

    /// @notice Per position: when its latest mark was set, when that mark's grace ends, and the type's paused clock then.
    struct Grace {
        uint64 markedAt;
        uint64 end;
        uint64 pausedAtMark;
    }

    /// @notice Per type: since when its quote has read unpriced (0 while priced), and the unpriced seconds recorded so far.
    struct Clock {
        uint64 unpricedSince;
        uint64 paused;
    }

    /// @notice Edge-type debt recorded at each live mark, and their sum (the edge sleeve's capacity is net of it).
    /// A mark's debt is counted from `bark` until the mark is bitten, cleared or replaced by a new mark; an expired mark that
    /// nobody replaced keeps counting, which only makes the edge bound stricter, until `releaseEdgeMark`.
    mapping(uint256 id => uint256) public markedEdgeDebt;
    uint256 public edgeInAuction;

    mapping(uint256 id => Mark) public marks;
    mapping(uint256 id => Grace) public graces;
    mapping(bytes32 ilk => Clock) public clocks;

    /// @dev Gas a liquidation that booked bad debt must still hold to attempt its cover. Far above what a cover uses, with room for Glamsterdam's storage prices. It only has to be held: what is not used is not paid for.
    uint256 internal constant COVER_MIN_GAS = 2_000_000;

    error NotPriced();
    error Healthy();
    error NotMarked();
    error InGrace(uint256 until);
    error MarkExpired();
    error AlreadyMarked();
    error StillUnhealthy();
    error EdgeMarkLive();

    event Barked(uint256 indexed id, bytes32 indexed ilk, address marker);
    event Cleared(uint256 indexed id, bytes32 indexed ilk);
    event AuctionOpened(uint256 indexed id, bytes32 indexed ilk, address marker);
    event HeldByGrace(uint256 indexed id, bytes32 indexed ilk);
    event StandingBid(uint256 indexed id, bytes32 indexed ilk, address indexed sleeve, uint256 repaid, uint256 received);

    error SequencerGrace();

    error Unauthorized();
    error SeizedTooLow(uint256 seized, uint256 minSeized);
    error CoverGasShort();

    constructor(Ledger ledger_, Pricer pricer_) {
        ledger = ledger_;
        pricer = pricer_;
        params = ledger_.params();
        pulse = ledger_.pulse();
    }

    function bark(uint256 id) public nonReentrant {
        _poke();
        bytes32 ilk = ledger.ilkOf(id);
        Mark storage m = marks[id];
        Pricer.Quote memory q = _requireUnhealthy(ilk, id);
        if (m.at != 0 && !_expired(ilk, id, m.at)) revert AlreadyMarked();
        Grace storage g = graces[id];
        uint64 end = uint64(block.timestamp + q.lull);
        // L2: a mark set while the previous one would still be alive inherits that mark's grace end.
        if (g.markedAt != 0 && block.timestamp <= g.markedAt + MARK_TTL && g.end < end) end = g.end;
        graces[id] = Grace({markedAt: uint64(block.timestamp), end: end, pausedAtMark: clocks[ilk].paused});
        marks[id] = Mark({at: uint64(block.timestamp), marker: msg.sender});
        if (params.edgeIlk(ilk)) _setEdgeMark(id, ledger.debtOf(id));
        emit Barked(id, ilk, msg.sender);
    }

    /// @notice Close a marked position whose grace has run. The caller pays its debt and takes the collateral.
    function bite(uint256 id) public returns (uint256, uint256, uint256) {
        return bite(id, 0);
    }

    /// @notice `bite`, reverting on the caller path if the position would give up less collateral than `minSeized`. A price
    /// update landing ahead of a caller lifts the price he pays. Keepers and the site always use this form, by private send. A
    /// standing bid does not read it: the caller pays nothing there (and earns only the chip, if it is also the marker).
    function bite(uint256 id, uint256 minSeized) public nonReentrant returns (uint256 repaid, uint256 seized, uint256 bad) {
        Mark memory m = marks[id];
        if (m.at == 0) revert NotMarked();
        bytes32 ilk = ledger.ilkOf(id);
        Pricer.Quote memory q = _requireUnhealthy(ilk, id);
        if (_expired(ilk, id, m.at)) revert MarkExpired();
        // The grace granted at the mark (or inherited), never longer than the lull the NHI allows now.
        uint256 until = Math.min(graces[id].end, m.at + q.lull);
        if (block.timestamp < until) revert InGrace(until);
        if (_poke()) {
            emit HeldByGrace(id, ilk);
            return (0, 0, 0);
        }
        delete marks[id];
        _setEdgeMark(id, 0);
        ParametersBase.Config memory c = params.config(ilk);
        if (c.auction) {
            IAuctionJoin(c.join).open(id, m.marker);
            emit AuctionOpened(id, ilk, m.marker);
            return (0, 0, 0);
        }
        // STANDING BID: a sleeve that covers the type and can pay what this liquidation repays buys the
        // collateral now, at the same price a caller would; the penalty (less the Treasury's cut and the marker's chip) is
        // the sleeve's. Otherwise the caller pays, as before. The kick is the marker's chip: a `bite` caller who did not mark
        // earns nothing, but `liquidate` on a type with no grace (every beta type) marks first, so its caller IS the marker.
        // only while the type's legs agree. Apart past `skew`, `low` is the (possibly lagging) median, and a
        // forced bid there would overpay; a caller may still choose to pay it.
        address sleeve = params.edgeIlk(ilk) ? params.edgeBackstop() : params.blueBackstop();
        if (sleeve != address(0) && q.agree) {
            uint256 need = ledger.liquidationNeed(id, q.low);
            // openBid first: it folds matured deposit buckets into the pool, so the room read next is the real one. A sleeve
            // that does not cover this type refuses to open (try): the caller path below is unchanged then.
            if (need != 0) {
                try IBackstop(sleeve).openBid(ilk) {
                    if (IBackstop(sleeve).bidRoom(ilk) >= need) {
                        (repaid, seized, bad) = ledger.liquidatePosition(id, q.low, sleeve, m.marker, false);
                        (, uint256 received) = IBackstop(sleeve).closeBid(ilk, repaid);
                        emit StandingBid(id, ilk, sleeve, repaid, received);
                        _cover(ilk, bad);
                        return (repaid, seized, bad);
                    }
                    IBackstop(sleeve).closeBid(ilk, 0); // not enough room: release the sleeve, the caller pays
                } catch {}
            }
        }
        (repaid, seized, bad) = ledger.liquidatePosition(id, q.low, msg.sender, m.marker, false);
        if (seized < minSeized) revert SeizedTooLow(seized, minSeized);
        _cover(ilk, bad);
    }

    /// @dev Cover booked bad debt in the liquidation's own transaction (the edge sleeve
    /// first, then the Treasury; Treasury.coverBadDebt orders them), so no depositor can leave between the loss and its
    /// cover, and the unbacked brake sees only what both could not pay. Best effort: a cover that cannot run now (a sleeve
    /// mid-bid, an empty Treasury) never blocks the liquidation; anyone may call coverBadDebt later. The caller picks the gas
    /// limit, so a cover starved on purpose would look the same and leave the gap this closes: too little gas for it reverts.
    function _cover(bytes32 ilk, uint256 bad) private {
        if (bad == 0) return;
        if (gasleft() < COVER_MIN_GAS) revert CoverGasShort();
        try ITreasuryCover(ledger.treasury()).coverBadDebt(ilk) {} catch {}
    }

    /// @notice An auction type's join closes the position it has just sold, at the price the taker paid
    /// (per 1e18 units, in imdUSD). The join is the payer: the Ledger burns the debt from what the taker
    /// paid into it, or, with `reserve` (a sale paid in a reserve asset sent to the Treasury, the USDG auction),
    /// books it as reserve-backed supply instead of burning. Bad debt the sale leaves is covered in the same transaction, as
    /// `bite` does (audit wave 1: it was left booked for anyone to cover later).
    function settle(uint256 id, uint256 price, address marker, bool reserve)
        external
        nonReentrant
        returns (uint256 repaid, uint256 seized, uint256 bad)
    {
        bytes32 ilk = ledger.ilkOf(id);
        ParametersBase.Config memory c = params.config(ilk);
        if (!c.auction || msg.sender != c.join) revert Unauthorized();
        if (_poke()) revert SequencerGrace();
        _requireUnhealthy(ilk, id);
        (repaid, seized, bad) = ledger.liquidatePosition(id, price, msg.sender, marker, reserve);
        _cover(ilk, bad);
    }

    /// @notice Mark and bite in one call, for types with no grace (or once a grace has already run).
    function liquidate(uint256 id) external returns (uint256, uint256, uint256) {
        return liquidate(id, 0);
    }

    /// @notice `liquidate` with the guard on `bite`.
    function liquidate(uint256 id, uint256 minSeized) public returns (uint256, uint256, uint256) {
        Mark memory m = marks[id];
        if (m.at == 0 || _expired(ledger.ilkOf(id), id, m.at)) bark(id);
        return bite(id, minSeized);
    }

    /// @notice Record whether the type is priced now, so unpriced time does not age its marks. Permissionless;
    /// every mark and bite does it too.
    function tick(bytes32 ilk) public {
        bool priced;
        try pricer.quote(ilk) returns (Pricer.Quote memory q) {
            priced = q.priced;
        } catch {}
        _tick(ilk, priced);
    }

    /// @notice When the position's mark expires: `MARK_TTL` after it was set, plus the type's unpriced time since.
    function markExpiresAt(uint256 id) external view returns (uint256) {
        Mark memory m = marks[id];
        if (m.at == 0) return 0;
        return m.at + MARK_TTL + (_pausedNow(ledger.ilkOf(id)) - graces[id].pausedAtMark);
    }

    /// @notice Remove the mark from a position that is healthy again.
    function clear(uint256 id) external {
        (bool ok, bool priced) = ledger.healthy(id);
        if (!priced) revert NotPriced();
        if (!ok) revert StillUnhealthy();
        delete marks[id];
        _setEdgeMark(id, 0);
        emit Cleared(id, ledger.ilkOf(id));
    }

    /// @notice Stop counting a mark's debt against the edge capacity, for a mark nothing else can end: the position has no debt
    /// left, or its type has been unpriced past EDGE_MARK_MAX_UNPRICED (recorded by `tick`), when `bite` and `clear` both refuse and one
    /// dead feed would shrink every edge type's room for good. The debt itself still counts in the bound; the mark stays.
    function releaseEdgeMark(uint256 id) external {
        if (ledger.debtOf(id) != 0) {
            bytes32 ilk = ledger.ilkOf(id);
            _tick(ilk, pricer.quote(ilk).priced);
            uint256 since = clocks[ilk].unpricedSince;
            if (since == 0 || block.timestamp <= since + EDGE_MARK_MAX_UNPRICED) revert EdgeMarkLive();
        }
        _setEdgeMark(id, 0);
    }

    function _setEdgeMark(uint256 id, uint256 debt) private {
        uint256 old = markedEdgeDebt[id];
        if (old == debt) return;
        markedEdgeDebt[id] = debt;
        edgeInAuction = edgeInAuction - old + debt;
    }

    /// @dev Poke the Pulse (if any) and report whether seizing must wait.
    function _poke() private returns (bool held) {
        if (address(pulse) == address(0)) return false;
        pulse.poke();
        return IPulseView(address(pulse)).inGrace();
    }

    function _requireUnhealthy(bytes32 ilk, uint256 id) private returns (Pricer.Quote memory q) {
        q = pricer.quote(ilk);
        _tick(ilk, q.priced);
        if (!q.priced) revert NotPriced();
        (bool ok,) = ledger.healthy(id);
        if (ok) revert Healthy();
    }

    function _tick(bytes32 ilk, bool priced) private {
        Clock storage c = clocks[ilk];
        if (!priced) {
            if (c.unpricedSince == 0) c.unpricedSince = uint64(block.timestamp);
        } else if (c.unpricedSince != 0) {
            c.paused += uint64(block.timestamp - c.unpricedSince);
            c.unpricedSince = 0;
        }
    }

    /// @dev The type's unpriced seconds to date, including a span still open.
    function _pausedNow(bytes32 ilk) private view returns (uint256) {
        Clock memory c = clocks[ilk];
        return c.paused + (c.unpricedSince != 0 ? block.timestamp - c.unpricedSince : 0);
    }

    function _expired(bytes32 ilk, uint256 id, uint64 at) private view returns (bool) {
        return block.timestamp > at + MARK_TTL + (_pausedNow(ilk) - graces[id].pausedAtMark);
    }
}
