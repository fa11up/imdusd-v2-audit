// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The slice of the Ledger a manager reads and calls. Mirrors LedgerBase.Position's ABI exactly.
struct ManagedPosition {
    uint128 collateral;
    uint128 debt;
    uint64 rate;
    uint64 lastUpdate;
    uint64 lastRateChange;
    uint64 premiumRate;
    uint192 yieldMark;
}

interface IManagedLedger {
    function nft() external view returns (address);
    function ilkOf(uint256 id) external view returns (bytes32);
    function position(uint256 id) external view returns (ManagedPosition memory);
    function setRate(uint256 id, uint64 newRate, uint256 prevHint, uint256 nextHint) external;
    function RATE_COOLDOWN() external view returns (uint256);
}

interface IManagedNft {
    function ownerOf(uint256 id) external view returns (address);
    function rightsOf(uint256 id, address who) external view returns (uint8);
    function epochOf(uint256 id) external view returns (uint256);
}

/// @title RateManager
/// @notice Interest-rate delegation for imdUSD positions, OUTSIDE the core (no Ledger change). An owner joins by granting
/// this contract ONE right on their position, SET_RATE (PositionNFT.approveOperator(id, manager, 4)), and calling `join`.
/// The manager key then sets one rate for many members at once (`setRates`), inside bounds fixed at deployment and inside
/// each member's own floor and ceiling. Anyone may deploy a manager; none is part of genesis.
///
/// WHAT A MANAGER CAN NEVER DO, by construction:
///  - Move collateral or debt: it holds only SET_RATE; the Ledger checks the right on every call (rights isolation).
///  - Add debt to a member (Liquity v2 known issue 11: a batch rate change pushed troves under the line through the premium).
///    A member is re-rated ONLY when their position is outside its own 7-day rate cooldown, where the Ledger charges no
///    premium. A rate change alone does not move a position's ratio, so a manager can never make a position liquidatable.
///  - Rate a member below their own floor or above their own ceiling (set by the member, any time), or outside the
///    manager's fixed [minRate, maxRate] for the type.
///  - Move rates by more than `maxStep` per call, or call more often than every `minInterval` (>= 1 hour): no flapping, and
///    a sandwich around a change (Liquity known issue 12, the type average moving under a borrower's upfront fee) is
///    limited to one bounded step per interval.
///  - Keep a member: `leave` works at any time and needs nothing from the manager; so does revoking the right on the NFT.
///    A member can always set their own rate on the Ledger directly.
/// There is no batch-average in the core, so Liquity known issue 20 (joining an empty batch at a stale average) has no
/// analogue here.
///
/// FEES: none. The core cannot add a fee as debt without a Ledger change, and pulling imdUSD from members needs standing
/// allowances that a bug or a compromised key could drain. A manager is run for free (ours: the keeper's automatic manager)
/// or charges off chain.
///
/// RESIDUAL TRUST: within the bounds, the manager key chooses the rate. A hostile key can (a) set every member to the
/// floor that the member and the type allow, which moves them toward the front of the redemption queue, or (b) set them
/// to the ceiling, which costs interest. Both are bounded by the member's own floor/ceiling and by `maxStep` per interval,
/// and each re-rating starts a new 7-day cooldown (a member who then changes their own rate inside it pays the Ledger's
/// cooldown premium, as with any change). A member who disagrees leaves.
contract RateManager {
    uint8 public constant RIGHT_SET_RATE = 4;
    uint256 public constant MIN_INTERVAL = 1 hours;

    struct Bounds {
        uint64 minRate;
        uint64 maxRate;
        bool listed;
    }

    struct Member {
        address owner; // who joined; a transfer of the position ends the membership
        uint64 floor; // the member's own lowest rate (0 = the type's minRate)
        uint64 ceiling; // the member's own highest rate (0 = the type's maxRate)
        uint128 epoch; // the position's transfer epoch at join: a transfer ends the membership for good, even if the
        // position later returns to the same owner
    }

    IManagedLedger public immutable ledger;
    IManagedNft public immutable nft;
    address public immutable manager;
    uint256 public immutable minInterval;
    uint64 public immutable maxStep;
    uint256 public immutable cooldown;

    mapping(bytes32 ilk => Bounds) public bounds;
    mapping(bytes32 ilk => uint64) public lastRate;
    mapping(bytes32 ilk => uint256) public lastCall;
    mapping(uint256 id => Member) public members;

    error Unauthorized();
    error BadConfig();
    error NotListed();
    error OutOfBounds();
    error TooSoon(uint256 next);
    error StepTooLarge();
    error NoRight();
    error LengthMismatch();

    event Joined(uint256 indexed id, address indexed owner, uint64 floor, uint64 ceiling);
    event Left(uint256 indexed id);
    event Rated(uint256 indexed id, uint64 rate);
    event Skipped(uint256 indexed id, uint8 reason);

    /// @param ilks types this manager rates, each with its fixed [minRate, maxRate]
    /// @param maxStep_ the most the target rate may move per call (1e18 = 100 pts a year)
    constructor(
        IManagedLedger ledger_,
        address manager_,
        bytes32[] memory ilks,
        uint64[] memory minRates,
        uint64[] memory maxRates,
        uint256 minInterval_,
        uint64 maxStep_
    ) {
        if (address(ledger_).code.length == 0 || manager_ == address(0)) revert BadConfig();
        if (minInterval_ < MIN_INTERVAL || maxStep_ == 0) revert BadConfig();
        if (ilks.length == 0 || ilks.length != minRates.length || ilks.length != maxRates.length) revert BadConfig();
        ledger = ledger_;
        nft = IManagedNft(ledger_.nft());
        manager = manager_;
        minInterval = minInterval_;
        maxStep = maxStep_;
        cooldown = ledger_.RATE_COOLDOWN();
        for (uint256 i; i < ilks.length; ++i) {
            if (ilks[i] == bytes32(0) || minRates[i] > maxRates[i] || bounds[ilks[i]].listed) revert BadConfig();
            bounds[ilks[i]] = Bounds(minRates[i], maxRates[i], true);
        }
    }

    // ------------------------------------------------------------ members

    /// @notice Join with position `id` (yours, of a type this manager rates). Grant SET_RATE to this contract first.
    /// `floor` / `ceiling` (0 = the type's bounds) are the member's own limits; both inside the type's bounds.
    function join(uint256 id, uint64 floor, uint64 ceiling) external {
        if (nft.ownerOf(id) != msg.sender) revert Unauthorized();
        Bounds memory b = bounds[ledger.ilkOf(id)];
        if (!b.listed) revert NotListed();
        if (nft.rightsOf(id, address(this)) & RIGHT_SET_RATE == 0) revert NoRight();
        _checkLimits(b, floor, ceiling);
        members[id] = Member(msg.sender, floor, ceiling, uint128(nft.epochOf(id)));
        emit Joined(id, msg.sender, floor, ceiling);
    }

    /// @notice Change your own floor and ceiling at any time.
    function setLimits(uint256 id, uint64 floor, uint64 ceiling) external {
        Member memory m = members[id];
        if (m.owner != msg.sender || nft.ownerOf(id) != msg.sender || nft.epochOf(id) != m.epoch) revert Unauthorized();
        _checkLimits(bounds[ledger.ilkOf(id)], floor, ceiling);
        (members[id].floor, members[id].ceiling) = (floor, ceiling);
        emit Joined(id, msg.sender, floor, ceiling);
    }

    /// @notice Leave at any time (the position's current owner, or the member who joined). Revoke the NFT right too, or
    /// keep it for another manager: without membership this contract never touches the position.
    function leave(uint256 id) external {
        if (msg.sender != members[id].owner && msg.sender != nft.ownerOf(id)) revert Unauthorized();
        delete members[id];
        emit Left(id);
    }

    // ------------------------------------------------------------ manager

    /// @notice Set `rate` for the listed members of type `ilk`. Per member the applied rate is `rate` clamped into the
    /// member's own [floor, ceiling]. A member is skipped (not reverted) when: not a member or the position changed hands
    /// (reason 1), of another type (2), the right was revoked (3), inside its own rate cooldown (4: the Ledger would charge
    /// a premium), already at that rate (5), or the Ledger refused (6: no debt, unpriced, ...).
    function setRates(bytes32 ilk, uint64 rate, uint256[] calldata ids, uint256[] calldata prevHints, uint256[] calldata nextHints)
        external
        returns (uint256 rated)
    {
        if (msg.sender != manager) revert Unauthorized();
        Bounds memory b = bounds[ilk];
        if (!b.listed) revert NotListed();
        if (rate < b.minRate || rate > b.maxRate) revert OutOfBounds();
        uint256 next_ = lastCall[ilk] + minInterval;
        if (lastCall[ilk] != 0 && block.timestamp < next_) revert TooSoon(next_);
        uint64 prior = lastRate[ilk];
        if (prior != 0 && (rate > prior ? rate - prior : prior - rate) > maxStep) revert StepTooLarge();
        if (ids.length != prevHints.length || ids.length != nextHints.length) revert LengthMismatch();
        (lastCall[ilk], lastRate[ilk]) = (block.timestamp, rate);
        for (uint256 i; i < ids.length; ++i) {
            if (_rate(ilk, ids[i], rate, prevHints[i], nextHints[i])) ++rated;
        }
    }

    // ------------------------------------------------------------ internals

    function _rate(bytes32 ilk, uint256 id, uint64 rate, uint256 prevHint, uint256 nextHint) private returns (bool) {
        Member memory m = members[id];
        if (m.owner == address(0) || nft.ownerOf(id) != m.owner || nft.epochOf(id) != m.epoch) return _skip(id, 1);
        if (ledger.ilkOf(id) != ilk) return _skip(id, 2);
        if (nft.rightsOf(id, address(this)) & RIGHT_SET_RATE == 0) return _skip(id, 3);
        ManagedPosition memory p = ledger.position(id);
        if (block.timestamp < uint256(p.lastRateChange) + cooldown) return _skip(id, 4);
        uint64 r = rate;
        if (m.floor != 0 && r < m.floor) r = m.floor;
        if (m.ceiling != 0 && r > m.ceiling) r = m.ceiling;
        if (r == p.rate) return _skip(id, 5);
        try ledger.setRate(id, r, prevHint, nextHint) {
            emit Rated(id, r);
            return true;
        } catch {
            return _skip(id, 6);
        }
    }

    function _skip(uint256 id, uint8 reason) private returns (bool) {
        emit Skipped(id, reason);
        return false;
    }

    function _checkLimits(Bounds memory b, uint64 floor, uint64 ceiling) private pure {
        if (floor != 0 && (floor < b.minRate || floor > b.maxRate)) revert OutOfBounds();
        if (ceiling != 0 && (ceiling < b.minRate || ceiling > b.maxRate)) revert OutOfBounds();
        if (floor != 0 && ceiling != 0 && floor > ceiling) revert OutOfBounds();
    }
}
