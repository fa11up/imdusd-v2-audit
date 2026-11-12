// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GovernedByKind} from "./GovernedByKind.sol";
import {IFeed} from "./interfaces/IFeed.sol";

interface IImdDepth {
    function params() external view returns (address);
    function depth() external view returns (uint256);
    function addSampler(address sampler) external;
    function removeSampler(address sampler) external;
    function setLeg(address leg, address price) external;
}

interface IJoinView {
    function token() external view returns (address);
    function ledger() external view returns (address);
}

interface IAssetView {
    function asset() external view returns (address);
}

interface IBridgeSettable {
    function setBridge(address bridge) external;
    function setKeeper(address keeper) external;
    function bridge() external view returns (address);
    function keeper() external view returns (address);
}

interface INoteSeries {
    function token() external view returns (address);
    function params() external view returns (address);
    function open(uint64 tenor, uint32 discountBps, uint128 cap) external returns (uint256);
}

interface ISleeve {
    function oracle() external view returns (address);
    function ilks(bytes32 ilk) external view returns (address token, uint64 listedAt, uint128 genesisLine, bool on);
    function addIlk(bytes32 ilk, address token, uint128 genesisLine, uint128 saleMax, uint128 saleSlope) external;
    function disableIlk(bytes32 ilk) external;
    function isToken(address token) external view returns (bool);
    function tokenCount() external view returns (uint256);
    function ilkCount() external view returns (uint256);
    function EDGE_MULTIPLE() external view returns (uint256);
    function netVested() external view returns (uint256);
    function edgeCapacity(bytes32 ilk, uint256 inAuction) external view returns (uint256);
    function retire(address token, bool on) external;
}

interface ILedgerEdgeView {
    function ilkState(bytes32 ilk)
        external
        view
        returns (uint128 debt, uint128 collateral, uint256 weighted, uint64 lastAccrual, uint128 badDebt);
    function liquidator() external view returns (address);
}

interface IEdgeInAuction {
    function edgeInAuction() external view returns (uint256);
}

interface ISleeveOracle {
    function ilkOf(address token) external view returns (bytes32);
    function setIlk(address token, bytes32 ilk) external;
}

interface ISeatGoverned {
    function setLimits(uint256 maxSeats, uint256 perBorrower) external;
    function setClaimRule(address target, bytes4 selector, uint8 rule) external;
}

/// @notice Parameters' storage, events, errors and the helpers both Parameters and ParametersRules use (an EIP-170 size split,
/// the LedgerBase pattern). Parameters holds the public surface; ParametersRules holds the per-kind validate/apply, run ONLY
/// by delegatecall from Parameters on Parameters' storage.
abstract contract ParametersBase is GovernedByKind {
    struct Config {
        address token; // collateral token (for yield types: the ERC-4626 share)
        address join; // custody
        IFeed median; // slow price leg
        IFeed spot; // fast price leg (same as median for Chainlink types)
        IFeed nhi; // non-zero only for NHI-linked types (sIMD): mat and lull then follow NHI as in v1
        address yieldRate; // RateFeed whose capped rate the Ledger harvests against; zero = no yield harvest
        address pegAggregator; // Chainlink X/USD for a stablecoin type's depeg breaker; zero = none
        IFeed liveSpot; // live pool price, redemption payout leg only; zero for Chainlink types
        bool redeemable;
        bool auction; // non-fungible: liquidation seizes the WHOLE position and the join sells it by Dutch auction
    }

    struct Risk {
        uint64 mat; // liquidation ratio, 1e18 (1.4e18 = 140%); ignored when nhi is set
        uint64 chop; // liquidation penalty, 1e18
        uint64 cut; // Treasury share of the penalty, 1e18
        uint64 chip; // marker share of the penalty, 1e18
        uint64 rateFloor; // lowest borrower-set annual rate, 1e18
        uint64 yieldFee; // protocol share of harvested yield, 1e18
        uint64 skew; // max median/spot divergence before the type freezes, 1e18
        uint64 pegFloor; // depeg breaker on pegAggregator's answer, 1e18 ($0.98 = 0.98e18); 0 = none
        uint128 line; // debt ceiling
        uint128 dust; // minimum non-zero debt
        uint64 redeemFloor; // redemption fee floor, 1e18
        uint64 redeemDivisor; // base-rate increase = redeemed share of supply / divisor
        uint128 redeemCap; // most imdUSD redeemed against the type per rolling 2h window; 0 = no cap
    }

    // ---- bounds ----
    uint256 public constant MIN_MAT = 1.01e18;
    uint256 public constant MAX_MAT = 3e18;
    uint256 public constant MIN_CHOP = 0.02e18;
    uint256 public constant MAX_CHOP = 0.25e18;
    uint256 public constant MAX_RATE_FLOOR = 0.5e18;
    uint256 public constant MAX_YIELD_FEE = 0.25e18;
    uint256 public constant MIN_SKEW = 0.005e18;
    uint256 public constant MAX_SKEW = 0.25e18;
    uint256 public constant MIN_PEG_FLOOR = 0.9e18;
    /// @notice Redemption fee bounds per type. The cap (5%) is the Redeemer's, and fixed.
    uint256 public constant MIN_REDEEM_FLOOR = 0.001e18;
    uint256 public constant MAX_REDEEM_FLOOR = 0.05e18;
    uint256 public constant MAX_REDEEM_DIVISOR = 16;
    /// @notice Most of borrower interest that may go to sImdUSD savers (50% since 2026-10-29).
    uint256 public constant MAX_SAVINGS_SHARE = 0.5e18;
    /// @notice Most a governed change may move `savingsShare`, either way (10 points). The genesis start value is exempt:
    /// it is a one-off choice before `seal`, not a change to a live rate savers rely on.
    uint256 public constant MAX_SAVINGS_STEP = 0.1e18;
    /// @notice `dust` (the minimum non-zero debt) is not versioned, yet it decides whether a liquidation is partial
    /// or a full close and whether a partial repayment is allowed. So it is bounded in source, whatever the line, and a
    /// governed raise may at most double it (or lift it to DUST_STEP from below): no single change turns every partial
    /// liquidation into a full close.
    uint256 public constant MAX_DUST = 5_000e18;
    uint256 public constant DUST_STEP = 100e18;

    uint8 public constant SET_RISK = 1;
    uint8 public constant ADD_ILK = 2;
    uint8 public constant SET_MIGRATOR_LINE = 3;
    uint8 public constant SET_BRIDGE = 4;
    uint8 public constant SET_SAVINGS_SHARE = 5;
    uint8 public constant SET_KEEPER = 6;
    uint8 public constant SET_KEEPER_CAP = 7;
    uint8 public constant OPEN_NOTE_SERIES = 8;
    /// @notice Seat type knobs, applied on the seat join: how many seats the type admits and per
    /// borrower, and which reward distributors a SeatAccount may call.
    uint8 public constant SET_SEAT_LIMITS = 9;
    uint8 public constant SET_SEAT_CLAIM = 10;
    uint256 public constant MAX_SEATS = 2000; // the collection's supply
    uint256 public constant MAX_SEATS_PER_BORROWER = 50;
    uint8 public constant MAX_CLAIM_RULE = 2;
    /// @notice The chain's global debt cap, on chains whose genesis capped it (`setGenesisChainLine`): Robinhood,
    /// and the mainnet beta (300k). The full MainnetConfig is uncapped. A capped chain stays capped; this only moves the line.
    uint8 public constant SET_CHAIN_LINE = 11;
    uint256 public constant MAX_CHAIN_LINE = 50_000_000e18;
    /// @notice Debt-cap groups (stock + SGOV types together within 25% of the chain): a type's group and a group's
    /// line (Σ debt + bad debt of its types), checked where debt is created. Group 0 = none. Lines are bounded like the chain's.
    uint8 public constant SET_GROUP = 12;
    uint8 public constant SET_GROUP_LINE = 13;
    /// @notice The peg hook's buffer target: keeper profit is kept as a below-peg buyer up to it, in the quote
    /// token's units (USDC: 6 decimals). Bounded by MAX_BUFFER_TARGET.
    uint8 public constant SET_BUFFER_TARGET = 14;
    uint256 public constant MAX_BUFFER_TARGET = 50_000e6;
    uint8 public constant MAX_GROUP = 7;

    /// @notice D1 (the depth rule): the IMD-collateral type's line is tied to IMD's market depth.
    ///   line x (1 + chop) + redeemCap  <=  k x depthIMD
    /// `depthIMD()` is MEASURED: `ImdDepth.depth()` = the 7-day low of Σ on-chain DepthSampler readings of
    /// the IMD exit pools to -15% (min'd with the swarm's attested depth once configured), capped by a POSTED ceiling
    /// `depthCap` (USD, 1e18; 0 = none) that the governor lowers at once (`postLowerDepth`) and raises or clears only
    /// through SET_DEPTH (48h). Chains without an ImdDepth fall back to the posted figure alone. `redeemCap` is the
    /// type's own `Risk.redeemCap`, the figure the Redeemer enforces per 2h window. Raising the line, chop or redeemCap
    /// (SET_RISK), raising k (SET_DEPTH_K) or posting a depth (SET_DEPTH) goes through the 48h timelock, and a raise of the
    /// line, chop, redeemCap or k applies only if the rule then holds (SET_DEPTH is not checked: a higher depth ceiling
    /// cannot worsen the rule). Lowering the line, k or the depth is instant by the governor; if that breaks the rule
    /// nothing is forced, `DepthRuleBroken` is emitted, and no raise applies until the rule holds again. A line below the
    /// type's debt stops new draws and in-cooldown rate changes (the line binds the cooldown premium); repay, redemption
    /// and liquidation carry on. Not checked at genesis (the beta opens the type at line 0). Because depth now MOVES, the rule
    /// also binds live: `risk(depthIlk).line` reads min(stored line, `depthLine()`), the largest line the rule allows at
    /// today's depth, so a fall in depth (or no samples at all: depth 0) stops new debt on the type at once, while repay,
    /// redemption and liquidation (which never check the line) carry on.
    uint8 public constant SET_DEPTH_K = 15;
    uint8 public constant SET_DEPTH = 16;
    /// @notice Several governed changes as ONE proposal (the Safe's day-7 batch: depth post + sIMD line + keeper cap): acts
    /// that must land together share it. Every item is validated with the batch at propose and again, in order, just before
    /// it applies; no nested batches. A batch holds the BATCH slot and locks every kind it carries (GovernedByKind): it
    /// cannot be proposed while one of those kinds is pending alone, nor can such a kind be proposed alone while it waits.
    uint8 public constant BATCH = 17;
    uint256 public constant MAX_BATCH = 8;
    /// @notice E2: IMD-collateral lines on OTHER chains (Robinhood's IMD type) sell into the same IMD market, so they
    /// count against this chain's rule: need += otherImdLines x (1 + otherImdChop). A posted number (no cross-chain
    /// messaging): raised only through the timelock (and only if the rule then holds), lowered instantly. Raise it HERE
    /// before raising the other chain's line.
    uint8 public constant SET_OTHER_IMD = 18;
    uint256 public constant MAX_DEPTH_K = 1e18;
    /// @notice F3's brake: while the Ledger's `unbacked()` (Σ bad debt less Treasury imdUSD) exceeds
    /// this fraction of the circulating supply, no type lends. Raised only through the timelock and never past
    /// MAX_UNBACKED_BRAKE; lowered at once by the governor (`lowerUnbackedBrake`). Genesis 1%.
    uint8 public constant SET_UNBACKED_BRAKE = 19;
    uint256 public constant MAX_UNBACKED_BRAKE = 0.05e18;
    /// @notice Most liquidation grace (`lull`) an NHI-linked type may give, in seconds: the Pricer returns
    /// min(NHI schedule, maxLull). 6h (v1's schedule) unless genesis set less (the beta: 0).
    /// Moved only through the timelock, inside MAX_LULL.
    uint8 public constant SET_MAX_LULL = 20;
    uint256 public constant MAX_LULL = 6 hours;
    /// @notice A type's BORROW price ceiling (Sky's capped OSM): borrowing and withdrawing (every adjust but a
    /// de-risking repay-and-withdraw) are measured at min(low, cap) (`Pricer.Quote.borrow`); a charged rate change is
    /// measured at `low` (it is not a borrow); liquidation health, liquidation prices and redemption payouts
    /// never see the cap, so it can only make borrowing harder and never shelters or condemns an open position. 0 = none.
    /// In the Pricer's price units (USD, 1e18, per 1e18 collateral units). Setting one where there is none, or lowering
    /// it, is instant by the governor (`lowerCap`); raising goes through SET_CAP (48h), at most x2 of the cap in force when
    /// it applies, or up to the live `low` when that is higher (a cap below the market shelters nothing, so a mistaken
    /// one is lifted to the market in one 48h step); it is never removed once set. `lowerCap` refuses a cap below 1/100 of
    /// the live `low` (a unit error: prices are per 1e18 RAW units, so an 8-decimal token reads ~1e10 x its per-token price).
    uint8 public constant SET_CAP = 21;
    /// @notice Liquidation size (Aave v4 target health factor): a fungible type's liquidation repays only what
    /// brings the position back to `mat + targetBuffer[ilk]` (plus the dust rule), not the whole debt. 0 = close in full
    /// (the v1/v2 rule). Set at genesis or through SET_TARGET (48h): it changes how much of a borrower's collateral one
    /// liquidation takes, in either direction, so neither way is instant.
    uint8 public constant SET_TARGET = 22;
    uint256 public constant MAX_TARGET_BUFFER = 1e18;
    /// @notice The edge sleeve's share of each edge type's interest (first loss is paid for). Lowered at once by
    /// the governor (`lowerEdgePremium`); raised through SET_EDGE_PREMIUM (48h), never past MAX_EDGE_PREMIUM.
    uint8 public constant SET_EDGE_PREMIUM = 23;
    uint256 public constant MAX_EDGE_PREMIUM = 0.5e18;
    /// @notice List an IMD exit-pool DepthSampler in ImdDepth (48h; removal is instant, `removeDepthSampler`),
    /// and set or clear the swarm depth leg (48h either way: adding a leg can only lower depth, but a broken one would
    /// read 0 for good, so it waits like a listing).
    uint8 public constant ADD_DEPTH_SAMPLER = 24;
    /// @notice Cover a type listed after launch with a Backstop sleeve. payload = (kind, ilk, edge, genesisLine,
    /// saleMax, saleSlope). Maps the type's token in the sleeve's PricerOracle (new tokens only), lists the type in the
    /// sleeve, and flags an edge type (first loss, premium, summed capacity). Uncovering is instant (`disableSleeveIlk`).
    uint8 public constant ADD_SLEEVE_ILK = 26;
    uint8 public constant SET_DEPTH_LEG = 25;
    /// @notice Value a sleeve's held token at 0 for deposit conversions while it has no price (a dead feed, a
    /// written-off stock), or undo that. payload = (kind, edge, token, on). Exits still pay it in kind (`Backstop.retire`).
    uint8 public constant RETIRE_SLEEVE_TOKEN = 27;

    /// @notice Hard bound on the peg keeper's outstanding mint. Governance sets `keeperCap` under it.
    uint256 public constant MAX_KEEPER_CAP = 10_000_000e18;
    /// @notice Largest discount a fee-note series may be sold at ("a fixed, small cost of capital").
    uint256 public constant MAX_NOTE_DISCOUNT_BPS = 1000;

    address public immutable wirer;
    address public ledger;
    address public token;
    bool public sealed_;
    /// @notice When `seal` ran (genesis types' launch time) and when each type was added: see `listedAt`.
    uint64 public sealedAt;
    mapping(bytes32 ilk => uint64) internal _addedAt;

    /// @notice D1's type (zero: no rule on this chain), k (1e18, <= MAX_DEPTH_K), the posted depth ceiling (USD, 1e18;
    /// 0 = none, or the whole depth on a chain without an ImdDepth) and the measured depth.
    bytes32 public depthIlk;
    uint64 public depthK;
    uint256 public depthCap;
    IImdDepth public imdDepth;
    uint256 public otherImdLines;
    uint64 public otherImdChop;

    mapping(bytes32 ilk => Config) internal _config;
    mapping(bytes32 ilk => Risk) internal _risk;
    bytes32[] public ilks;

    /// @notice Most imdUSD v1 the Migrator may hold (= most imdUSD it may mint against v1).
    uint256 public migratorLine;

    /// @notice The sImdUSD vault, set once at genesis (zero = no savings rate), and the share of every
    /// interest accrual the Ledger mints to it instead of to the Treasury.
    address public savings;
    uint64 public savingsShare;

    /// @notice Most imdUSD the peg keeper may have outstanding (minted and not yet bought back and burned).
    uint256 public keeperCap;
    /// @notice Keeper profit the peg hook keeps as its below-peg buffer before paying the Treasury. 0 at genesis.
    uint256 public bufferTarget;

    /// @notice The fee-notes contract, set once at genesis; a series is opened only through the timelock.
    address public notes;

    /// @notice Most debt (Σ recorded debt + bad debt, every type) the Ledger may carry on this chain, when `chainCapped`.
    /// Capped only at genesis and never uncapped: the timelock can move the number, inside MAX_CHAIN_LINE, but not remove it.
    uint128 public chainLine;
    bool public chainCapped;

    mapping(bytes32 ilk => uint8) public groupOf;
    mapping(uint8 group => uint128) public groupLine;

    /// @notice The unbacked-supply fraction past which the Ledger refuses new debt (SET_UNBACKED_BRAKE, 1e18).
    uint64 public unbackedBrake = 0.01e18;

    /// @notice Cap on the NHI-derived liquidation grace (SET_MAX_LULL, seconds). See MAX_LULL.
    uint64 public maxLull = uint64(MAX_LULL);

    /// @notice Per type liquidation target buffer over `mat` (SET_TARGET). 0 = liquidations close in full.
    mapping(bytes32 ilk => uint64) public targetBuffer;
    /// @notice The two Backstop sleeves: `blue` bids on blue types, `edge` on edge types and takes their first
    /// loss. Zero = no standing bid on this chain. Set once, before the seal.
    address public blueBackstop;
    address public edgeBackstop;
    /// @notice Share of an edge type's interest minted to the edge sleeve (SET_EDGE_PREMIUM).
    uint64 public edgePremium;
    /// @notice Types whose standing bid and first loss are the edge sleeve's, and whose SUMMED debt the sleeve bounds.
    mapping(bytes32 ilk => bool) public edgeIlk;
    bytes32[] public edgeIlks;

    /// @notice Per type borrow price ceiling (SET_CAP). 0 = none.
    mapping(bytes32 ilk => uint256) public cap;

    /// @notice Versioned liquidation risk. A type's `mat` and `chop` are kept per version; a position stays on
    /// the version it last took on risk under, until a newer version reaches its `bindAt`. A change that only LOWERS mat
    /// and chop (kinder to borrowers) binds at once; any other change binds RISK_GRACE later, so open positions are never
    /// made liquidatable by a governance change without a week to repair. NHI-linked types keep a live mat (only chop
    /// is versioned): NHI is a market signal, not a governance change, and its own lull applies.
    struct LiqRisk {
        uint64 mat;
        uint64 chop;
        uint64 bindAt;
    }

    uint256 public constant RISK_GRACE = 7 days;
    mapping(bytes32 ilk => LiqRisk[]) internal _versions;

    event RiskVersioned(bytes32 indexed ilk, uint256 version, uint256 mat, uint256 chop, uint256 bindAt);

    error Unauthorized();
    error AlreadyWired();
    error Sealed();
    error UnknownKind();
    error IlkExists();
    error UnknownIlk();
    error BadConfig();
    error OutOfBounds();
    error DepthRuleFails(uint256 need, uint256 room);

    event IlkAdded(bytes32 indexed ilk, Config config);
    event RiskSet(bytes32 indexed ilk, Risk risk);
    event MigratorLineSet(uint256 line);
    event SavingsSet(address vault, uint256 share);
    event KeeperCapSet(uint256 cap);
    event BufferTargetSet(uint256 target);
    event NotesSet(address notes);
    event NoteSeriesOpened(uint256 indexed id, uint64 tenor, uint32 discountBps, uint128 cap);
    event SeatLimitsSet(address join, uint256 maxSeats, uint256 perBorrower);
    event ChainLineSet(uint256 line);
    event SeatClaimRuleSet(address join, address target, bytes4 selector, uint8 rule);
    event GroupSet(bytes32 indexed ilk, uint8 group);
    event GroupLineSet(uint8 indexed group, uint256 line);
    event DepthRuleSet(bytes32 indexed ilk, uint256 k, uint256 depth);
    event DepthKSet(uint256 k);
    event DepthPosted(uint256 depth);
    event ImdDepthSet(address imdDepth);
    event OtherImdSet(uint256 lines, uint256 chop);
    /// @notice The D1 rule no longer holds (after a lowering): ops alert; the Safe lowers the line or waits for depth.
    event DepthRuleBroken(uint256 need, uint256 room);
    event UnbackedBrakeSet(uint256 brake);
    event MaxLullSet(uint256 lull);
    event CapSet(bytes32 indexed ilk, uint256 cap);
    event BackstopsSet(address blue, address edge, uint256 premium);
    event EdgeIlkSet(bytes32 indexed ilk);
    event SleeveIlkAdded(bytes32 indexed ilk, bool edge, uint256 genesisLine);
    event SleeveIlkDisabled(bytes32 indexed ilk, bool edge);
    event TargetSet(bytes32 indexed ilk, uint256 buffer);
    event EdgePremiumSet(uint256 premium);

    constructor(address governor_, address wirer_) GovernedByKind(governor_) {
        if (wirer_ == address(0)) revert ZeroAddress();
        wirer = wirer_;
    }

    /// @dev A batch locks BATCH and each item's kind (items are validated, and nested batches refused, in `_validate`).
    function _kindsOf(bytes memory payload) internal pure override returns (uint256 locks) {
        uint8 kind = abi.decode(payload, (uint8));
        locks = uint256(1) << kind;
        if (kind == BATCH) {
            (, bytes[] memory items) = abi.decode(payload, (uint8, bytes[]));
            for (uint256 i; i < items.length; ++i) locks |= uint256(1) << abi.decode(items[i], (uint8));
        }
    }
    /// @dev payload (both kinds) = (kind, ilk, group, line). SET_GROUP moves `ilk` into `group` (0 takes it out) and sets that
    /// group's line; SET_GROUP_LINE (ilk ignored, pass 0) only sets the line. A group's line is bounded like the chain line.
    function _checkGroup(bytes32 ilk, uint8 group, uint256 line) internal view {
        if (ilk != bytes32(0) && !exists(ilk)) revert UnknownIlk();
        if (group > MAX_GROUP || line > MAX_CHAIN_LINE || (group == 0 && line != 0)) revert OutOfBounds();
    }
    function _setGroup(bytes32 ilk, uint8 group, uint256 line) internal {
        if (ilk != bytes32(0)) {
            groupOf[ilk] = group;
            emit GroupSet(ilk, group);
        }
        if (group != 0) {
            groupLine[group] = uint128(line);
            emit GroupLineSet(group, line);
        }
    }
    /// @dev A seat knob may only land on a join wired to this system's Ledger.
    function _checkSeatJoin(address join) internal view {
        if (join.code.length == 0 || IJoinView(join).ledger() != ledger) revert BadConfig();
    }
    function _pushVersion(bytes32 ilk, uint256 mat, uint256 chop, uint256 bindAt) internal {
        _versions[ilk].push(LiqRisk(uint64(mat), uint64(chop), uint64(bindAt)));
        emit RiskVersioned(ilk, _versions[ilk].length - 1, mat, chop, bindAt);
    }

    function _addIlk(bytes32 ilk, Config memory c, Risk memory r) internal {
        _config[ilk] = c;
        _risk[ilk] = r;
        _pushVersion(ilk, r.mat, r.chop, 0);
        ilks.push(ilk);
        _addedAt[ilk] = uint64(block.timestamp);
        emit IlkAdded(ilk, c);
        emit RiskSet(ilk, r);
    }
    function _checkIlk(bytes32 ilk, Config memory c, Risk memory r) internal view {
        if (ledger == address(0)) revert BadConfig();
        if (ilk == bytes32(0) || exists(ilk)) revert IlkExists();
        if (c.token.code.length == 0 || c.join.code.length == 0) revert BadConfig();
        if (IJoinView(c.join).token() != c.token || IJoinView(c.join).ledger() != ledger) revert BadConfig();
        if (address(c.median).code.length == 0 || address(c.spot).code.length == 0) revert BadConfig();
        if (address(c.nhi) != address(0) && address(c.nhi).code.length == 0) revert BadConfig();
        if (c.yieldRate != address(0) && c.yieldRate.code.length == 0) revert BadConfig();
        if (c.pegAggregator != address(0) && c.pegAggregator.code.length == 0) revert BadConfig();
        if (address(c.liveSpot) != address(0) && address(c.liveSpot).code.length == 0) revert BadConfig();
        _checkRisk(c, r);
    }
    function _checkRisk(Config memory c, Risk memory r) internal pure {
        if (r.chop < MIN_CHOP || r.chop > MAX_CHOP) revert OutOfBounds();
        if (uint256(r.cut) + r.chip > 1e18) revert OutOfBounds();
        if (r.rateFloor > MAX_RATE_FLOOR || r.yieldFee > MAX_YIELD_FEE) revert OutOfBounds();
        if (r.skew < MIN_SKEW || r.skew > MAX_SKEW) revert OutOfBounds();
        if (r.pegFloor != 0 && (r.pegFloor < MIN_PEG_FLOOR || r.pegFloor > 1e18)) revert OutOfBounds();
        if (r.dust > MAX_DUST || (r.line != 0 && r.dust > r.line)) revert OutOfBounds();
        if (address(c.nhi) == address(0)) {
            if (r.mat < MIN_MAT || r.mat > MAX_MAT) revert OutOfBounds();
            // A position liquidated right at `mat` must be able to pay the whole penalty from collateral,
            // or every liquidation at the line becomes bad debt.
            if (r.mat < 1e18 + uint256(r.chop)) revert OutOfBounds();
        }
        // The fee on yield needs something to harvest: a capped share rate, or (seats) rewards reported by the join.
        if (r.yieldFee != 0 && c.yieldRate == address(0) && !c.auction) revert OutOfBounds();
        // A yield-harvested type is sold by units in the Ledger; the two liquidation paths do not mix.
        if (c.auction && c.yieldRate != address(0)) revert BadConfig();
        if (r.redeemFloor < MIN_REDEEM_FLOOR || r.redeemFloor > MAX_REDEEM_FLOOR) revert OutOfBounds();
        if (r.redeemDivisor == 0 || r.redeemDivisor > MAX_REDEEM_DIVISOR) revert OutOfBounds();
        // A type priced from a manipulable pool can never be uncapped: the window cap is what keeps a
        // push-and-hold unprofitable. Chainlink types may be uncapped (0).
        if (address(c.liveSpot) != address(0) && r.redeemCap == 0) revert OutOfBounds();
    }
    /// @dev The type's live `low` as the Pricer computes it (fresh median; min with a fresh spot that agrees within skew),
    /// 0 while the median is stale, zero or unreadable. What SET_CAP may raise a cap to, and lowerCap's unit-error
    /// floor. A reverting feed must not block the instant cap (read 0: the floor does not apply), as the Ledger's quote read
    /// tolerates one.
    function _liveLow(bytes32 ilk) internal view returns (uint256) {
        Config storage c = _config[ilk];
        uint256 m = _freshValue(c.median);
        uint256 s = m == 0 ? 0 : _freshValue(c.spot);
        return s != 0 && s < m && (m - s) * 1e18 / m <= _risk[ilk].skew ? s : m;
    }
    /// @dev The feed's value, 0 if it is stale, zero or reverts.
    function _freshValue(IFeed f) private view returns (uint256 v) {
        try f.latestValue() returns (uint256 x, uint64) {
            try f.isStale() returns (bool stale) {
                if (!stale) v = x;
            } catch {}
        } catch {}
    }
    function _setCap(bytes32 ilk, uint256 cap_) internal {
        cap[ilk] = cap_;
        emit CapSet(ilk, cap_);
    }
    /// @notice The rule's two sides now: need = line x (1 + chop) + redeemCap, room = k x depth. Holds iff need <= room.
    function depthRule() public view returns (bool holds, uint256 need, uint256 room) {
        if (depthIlk == bytes32(0)) return (true, 0, 0);
        need = _depthNeed(_risk[depthIlk]);
        room = uint256(depthK) * depthIMD() / 1e18;
        holds = need <= room;
    }
    /// @notice The depth the rule multiplies (USD, 1e18): min(measured, posted ceiling); the posted figure alone where
    /// this chain has no ImdDepth. Never reverts (ImdDepth never does; a failed read counts as 0).
    function depthIMD() public view returns (uint256 d) {
        if (address(imdDepth) == address(0)) return depthCap;
        try imdDepth.depth() returns (uint256 v) {
            d = v;
        } catch {
            return 0;
        }
        if (depthCap != 0 && depthCap < d) d = depthCap;
    }
    /// @notice The largest line the depth-gated type may have at today's depth: line x (1 + chop) + redeemCap + the
    /// other chains' term <= k x depth, solved for line (0 when depth does not even cover the fixed terms).
    function depthLine() public view returns (uint256) {
        if (depthIlk == bytes32(0)) return type(uint256).max;
        Risk memory r = _risk[depthIlk];
        uint256 room = uint256(depthK) * depthIMD() / 1e18;
        uint256 fixed_ = uint256(r.redeemCap) + otherImdLines * (1e18 + otherImdChop) / 1e18;
        if (room <= fixed_) return 0;
        return (room - fixed_) * 1e18 / (1e18 + r.chop);
    }
    function _depthNeed(Risk memory r) internal view returns (uint256) {
        return uint256(r.line) * (1e18 + r.chop) / 1e18 + r.redeemCap + otherImdLines * (1e18 + otherImdChop) / 1e18;
    }
    function _flagDepth() internal {
        (bool holds, uint256 need, uint256 room) = depthRule();
        if (!holds) emit DepthRuleBroken(need, room);
    }
    /// @dev A change that raises the need (or k) applies only if the rule holds after it.
    function _requireDepth() internal view {
        (bool holds, uint256 need, uint256 room) = depthRule();
        if (!holds) revert DepthRuleFails(need, room);
    }
    function exists(bytes32 ilk) public view returns (bool) {
        return _config[ilk].token != address(0);
    }
}
