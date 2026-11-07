// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {PegShareFeed} from "../../src/earn/PegShareFeed.sol";
import {DeployTypes, MainnetConfig} from "../../script/DeployConfig.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Treasury, ICoverable} from "../../src/Treasury.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Governed} from "../../src/Governed.sol";
import {Join} from "../../src/Join.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {LivePoolPrice} from "../../src/feeds/LivePoolPrice.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {PegHook} from "../../src/peg/PegHook.sol";
import {FeeNotes} from "../../src/peg/FeeNotes.sol";
import {PegRouter} from "../utils/PegSystem.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IAgg {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Fork rehearsal of script/Deploy.s.sol with the real mainnet config: what it deploys, who holds
/// power afterwards (the Safe; the deployer nothing), and one borrow/repay through the result.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/Deploy.t.sol
interface IUsdcAgg {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract DeployForkTest is Test {
    using SafeERC20 for IERC20;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address safe = Mainnet.GOVERNANCE_SAFE;

    DeployTypes.Config cfg;
    Deploy.Deployed d;
    Deploy deployer_;

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.deal(deployer, 10 ether);
        DeployTypes.Config memory c = MainnetConfig.get();
        _store(c);
        deployer_ = new Deploy();
        d = deployer_.deployAs(c, deployer);
    }

    function _store(DeployTypes.Config memory c) internal {
        cfg.governor = c.governor;
        cfg.v1 = c.v1;
        cfg.flashCap = c.flashCap;
        cfg.migratorLine = c.migratorLine;
        cfg.savingsShare = c.savingsShare;
        cfg.poolManager = c.poolManager;
        cfg.pegQuote = c.pegQuote;
        cfg.pegQuoteFeed = c.pegQuoteFeed;
        cfg.pegQuoteFeedMaxAge = c.pegQuoteFeedMaxAge;
        (cfg.depthIlk, cfg.depthK, cfg.depthIMD) = (c.depthIlk, c.depthK, c.depthIMD);
        (cfg.otherImdLines, cfg.otherImdChop) = (c.otherImdLines, c.otherImdChop);
        for (uint256 i; i < c.feeds.length; ++i) cfg.feeds.push(c.feeds[i]);
        for (uint256 i; i < c.ilks.length; ++i) cfg.ilks.push(c.ilks[i]);
        cfg.lpVault = c.lpVault;
        cfg.pegPositions = c.pegPositions;
        cfg.loopVault = c.loopVault;
        cfg.seats = c.seats;
        cfg.dex = c.dex;
    }

    // ------------------------------------------------------------ the config is the one in the source

    function test_configUsesTheRecordedAddresses() public view {
        assertEq(cfg.governor, Mainnet.GOVERNANCE_SAFE);
        assertEq(cfg.v1, Mainnet.V1_IMDUSD);
        assertEq(cfg.ilks.length, 9);
        assertEq(cfg.feeds.length, 23); // + wstETH's second leg (ETH/USD x stEthPerToken), + sIMD's median nodes
        assertEq(cfg.ilks[1].spot, MainnetConfig.F_WSTETH_ETH, "wstETH spot = ETH/USD x stEthPerToken");
        assertEq(cfg.ilks[2].spot, MainnetConfig.F_BTC, "cbBTC spot = BTC/USD");
        assertEq(cfg.ilks[3].spot, MainnetConfig.F_BTC, "WBTC spot = BTC/USD");
        assertEq(cfg.feeds[MainnetConfig.F_BTC].source, Mainnet.CL_BTC_USD);
        assertEq(cfg.ilks[0].token, Mainnet.WETH);
        assertEq(cfg.ilks[6].token, Mainnet.SIMD);
        assertEq(cfg.feeds[MainnetConfig.F_NHI].kind, DeployTypes.SWARM_NHI); // v2 leaf, not v1's feed
    }

    function _expectedLine() internal view returns (uint256) {
        uint256 twice = 2 * IERC20(Mainnet.V1_IMDUSD).totalSupply();
        return twice > cfg.migratorLine ? twice : cfg.migratorLine;
    }

    function test_migratorLineCoversLiveV1Supply() public {
        uint256 v1Supply = IERC20(Mainnet.V1_IMDUSD).totalSupply();
        emit log_named_decimal_uint("v1 supply", v1Supply, 18);
        assertGe(d.params.migratorLine(), v1Supply, "every v1 imdUSD can migrate");
        assertGe(d.params.migratorLine(), 2 * v1Supply, "twice the live supply");
        assertGe(d.params.migratorLine(), 150_000e18, "never below the floor");
        assertEq(d.params.migratorLine(), _expectedLine());
    }

    // ------------------------------------------------------------ authority

    function test_everyAuthorityIsTheSafe() public view {
        assertEq(d.params.governor(), safe, "params governor");
        assertEq(d.treasury.governor(), safe, "treasury governor");
        assertTrue(d.params.sealed_(), "sealed");
        // The broadcast really came from the deployer (its single-use wirer powers are what was spent).
        assertEq(d.usd.wirer(), deployer);
        assertEq(d.params.wirer(), deployer);
        assertEq(d.treasury.wirer(), deployer);
        assertEq(d.ledger.wirer(), deployer);
        // Minters are the system's own contracts; the bridge setter is the timelocked Parameters.
        assertEq(d.usd.ledger(), address(d.ledger));
        assertEq(d.usd.migrator(), address(d.migrator));
        assertEq(d.usd.bridgeSetter(), address(d.params));
        assertEq(d.usd.bridge(), address(0));
        assertEq(d.ledger.redeemer(), address(d.redeemer));
        assertEq(d.ledger.liquidator(), address(d.liquidator));
        assertEq(d.ledger.treasury(), address(d.treasury));
        assertEq(address(d.treasury.ledger()), address(d.ledger));
        assertEq(d.params.ledger(), address(d.ledger));
        assertEq(d.params.token(), address(d.usd));
        assertEq(d.usd.flashCap(), cfg.flashCap);
        assertEq(d.params.migratorLine(), _expectedLine());
        (address sv, uint256 share) = d.params.savingsSplit();
        assertEq(sv, address(d.savings));
        assertEq(share, cfg.savingsShare);
        assertEq(d.savings.asset(), address(d.usd));
        // The peg hook: keeper minter at genesis, cap 0, buffer target 0, its pool open at exactly $1.
        assertEq(d.usd.keeper(), address(d.hook), "keeper minter");
        assertEq(d.params.keeperCap(), 0, "cap starts at 0");
        assertEq(d.hook.buffer(), 0);
        assertEq(d.params.bufferTarget(), 0);
        assertEq(d.hook.stable(), address(d.usd));
        assertEq(d.hook.quote(), Mainnet.USDC);
        assertEq(d.hook.treasury(), address(d.treasury));
        assertEq(address(d.hook.params()), address(d.params));
        assertEq(address(d.hook.poolManager()), cfg.poolManager);
        assertTrue(d.hook.initialized());
        (uint160 sp,,,) = StateLibrary.getSlot0(IPoolManager(cfg.poolManager), d.pegKey.toId());
        assertEq(sp, d.hook.pegSqrtPriceX96(), "pool opened at $1");
        // Fee notes: wired both ways, sold for USDC to the Treasury, no series open at launch.
        assertEq(d.treasury.notes(), address(d.notes), "treasury -> notes");
        assertEq(d.params.notes(), address(d.notes), "params -> notes");
        assertEq(address(d.notes.token()), address(d.usd));
        assertEq(address(d.notes.quote()), Mainnet.USDC);
        assertEq(address(d.notes.treasury()), address(d.treasury));
        assertEq(d.notes.params(), address(d.params));
        assertEq(d.notes.count(), 0, "no series at launch");
        assertEq(d.notes.outstanding(), 0);
        assertEq(d.treasury.trailingRevenue(), 0);
    }

    function test_noContractHasAnOwner() public view {
        address[11] memory all = [
            address(d.usd),
            address(d.params),
            address(d.pricer),
            address(d.treasury),
            address(d.ledger),
            address(d.redeemer),
            address(d.liquidator),
            address(d.migrator),
            address(d.savings),
            address(d.notes),
            address(d.ledger.sorted())
        ];
        (bool hookOwner,) = address(d.hook).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hookOwner, "hook owner() exists");
        address[4] memory modules = [address(d.pegLP), address(d.loop), address(d.dexHook), address(d.dexLens)];
        for (uint256 i; i < modules.length; ++i) {
            assertGt(modules[i].code.length, 0, "module deployed");
            (bool ok,) = modules[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "module owner() exists");
        }
        for (uint256 i; i < all.length; ++i) {
            (bool ok,) = all[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "owner() exists");
        }
    }

    function test_deployerHasNoPowerLeft() public {
        ParametersBase.Config memory c0 = d.params.config(cfg.ilks[0].ilk);
        ParametersBase.Risk memory r0 = d.params.storedRisk(cfg.ilks[0].ilk);
        vm.startPrank(deployer);

        vm.expectRevert(ImdUSD.AlreadySet.selector);
        d.usd.wire(address(d.ledger), address(d.migrator), address(d.params));
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        d.usd.mint(deployer, 1);
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        d.usd.setBridge(address(d.ledger));

        vm.expectRevert(ParametersBase.AlreadyWired.selector);
        d.params.wire(address(d.ledger), address(d.usd));
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.addGenesisIlk("NEW", c0, r0);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.setGenesisMigratorLine(type(uint256).max);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.setGenesisSavings(address(d.savings), 0.8e18);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.setGenesisKeeper(deployer);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.setGenesisNotes(address(d.notes));
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.seal(); // a second seal would restart every type's redemption fee at the cap
        bytes memory openSeries = abi.encode(d.params.OPEN_NOTE_SERIES(), uint64(30 days), uint32(300), uint128(1_000e18));
        vm.expectRevert(Governed.NotGovernor.selector);
        d.params.propose(openSeries);
        vm.expectRevert(FeeNotes.Unauthorized.selector);
        d.notes.open(30 days, 300, 1_000e18);
        vm.expectRevert(Treasury.AlreadyWired.selector);
        d.treasury.wireNotes(address(d.notes));
        vm.expectRevert(Treasury.Unauthorized.selector);
        d.treasury.payNote(deployer, 1);
        vm.expectRevert(Treasury.Unauthorized.selector);
        d.treasury.noteRevenue(bytes32("ETH"), 1);
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        d.usd.setKeeper(deployer);
        vm.expectRevert(PegHook.NotGovernor.selector);
        d.hook.pullBuffer(0);
        vm.expectRevert(Governed.NotGovernor.selector);
        d.params.propose(abi.encode(uint8(5), uint64(0)));
        vm.expectRevert(Governed.NotGovernor.selector);
        d.params.cancel();

        vm.expectRevert(Treasury.AlreadyWired.selector);
        d.treasury.wire(ICoverable(address(d.ledger)));
        vm.expectRevert(Governed.NotGovernor.selector);
        d.treasury.propose(abi.encode(address(d.usd), deployer, uint256(1)));

        vm.expectRevert(LedgerBase.AlreadyWired.selector);
        d.ledger.wire(deployer, deployer);
        for (uint256 i; i < d.joins.length; ++i) {
            vm.expectRevert(Join.AlreadyWired.selector);
            d.joins[i].wire(deployer);
            vm.expectRevert(Join.Unauthorized.selector);
            d.joins[i].exit(deployer, 1);
        }
        vm.stopPrank();

        assertEq(d.usd.balanceOf(deployer), 0);
        assertEq(d.usd.totalSupply(), 0);
    }

    function test_safeGovernsThroughTheTimelock() public {
        vm.prank(safe);
        d.params.propose(abi.encode(uint8(5), uint64(0.3e18)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        assertEq(d.params.savingsShare(), 0.3e18);
    }

    /// @dev Fee notes on the deployed system: a borrower's 30 days of interest meters revenue; the Safe opens a
    /// 30-day series through the timelock (the deployer cannot: above); a buyer pays USDC to the Treasury under
    /// the 2x cap; at maturity the Treasury pays the face from interest it already holds, minting nothing.
    function test_safeOpensNoteSeriesThroughTheTimelock() public {
        _freshEth();
        bytes32 ilk = cfg.ilks[0].ilk;
        deal(Mainnet.WETH, alice, 100e18);
        vm.startPrank(alice);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), 100e18);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition(ilk, 0.05e18);
        d.ledger.open(ilk, 0, Adjust(100e18, 100_000e18, 0.05e18, p, n, false, type(uint256).max, address(0)));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        d.ledger.accrue(ilk);
        uint256 revenue = d.treasury.trailingRevenue();
        // The upfront fee (100k x 5% x 7/365 = 95.89) + 30 days of 5% on the debt incl. it: all to the Treasury (no savers).
        assertApproxEqRel(revenue, uint256(95.89e18) + uint256(100_095.89e18) * 5 * 30 / 36500, 0.001e18, "upfront fee + 30 days of interest");
        assertEq(d.usd.balanceOf(address(d.treasury)), revenue);

        bytes memory open = abi.encode(d.params.OPEN_NOTE_SERIES(), uint64(30 days), uint32(300), uint128(50_000e18));
        vm.prank(safe);
        d.params.propose(open);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, vm.getBlockTimestamp() + 48 hours));
        d.params.applyPending();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        assertEq(d.notes.count(), 1, "series opened by the timelock");
        FeeNotes.Series memory s = d.notes.series(1);
        assertEq(s.discountBps, 300);
        assertEq(s.maturity, vm.getBlockTimestamp() + 7 days + 30 days);
        assertEq(d.notes.capacity(), 2 * revenue, "cap = 2x trailing revenue");

        address buyer = makeAddr("buyer");
        vm.prank(USDC_WHALE);
        IERC20(Mainnet.USDC).transfer(buyer, 10_000e6);
        uint256 face = 800e18;
        uint256 price = d.notes.priceOf(1, face);
        assertEq(price, 776e6, "800 at 3% off");
        uint256 tUsdc = IERC20(Mainnet.USDC).balanceOf(address(d.treasury));
        vm.startPrank(buyer);
        IERC20(Mainnet.USDC).approve(address(d.notes), price);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.CapExceeded.selector, 2 * revenue));
        d.notes.buy(1, 2 * revenue + 1);
        d.notes.buy(1, face);
        vm.stopPrank();
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(d.treasury)) - tUsdc, price, "USDC to the Treasury");
        assertEq(d.notes.balanceOf(buyer, 1), face);

        vm.warp(s.maturity - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.NotMatured.selector, s.maturity));
        d.notes.redeem(1, face);
        vm.warp(s.maturity);
        d.ledger.accrue(ilk); // interest since the last settlement funds the Treasury
        uint256 supply = d.usd.totalSupply();
        vm.prank(buyer);
        d.notes.redeem(1, face);
        assertEq(d.usd.balanceOf(buyer), face, "paid in imdUSD");
        assertEq(d.usd.totalSupply(), supply, "nothing minted");
        assertEq(d.notes.outstanding(), 0);
        (uint128 debt,,,, uint128 bad) = d.ledger.ilkState(ilk);
        assertEq(
            d.usd.totalSupply(),
            uint256(debt) + bad + d.ledger.reserveBacked() + d.migrator.outstanding() + d.hook.outstanding(),
            "supply equation"
        );
    }

    function _freshEth() internal {
        (uint80 id, int256 answer,,, uint80 ans) = IAgg(Mainnet.CL_ETH_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer, block.timestamp, block.timestamp, ans)
        );
    }

    // ------------------------------------------------------------ the optional modules (mainnet: all but SEAT)

    /// @dev Only the beta is capped: the full config is uncapped and keeps v1's 6h NHI grace.
    function test_fullIsUncappedWithTheNhiGrace() public view {
        (bool capped, uint256 line) = d.params.chainCap();
        assertFalse(capped, "full: no chain line");
        assertEq(line, 0);
        assertEq(d.params.maxLull(), 6 hours, "full: v1's grace schedule");
    }

    function test_mainnetModules() public view {
        assertTrue(cfg.lpVault.enabled && cfg.loopVault.enabled && cfg.dex.enabled, "modules on");
        assertFalse(cfg.seats.enabled, "SEAT is not registered on mainnet");
        assertEq(address(d.seatJoin), address(0), "no seat join");
        assertFalse(d.params.exists("SEAT"), "no SEAT type");
        // PegLPVault: the v2 peg pool, the peg hook, the v2 Treasury, the at-peg band.
        assertEq(address(d.pegLP.hook()), address(d.hook));
        assertEq(address(d.pegLP.poolManager()), cfg.poolManager);
        assertEq(d.pegLP.treasury(), address(d.treasury));
        assertEq(d.pegLP.tickUpper() - d.pegLP.tickLower(), 2 * cfg.lpVault.band);
        assertEq(d.pegLP.totalSupply(), 0, "not seeded by the script");
        // LoopVault on sIMD (live leg present).
        assertEq(address(d.loop.ledger()), address(d.ledger));
        assertEq(d.loop.ilk(), bytes32("SIMD"));
        assertEq(address(d.loop.staked()), Mainnet.SIMD);
        assertEq(address(d.loop.imd()), Mainnet.IMD);
        assertEq(d.loop.treasury(), address(d.treasury));
        // Compound DEX: sIMD/sINFER, fees to the v2 Treasury, opened at the INFER/IMD launch pool's price.
        assertEq(d.dexHook.treasury(), address(d.treasury));
        assertEq(address(d.dexHook.vault0()), Mainnet.SINFER, "INFER sorts first");
        assertEq(address(d.dexHook.vault1()), Mainnet.SIMD);
        assertEq(uint160(address(d.dexHook)) & 0x3fff, d.dexHook.FLAGS(), "mined permission bits");
        (uint160 market,,,) =
            StateLibrary.getSlot0(IPoolManager(cfg.poolManager), PoolId.wrap(MainnetConfig.INFER_IMD_POOL_ID));
        assertEq(d.dexHook.initialSqrtPriceX96(), market, "opened at the launch pool's price");
        (uint160 sp,,,) = StateLibrary.getSlot0(IPoolManager(cfg.poolManager), d.dexKey.toId());
        assertEq(sp, market, "dex pool initialised");
        assertEq(d.dexHook.totalSupply(), 0, "not seeded by the script");
        assertGt(d.curveLib.code.length, 0);
        assertGt(d.oracleLib.code.length, 0);
    }

    /// @dev EIP-7825 caps a transaction at 2^24 gas. v1's vault went over it with forge's default 1.3x gas margin, so
    /// every estimated transaction must fit with that margin.
    /// @dev The script's own per-transaction estimates.
    function _gasRows() internal view virtual returns (Deploy.GasRow[] memory) {
        return deployer_.gasLog();
    }

    function test_everyDeployTxFitsTheEip7825Cap() public {
        Deploy.GasRow[] memory rows = _gasRows();
        uint256 total;
        uint256 largest;
        string memory largestLabel;
        for (uint256 i; i < rows.length; ++i) {
            total += rows[i].gas;
            if (rows[i].gas > largest) (largest, largestLabel) = (rows[i].gas, rows[i].label);
            assertLe(rows[i].gas * 13 / 10, 16_777_216, rows[i].label);
        }
        emit log_named_uint("transactions", rows.length);
        emit log_named_uint("total gas", total);
        emit log_named_uint("largest gas", largest);
        emit log_string(largestLabel);
    }

    /// @dev The standing bid's deploy transactions (PricerOracle, both sleeves, the Allocator, their wiring).
    function test_printBackstopDeployGas() public {
        Deploy.GasRow[] memory rows = _gasRows();
        uint256 n;
        for (uint256 i; i < rows.length; ++i) {
            bytes memory l = bytes(rows[i].label);
            if (_has(l, "ackstop") || _has(l, "PricerOracle") || _has(l, "Allocator") || _has(l, "backstopOracle")) {
                emit log_named_uint(rows[i].label, rows[i].gas);
                ++n;
            }
        }
        assertGt(n, 0, "the backstop is deployed");
    }

    function _has(bytes memory s, string memory sub) internal pure returns (bool) {
        bytes memory t = bytes(sub);
        if (t.length > s.length) return false;
        for (uint256 i; i + t.length <= s.length; ++i) {
            bool m = true;
            for (uint256 j; j < t.length && m; ++j) m = s[i + j] == t[j];
            if (m) return true;
        }
        return false;
    }

    // ------------------------------------------------------------ every type is what the config says

    function test_everyIlkMatchesTheConfig() public view {
        // + the peg-position type, added after the config's types and checked below
        assertEq(d.params.ilkCount(), cfg.ilks.length + (cfg.pegPositions.enabled ? 1 : 0));
        for (uint256 i; i < cfg.ilks.length; ++i) {
            DeployTypes.IlkSpec memory s = cfg.ilks[i];
            assertEq(d.params.ilks(i), s.ilk, "order");
            ParametersBase.Config memory c = d.params.config(s.ilk);
            assertEq(c.token, s.token, "token");
            assertEq(c.join, address(d.joins[i]), "join");
            assertEq(d.joins[i].token(), s.token, "join token");
            assertEq(d.joins[i].ledger(), address(d.ledger), "join ledger");
            assertEq(address(c.median), address(d.feeds[s.median]), "median");
            assertEq(address(c.spot), address(d.feeds[s.spot]), "spot");
            assertEq(address(c.nhi), s.nhi == DeployTypes.NONE ? address(0) : address(d.feeds[s.nhi]), "nhi");
            assertEq(c.yieldRate, s.yieldRate == DeployTypes.NONE ? address(0) : address(d.feeds[s.yieldRate]), "yield");
            assertEq(c.pegAggregator, s.pegAggregator, "peg");
            assertEq(address(c.liveSpot), s.liveSpot == DeployTypes.NONE ? address(0) : address(d.feeds[s.liveSpot]), "live");
            assertEq(c.redeemable, s.redeemable, "redeemable");
            assertEq(abi.encode(d.params.storedRisk(s.ilk)), abi.encode(s.risk), "risk");
        }
        if (cfg.pegPositions.enabled) {
            bytes32 peg = cfg.pegPositions.ilk;
            ParametersBase.Config memory pc = d.params.config(peg);
            assertEq(pc.token, address(d.pegCollateral), "peg: token = the zap-only wrapper");
            assertEq(address(d.pegCollateral.shares()), address(d.pegLP), "peg: wrapper over PegLPVault shares");
            assertEq(d.pegCollateral.zap(), address(d.pegZap), "peg: only the zap mints");
            assertEq(pc.join, address(d.pegJoin), "peg: join");
            assertEq(d.pegJoin.ledger(), address(d.ledger), "peg: join ledger");
            assertEq(address(pc.median), address(d.pegFeed), "peg: median = share feed");
            assertTrue(PegShareFeed(address(pc.spot)).twoSidedOnly(), "peg: spot = the two-sided leg");
            assertEq(address(PegShareFeed(address(pc.spot)).vault()), address(d.pegLP), "peg: spot's vault");
            assertFalse(pc.redeemable, "peg: not redeemable");
            assertEq(abi.encode(d.params.storedRisk(peg)), abi.encode(cfg.pegPositions.risk), "peg: risk");
            assertTrue(d.params.depthIlk() != peg, "peg debt is not the depth-gated type");
            assertEq(d.pegZap.ilk(), peg, "zap ilk");
        }
    }

    function test_everyFeedMatchesItsNode() public view {
        for (uint256 i; i < cfg.feeds.length; ++i) {
            DeployTypes.FeedNode memory n = cfg.feeds[i];
            address f = address(d.feeds[i]);
            if (n.kind == DeployTypes.EXISTING) {
                assertEq(f, n.source, "existing");
            } else if (n.kind == DeployTypes.CHAINLINK) {
                assertEq(ChainlinkFeed(f).aggregator(), n.source, "aggregator");
                assertEq(ChainlinkFeed(f).tokenDecimals(), n.decimals, "decimals");
                assertEq(ChainlinkFeed(f).maxAge(), n.maxAge, "maxAge");
            } else if (n.kind == DeployTypes.PRODUCT) {
                assertEq(address(ProductFeed(f).a()), address(d.feeds[n.a]), "a");
                assertEq(address(ProductFeed(f).b()), address(d.feeds[n.b]), "b");
            } else if (n.kind == DeployTypes.SWARM_PRICE || n.kind == DeployTypes.SWARM_SPOT || n.kind == DeployTypes.SWARM_NHI) {
                assertEq(SwarmFeed(f).maxAge(), n.maxAge, "leaf maxAge");
                assertEq(SwarmFeed(f).maxDeviationBps(), n.cap, "leaf cap");
                assertEq(SwarmFeed(f).MAX_ALLOWANCE_BPS(), 20_000, "leaf stale cap");
            } else if (n.kind == DeployTypes.LIVE_POOL) {
                assertEq(address(LivePoolPrice(f).manager()), n.source, "manager");
                assertEq(PoolId.unwrap(LivePoolPrice(f).poolId()), n.poolId, "pool");
                assertEq(LivePoolPrice(f).baseIsToken0(), n.passOneE18, "base side");
            } else {
                assertEq(RateFeed(f).rateSource(), n.source, "rate source");
                assertEq(RateFeed(f).selector(), n.selector, "selector");
                assertEq(RateFeed(f).passOneE18(), n.passOneE18, "passOne");
                assertEq(address(RateFeed(f).underlying()), address(d.feeds[n.a]), "underlying");
                assertEq(RateFeed(f).maxGrowthPerSecond(), n.cap, "cap");
            }
            // Every feed answers something on mainnet (staleness aside), but the swarm leaves and what is priced through
            // them: deployed empty, unpriced until the first relay.
            bool empty = i == MainnetConfig.F_IMD_MEDIAN || i == MainnetConfig.F_IMD_SPOT || i == MainnetConfig.F_IMD_USD_SPOT
                || i == MainnetConfig.F_SIMD_SPOT || i == MainnetConfig.F_NHI || i == MainnetConfig.F_IMD_USD_MEDIAN
                || i == MainnetConfig.F_SIMD_MEDIAN;
            (uint256 v,) = IFeed(f).latestValue();
            if (empty) assertEq(v, 0, "empty until the first relay");
            else assertGt(v, 0, "feed reads zero");
        }
    }

    // ------------------------------------------------------------ the deployed system works

    function test_borrowAndRepayEth() public {
        (uint80 id, int256 answer,,, uint80 ans) = IAgg(Mainnet.CL_ETH_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer, block.timestamp, block.timestamp, ans)
        );
        bytes32 ilk = cfg.ilks[0].ilk;
        deal(Mainnet.WETH, alice, 10e18);
        vm.startPrank(alice);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), 10e18);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition(ilk, 0.03e18);
        d.ledger.open(ilk, 0, Adjust(10e18, 5_000e18, 0.03e18, p, n, false, type(uint256).max, address(0)));
        assertEq(d.usd.balanceOf(alice), 5_000e18);
        assertEq(IERC20(Mainnet.WETH).balanceOf(address(d.joins[0])), 10e18);
        vm.stopPrank();
        // The upfront fee was minted to the Treasury; it comes back to repay in full.
        uint256 owed = d.ledger.debtOf(_pid(ilk, alice));
        assertApproxEqRel(owed - 5_000e18, uint256(5_000e18) * 0.03e18 * 7 days / (365 days * 1e18), 0.001e18, "7 days at 3%");
        vm.prank(address(d.treasury));
        d.usd.transfer(alice, owed - 5_000e18);
        vm.prank(alice);
        d.ledger.open(ilk, 0, Adjust(-10e18, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(IERC20(Mainnet.WETH).balanceOf(alice), 10e18, "collateral back");
        assertEq(d.ledger.debtOf(_pid(ilk, alice)), 0);
        assertEq(d.usd.totalSupply(), 0);
    }

    // ------------------------------------------------------------ the deployed peg hook works

    address constant USDC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // Morpho Blue
    PegRouter router;

    /// @dev After the deploy: the Safe raises the cap and sets the 5,000 USDC buffer target (48h each); an LP opens a
    /// band; then strangers close an excursion above (mint + sell, profit kept as the buffer), below (buy back + burn)
    /// and a deeper fall (the buffer buys, held by the Treasury).
    /// @notice E1: the full config's 100k sIMD line is a target; genesis sets what D1 admits at the posted depth.
    function test_fullSimdLineIsDepthGated() public {
        assertEq(d.params.storedRisk("SIMD").line, 33_733e18, "rule-admitted line at $80.1k, not 100k");
        // Depth is MEASURED. A fresh ImdDepth reads 0 (no week of lows yet), so the live line is 0 and no
        // sIMD debt can open until the keeper has sampled for a week; the stored line is what the posted cap admits.
        assertEq(d.params.depthIMD(), 0, "fresh ImdDepth: no week of lows yet");
        assertEq(d.params.risk("SIMD").line, 0, "the rule binds live: no sIMD debt at zero depth");
        vm.mockCall(address(d.imdDepth), abi.encodeWithSignature("depth()"), abi.encode(uint256(80_100e18)));
        (bool holds,,) = d.params.depthRule();
        assertTrue(holds, "the full deploy satisfies D1 at the measured depth the cap assumes");
        assertEq(d.params.risk("SIMD").line, 33_733e18);
        assertEq(d.params.otherImdLines(), 3_000e18, "Robinhood's IMD line counted (E2)");
        assertEq(d.params.otherImdChop(), 0.2e18);
        // The same math: 100k only once the posted depth is ~$179.5k.
        assertEq(MainnetConfig.simdLineFor(100_000e18, 80_100e18), 33_733e18);
        assertLt(MainnetConfig.simdLineFor(100_000e18, 175_000e18), 100_000e18);
        assertEq(MainnetConfig.simdLineFor(100_000e18, 179_500e18), 100_000e18);
        assertEq(MainnetConfig.simdLineFor(100_000e18, 1_000_000e18), 100_000e18, "capped at the target");
        assertEq(MainnetConfig.simdLineFor(100_000e18, 20_000e18), 0, "no room, no line");
    }

    /// @notice D4: the second legs are live at the fork block. cbBTC/WBTC/wstETH quote both legs, agree within skew, and
    /// pay at the higher one (the redemption payout) while borrowing uses the lower.
    function test_secondLegsPriceAtTheForkBlock() public view {
        bytes32[3] memory ks = [bytes32("WSTETH"), bytes32("CBBTC"), bytes32("WBTC")];
        for (uint256 i; i < 3; ++i) {
            ParametersBase.Config memory c = d.params.config(ks[i]);
            assertTrue(address(c.spot) != address(c.median), "a second leg");
            (uint256 m,) = c.median.latestValue();
            (uint256 sp,) = c.spot.latestValue();
            assertGt(m, 0);
            assertGt(sp, 0);
            (uint256 low, uint256 high, uint256 payout,,,, bool borrowable) = _q(ks[i]);
            assertTrue(borrowable, "legs agree within skew");
            assertEq(low, m < sp ? m : sp);
            assertEq(high, m > sp ? m : sp);
            assertEq(payout, high);
        }
    }

    function _q(bytes32 ilk) internal view returns (uint256, uint256, uint256, uint256, uint256, bool, bool) {
        (bool ok, bytes memory ret) = address(d.pricer).staticcall(abi.encodeWithSignature("quote(bytes32)", ilk));
        require(ok, "quote");
        return abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, bool, bool));
    }

    /// @dev The live Chainlink USDC/USD answer restamped now: the suite warps through timelocks, and the hook's quote gate
    /// (fix A4) refuses a USDC price older than its max age.
    function _freshUsdc() internal {
        (, int256 a,,,) = IUsdcAgg(Mainnet.CL_USDC_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_USDC_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), a, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function test_pegKeeperRoundTripAfterGovernance() public {
        PegHook hook = d.hook;
        // The deployed hook gates on the real USDC/USD feed: sound at the fork block, stale after the timelocks below.
        assertEq(hook.quoteUsdFeed(), Mainnet.CL_USDC_USD);
        assertEq(hook.quoteFeedMaxAge(), 1 days + 1 hours);
        assertTrue(hook.quoteSound(), "USDC/USD fresh and >= $0.98 at the fork block");
        bytes memory raise = abi.encode(d.params.SET_KEEPER_CAP(), uint256(500_000e18));
        vm.prank(safe);
        d.params.propose(raise);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        assertEq(d.params.keeperCap(), 500_000e18);

        bytes memory target = abi.encode(d.params.SET_BUFFER_TARGET(), uint256(5_000e6));
        vm.prank(safe);
        d.params.propose(target);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        assertEq(d.params.bufferTarget(), 5_000e6);

        router = new PegRouter(IPoolManager(cfg.poolManager));
        deal(address(d.usd), address(router), 5_000_000e18, true);
        vm.prank(USDC_WHALE);
        IERC20(Mainnet.USDC).transfer(address(router), 5_000_000e6);
        int24 t = hook.pegTick();
        router.addLiquidity(d.pegKey, ModifyLiquidityParams(t - 1000, t + 1000, 1e18, 0));
        _hold(0, 31 minutes);

        _hold(60, 31 minutes);
        assertFalse(hook.quoteSound(), "96h of warps: the real feed is stale");
        vm.expectRevert(PegHook.QuoteUnsound.selector);
        hook.provide();
        _freshUsdc();
        vm.prank(makeAddr("s1"));
        uint256 minted = hook.provide();
        assertGt(minted, 0);
        uint256 kept = hook.buffer();
        assertGt(kept, 0, "the sale's profit is kept as the buffer");
        _hold(-300, 31 minutes);
        _freshUsdc();
        uint256 tUsd = d.usd.balanceOf(address(d.treasury));
        vm.prank(makeAddr("s2"));
        (uint256 burned, uint256 bought) = hook.withdraw();
        assertEq(burned, minted, "everything minted bought back and burned");
        assertGt(bought, 0, "then the buffer bought below the peg");
        assertEq(d.usd.balanceOf(address(d.treasury)) - tUsd, bought, "held by the Treasury");
        assertLt(hook.buffer(), kept);
        assertGe(IERC20(Mainnet.USDC).balanceOf(address(hook)), hook.principal() + hook.buffer(), "solvent");
        emit log_named_decimal_uint("minted", minted, 18);
        emit log_named_decimal_uint("burned", burned, 18);
        emit log_named_decimal_uint("buffer kept", kept, 6);
        emit log_named_decimal_uint("buffer bought", bought, 18);
        emit log_named_decimal_uint("buffer left", hook.buffer(), 6);
    }

    function _moveTo(int24 ticks) internal {
        int24 t = d.hook.pegTick();
        uint160 limit = TickMath.getSqrtPriceAtTick(d.hook.stableIsToken0() ? t + ticks : t - ticks);
        (uint160 now_,,,) = StateLibrary.getSlot0(IPoolManager(cfg.poolManager), d.pegKey.toId());
        if (now_ == limit) return;
        router.swap(d.pegKey, SwapParams(limit < now_, -int256(1e30), limit));
    }

    function _hold(int24 ticks, uint256 secs) internal {
        for (uint256 s; s < secs; s += 60) {
            _moveTo(ticks);
            router.swap(d.pegKey, SwapParams(true, -int256(uint256(d.hook.stableIsToken0() ? 1e12 : 1)), TickMath.MIN_SQRT_PRICE + 1));
            vm.warp(vm.getBlockTimestamp() + 60);
            vm.roll(vm.getBlockNumber() + 5);
        }
        _moveTo(ticks);
    }
}
