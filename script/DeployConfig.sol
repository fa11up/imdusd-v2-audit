// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ParametersBase} from "../src/ParametersBase.sol";
import {Parameters} from "../src/Parameters.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";

/// @notice What a deployment is made of, as data. The script deploys exactly this and nothing else, and
/// the fork test checks the result against the same struct.
///
/// FEEDS are a list of nodes; a node may use earlier nodes by index (a ProductFeed of two, a RateFeed
/// over one), so a price like "sIMD share rate x (v1 IMD/ETH spot x Chainlink ETH/USD)" is three nodes
/// with no special case in the script.
library DeployTypes {
    uint8 internal constant NONE = type(uint8).max;

    /// `source` is an already-deployed IFeed. Stage 2 refuses one that does not PROVE a capped stale allowance
    /// (`MAX_ALLOWANCE_BPS() <= 20,000`: v1's feeds grow to 100x). No mainnet config uses this any more.
    uint8 internal constant EXISTING = 0;
    uint8 internal constant CHAINLINK = 1; // ChainlinkFeed(source, decimals, maxAge)
    uint8 internal constant PRODUCT = 2; // ProductFeed(feeds[a], feeds[b])
    uint8 internal constant RATE = 3; // RateFeed(source, selector, passOneE18, feeds[a], cap)
    uint8 internal constant LIVE_POOL = 4; // LivePoolPrice(source = PoolManager, poolId, passOneE18 = base is token0)
    // Swarm-attested feeds of the MAINNET questions (src/feeds/SwarmFeeds.sol): new SwarmXFeed(maxAge, cap = maxDeviationBps).
    // On mainnet as on a chain with no IMD market. Deployed EMPTY (priced 0 until the first relay).
    uint8 internal constant SWARM_PRICE = 5;
    uint8 internal constant SWARM_SPOT = 6;
    uint8 internal constant SWARM_NHI = 7;
    // The seat type's two attested legs (src/feeds/SwarmFeeds.sol, recipe nft-sale-median): new SwarmSeatXFeed(maxAge, cap).
    // Deployed EMPTY: the first value of each is bought and relayed after the deploy.
    uint8 internal constant SWARM_SEAT_MEDIAN = 8;
    uint8 internal constant SWARM_SEAT_SPOT = 9;

    struct FeedNode {
        uint8 kind;
        address source;
        uint8 decimals;
        uint256 maxAge;
        bytes4 selector;
        bool passOneE18;
        uint256 cap;
        uint8 a;
        uint8 b;
        bytes32 poolId; // LIVE_POOL only
    }

    struct IlkSpec {
        bytes32 ilk;
        address token;
        uint8 median; // feed node index
        uint8 spot; // feed node index
        uint8 nhi; // feed node index or NONE
        uint8 yieldRate; // feed node index (a RATE node) or NONE
        address pegAggregator;
        uint8 liveSpot; // feed node index or NONE (redemption payout leg only)
        bool redeemable;
        ParametersBase.Risk risk;
    }

    /// @notice PegLPVault on the v2 peg pool + PegHook. Needs `poolManager` (the peg hook).
    /// @notice Peg positions, a type whose collateral is PegLPVault shares (needs `lpVault`). `risk` is the
    /// type's risk; it is not redeemable (a redeemer would receive LP shares) and is not the depth-gated type.
    struct PegPositionSpec {
        bool enabled;
        bytes32 ilk;
        ParametersBase.Risk risk;
    }

    struct LpVaultSpec {
        bool enabled;
        int24 band; // ticks either side of the peg tick (100 = the at-peg band, ~$0.99-$1.01)
    }

    /// @notice One DepthSampler per IMD exit pool (v4 only: the sampler reads a v4 PoolManager). `feed0` /
    /// `feed1` are node indices into `feeds` for the two currencies' USD prices; NO_FEED = a stablecoin at $1. `poolId`
    /// is the expected id of the key (the stage refuses a key that hashes elsewhere).
    struct SamplerSpec {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes32 poolId;
        uint256 feed0;
        uint256 feed1;
        uint256 bandBps;
        uint24 maxDeviationTicks;
        uint256 maxSteps;
        bool soldIsToken0;
    }

    uint256 internal constant NO_FEED = type(uint256).max;

    /// @notice The measured IMD depth (ImdDepth + its samplers), deployed and listed at genesis (stage 4).
    struct DepthSpec {
        bool enabled;
        SamplerSpec[] samplers;
    }

    /// @notice LoopVault on one genesis type that has a live pool leg (sIMD).
    struct LoopSpec {
        bool enabled;
        bytes32 ilk;
    }

    /// @notice The seat type: SeatJoin + SeatFeed + SeatSpotLeg, registered at genesis as an auction type.
    /// The join can exist without the type, the feed cannot (it anchors on the live median at construction), so the
    /// whole module is one switch.
    struct SeatSpec {
        bool enabled;
        bytes32 ilk;
        address nft; // the identity.md collection
        address adapter; // the plane's Adapter8004
        uint256 maxSeats;
        uint256 perBorrower;
        uint8 median; // feed node: attested 7-day p25 sale median, wei per seat; its figure = distinct seats sold
        uint8 spot; // feed node: attested 1-day spot (median5), wei per seat
        uint8 ethUsd; // feed node: USD per 1e18 wei
        ParametersBase.Risk risk;
    }

    /// @notice The Compound DEX pool for two ERC-4626 vaults, fees and yield share to the v2 Treasury.
    struct DexSpec {
        bool enabled;
        address vaultA;
        address vaultB;
        /// @dev The opening price (token1 per token0, underlying units, Q64.96). 0 = read `marketPoolId`'s slot0 on
        /// `poolManager` at the deploy block (same token order: both pools sort the underlyings).
        uint160 sqrtPriceX96;
        bytes32 marketPoolId;
    }

    /// @notice What makes a deployment chain-specific. Mainnet: all off.
    struct ChainSpec {
        uint256 chainId; // the script refuses any other chain; 0 = any (offline systems)
        bool pulse; // deploy a Pulse and give it to the Ledger (sequencer-outage grace)
        uint64 pulseGap;
        uint64 pulseGrace;
        bool capped; // set Parameters.chainLine at genesis (never uncapped afterwards)
        uint256 chainLine;
    }

    /// @notice imdUSD's LayerZero path (src/bridge/ImdBridge.sol). Deployed by the script; becoming the token's bridge minter
    /// (SET_BRIDGE) and opening each path (peer + limits, ImdBridge.SET_PATH) are the Safe's timelocked acts afterwards.
    struct BridgeSpec {
        bool enabled;
        address endpoint; // LayerZero EndpointV2
        address guardian; // may pause a path instantly; zero = only the Safe
    }

    /// @notice One Robinhood stock-token type: the token pooled in a StockVault, priced by its Chainlink
    /// equity feed inside the NYSE session (MarketHoursFeed) x the vault's capped share rate (RateFeed), sold by a USDG Dutch
    /// auction (StockJoin). Not redeemable.
    struct StockSpec {
        bytes32 ilk;
        address stock; // the canonical token (docs.robinhood.com/chain/contracts, read from Robinhood's asset registry)
        address aggregator; // its Chainlink feed (reference-data-directory feeds-robinhood-mainnet.json)
        uint256 maxAge; // dead-feed bound inside the session (the feeds' heartbeat is 24h)
        uint256 auctionTime; // seconds for the auction factor to fall from 1 to auctionFloor
        uint64 auctionFloor; // 1e18
        ParametersBase.Risk risk;
    }

    /// @notice The stock-token module: one calendar for every type, their debt-cap group and the settlement stable.
    struct StocksSpec {
        StockSpec[] types;
        address usdg; // what auctions are paid in
        uint32[] closedDays; // NYSE full-day closures, as UTC day numbers (timestamp / 1 days)
        uint32[] earlyDays; // NYSE 13:00 closes
        uint8 group; // Parameters debt-cap group shared by every stock / SGOV type
        uint256 groupLine; // that group's line
        uint256 rateCap; // RateFeed growth cap on each vault's share rate (per second, 1e18)
    }

    /// @notice One type a Backstop sleeve bids on. `genesisLine` = the edge bootstrap allowance (ignored on blue).
    /// `saleMax` (collateral raw units) refills over a day: the most of this collateral the allocator may sell per day.
    struct SleeveIlk {
        bytes32 ilk;
        bool edge;
        uint128 genesisLine;
        uint128 saleMax;
    }

    /// @notice The two sleeves (blue, edge), their PricerOracle and the Allocator (their seller). Fungible types only: seat
    /// (auction) and stock types keep their Dutch auctions. `freezer` = the Safe on mainnet;
    /// nothing on chain refuses zero.
    struct BackstopSpec {
        bool enabled;
        SleeveIlk[] ilks;
        uint64 edgePremium;
        uint16 maxSlippageBps;
        address freezer;
    }

    struct Config {
        address governor; // the governance Safe: proposes and cancels on Parameters and Treasury
        address v1; // imdUSD v1, for the Migrator
        uint256 flashCap;
        uint256 migratorLine;
        /// @dev True deploys with migrator line 0 (no v1 -> v2 conversion at genesis; it opens only
        /// through the Safe's timelocked SET_MIGRATOR_LINE). False: max(migratorLine, 2 x v1 supply).
        bool migratorClosed;
        uint64 savingsShare; // savers' share of interest, 1e18
        address poolManager; // Uniswap v4 PoolManager for the imdUSD v2 / USDC peg pool (zero: no peg hook)
        address pegQuote; // USDC
        /// @dev The peg hook's quote gate (Job 2): the quote stablecoin's Chainlink USD aggregator and its max age.
        address pegQuoteFeed;
        uint256 pegQuoteFeedMaxAge;
        /// @dev D1: the depth-gated IMD-collateral type (zero: no rule), k and the first posted depth (USD, 1e18).
        bytes32 depthIlk;
        uint64 depthK;
        uint256 depthIMD;
        /// @dev E2: other chains' IMD-collateral lines counted against this chain's rule, and their chop.
        uint256 otherImdLines;
        uint64 otherImdChop;
        /// @dev true: Parameters.maxLull = 0 at genesis, so NHI-linked types (sIMD) have no liquidation grace (the beta).
        /// false: v1's 6h schedule. Moved later only through the timelock (SET_MAX_LULL).
        bool graceOff;
        FeedNode[] feeds;
        IlkSpec[] ilks;
        // Optional modules (the seat type is on in the beta: plane PR #701 made its recipe live, 2026-10-26).
        LpVaultSpec lpVault;
        LoopSpec loopVault;
        SeatSpec seats;
        DexSpec dex;
        ChainSpec chain;
        BridgeSpec bridge;
        StocksSpec stocks; // Robinhood only; empty elsewhere
        DepthSpec depth; // mainnet only (the k-rule's chain)
        BackstopSpec backstop; // the standing bid
        PegPositionSpec pegPositions; // needs lpVault
    }
}

/// @notice D1/E1: the largest whole-imdUSD line the depth rule admits:
///   line x (1 + chop) + redeemCap + otherLines x (1 + otherChop) <= k x depth   (Parameters.depthRule)
/// capped at `target`. A line in a config is a TARGET; the line set is this, so it grows only as the posted depth does.
library DepthMath {
    function fit(uint256 target, uint256 k, uint256 depth, uint256 chop, uint256 redeemCap, uint256 otherLines, uint256 otherChop)
        internal
        pure
        returns (uint128)
    {
        uint256 room = k * depth / 1e18;
        uint256 used = redeemCap + otherLines * (1e18 + otherChop) / 1e18;
        uint256 l = room > used ? (room - used) * 1e18 / (1e18 + chop) : 0;
        l = l / 1e18 * 1e18;
        return uint128(l < target ? l : target);
    }
}

/// @notice Ethereum mainnet. Addresses from test/fork/MainnetAddresses.sol (each read on chain 2026-10-16).
/// Debt ceilings, the migrator line and the flash cap are PROPOSED values, subject to governance sign-off.
library MainnetConfig {
    /// @notice A peg position holds imdUSD + USDC at ~2x its imdUSD debt and is solvent in imdUSD terms at every
    /// price (below the band its shares are all imdUSD, which repays the debt at par; above it, ~2x the debt in USDC), so
    /// it needs no market oracle and a low mat. 125% (not 110%: it bounds own-USDC leverage, and no zap open needs less) covers the ~1% a pool push can move the share value and a USDC
    /// depeg to ~$0.80 on the USDC half. The rate floor is low (the holder supplies the peg's depth), the line is its own.
    /// A USDC DEPEG IS NOT THE MIXED CASE: it drives the pool above the band (holders sell USDC for imdUSD), so positions go all
    /// USDC and the whole value follows USDC, not just half. From test_R3_crTable, a position opened at the gate's low edge (the
    /// tightest), pool above the band: 134.35% at $1, 131.66% at $0.98, 127.63% at $0.95, 120.92% at $0.90, 107.48% at $0.80, so it is
    /// liquidatable from about $0.93. Opened at the centre: 200.43% at $1, 160.35% at $0.80. Opened at the high edge: 393.47%, 314.78%.
    function pegRisk(uint128 line) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: 1.25e18, // a zap position opens at 134.09% or more inside the two-sided gate (25-75% USDC) at the floor rate, 131.61% with the average rate at max; own-USDC leverage 3.9x debt over own USDC (4.9x collateral over equity)
            chop: 0.05e18,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: 0.005e18,
            yieldFee: 0,
            skew: 0.01e18,
            pegFloor: 0.98e18,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 1,
            redeemCap: 0
        });
    }

    // tokens
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant METAMORPHO_STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address internal constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    address internal constant V1_IMDUSD = 0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25;
    // Chainlink
    address internal constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CL_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address internal constant CL_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address internal constant CL_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address internal constant CL_CBBTC_USD = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    address internal constant CL_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant CL_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address internal constant CL_USDS_USD = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;
    // IMD's deepest market: Uniswap v4 native ETH / IMD, fee 10000, tickSpacing 200, no hook (~$1.9M, 2026-10-18).
    // currency0 = native ETH, so IMD is token1.
    address internal constant UNIV4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant IMD_ETH_POOL_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;

    address internal constant GOVERNANCE_SAFE = 0xbeFd108085613662356aa26A2466Ad3426DA9C32;

    // The Compound DEX pair: sIMD and a second ERC-4626 staked token, opened at that token's existing v4 pool price against
    // IMD (fee 12500, tickSpacing 60, hook = the plane's PoolInitializationGuard 0x784F…6000; IMD is token1).
    address internal constant SINFER = 0x5e3B440156Ce928Fda68b2378578dC9333846cE4;
    bytes32 internal constant INFER_IMD_POOL_ID = 0x1f03dd2c202cf17b58305b73ae2f8b3143e9c056ed9c9e8dbd4924b350431e95;

    // identity.md seats (the nft-sale-median recipe is live on the plane since PR #701, 2026-10-26).
    address internal constant IDMD = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address internal constant IMD_AGENT_ADAPTER = 0xde152AfB7db5373F34876E1499fbD893A82dD336; // IMD6900.IMD_AGENT_ADAPTER()

    bytes4 internal constant CONVERT = bytes4(keccak256("convertToAssets(uint256)"));
    uint256 internal constant CAP = uint256(0.001e18) / 1 days; // share-rate growth cap, 0.1%/day

    // feed node indices
    uint8 internal constant F_ETH = 0;
    uint8 internal constant F_STETH = 1;
    uint8 internal constant F_WSTETH = 2;
    uint8 internal constant F_CBBTC = 3;
    uint8 internal constant F_BTC = 4;
    uint8 internal constant F_WBTC_BTC = 5;
    uint8 internal constant F_WBTC = 6;
    uint8 internal constant F_USDS = 7;
    uint8 internal constant F_SUSDS = 8;
    uint8 internal constant F_USDC = 9;
    uint8 internal constant F_SUSDC = 10;
    uint8 internal constant F_USDT = 11;
    /// @dev The sIMD legs and NHI are v2's own SwarmFeed leaves (2x stale cap, question binding), answering the
    /// same swarm questions as v1's feeds, not v1's deployed feeds. Wei of ETH per 1e18 IMD.
    uint8 internal constant F_IMD_MEDIAN = 12;
    uint8 internal constant F_IMD_SPOT = 13;
    uint8 internal constant F_IMD_USD_SPOT = 14;
    uint8 internal constant F_SIMD_SPOT = 15;
    uint8 internal constant F_NHI = 16;
    uint8 internal constant F_IMD_LIVE = 17; // wei ETH per 1e18 IMD, this block
    uint8 internal constant F_IMD_USD_LIVE = 18;
    uint8 internal constant F_SIMD_LIVE = 19;
    /// @dev D4: wstETH's second leg, ETH/USD x stEthPerToken (the underlying's own feed, not stETH/USD).
    uint8 internal constant F_WSTETH_ETH = 20;
    /// @dev The sIMD median: IMD/ETH median x ETH/USD x sIMD's share rate (what v1's SharePriceFeed computed from v1's legs).
    uint8 internal constant F_IMD_USD_MEDIAN = 21;
    uint8 internal constant F_SIMD_MEDIAN = 22;
    /// @dev v1's lifetimes and caps (1 h and 20% on the prices, 1 day and 20% on NHI).
    uint256 internal constant IMD_LEG_MAX_AGE = 1 hours;
    uint256 internal constant NHI_MAX_AGE = 1 days;
    uint256 internal constant SWARM_CAP_BPS = 2_000;
    /// @dev D1 defaults: k 0.8 on the 7-day minimum of IMD depth to -15%. The depth posted at
    /// genesis is the 7-day low measured 2026-10-29 (block 26295670): $80.1k. Re-measure before posting.
    uint64 internal constant DEPTH_K = 0.8e18;
    uint256 internal constant DEPTH_IMD = 80_100e18;
    /// @dev E1: the full config's sIMD line is a TARGET: the line set is min(100k, what D1 admits at the posted depth).
    /// At $80.1k that is 33,733; 100k needs a posted depth of about $179.5k.
    uint256 internal constant SIMD_LINE_TARGET = 100_000e18;
    uint64 internal constant SIMD_CHOP = 0.2e18;
    uint128 internal constant SIMD_REDEEM_CAP = 20_000e18;

    // IMD's v4 exit pools (measured 2026-10-29: 0xb07d 77% of depth to -15%, POOL4 7%, the v1 imdUSD/IMD pool
    // ~0.5%). The two v3 pools (USDC/IMD ~11%, USDT/IMD ~4%) are left out: DepthSampler reads v4 only, and leaving depth
    // out only lowers the line (conservative).
    address internal constant IMD_TOKEN = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    bytes32 internal constant POOL4_ID = 0x415829f72e9f54531c26eae76f107618540e898a45d6ae35959e143f5faca704;
    /// @dev The Treasury's v1 imdUSD/IMD pool, tickSpacing 10, opened by the Safe 2026-11-09 (block 26,379,044). It replaces the
    /// spacing-60 pool 0x5e0b6d80..6c8e, stranded at IMD 4.17 imdUSD with nothing in range (the sampler refused PoolOffReference).
    bytes32 internal constant IMDUSD_V1_IMD_POOL_ID = 0x617d697bdafcfd21b137e811149af6e13328d644ac18f189ffd54e079aefb472;

    /// @dev Band 1500 = -15%, the analysis' definition. The IMD reference is the LIVE pool price x ETH/USD (F_IMD_USD_LIVE), on
    /// purpose, not an attested leg: the attested legs are bought on demand and are stale most hours, and DepthSampler refuses to
    /// sample on a stale feed, so an attested reference would stop sampling and read as zero depth. The live reference can be
    /// pushed with no capital held: push, sample, push back in one transaction (between two unlocks) or one bundle, for the
    /// pool fee both ways, ~2% of the push (audit wave 1; DepthSampler header). The 4th-lowest bucket and 4th-lowest hour
    /// (ImdDepth) must be moved for it to count, so four pushed hours (~$200 each for 25%) lower the sIMD line for ~8 days.
    /// Accepted for the beta (audit wave 1); it can only lower the sIMD line. Sampler 0's
    /// reference is its own pool's price, so its `maxDeviationTicks` guard can never fire; samplers 1 and 2 are measured
    /// against pool 0xb07d's price.
    function _depthSamplers(DeployTypes.Config memory c) private pure {
        c.depth.enabled = true;
        c.depth.samplers = new DeployTypes.SamplerSpec[](3);
        c.depth.samplers[0] = _sampler(address(0), IMD_TOKEN, 10_000, 200, address(0), IMD_ETH_POOL_ID, F_ETH);
        c.depth.samplers[1] = _sampler(address(0), IMD_TOKEN, 10_000, 60, POOL4_HOOK, POOL4_ID, F_ETH);
        c.depth.samplers[2] =
            _sampler(V1_IMDUSD, IMD_TOKEN, 3_000, 10, address(0), IMDUSD_V1_IMD_POOL_ID, DeployTypes.NO_FEED);
    }

    function _sampler(address c0, address c1, uint24 fee, int24 spacing, address hooks, bytes32 id, uint256 feed0)
        private
        pure
        returns (DeployTypes.SamplerSpec memory)
    {
        return DeployTypes.SamplerSpec({
            currency0: c0,
            currency1: c1,
            fee: fee,
            tickSpacing: spacing,
            hooks: hooks,
            poolId: id,
            feed0: feed0,
            feed1: F_IMD_USD_LIVE,
            bandBps: 1_500,
            maxDeviationTicks: 400,
            maxSteps: 4_096,
            soldIsToken0: false
        });
    }

    /// @notice The sIMD line D1 admits at `depth` (k 0.8, Robinhood's IMD line counted: E2), capped at `target`.
    function simdLineFor(uint256 target, uint256 depth) internal pure returns (uint128) {
        return DepthMath.fit(
            target, DEPTH_K, depth, SIMD_CHOP, SIMD_REDEEM_CAP, RobinhoodConfig.IMD_LINE, RobinhoodConfig.IMD_CHOP
        );
    }

    function get() internal pure returns (DeployTypes.Config memory c) {
        c.governor = GOVERNANCE_SAFE;
        c.v1 = V1_IMDUSD;
        c.flashCap = 10_000_000e18;
        // FLOOR of the migrator line; the script sets max(floor, 2 x v1 supply at the deploy block) (Deploy.migratorLineFor).
        // v1 supply: 56,631.59 on 2026-10-18, 110,900.44 on 2026-10-19. Later raises: the Safe, via the 48h timelock.
        c.migratorLine = 150_000e18;
        // The peg hook at genesis: keeper minter wired, keeperCap 0, bufferTarget 0. Setting the buffer
        // target (5,000 USDC) and raising the cap are governance acts after launch.
        c.poolManager = UNIV4_POOL_MANAGER;
        c.pegQuote = USDC;
        // USDC/USD: "USDC / USD", 8 decimals, 24h heartbeat (read 2026-10-28: 0.99971556, updated 7.8h before)
        c.pegQuoteFeed = CL_USDC_USD;
        c.pegQuoteFeedMaxAge = 1 days + 1 hours;
        c.savingsShare = 0.35e18; // 35%, governed 0-50%, 10 points per change
        (c.depthIlk, c.depthK, c.depthIMD) = ("SIMD", DEPTH_K, DEPTH_IMD); // depthIMD = the posted CAP on the measured depth
        _depthSamplers(c);
        // E2: Robinhood's IMD type sells into the same IMD market: its line counts against this rule.
        (c.otherImdLines, c.otherImdChop) = (RobinhoodConfig.IMD_LINE, RobinhoodConfig.IMD_CHOP);

        c.feeds = new DeployTypes.FeedNode[](23);
        c.feeds[F_ETH] = _cl(CL_ETH_USD, 18, 1 hours + 10 minutes);
        c.feeds[F_STETH] = _cl(CL_STETH_USD, 18, 1 hours + 10 minutes);
        c.feeds[F_WSTETH] = _rate(WSTETH, bytes4(keccak256("stEthPerToken()")), false, F_STETH);
        c.feeds[F_CBBTC] = _cl(CL_CBBTC_USD, 8, 1 days + 1 hours);
        c.feeds[F_BTC] = _cl(CL_BTC_USD, 8, 1 hours + 10 minutes);
        c.feeds[F_WBTC_BTC] = _cl(CL_WBTC_BTC, 18, 1 days + 1 hours);
        c.feeds[F_WBTC] = _product(F_BTC, F_WBTC_BTC);
        // 24h heartbeat + 1h, as USDT and the peg quote: at exactly 1 day the USDC/USDS types read stale around every
        // heartbeat update (audit wave 1).
        c.feeds[F_USDS] = _cl(CL_USDS_USD, 18, 1 days + 1 hours);
        c.feeds[F_SUSDS] = _rate(SUSDS, CONVERT, true, F_USDS);
        c.feeds[F_USDC] = _cl(CL_USDC_USD, 6, 1 days + 1 hours);
        c.feeds[F_SUSDC] = _rate(METAMORPHO_STEAKHOUSE_USDC, CONVERT, true, F_USDC);
        c.feeds[F_USDT] = _cl(CL_USDT_USD, 6, 1 days + 1 hours);
        c.feeds[F_IMD_MEDIAN] = _swarm(DeployTypes.SWARM_PRICE, IMD_LEG_MAX_AGE);
        c.feeds[F_IMD_SPOT] = _swarm(DeployTypes.SWARM_SPOT, IMD_LEG_MAX_AGE);
        c.feeds[F_IMD_USD_SPOT] = _product(F_IMD_SPOT, F_ETH);
        c.feeds[F_SIMD_SPOT] = _rate(SIMD, CONVERT, true, F_IMD_USD_SPOT);
        c.feeds[F_NHI] = _swarm(DeployTypes.SWARM_NHI, NHI_MAX_AGE);
        c.feeds[F_IMD_LIVE] = _live(UNIV4_POOL_MANAGER, IMD_ETH_POOL_ID, false);
        c.feeds[F_IMD_USD_LIVE] = _product(F_IMD_LIVE, F_ETH);
        c.feeds[F_SIMD_LIVE] = _rate(SIMD, CONVERT, true, F_IMD_USD_LIVE);
        // D4. Read on chain 2026-10-29: ETH/USD 8 dec $2,303.66; BTC/USD 8 dec $79,753.84 (both
        // ~1h heartbeat); wstETH.stEthPerToken() = 1.2474.
        c.feeds[F_WSTETH_ETH] = _rate(WSTETH, bytes4(keccak256("stEthPerToken()")), false, F_ETH);
        c.feeds[F_IMD_USD_MEDIAN] = _product(F_IMD_MEDIAN, F_ETH);
        c.feeds[F_SIMD_MEDIAN] = _rate(SIMD, CONVERT, true, F_IMD_USD_MEDIAN);

        uint8 N = DeployTypes.NONE;
        c.ilks = new DeployTypes.IlkSpec[](9);
        c.ilks[0] = _ilk("ETH", WETH, F_ETH, F_ETH, N, N, address(0), _blue(_r(1.4e18, 0.1e18, 0.01e18, 0, 2_000_000e18)));
        c.ilks[1] = _ilk("WSTETH", WSTETH, F_WSTETH, F_WSTETH_ETH, N, F_WSTETH, address(0), _blue(_r(1.45e18, 0.1e18, 0.01e18, 0.1e18, 2_000_000e18)));
        c.ilks[2] = _ilk("CBBTC", CBBTC, F_CBBTC, F_BTC, N, N, address(0), _blue(_r(1.5e18, 0.12e18, 0.015e18, 0, 1_000_000e18)));
        c.ilks[3] = _ilk("WBTC", WBTC, F_WBTC, F_BTC, N, N, address(0), _blue(_r(1.5e18, 0.12e18, 0.015e18, 0, 1_000_000e18)));
        c.ilks[4] = _ilk("S-USDS", SUSDS, F_SUSDS, F_SUSDS, N, F_SUSDS, CL_USDS_USD, _stable(0.05e18, 0.1e18, 1_000_000e18));
        c.ilks[5] = _ilk("S-USDC-STEAKHOUSE", METAMORPHO_STEAKHOUSE_USDC, F_SUSDC, F_SUSDC, N, F_SUSDC, CL_USDC_USD, _stable(0.05e18, 0.1e18, 1_000_000e18));
        // mat follows NHI; line = E1's rule-admitted line at the genesis depth (target 100k)
        ParametersBase.Risk memory ir = _r(1.7e18, SIMD_CHOP, 0.04e18, 0, simdLineFor(SIMD_LINE_TARGET, DEPTH_IMD));
        ir.skew = 0.05e18; // 5% (was 10% in code)
        // sIMD fee 0.5% / divisor 2, and at most 20k imdUSD redeemed per rolling 2h window
        // (the simulator's no-profit bound was ~28k at 2026-10-18 pool depth).
        ir.redeemFloor = 0.005e18;
        ir.redeemDivisor = 2;
        ir.redeemCap = SIMD_REDEEM_CAP;
        c.ilks[6] = _ilk("SIMD", SIMD, F_SIMD_MEDIAN, F_SIMD_SPOT, F_NHI, N, address(0), ir);
        c.ilks[6].liveSpot = F_SIMD_LIVE;
        c.ilks[7] = _ilk("USDC", USDC, F_USDC, F_USDC, N, N, CL_USDC_USD, _held(500_000e18));
        c.ilks[8] = _ilk("USDT", USDT, F_USDT, F_USDT, N, N, CL_USDT_USD, _held(500_000e18));

        c.lpVault = DeployTypes.LpVaultSpec({enabled: true, band: 100});
        c.pegPositions = DeployTypes.PegPositionSpec({enabled: true, ilk: "PEG", risk: pegRisk(50_000e18)});
        c.loopVault = DeployTypes.LoopSpec({enabled: true, ilk: "SIMD"});
        c.dex = DeployTypes.DexSpec({
            enabled: true, vaultA: SIMD, vaultB: SINFER, sqrtPriceX96: 0, marketPoolId: INFER_IMD_POOL_ID
        });
        // Off in the FULL config until the full launch: the beta registers it (BetaConfig) on its own seat leaves.
        c.seats = seatSpec(false, N, N, F_ETH);
        c.backstop = backstopSpec(SIMD_LINE_TARGET);
        c.chain.chainId = 1; // no Pulse (Chainlink-priced mainnet needs none)
        // The full config is UNCAPPED (explicit; only the beta config is capped): its per-type lines are the limit.
        // A cap set at genesis can never be removed (Parameters), so a full launch that wants one decides it here.
        (c.chain.capped, c.chain.chainLine) = (false, 0);
        // The mainnet end of the Robinhood path is deployed separately (DeployMainnetBridge), not with this config.
    }

    /// @notice On mainnet: the blue sleeve bids on ETH, wstETH, cbBTC, WBTC and the two staked stables (six
    /// tokens = the sleeve's MAX_TOKENS); the edge sleeve on sIMD, with a bootstrap allowance of the sIMD line TARGET (the
    /// genesis line is 0 in the beta: a 0 bootstrap would shut sIMD until the sleeve filled). Held USDC/USDT are not covered
    /// (the sleeve's token slots are full; they are $1 collateral the caller path clears at no loss). Daily sale limits,
    /// roughly $100k-200k of each token at 2026-11 prices.
    function backstopSpec(uint256 simdBootstrap) internal pure returns (DeployTypes.BackstopSpec memory b) {
        b.enabled = true;
        b.edgePremium = 0.2e18; // 20% of edge-type interest to the edge sleeve
        b.maxSlippageBps = 200;
        // The Allocator's freezer from genesis (audit wave 1) is the Safe: there is no separate freezer key.
        // The four discretionary Allocator jobs are rule-driven, so no keeper key routes protocol funds and nothing needs a
        // faster stop than the Safe; each action's daily bucket bounds a loss until it signs. The protocol's watcher alerts.
        b.freezer = GOVERNANCE_SAFE;
        b.ilks = new DeployTypes.SleeveIlk[](7);
        b.ilks[0] = DeployTypes.SleeveIlk("ETH", false, 0, 50e18);
        b.ilks[1] = DeployTypes.SleeveIlk("WSTETH", false, 0, 40e18);
        b.ilks[2] = DeployTypes.SleeveIlk("CBBTC", false, 0, 2e8);
        b.ilks[3] = DeployTypes.SleeveIlk("WBTC", false, 0, 2e8);
        b.ilks[4] = DeployTypes.SleeveIlk("S-USDS", false, 0, 200_000e18);
        b.ilks[5] = DeployTypes.SleeveIlk("S-USDC-STEAKHOUSE", false, 0, 200_000e18);
        // sIMD shares: ~1.25e5 raw shares per IMD (Treasury 114.5M shares ~ 913 IMD, 2026-10): 1e27 ~ 8k IMD a day.
        b.ilks[6] = DeployTypes.SleeveIlk("SIMD", true, uint128(simdBootstrap), 1e27);
    }

    /// @notice SEAT at the launch limits (25 seats, 3 per borrower, mat 250%, rate floor 8%, not redeemable,
    /// skew 25%, 10% fee on rewards). Feed indices are nodes of the same config.
    function seatSpec(bool enabled, uint8 median, uint8 spot, uint8 ethUsd)
        internal
        pure
        returns (DeployTypes.SeatSpec memory s)
    {
        s.enabled = enabled;
        s.ilk = "SEAT";
        s.nft = IDMD;
        s.adapter = IMD_AGENT_ADAPTER;
        s.maxSeats = 25;
        s.perBorrower = 3;
        (s.median, s.spot, s.ethUsd) = (median, spot, ethUsd);
        s.risk = ParametersBase.Risk({
            mat: 2.5e18,
            chop: 0.1e18,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: 0.08e18,
            yieldFee: 0.1e18,
            skew: 0.25e18,
            pegFloor: 0,
            line: 40_000e18, // 25 x $4,000 x 40%; the 25-seat count binds first
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 4,
            redeemCap: 0
        });
    }

    // ---------------------------------------------------------------- builders

    function _cl(address agg, uint8 dec, uint256 maxAge) private pure returns (DeployTypes.FeedNode memory n) {
        n.kind = DeployTypes.CHAINLINK;
        n.source = agg;
        n.decimals = dec;
        n.maxAge = maxAge;
    }

    function _rate(address src, bytes4 sel, bool one, uint8 underlying) private pure returns (DeployTypes.FeedNode memory n) {
        n.kind = DeployTypes.RATE;
        n.source = src;
        n.selector = sel;
        n.passOneE18 = one;
        n.cap = CAP;
        n.a = underlying;
    }

    function _product(uint8 a, uint8 b) private pure returns (DeployTypes.FeedNode memory n) {
        n.kind = DeployTypes.PRODUCT;
        n.a = a;
        n.b = b;
    }

    function _live(address manager, bytes32 poolId, bool baseIsToken0) private pure returns (DeployTypes.FeedNode memory n) {
        n.kind = DeployTypes.LIVE_POOL;
        n.source = manager;
        n.poolId = poolId;
        n.passOneE18 = baseIsToken0;
    }

    function _swarm(uint8 kind, uint256 maxAge) private pure returns (DeployTypes.FeedNode memory n) {
        n.kind = kind;
        n.maxAge = maxAge;
        n.cap = SWARM_CAP_BPS;
    }

    function _ilk(
        bytes32 ilk,
        address token,
        uint8 median,
        uint8 spot,
        uint8 nhi,
        uint8 yieldRate,
        address peg,
        ParametersBase.Risk memory risk
    ) private pure returns (DeployTypes.IlkSpec memory s) {
        s = DeployTypes.IlkSpec(ilk, token, median, spot, nhi, yieldRate, peg, DeployTypes.NONE, true, risk);
    }

    function _r(uint64 mat, uint64 chop, uint64 rateFloor, uint64 yieldFee, uint128 line)
        private
        pure
        returns (ParametersBase.Risk memory)
    {
        return ParametersBase.Risk({
            mat: mat,
            chop: chop,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: rateFloor,
            yieldFee: yieldFee,
            skew: 0.05e18,
            pegFloor: 0,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 4,
            redeemCap: 0
        });
    }

    /// @dev Chainlink-priced volatile collateral: fee floor 0.5%, divisor 4, uncapped.
    function _blue(ParametersBase.Risk memory r) private pure returns (ParametersBase.Risk memory) {
        r.redeemFloor = 0.005e18;
        r.redeemDivisor = 4;
        return r;
    }

    /// @dev Stablecoin types: fee floor 0.10%, divisor 8, uncapped.
    function _stable(uint64 chop, uint64 yieldFee, uint128 line) private pure returns (ParametersBase.Risk memory r) {
        r = _r(1.08e18, chop, 0.005e18, yieldFee, line);
        r.pegFloor = 0.98e18;
        r.redeemFloor = 0.001e18;
        r.redeemDivisor = 8;
    }

    function _held(uint128 line) private pure returns (ParametersBase.Risk memory r) {
        r = _r(1.05e18, 0.03e18, 0.005e18, 0, line);
        r.pegFloor = 0.98e18;
        r.redeemFloor = 0.001e18;
        r.redeemDivisor = 8;
    }
}

/// @notice The capped live beta: the full mainnet config with only these
/// changes, so every feed, address and risk value other than the ceilings is the confirmed full-launch one.
///   - debt ceilings: ETH/wstETH 50k each, cbBTC/WBTC 25k each, sIMD 50k, sUSDS/Steakhouse USDC 12.5k each,
///     USDC/USDT (held) 25k each, PEG positions 25k: 300k in total (PEG counts in the chain cap, so its line
///     is inside the budget, carved from the two yield-stable lines; the seat type's 40k sits on top, bounded by its
///     25-seat count and by the 300k chain cap);
///   - migrator line 0 (`migratorClosed`): v1 -> v2 opens later, through the timelock;
///   - flash-mint cap 100k;
///   - chain-wide debt cap 300k at genesis (`chain.capped`; full: uncapped);
///   - redemption divisor 16 on ETH/wstETH/cbBTC/WBTC (full: 4);
///   - no liquidation grace on sIMD (`graceOff`: Parameters.maxLull 0; full: v1's 6h NHI schedule);
///   - SEATS ON: two new swarm leaves (seat median + spot,
///     nodes F_SEAT_MEDIAN / F_SEAT_SPOT appended to the feed list), SeatFeed reading the median's figure as sales7d,
///     the launch limits (25 seats, 3 per borrower, mat 250%, line 40k). Deployed with EMPTY legs: the type prices at
///     0 (no borrowing) until the deployment relays the first median + spot;
///   - modules OFF: LoopVault (swarm design review + keeper wiring pending) and the Compound DEX.
///     PegLPVault is ON from day 1 (`lpVault.enabled` below).
/// Unchanged from the full config and already the beta values: keeper cap 0 at genesis (the script never sets it),
/// savings share 35%, no fee-note series (FeeNotes is deployed dormant: a series opens only through the timelock),
/// below-peg reserve empty at genesis (any USDC seed is a post-deploy governance act).
library BetaConfig {
    uint256 internal constant TOTAL_LINES = 300_000e18; // incl. the sIMD line opened on day 7 and the PEG line
    uint128 internal constant SIMD_LINE_TARGET = 50_000e18;
    uint128 internal constant PEG_LINE = 25_000e18;
    uint64 internal constant BLUE_REDEEM_DIVISOR = 16;

    function get() internal pure returns (DeployTypes.Config memory c) {
        c = MainnetConfig.get();
        c.flashCap = 100_000e18;
        c.migratorClosed = true;
        // A chain-wide debt cap of 300k at genesis (Parameters.setGenesisChainLine; Ledger._checkLines counts
        // Σ debt + bad debt of every type on each borrow). The type lines, PEG included, sum to 250k at genesis
        // and 300k once the day-7 sIMD line reaches its 50k target; 340k with the seat type's 40k, where the chain line binds.
        // Raising it is SET_CHAIN_LINE (48h); it can never be removed.
        (c.chain.capped, c.chain.chainLine) = (true, TOTAL_LINES);
        // The edge bootstrap's genesisLine = the beta's sIMD target. It falls linearly to 0 over 60 days from the genesis
        // listing (Backstop.bootstrap), so on day 7 it is 50k x 53/60 (~44.2k), on day 20 ~33.3k, on day 60 zero.
        c.backstop = MainnetConfig.backstopSpec(SIMD_LINE_TARGET);
        // sIMD is bitten as soon as it is marked in the beta (no 6h grace). Restoring the grace is a
        // SET_MAX_LULL proposal (48h), no redeploy.
        c.graceOff = true;
        _line(c, "ETH", 50_000e18);
        _line(c, "WSTETH", 50_000e18);
        _line(c, "CBBTC", 25_000e18);
        _line(c, "WBTC", 25_000e18);
        _line(c, "S-USDS", 12_500e18);
        _line(c, "S-USDC-STEAKHOUSE", 12_500e18);
        // D2: the sIMD line opens on day 7, in the same Safe batch as the keeper cap, at
        // min(SIMD_LINE_TARGET, what D1 allows on the depth posted that day). 0 at genesis.
        _line(c, "SIMD", 0);
        _line(c, "USDC", 25_000e18);
        _line(c, "USDT", 25_000e18);
        c.pegPositions.risk.line = PEG_LINE; // inside the 300k (full config 50k)
        // The blue types' redemption base rate rises 4x slower in the beta (divisor 4 -> 16, the bound in
        // Parameters.MAX_REDEEM_DIVISOR): with small lines, one redemption is a large share of supply and would pin the
        // fee near its 5% cap. Stables stay 8, sIMD 2. The full config keeps 4.
        _divisor(c, "ETH", BLUE_REDEEM_DIVISOR);
        _divisor(c, "WSTETH", BLUE_REDEEM_DIVISOR);
        _divisor(c, "CBBTC", BLUE_REDEEM_DIVISOR);
        _divisor(c, "WBTC", BLUE_REDEEM_DIVISOR);
        // F2: PegLPVault ON in the beta from day 1, deployed in stage 4 exactly as the full config does.
        c.loopVault.enabled = false;
        c.dex.enabled = false;
        _seats(c);
    }

    uint8 internal constant F_SEAT_MEDIAN = 23; // appended after MainnetConfig's 23 nodes
    uint8 internal constant F_SEAT_SPOT = 24;
    /// @dev Both legs are refreshed about daily (2 x 0.5 IMD); a day and two hours of life covers one missed slot.
    uint256 internal constant SEAT_MAX_AGE = 26 hours;
    /// @dev Per-epoch move caps of the leaves (SwarmFeed). The median also has SeatFeed's 20%-per-update fall cap.
    uint256 internal constant SEAT_MEDIAN_CAP_BPS = 3_000;
    uint256 internal constant SEAT_SPOT_CAP_BPS = 5_000;

    function _seats(DeployTypes.Config memory c) private pure {
        DeployTypes.FeedNode[] memory f = new DeployTypes.FeedNode[](c.feeds.length + 2);
        for (uint256 i; i < c.feeds.length; ++i) f[i] = c.feeds[i];
        require(c.feeds.length == F_SEAT_MEDIAN, "beta: seat node index");
        f[F_SEAT_MEDIAN].kind = DeployTypes.SWARM_SEAT_MEDIAN;
        f[F_SEAT_MEDIAN].maxAge = SEAT_MAX_AGE;
        f[F_SEAT_MEDIAN].cap = SEAT_MEDIAN_CAP_BPS;
        f[F_SEAT_SPOT].kind = DeployTypes.SWARM_SEAT_SPOT;
        f[F_SEAT_SPOT].maxAge = SEAT_MAX_AGE;
        f[F_SEAT_SPOT].cap = SEAT_SPOT_CAP_BPS;
        c.feeds = f;
        c.seats = MainnetConfig.seatSpec(true, F_SEAT_MEDIAN, F_SEAT_SPOT, MainnetConfig.F_ETH);
    }

    error UnknownBetaIlk(bytes32 ilk);

    function _line(DeployTypes.Config memory c, bytes32 ilk, uint128 line) private pure {
        c.ilks[_at(c, ilk)].risk.line = line;
    }

    function _divisor(DeployTypes.Config memory c, bytes32 ilk, uint64 divisor) private pure {
        c.ilks[_at(c, ilk)].risk.redeemDivisor = divisor;
    }

    function _at(DeployTypes.Config memory c, bytes32 ilk) private pure returns (uint256) {
        for (uint256 i; i < c.ilks.length; ++i) {
            if (c.ilks[i].ilk == ilk) return i;
        }
        revert UnknownBetaIlk(ilk);
    }
}

/// @notice Robinhood Chain (chainId 4663, LayerZero eid 30416): the 3a core. Every address was read on chain
/// on 2026-10-21 (block 94,795,954 on two RPCs). Types: ETH, S-USDG (USDG staked on deposit into Steakhouse
/// USDG), IMD (raw IMD OFT, priced from swarm attestations of the MAINNET median and spot, NHI-linked like sIMD), plus the 3b
/// stock types; the imdUSD/USDG peg pool + PegHook and FeeNotes for USDG (dormant). No earn vaults, seats
/// or DEX; no v1 to migrate. Ceilings are PROPOSED values, subject to governance sign-off.
library RobinhoodConfig {
    uint256 internal constant CHAIN_ID = 4663;
    uint32 internal constant EID = 30416;
    uint32 internal constant MAINNET_EID = 30101;

    // tokens (docs.robinhood.com/chain/contracts + chain)
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Paxos, 6 decimals, can freeze
    address internal constant STEAKHOUSE_USDG = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd; // Morpho VaultV2, 18-dec shares
    address internal constant SPARK_SAVINGS_USDG = 0xde770c84FE66E063336b31737cFE9790f18c4087; // backup only, not registered
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127; // IMD OFT (peer of mainnet 0xd34a…63b7)
    // Chainlink (reference-data-directory feeds-robinhood-mainnet.json): 8 decimals, 24h heartbeat, 0.5% deviation
    address internal constant CL_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address internal constant CL_USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    // LayerZero V2 (metadata.layerzero-api.com)
    address internal constant LZ_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    /// @notice Uniswap v4 PoolManager on 4663 (sdk-core ROBINHOOD_ADDRESSES; 24,010 bytes of code, owner 0x2BAD…46CD, read
    /// 2026-10-24). The peg pool imdUSD/USDG lives here with the PegHook (fee 0.01%, tick spacing 1, opened at $1).
    address internal constant UNIV4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @notice The plane on 4663 (Identity-md/protocol @ 57d056d3, DEPLOY.md + packages/contracts/deployments/robinhood.json):
    /// Intake v2 and IntakeDelivery. Not used by any contract here: an attestation for a 4663 feed is bought with
    /// `consumer = {chainId: 4663, verifyingContract: feed}` (apps/control-plane/src/intake/orders.ts), paid on mainnet or here.
    address internal constant PLANE_INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant PLANE_INTAKE_DELIVERY = 0xCE0E6a670AA75E161d02aca3C7F00B94cA428CCb;

    /// @notice The governance Safe on 4663. NONE EXISTS YET (the mainnet Safe's address has no code on 4663, 2026-10-21):
    /// one is to be deployed (Safe 1.4.1 and 1.5.0 factories are on 4663) and records it here. DeployRobinhood refuses a
    /// governor with no code, so this placeholder cannot be deployed with, and an EOA can never be the governor.
    address internal constant GOVERNANCE_SAFE = address(0);

    bytes4 internal constant CONVERT = bytes4(keccak256("convertToAssets(uint256)"));
    uint256 internal constant CAP = uint256(0.001e18) / 1 days; // share-rate growth cap, 0.1%/day
    uint256 internal constant CL_MAX_AGE = 1 days + 1 hours; // the 4663 feeds' heartbeat is 24h (mainnet ETH/USD: 1h)
    /// @notice The IMD type's line and chop. E2: mainnet's depth rule counts this line (Parameters.otherImdLines):
    /// RAISE THE MAINNET VALUE FIRST (SET_OTHER_IMD, 48h), then this chain's line.
    uint128 internal constant IMD_LINE = 3_000e18;
    uint64 internal constant IMD_CHOP = 0.2e18;

    // ---- chain-risk caps, PROPOSED
    /// @notice 10% of Ethereum debt, as an absolute number. v2 Ethereum is not live, so 10% of the beta's 300k of
    /// lines (BetaConfig.TOTAL_LINES); the Safe moves it with Ethereum's debt through SET_CHAIN_LINE (48h, <= 50M).
    uint256 internal constant CHAIN_LINE = 30_000e18;
    /// @notice The most that may leave 4663 per day, sized to normal flow at the cap (a third of the chain line),
    /// and the inbound (mint) limit from mainnet, larger so arrivals for repayment are not throttled. Mainnet mirrors both.
    uint256 internal constant OUT_LIMIT = 10_000e18;
    uint256 internal constant IN_LIMIT = 50_000e18;
    uint256 internal constant LIMIT_WINDOW = 1 days;

    // feed node indices
    uint8 internal constant F_ETH = 0;
    uint8 internal constant F_USDG = 1;
    uint8 internal constant F_SUSDG = 2;
    uint8 internal constant F_IMD_ETH = 3; // swarm median, wei per 1e18 IMD (mainnet window)
    uint8 internal constant F_IMD_ETH_SPOT = 4; // swarm spot
    uint8 internal constant F_NHI = 5; // swarm NHI
    uint8 internal constant F_IMD_USD = 6;
    uint8 internal constant F_IMD_USD_SPOT = 7;

    function get() internal pure returns (DeployTypes.Config memory c) {
        c.governor = GOVERNANCE_SAFE;
        c.v1 = address(0); // no imdUSD v1 on 4663: the migrator is deployed closed (line 0) and stays inert
        c.migratorClosed = true;
        c.flashCap = 100_000e18;
        c.savingsShare = 0.35e18;
        // the peg hook on imdUSD/USDG (keeper cap 0 and reserve empty at genesis, as on mainnet) + FeeNotes sold for USDG
        c.poolManager = UNIV4_POOL_MANAGER;
        c.pegQuote = USDG;
        // USDG/USD: "USDG / USD", 8 decimals, 24h heartbeat (read on 4663 2026-10-28: 0.99995, updated 10.8h before)
        c.pegQuoteFeed = CL_USDG_USD;
        c.pegQuoteFeedMaxAge = CL_MAX_AGE;

        c.feeds = new DeployTypes.FeedNode[](8);
        c.feeds[F_ETH] = _cl(CL_ETH_USD, 18);
        c.feeds[F_USDG] = _cl(CL_USDG_USD, 6);
        c.feeds[F_SUSDG] = _node(DeployTypes.RATE, STEAKHOUSE_USDG, 0, F_USDG, 0);
        c.feeds[F_SUSDG].selector = CONVERT;
        c.feeds[F_SUSDG].passOneE18 = true;
        c.feeds[F_SUSDG].cap = CAP;
        // v1's live feeds: price + spot live 1h, NHI 1 day, each capped at 20% per epoch (read from mainnet 2026-10-21)
        c.feeds[F_IMD_ETH] = _node(DeployTypes.SWARM_PRICE, address(0), 1 hours, 0, 2000);
        c.feeds[F_IMD_ETH_SPOT] = _node(DeployTypes.SWARM_SPOT, address(0), 1 hours, 0, 2000);
        c.feeds[F_NHI] = _node(DeployTypes.SWARM_NHI, address(0), 1 days, 0, 2000);
        c.feeds[F_IMD_USD] = _node(DeployTypes.PRODUCT, address(0), 0, F_IMD_ETH, 0);
        c.feeds[F_IMD_USD].b = F_ETH;
        c.feeds[F_IMD_USD_SPOT] = _node(DeployTypes.PRODUCT, address(0), 0, F_IMD_ETH_SPOT, 0);
        c.feeds[F_IMD_USD_SPOT].b = F_ETH;

        uint8 N = DeployTypes.NONE;
        c.ilks = new DeployTypes.IlkSpec[](3);
        c.ilks[0] = DeployTypes.IlkSpec("ETH", WETH, F_ETH, F_ETH, N, N, address(0), N, true, _r(1.4e18, 0.1e18, 0.01e18, 0, 20_000e18));
        ParametersBase.Risk memory sr = _r(1.08e18, 0.05e18, 0.005e18, 0.1e18, 20_000e18); // stable type; line <= 5% of TVL
        sr.pegFloor = 0.98e18;
        sr.redeemFloor = 0.001e18;
        sr.redeemDivisor = 8;
        c.ilks[1] = DeployTypes.IlkSpec("S-USDG", STEAKHOUSE_USDG, F_SUSDG, F_SUSDG, N, F_SUSDG, CL_USDG_USD, N, true, sr);
        // IMD: mat follows NHI (170-200%), chop 20% as sIMD, skew 10% (mainnet sIMD is 5%; this value
        // is a governance choice, no 4663 analysis yet); NOT redeemable (no live pool leg to guard the payout),
        // so a 5% floor rate; a small line (no IMD market on 4663: a liquidator bridges the IMD home to sell it).
        ParametersBase.Risk memory ir = _r(1.7e18, IMD_CHOP, 0.05e18, 0, IMD_LINE);
        ir.skew = 0.1e18;
        c.ilks[2] = DeployTypes.IlkSpec("IMD", IMD, F_IMD_USD, F_IMD_USD_SPOT, F_NHI, N, address(0), N, false, ir);

        c.chain = DeployTypes.ChainSpec({
            chainId: CHAIN_ID, pulse: true, pulseGap: 15 minutes, pulseGrace: 1 hours, capped: true, chainLine: CHAIN_LINE
        });
        // guardian: filled by DeployRobinhood from env GUARDIAN (the operator's dedicated guardian key); zero refused off a local fork
        c.bridge = DeployTypes.BridgeSpec({enabled: true, endpoint: LZ_ENDPOINT, guardian: address(0)});
        // On 4663: the blue sleeve bids on ETH and S-USDG. IMD is NOT covered: there is no IMD market on 4663
        // (a liquidator bridges IMD home to sell it), so a sleeve holding IMD could not unwind; IMD keeps the caller path.
        // The edge sleeve is deployed EMPTY (no edge type; premium 0) so a later type can be listed by ADD_SLEEVE_ILK.
        c.backstop.enabled = true;
        c.backstop.maxSlippageBps = 200;
        c.backstop.ilks = new DeployTypes.SleeveIlk[](2);
        c.backstop.ilks[0] = DeployTypes.SleeveIlk("ETH", false, 0, 10e18);
        c.backstop.ilks[1] = DeployTypes.SleeveIlk("S-USDG", false, 0, 50_000e18);
        c.stocks = stocks();
    }

    // ---- stock tokens. Tokens: Robinhood's asset registry (api.robinhood.com/rhj/assets, the source
    // docs.robinhood.com/chain/contracts renders), checked on chain; feeds: Chainlink's feeds-robinhood-mainnet.json. Both
    // 2026-10-22, block ~95.33M. Allowlist = feed AND >= $500k of USDG/WETH bid depth within -5%.
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant CL_SPY = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address internal constant SGOV = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address internal constant CL_SGOV = 0xa0DF4ee0fFf975306345875E3548Fcc519577A11;
    address internal constant USO = 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344;
    address internal constant CL_USO = 0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant CL_NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant CRCL = 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5;
    address internal constant CL_CRCL = 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a;
    address internal constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address internal constant CL_MSTR = 0x396118bdFB181e6240E74D243F266B061c0edc3D;
    address internal constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address internal constant CL_SPCX = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant CL_TSLA = 0x4A1166a659A55625345e9515b32adECea5547C38;
    /// @dev AAPL: an exception to the $500k rule: $475k at -5% on 10-22, $433k on 10-24 (block 96,620,003). Same beacon/registry as the others (read 10-24).
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant CL_AAPL = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    /// @notice The stock-token registry (AccessControlledRegistry + beacon): global pause, blocklist (`isBlocked`).
    address internal constant STOCK_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;

    /// @notice Stock + SGOV debt within 25% of the chain line: 7,500 of the 30k genesis chain line; the Safe
    /// moves it with the chain line (SET_GROUP_LINE, 48h). Since AAPL (2026-10-24) the per-type lines sum to 8,250, so the
    /// group line binds before every type is full (the group line is kept at chain line / 4).
    uint8 internal constant STOCK_GROUP = 1;
    uint256 internal constant STOCK_GROUP_LINE = CHAIN_LINE / 4;

    /// @notice The allowlisted types (step 0-1). mat = (1 + chop) / ((1 - p99.9 closed-market gap) x auction floor), rounded up
    /// to 5% plus 5% for the feed's 0.5% band and the auction hour (weekend-gap study, 2000-2026). CRCL and SPCX have under 2 years of
    /// history, so the single-stock default (200%) stands. AAPL: measured mat, line 750.
    function stocks() internal pure returns (DeployTypes.StocksSpec memory s) {
        s.usdg = USDG;
        s.group = STOCK_GROUP;
        s.groupLine = STOCK_GROUP_LINE;
        s.rateCap = CAP;
        (s.closedDays, s.earlyDays) = nyse2026to2028();
        s.types = new DeployTypes.StockSpec[](9);
        s.types[0] = _stock("STOCK-SPY", SPY, CL_SPY, 1.4e18, 2_500e18);
        s.types[1] = _stock("STOCK-NVDA", NVDA, CL_NVDA, 1.5e18, 1_000e18);
        s.types[2] = _stock("STOCK-TSLA", TSLA, CL_TSLA, 1.5e18, 1_000e18);
        s.types[3] = _stock("STOCK-USO", USO, CL_USO, 1.45e18, 750e18);
        s.types[4] = _stock("STOCK-MSTR", MSTR, CL_MSTR, 1.75e18, 500e18);
        s.types[5] = _stock("STOCK-CRCL", CRCL, CL_CRCL, 2e18, 250e18);
        s.types[6] = _stock("STOCK-SPCX", SPCX, CL_SPCX, 2e18, 250e18);
        // AAPL: p99.9 closed-market gap 9.9% (1,464 closures since 2000) -> formula 1.36 -> 1.40 -> 1.45 with the band.
        s.types[7] = _stock("STOCK-AAPL", AAPL, CL_AAPL, 1.45e18, 750e18);
        // SGOV: T-bill fund, no measurable weekend gap; penalty 5%, the auction ends at 97%, mat 115% (the stable-fund default).
        s.types[8] = _stock("SGOV", SGOV, CL_SGOV, 1.15e18, 1_250e18);
        s.types[8].risk.chop = 0.05e18;
        s.types[8].risk.rateFloor = 0.04e18;
        s.types[8].auctionFloor = 0.97e18;
    }

    function _stock(bytes32 ilk, address token, address agg, uint64 mat, uint128 line)
        private
        pure
        returns (DeployTypes.StockSpec memory t)
    {
        t.ilk = ilk;
        t.stock = token;
        t.aggregator = agg;
        t.maxAge = CL_MAX_AGE;
        t.auctionTime = 1 hours;
        t.auctionFloor = 0.9e18;
        t.risk = _r(mat, 0.1e18, 0.05e18, 0, line);
    }

    /// @notice NYSE closures and 13:00 closes from 2026-10-22 to the end of 2028, as UTC day numbers, from nyse.com/markets/
    /// hours-calendars (read 2026-10-22). The Safe extends the calendar each year (MarketCalendar.SET_DAYS, 48h).
    function nyse2026to2028() internal pure returns (uint32[] memory closed, uint32[] memory early) {
        uint32[21] memory c = [
            uint32(20783), 20812, 20819, 20836, 20864, 20903, 20969, 20987, 21004, 21067, 21147, 21176, 21200, 21235, 21288,
            21333, 21354, 21369, 21431, 21511, 21543
        ];
        uint32[5] memory e = [uint32(20784), 20811, 21148, 21368, 21512];
        closed = new uint32[](21);
        early = new uint32[](5);
        for (uint256 i; i < 21; ++i) closed[i] = c[i];
        for (uint256 i; i < 5; ++i) early[i] = e[i];
    }

    // ---- LayerZero libraries and the DVN SET (the IMD OFT's two DVNs on this path + P2P, 3 required =
    // ImdBridge.MIN_REQUIRED_DVNS; P2P serves both chains (LayerZero metadata, V2, dstConfig
    // set both ways, checked 2026-10-31) and is neither LayerZero nor the USDG issuer (Paxos). The endpoint's defaults are a
    // dead DVN for a new OApp, so a path needs its own config before it sends).
    address internal constant SEND_ULN = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
    address internal constant RECEIVE_ULN = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
    address internal constant LZ_EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
    address internal constant DVN_TWINSTAKE = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8; // sorted ascending
    address internal constant DVN_P2P = 0x8ed0A851964604BB1b6b1a703F4c8234EE684d76;
    address internal constant DVN_LZ_LABS = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12;
    address internal constant M_SEND_ULN = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address internal constant M_RECEIVE_ULN = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
    address internal constant M_LZ_EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
    address internal constant M_DVN_P2P = 0x06559EE34D85a88317Bf0bfE307444116c631b67; // sorted ascending
    address internal constant M_DVN_LZ_LABS = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address internal constant M_DVN_TWINSTAKE = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    // 4663 -> mainnet: 20 (ImdBridge.MIN_CONFIRMATIONS_FROM_OTHER, LayerZero's Arbitrum-family default; ). The IMD
    // OFT uses 5 (~1-2 s of sequencer soft confirmations), which the bridge now refuses.
    uint64 internal constant CONF_FROM_4663 = 20;
    uint64 internal constant CONF_FROM_MAINNET = 15; // mainnet -> 4663

    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    struct ExecutorConfig {
        uint32 maxMessageSize;
        address executor;
    }

    /// @notice ImdBridge BATCH items for 4663's side of the mainnet path: executor + DVNs on the send library, DVNs on the
    /// receive library. Append to the SET_PATH item in one BATCH proposal (one 48h window).
    function lzConfig4663() internal pure returns (bytes memory send_, bytes memory receive_) {
        (send_, receive_) = _lzConfig(
            MAINNET_EID,
            SEND_ULN,
            RECEIVE_ULN,
            LZ_EXECUTOR,
            [DVN_TWINSTAKE, DVN_P2P, DVN_LZ_LABS],
            CONF_FROM_4663,
            CONF_FROM_MAINNET
        );
    }

    /// @notice The same for mainnet's ImdBridge on its 4663 path.
    function lzConfigMainnet() internal pure returns (bytes memory send_, bytes memory receive_) {
        (send_, receive_) = _lzConfig(
            EID,
            M_SEND_ULN,
            M_RECEIVE_ULN,
            M_LZ_EXECUTOR,
            [M_DVN_P2P, M_DVN_LZ_LABS, M_DVN_TWINSTAKE],
            CONF_FROM_MAINNET,
            CONF_FROM_4663
        );
    }

    /// @notice ImdBridge BATCH items that PIN 4663's send and receive library for the mainnet path: without them
    /// the OApp follows LayerZero's default library, and a default move would put it where it has no DVN config. Grace 0.
    function lzLibraries4663() internal pure returns (bytes memory send_, bytes memory receive_) {
        send_ = abi.encode(uint8(3), MAINNET_EID, SEND_ULN);
        receive_ = abi.encode(uint8(4), MAINNET_EID, RECEIVE_ULN, uint256(0));
    }

    /// @notice The same pins on mainnet's ImdBridge for its 4663 path.
    function lzLibrariesMainnet() internal pure returns (bytes memory send_, bytes memory receive_) {
        send_ = abi.encode(uint8(3), EID, M_SEND_ULN);
        receive_ = abi.encode(uint8(4), EID, M_RECEIVE_ULN, uint256(0));
    }

    /// @notice 4663's whole launch BATCH for the mainnet path: SET_PATH, both library pins, then the executor + DVN config on
    /// the pinned libraries (one 48h window). `path` = `mainnetPath(...)`.
    function launchBatch4663(bytes memory path) internal pure returns (bytes memory) {
        (bytes memory sl, bytes memory rl) = lzLibraries4663();
        (bytes memory sc, bytes memory rc) = lzConfig4663();
        return _batch5(path, sl, rl, sc, rc);
    }

    /// @notice Mainnet's launch BATCH for the 4663 path. `path` = `robinhoodPathOnMainnet(...)`.
    function launchBatchMainnet(bytes memory path) internal pure returns (bytes memory) {
        (bytes memory sl, bytes memory rl) = lzLibrariesMainnet();
        (bytes memory sc, bytes memory rc) = lzConfigMainnet();
        return _batch5(path, sl, rl, sc, rc);
    }

    function _batch5(bytes memory a, bytes memory b, bytes memory c, bytes memory d, bytes memory e)
        private
        pure
        returns (bytes memory)
    {
        bytes[] memory items = new bytes[](5);
        (items[0], items[1], items[2], items[3], items[4]) = (a, b, c, d, e);
        return abi.encode(uint8(6), items);
    }

    function _lzConfig(
        uint32 remote,
        address sendLib,
        address receiveLib,
        address executor,
        address[3] memory sorted,
        uint64 sendConf,
        uint64 receiveConf
    ) private pure returns (bytes memory send_, bytes memory receive_) {
        address[] memory dvns = new address[](3);
        (dvns[0], dvns[1], dvns[2]) = (sorted[0], sorted[1], sorted[2]);
        SetConfigParam[] memory sp = new SetConfigParam[](2);
        sp[0] = SetConfigParam(remote, 1, abi.encode(ExecutorConfig(10_000, executor)));
        sp[1] = SetConfigParam(remote, 2, abi.encode(UlnConfig(sendConf, 3, 0, 0, dvns, new address[](0))));
        send_ = abi.encode(uint8(2), sendLib, sp);
        SetConfigParam[] memory rp = new SetConfigParam[](1);
        rp[0] = SetConfigParam(remote, 2, abi.encode(UlnConfig(receiveConf, 3, 0, 0, dvns, new address[](0))));
        receive_ = abi.encode(uint8(2), receiveLib, rp);
    }

    /// @notice The Safe's ImdBridge.SET_PATH payload for the 4663 -> mainnet path (after SET_BRIDGE on both chains).
    function mainnetPath(bytes32 mainnetPeer, bytes memory enforcedOptions) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), MAINNET_EID, mainnetPeer, OUT_LIMIT, LIMIT_WINDOW, IN_LIMIT, LIMIT_WINDOW, enforcedOptions);
    }

    /// @notice The mirror on mainnet's bridge: out = 4663's in, in = 4663's out (a forged 4663 message mints at most that).
    function robinhoodPathOnMainnet(bytes32 robinhoodPeer, bytes memory enforcedOptions) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), EID, robinhoodPeer, IN_LIMIT, LIMIT_WINDOW, OUT_LIMIT, LIMIT_WINDOW, enforcedOptions);
    }

    function _cl(address agg, uint8 dec) private pure returns (DeployTypes.FeedNode memory n) {
        n.kind = DeployTypes.CHAINLINK;
        n.source = agg;
        n.decimals = dec;
        n.maxAge = CL_MAX_AGE;
    }

    function _node(uint8 kind, address src, uint256 maxAge, uint8 a, uint256 cap)
        private
        pure
        returns (DeployTypes.FeedNode memory n)
    {
        n.kind = kind;
        n.source = src;
        n.maxAge = maxAge;
        n.a = a;
        n.cap = cap;
    }

    function _r(uint64 mat, uint64 chop, uint64 rateFloor, uint64 yieldFee, uint128 line)
        private
        pure
        returns (ParametersBase.Risk memory)
    {
        return ParametersBase.Risk({
            mat: mat,
            chop: chop,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: rateFloor,
            yieldFee: yieldFee,
            skew: 0.05e18,
            pegFloor: 0,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 4,
            redeemCap: 0
        });
    }
}
