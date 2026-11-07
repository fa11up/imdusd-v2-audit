// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Per type, every position (by id) with debt in ascending order of its borrower-set rate.
/// @dev Liquity v2's SortedTroves, reduced to what redemptions need. Redemptions walk from `first`
/// (lowest rate) upward, so a borrower's rate is their protection from being redeemed. Within equal rates
/// the NEWEST entry is redeemed first (it goes in front of existing equal ones, as in Liquity v2), so raising
/// your rate to match others never shelters you behind them: to get behind them you must outbid them.
///
/// Inserts take a (prev, next) hint pair computed off-chain with `findInsertPosition`. A wrong or stale
/// hint does not fail: the list walks from the hint (or the head) to the right place, at the caller's gas.
contract SortedPositions {
    struct Node {
        uint256 prev; // lower rate
        uint256 next; // higher rate
        uint64 rate;
        bool exists;
    }

    struct List {
        uint256 head; // lowest rate
        uint256 tail; // highest rate
        uint256 size;
        mapping(uint256 id => Node) nodes;
    }

    address public immutable ledger;
    mapping(bytes32 ilk => List) internal _lists;

    error Unauthorized();
    error AlreadyListed();
    error NotListed();

    constructor(address ledger_) {
        ledger = ledger_;
    }

    modifier onlyLedger() {
        if (msg.sender != ledger) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------- views

    function first(bytes32 ilk) external view returns (uint256) {
        return _lists[ilk].head;
    }

    function last(bytes32 ilk) external view returns (uint256) {
        return _lists[ilk].tail;
    }

    /// @notice The next position up (higher rate, or an equal rate that arrived earlier), or zero at the end.
    function next(bytes32 ilk, uint256 id) external view returns (uint256) {
        return _lists[ilk].nodes[id].next;
    }

    function prev(bytes32 ilk, uint256 id) external view returns (uint256) {
        return _lists[ilk].nodes[id].prev;
    }

    function size(bytes32 ilk) external view returns (uint256) {
        return _lists[ilk].size;
    }

    function contains(bytes32 ilk, uint256 id) external view returns (bool) {
        return _lists[ilk].nodes[id].exists;
    }

    function rateOf(bytes32 ilk, uint256 id) external view returns (uint64) {
        return _lists[ilk].nodes[id].rate;
    }

    /// @notice The (prev, next) pair a new entry at `rate` belongs between. Off-chain helper; O(n).
    function findInsertPosition(bytes32 ilk, uint64 rate) external view returns (uint256, uint256) {
        return _walk(_lists[ilk], rate, 0);
    }

    // ---------------------------------------------------------------- mutations

    function insert(bytes32 ilk, uint256 id, uint64 rate, uint256 prevHint, uint256 nextHint) external onlyLedger {
        _insert(_lists[ilk], id, rate, prevHint, nextHint);
    }

    function remove(bytes32 ilk, uint256 id) external onlyLedger {
        _remove(_lists[ilk], id);
    }

    function reinsert(bytes32 ilk, uint256 id, uint64 rate, uint256 prevHint, uint256 nextHint) external onlyLedger {
        List storage l = _lists[ilk];
        _remove(l, id);
        _insert(l, id, rate, prevHint, nextHint);
    }

    function _insert(List storage l, uint256 id, uint64 rate, uint256 prevHint, uint256 nextHint) private {
        if (l.nodes[id].exists) revert AlreadyListed();
        (uint256 p, uint256 n) = _valid(l, rate, prevHint, nextHint) ? (prevHint, nextHint) : _walk(l, rate, prevHint);
        l.nodes[id] = Node({prev: p, next: n, rate: rate, exists: true});
        if (p == 0) l.head = id;
        else l.nodes[p].next = id;
        if (n == 0) l.tail = id;
        else l.nodes[n].prev = id;
        l.size++;
    }

    function _remove(List storage l, uint256 id) private {
        Node memory node = l.nodes[id];
        if (!node.exists) revert NotListed();
        if (node.prev == 0) l.head = node.next;
        else l.nodes[node.prev].next = node.next;
        if (node.next == 0) l.tail = node.prev;
        else l.nodes[node.next].prev = node.prev;
        delete l.nodes[id];
        l.size--;
    }

    /// @dev Adjacent, and `prev.rate < rate <= next.rate` (a newcomer goes in front of existing equal ones).
    function _valid(List storage l, uint64 rate, uint256 p, uint256 n) private view returns (bool) {
        if (p == 0 && n == 0) return l.size == 0;
        if (p == 0) return l.head == n && rate <= l.nodes[n].rate;
        if (n == 0) return l.tail == p && l.nodes[p].exists && l.nodes[p].rate < rate;
        return l.nodes[p].exists && l.nodes[p].next == n && l.nodes[p].rate < rate && rate <= l.nodes[n].rate;
    }

    /// @dev Walk upward from `start` if it is a listed node strictly below `rate`, else from the head; stop in front of
    /// the first node at or above `rate`.
    function _walk(List storage l, uint64 rate, uint256 start) private view returns (uint256 p, uint256 n) {
        if (start != 0 && l.nodes[start].exists && l.nodes[start].rate < rate) {
            p = start;
            n = l.nodes[start].next;
        } else {
            p = 0;
            n = l.head;
        }
        while (n != 0 && l.nodes[n].rate < rate) {
            p = n;
            n = l.nodes[n].next;
        }
    }
}
