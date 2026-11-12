// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Ledger} from "../../src/Ledger.sol";
import {Pulse} from "../../src/Pulse.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Migrator} from "../../src/Migrator.sol";
import {Join} from "../../src/Join.sol";
import {SavingsVault} from "../../src/SavingsVault.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {LivePoolPrice} from "../../src/feeds/LivePoolPrice.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {PricerOracle} from "../../src/backstop/PricerOracle.sol";
import {Allocator} from "../../src/peg/Allocator.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PegHook} from "../../src/peg/PegHook.sol";
import {FeeNotes} from "../../src/peg/FeeNotes.sol";
import {PegLPVault} from "../../src/earn/PegLPVault.sol";
import {LoopVault} from "../../src/earn/LoopVault.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {SwarmQuestions} from "../../src/feeds/SwarmFeeds.sol";
import {SeatFeed, SeatSpotLeg} from "../../src/feeds/SeatFeed.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {CompoundLens} from "../../src/dex/CompoundLens.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {PegShareFeed} from "../../src/earn/PegShareFeed.sol";
import {PegCollateral} from "../../src/earn/PegCollateral.sol";
import {PegPositionZap} from "../../src/earn/PegPositionZap.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {StockVault} from "../../src/stocks/StockVault.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";

/// @notice What every deploy stage shares: the `Deployed` record, the per-transaction gas log and the CREATE2 mining.
/// It names contract TYPES only and holds no creation code, so a stage that inherits it embeds (and, for the DEX,
/// links) nothing it does not deploy itself. script/Deploy.s.sol is every stage in order (one run); the launch scripts
/// (not included in this snapshot) are one stage each.
///
/// Every stage function can be re-run: a contract already in `d` with code and the checked wiring is kept, one with no
/// code is deployed, and one with code but other wiring stops the run (`Mismatch`) for a person to decide. Each step
/// checks the fields it names, not every property of the contract. A fresh `Deployed` (all zero) therefore runs every
/// step exactly as the single-run deploy always did.
abstract contract DeployBase is Script {
    struct Deployed {
        ImdUSD usd;
        Parameters params;
        Pricer pricer;
        Treasury treasury;
        Ledger ledger;
        Redeemer redeemer;
        Liquidator liquidator;
        Migrator migrator;
        SavingsVault savings;
        FeeNotes notes;
        PegHook hook;
        PoolKey pegKey;
        IFeed[] feeds;
        Join[] joins;
        // optional modules (zero when switched off)
        PegLPVault pegLP;
        LoopVault loop;
        SeatJoin seatJoin;
        SeatFeed seatFeed;
        SeatSpotLeg seatSpot;
        CompoundHook dexHook;
        CompoundLens dexLens;
        PoolKey dexKey;
        address curveLib;
        address oracleLib;
        // chain-specific: zero on mainnet
        Pulse pulse;
        ImdBridge bridge;
        // stock tokens: Robinhood only, one entry per StocksSpec.types
        MarketCalendar calendar;
        StockVault[] stockVaults;
        StockJoin[] stockJoins;
        MarketHoursFeed[] stockFeeds; // the session-gated Chainlink leg
        RateFeed[] stockPrices; // the type's price: vault share rate x stockFeeds[i]
        // The measured IMD depth (mainnet; zero/empty elsewhere)
        ImdDepth imdDepth;
        DepthSampler[] samplers;
        // The standing bid (zero when the config has no backstop)
        PricerOracle backstopOracle;
        Backstop blue;
        Backstop edge;
        Allocator allocator;
        // Peg positions (zero when off)
        PegShareFeed pegFeed;
        Join pegJoin;
        PegPositionZap pegZap;
        PegCollateral pegCollateral;
    }

    /// @notice One broadcast transaction's gas, estimated from inside the simulation: the gas the call or create used
    /// in this frame + 21,000 base + 16 per byte of calldata (init code for a create, every byte counted as non-zero).
    /// It is an upper bound for the execution part only when access lists are cold; the fork test adds a margin.
    struct GasRow {
        string label;
        uint256 gas;
    }

    GasRow[] internal _gasLog;

    /// @notice The CREATE2 salts the mining found (recorded so a verifier can re-derive each hook's address).
    bytes32 internal _pegHookSalt;
    bytes32 internal _dexHookSalt;

    function gasLog() external view returns (GasRow[] memory) {
        return _gasLog;
    }

    function pegHookSalt() external view returns (bytes32) {
        return _pegHookSalt;
    }

    function _rec(string memory label, uint256 g0, uint256 dataLen) internal {
        uint256 used = g0 - gasleft();
        _gasLog.push(GasRow(label, used + 21_000 + 16 * dataLen));
    }

    uint256 internal constant CALL_DATA = 400; // calldata bound for a plain call (wire, register, initialize)

    error ModuleNeeds(string module, string what);
    error WrongChain(uint256 expected, uint256 actual);
    error LibraryMissing(address lib);
    error BadDexPrice(uint160 sqrtPriceX96);
    error HookNotDeployed();
    error BadNode(uint256 index);
    /// @notice An EXISTING feed that does not prove a capped stale allowance.
    error UncappedExistingFeed(uint256 index, address feed);
    /// @notice A recorded contract has code but is not wired the way this deployment needs: a person decides.
    error Mismatch(string what);

    /// @notice True when `a` has code: the only proof a recorded contract exists (a failed broadcast still records it).
    function _has(address a) internal view returns (bool) {
        return a.code.length != 0;
    }

    /// @dev Used as `_has(a) && _ok(<a is wired right>, "name")`: the `&&` skips the wiring reads when `a` has no code
    /// (they would revert), and a recorded contract with code but the wrong wiring stops the run.
    function _ok(bool wiredRight, string memory what) internal pure returns (bool) {
        if (!wiredRight) revert Mismatch(what);
        return true;
    }

    /// @notice True when the contract at `f` is node `n` over the feeds already built (same checks as Deploy.t.sol's
    /// test_everyFeedMatchesItsNode).
    function _feedIs(DeployTypes.FeedNode memory n, address f, IFeed[] memory built) internal view returns (bool) {
        if (n.kind == DeployTypes.CHAINLINK) {
            return ChainlinkFeed(f).aggregator() == n.source && ChainlinkFeed(f).tokenDecimals() == n.decimals
                && ChainlinkFeed(f).maxAge() == n.maxAge;
        }
        if (n.kind == DeployTypes.PRODUCT) {
            return address(ProductFeed(f).a()) == address(built[n.a]) && address(ProductFeed(f).b()) == address(built[n.b]);
        }
        if (n.kind == DeployTypes.RATE) {
            return RateFeed(f).rateSource() == n.source && RateFeed(f).selector() == n.selector
                && RateFeed(f).passOneE18() == n.passOneE18 && address(RateFeed(f).underlying()) == address(built[n.a])
                && RateFeed(f).maxGrowthPerSecond() == n.cap;
        }
        if (n.kind == DeployTypes.LIVE_POOL) {
            return address(LivePoolPrice(f).manager()) == n.source && PoolId.unwrap(LivePoolPrice(f).poolId()) == n.poolId
                && LivePoolPrice(f).baseIsToken0() == n.passOneE18;
        }
        // Every swarm leaf: its lifetime and cap, its question and its signer (a resume used to adopt on code alone).
        bytes memory q = _swarmQuestion(n.kind);
        if (q.length == 0) return false;
        return SwarmFeed(f).maxAge() == n.maxAge && SwarmFeed(f).maxDeviationBps() == n.cap
            && SwarmFeed(f).attester() == SwarmQuestions.ATTESTER && SwarmFeed(f).relayer() == address(0)
            && SwarmFeed(f).MAX_ALLOWANCE_BPS() <= STALE_ALLOWANCE_CEILING
            && SwarmFeed(f).expectedQuestionHash(1, 2) == keccak256(abi.encodePacked(q, "1", ',"toBlock":', "2", "}}"));
    }

    function _swarmQuestion(uint8 kind) internal pure returns (bytes memory) {
        if (kind == DeployTypes.SWARM_PRICE) return SwarmQuestions.PRICE;
        if (kind == DeployTypes.SWARM_SPOT) return SwarmQuestions.SPOT;
        if (kind == DeployTypes.SWARM_NHI) return SwarmQuestions.NHI;
        if (kind == DeployTypes.SWARM_SEAT_MEDIAN) return SwarmQuestions.SEAT_MEDIAN;
        if (kind == DeployTypes.SWARM_SEAT_SPOT) return SwarmQuestions.SEAT_SPOT;
        return "";
    }

    /// @notice v2's stale allowance ceiling (src/feeds/SwarmFeed.sol). A feed read as-is must prove it is under
    /// it. v1's feeds answer 1,000,000 (100x); v1's SharePriceFeed and anything else with no such getter cannot prove it.
    uint256 internal constant STALE_ALLOWANCE_CEILING = 20_000;

    function _allowanceCapped(address feed) internal view returns (bool) {
        (bool ok, bytes memory ret) = feed.staticcall(abi.encodeWithSignature("MAX_ALLOWANCE_BPS()"));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) <= STALE_ALLOWANCE_CEILING;
    }

    /// @notice True when node `i` is a swarm leaf or priced through one: it reads 0 until the first relay.
    function _emptyAtDeploy(DeployTypes.FeedNode[] memory nodes, uint256 i) internal pure returns (bool) {
        DeployTypes.FeedNode memory n = nodes[i];
        if (_swarmQuestion(n.kind).length != 0) return true;
        if (n.kind == DeployTypes.PRODUCT) return _emptyAtDeploy(nodes, n.a) || _emptyAtDeploy(nodes, n.b);
        if (n.kind == DeployTypes.RATE) return _emptyAtDeploy(nodes, n.a);
        return false;
    }

    function _ilkConfig(DeployTypes.IlkSpec memory s, address join, IFeed[] memory feeds)
        internal
        pure
        returns (ParametersBase.Config memory)
    {
        return ParametersBase.Config({
            token: s.token,
            join: join,
            median: feeds[s.median],
            spot: feeds[s.spot],
            nhi: s.nhi == DeployTypes.NONE ? IFeed(address(0)) : feeds[s.nhi],
            yieldRate: s.yieldRate == DeployTypes.NONE ? address(0) : address(feeds[s.yieldRate]),
            pegAggregator: s.pegAggregator,
            liveSpot: s.liveSpot == DeployTypes.NONE ? IFeed(address(0)) : feeds[s.liveSpot],
            redeemable: s.redeemable,
            auction: false
        });
    }

    // ---- chain parts. Built only by script/DeployChain.s.sol (DeployRobinhood), so the mainnet entries stay small
    // enough to be deployed in a mainnet-fork test (their runtime embeds every module's creation code).
    error NeedsDeployChain();

    function _newPulse(uint64, uint64) internal virtual returns (Pulse) {
        revert NeedsDeployChain();
    }

    function _newBridge(address, address, address, address, address) internal virtual returns (ImdBridge) {
        revert NeedsDeployChain();
    }

    function _deployStocks(DeployTypes.Config memory, Deployed memory, address) internal virtual {
        revert NeedsDeployChain();
    }

    // ---- CREATE2 through the deterministic deployer (both v4 hooks)

    /// @dev Foundry's deterministic CREATE2 deployer (present on mainnet and on every fork).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Mine a salt whose CREATE2 address carries exactly `flags` as its permission bits and has no code, then
    /// deploy through the deterministic deployer (so the address is the same whoever broadcasts).
    function _create2Mined(bytes memory init, uint160 flags, string memory label)
        internal
        returns (address a, bytes32 salt_)
    {
        bytes32 initHash = keccak256(init);
        for (uint256 salt;; ++salt) {
            a = _create2Address(bytes32(salt), initHash);
            if (uint160(a) & Hooks.ALL_HOOK_MASK != flags || a.code.length != 0) continue;
            uint256 g = gasleft();
            (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(salt), init));
            _rec(label, g, init.length + 32);
            if (!ok || a.code.length == 0) revert HookNotDeployed();
            return (a, bytes32(salt));
        }
    }

    /// @dev CREATE2 address through the deterministic deployer, in scratch memory: a mining loop of ~16k tries must
    /// not grow memory per iteration (it ran out of gas on memory expansion when each try allocated).
    function _create2Address(bytes32 salt, bytes32 initHash) internal pure returns (address a) {
        address deployer = CREATE2_DEPLOYER;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore8(p, 0xff)
            mstore(add(p, 1), shl(96, deployer))
            mstore(add(p, 21), salt)
            mstore(add(p, 53), initHash)
            a := and(keccak256(p, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
