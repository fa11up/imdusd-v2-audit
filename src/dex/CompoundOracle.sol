// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title CompoundOracle
/// @notice The Compound DEX's in-hook TWAP of its own curve tick (PegHook's accumulator and checkpoint ring, as a
/// linked library on the hook's storage). After every price change the tick that prevailed since the last update is
/// credited with the time it prevailed (the v3 oracle's rule), and a checkpoint is written at most every GAP seconds
/// into a ring of SLOTS. The mean is read over at least WINDOW: a price moved inside a block has had zero seconds of
/// weight when the same block reads it.
library CompoundOracle {
    uint32 internal constant WINDOW = 30 minutes;
    uint32 internal constant GAP = 5 minutes;
    uint256 internal constant SLOTS = 16;

    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    struct State {
        int24 lastTick;
        uint32 lastTimestamp;
        int56 tickCumulative;
        uint16 index; // newest written slot
        uint16 count;
        Observation[16] obs;
    }

    function init(State storage s, int24 tick) external {
        s.lastTick = tick;
        s.lastTimestamp = uint32(block.timestamp);
        s.obs[0] = Observation(uint32(block.timestamp), 0);
        s.count = 1;
    }

    /// @notice Credit the tick that prevailed since the last update with the time it prevailed, then adopt `tick`.
    function observe(State storage s, int24 tick) external {
        uint32 nowTs = uint32(block.timestamp);
        uint32 dt = nowTs - s.lastTimestamp;
        if (dt != 0) {
            int56 cum = s.tickCumulative + int56(s.lastTick) * int56(uint56(dt));
            s.tickCumulative = cum;
            s.lastTimestamp = nowTs;
            uint16 i = s.index;
            if (nowTs >= s.obs[i].timestamp + GAP) {
                uint16 next = uint16((i + 1) % SLOTS);
                s.obs[next] = Observation(nowTs, cum);
                s.index = next;
                if (s.count < SLOTS) ++s.count;
            }
        }
        s.lastTick = tick;
    }

    /// @notice The mean tick since the newest checkpoint at least WINDOW old, and whether one exists.
    function twap(State storage s) external view returns (bool, int24) {
        if (s.count == 0) return (false, 0);
        uint32 nowTs = uint32(block.timestamp);
        int56 cumNow = s.tickCumulative + int56(s.lastTick) * int56(uint56(nowTs - s.lastTimestamp));
        uint256 i = s.index;
        for (uint256 n; n < s.count; ++n) {
            Observation memory o = s.obs[i];
            if (o.timestamp + WINDOW <= nowTs) {
                return (true, int24((cumNow - o.tickCumulative) / int56(uint56(nowTs - o.timestamp))));
            }
            i = i == 0 ? SLOTS - 1 : i - 1;
        }
        return (false, 0);
    }
}
