// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A sequencer-outage grace for chains with no Chainlink L2 sequencer-uptime feed (Robinhood Chain).
/// @dev The chain's own liveness, seen from inside: every core action (the Ledger's accrual, the Liquidator's mark and
/// bite), the keeper and anyone may `poke()`, which records the time. A poke that finds more than `gap` seconds since the
/// previous one has just ended a silence the chain may have imposed (a halted or censoring sequencer), so it opens a
/// `grace` window. While it runs, liquidations may MARK but not seize: borrowers get the time the outage took from them.
///
/// Why a liquidator cannot skip it: the grace is started by whichever poke ends the long gap, and the Liquidator pokes
/// before it checks, so the first liquidation after a silence starts the grace itself and is held by it (and does not
/// revert, so the grace it started persists). Poking can only lengthen a grace, never end one.
///
/// A quiet chain with no outage looks the same as a halted one; that is accepted (it errs towards borrowers). The keeper
/// pokes more often than `gap` so a quiet period does not open a grace. No owner, no parameters after construction.
contract Pulse {
    uint256 public constant MIN_GAP = 1 minutes;
    uint256 public constant MAX_GAP = 1 hours;
    uint256 public constant MAX_GRACE = 6 hours;

    /// @notice A silence longer than this opens a grace.
    uint256 public immutable gap;
    /// @notice How long seizing waits after such a silence ends.
    uint256 public immutable grace;

    uint64 public lastPulse;
    uint64 public graceUntil;

    error OutOfBounds();

    event Pulsed(uint256 at);
    event GraceStarted(uint256 silence, uint256 until);

    constructor(uint256 gap_, uint256 grace_) {
        if (gap_ < MIN_GAP || gap_ > MAX_GAP || grace_ == 0 || grace_ > MAX_GRACE) revert OutOfBounds();
        gap = gap_;
        grace = grace_;
        lastPulse = uint64(block.timestamp);
    }

    /// @notice Record that the chain is alive now; open a grace if it was silent for longer than `gap`. Never reverts.
    function poke() external {
        uint256 last = lastPulse;
        if (block.timestamp == last) return;
        uint256 silence = block.timestamp - last;
        if (silence > gap) {
            uint256 until = block.timestamp + grace;
            if (until > graceUntil) graceUntil = uint64(until);
            emit GraceStarted(silence, until);
        }
        lastPulse = uint64(block.timestamp);
        emit Pulsed(block.timestamp);
    }

    /// @notice True while seizing must wait. Read after a poke in the same call: a pending long gap is a grace too.
    function inGrace() external view returns (bool) {
        return block.timestamp < graceUntil || block.timestamp - lastPulse > gap;
    }
}
