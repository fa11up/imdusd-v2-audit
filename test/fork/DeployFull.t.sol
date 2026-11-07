// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployTypes, MainnetConfig} from "../../script/DeployConfig.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {MockFeed, MockSeatFeed} from "../utils/Mocks.sol";
import {PegRouter} from "../utils/PegSystem.sol";
import {CompoundSystem} from "../utils/CompoundSystem.sol";
import {CdxRouter} from "../utils/DexMocks.sol";
import {PoolRoute} from "./LoopVault.fork.t.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {FeeNotes} from "../../src/peg/FeeNotes.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IAggF {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IDripperF {
    function drip() external returns (uint256 toVault, uint256 toKeeper);
    function canDrip() external view returns (bool);
}

/// @notice A1 rehearsal: the REAL script with EVERY module on, on a mainnet fork (the seat type registered with mock
/// sale feeds IN THIS TEST ONLY: mainnet's config leaves it off), then one cross-module path per pair of modules that
/// share state. After every step: the supply equation over every type and each touched module's solvency check.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/DeployFull.t.sol
contract DeployFullForkTest is CompoundSystem {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    address constant USDC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // Morpho Blue
    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";
    bytes32 constant SEAT = "SEAT";

    address deployer = makeAddr("deployer");
    address safe = Mainnet.GOVERNANCE_SAFE;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address desk = makeAddr("desk"); // borrows imdUSD against ETH to fund routers: no dealt supply anywhere

    Deploy script;
    Deploy.Deployed d;
    DeployTypes.Config cfgS;
    MockSeatFeed seatMedian;
    MockFeed seatSpot;
    PegRouter pegRouter;

    uint8 nSeatMedian;
    int256 ethAnswer;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        (, ethAnswer,,,) = IAggF(Mainnet.CL_ETH_USD).latestRoundData();
        _freshen();
        seatMedian = new MockSeatFeed(1.3e18, 60); // wei per seat (p25 1.28 ETH over 60 seats, 2026-10-21)
        seatSpot = new MockFeed(1.3e18);

        DeployTypes.Config memory c = MainnetConfig.get();
        // The rehearsal adds two EXISTING nodes (the mock sale feeds) and turns the seat module on.
        DeployTypes.FeedNode[] memory feeds = new DeployTypes.FeedNode[](c.feeds.length + 2);
        for (uint256 i; i < c.feeds.length; ++i) feeds[i] = c.feeds[i];
        nSeatMedian = uint8(c.feeds.length);
        feeds[nSeatMedian] = _existing(address(seatMedian));
        feeds[nSeatMedian + 1] = _existing(address(seatSpot));
        c.feeds = feeds;
        c.seats = MainnetConfig.seatSpec(true, nSeatMedian, nSeatMedian + 1, MainnetConfig.F_ETH);
        cfgS.seats = c.seats;

        vm.deal(deployer, 10 ether);
        script = new Deploy();
        // One test call runs all ~76 deployment transactions, which together exceed a mainnet block's gas limit (the
        // real deployment is 76 separate transactions; Deploy.t.sol and the offline full system check each one's gas).
        vm.pauseGasMetering();
        d = script.deployAs(c, deployer);
        vm.resumeGasMetering();

        // CompoundSystem's DEX helpers on the deployed hook.
        pm = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
        hook = d.dexHook;
        lens = d.dexLens;
        key = d.dexKey;
        treasury = address(d.treasury);
        router = new CdxRouter(pm);
        _attest();
        // The desk: 1,000 ETH of collateral, 1M imdUSD at 3%.
        _borrowEth(desk, 1_000e18, 1_000_000e18, 0.03e18);
    }

    // ------------------------------------------------------------ fork helpers

    function _existing(address f) internal pure returns (DeployTypes.FeedNode memory n) {
        n.kind = DeployTypes.EXISTING;
        n.source = f;
    }

    function _fundRaw(address to, uint8 i, uint256 amount) internal override {
        deal(address(_tok(i)), to, _tok(i).balanceOf(to) + amount);
    }

    /// @dev Depth is MEASURED, so a fresh deploy has no sIMD room until the samplers hold a week of readings.
    /// A keeper week on the live pools: every sampler hourly, the aggregate poked daily, feeds kept fresh.
    function _keeperWeek() internal {
        for (uint256 h; h < 7 * 24; ++h) {
            _freshen();
            for (uint256 i; i < d.samplers.length; ++i) {
                try d.samplers[i].sample() {} catch {}
            }
            if (h % 24 == 0) d.imdDepth.poke();
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        _freshen();
        d.imdDepth.poke();
        assertGt(d.imdDepth.depth(), 0, "measured depth after a keeper week");
    }

    /// @dev Chainlink ETH/USD at its forked answer stamped now; v2's swarm leaves (sIMD's attested legs + NHI) fresh, at the
    /// live pool (they deploy empty).
    function _freshen() internal {
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), ethAnswer, block.timestamp, block.timestamp, uint80(1))
        );
        if (d.feeds.length == 0) return; // setUp, before the deploy
        (uint256 imdEth,) = d.feeds[MainnetConfig.F_IMD_LIVE].latestValue();
        _leaf(MainnetConfig.F_IMD_MEDIAN, imdEth);
        _leaf(MainnetConfig.F_IMD_SPOT, imdEth);
        _leaf(MainnetConfig.F_NHI, 0.98e18);
    }

    function _leaf(uint8 node, uint256 v) internal {
        vm.mockCall(address(d.feeds[node]), abi.encodeWithSignature("latestValue()"), abi.encode(v, uint64(block.timestamp)));
        vm.mockCall(address(d.feeds[node]), abi.encodeWithSignature("isStale()"), abi.encode(false));
    }

    /// @dev Chainlink USDC/USD at its forked answer stamped now (the PegHook's quote gate, fix A4).
    function _freshUsdc() internal {
        (, int256 a,,,) = IAggF(Mainnet.CL_USDC_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_USDC_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), a, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// @dev The keeper's fresh attestation: sIMD's attested median and spot = the live IMD/ETH pool, now.
    function _attest() internal {
        _freshen();
        seatMedian.set(seatMedian.value());
        seatSpot.set(seatSpot.value());
    }

    function _next() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function _borrowEth(address who, uint256 weth, uint256 debt, uint64 rate) internal {
        deal(Mainnet.WETH, who, IERC20(Mainnet.WETH).balanceOf(who) + weth);
        vm.startPrank(who);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), type(uint256).max);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition(ETH, rate);
        d.ledger.open(ETH, 0, Adjust(int256(weth), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
        vm.stopPrank();
    }

    function _govern(bytes memory payload) internal {
        vm.prank(safe);
        d.params.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.roll(vm.getBlockNumber() + 14_400);
        d.params.applyPending();
        _attest();
    }

    // ------------------------------------------------------------ the checks after every step

    function _assertSupply() internal {
        uint256 sum;
        for (uint256 i; i < d.params.ilkCount(); ++i) {
            bytes32 ilk = d.params.ilks(i);
            d.ledger.accrue(ilk);
            (uint128 debt,,,, uint128 bad) = d.ledger.ilkState(ilk);
            sum += uint256(debt) + bad;
        }
        sum += d.ledger.reserveBacked() + d.migrator.outstanding() + d.hook.outstanding();
        assertEq(d.usd.totalSupply(), sum, "supply == debt + bad + reserve + migrated + keeper");
    }

    function _assertModules() internal view {
        // sImdUSD
        assertGe(d.usd.balanceOf(address(d.savings)), d.savings.tracked(), "savings balance >= tracked");
        assertGe(d.savings.tracked(), d.savings.totalAssets(), "savings tracked >= counted");
        // peg keeper
        assertGe(
            IERC20(Mainnet.USDC).balanceOf(address(d.hook)), d.hook.principal() + d.hook.buffer(), "keeper solvent"
        );
        assertLe(d.hook.outstanding(), d.params.keeperCap(), "keeper cap");
        // fee notes: every note sold is a claim the Treasury pays from its balance (checked where bought)
        // DEX
        (uint256 x, uint256 y) = d.dexLens.curveBalances(d.dexHook);
        (uint256 h0, uint256 h1) = d.dexHook.totals();
        assertLe(x, h0, "dex curve x <= held0");
        assertLe(y, h1, "dex curve y <= held1");
        // LoopVault: its position is the Ledger's record; no holders, no debt
        (uint256 lc, uint256 ld) = d.loop.position();
        assertEq(d.ledger.position(_pid(SIMD, address(d.loop))).collateral, lc);
        if (d.loop.totalSupply() <= d.loop.DEAD_SHARES()) assertEq(ld, 0, "loop: no holders, no debt");
        // seats: units == seats custodied by their accounts (only one seat is used here) and the pool == record
        (, uint128 coll,,,) = d.ledger.ilkState(SEAT);
        assertEq(d.seatJoin.balanceOf(address(d.seatJoin)), coll, "seat pool == recorded collateral");
    }

    function _check() internal {
        _assertSupply();
        _assertModules();
    }

    // ------------------------------------------------------------ the deployment itself

    function test_rehearsal_everyModuleWiredAndPowerless() public {
        assertTrue(d.params.exists(SEAT), "SEAT registered (rehearsal only)");
        ParametersBase.Config memory sc = d.params.config(SEAT);
        assertTrue(sc.auction && !sc.redeemable, "seat: auction, not redeemable");
        assertEq(sc.join, address(d.seatJoin));
        assertEq(address(sc.median), address(d.seatFeed));
        assertEq(address(sc.spot), address(d.seatSpot));
        assertEq(address(d.seatJoin.ledger()), address(d.ledger));
        assertEq(address(d.seatJoin.nft()), MainnetConfig.IDMD);
        assertEq(d.seatJoin.maxSeats(), 25);
        assertEq(d.seatJoin.perBorrower(), 3);
        assertEq(d.seatJoin.wirer(), deployer);
        vm.startPrank(deployer);
        vm.expectRevert();
        d.seatJoin.wire(deployer); // spent
        vm.expectRevert();
        d.seatJoin.setLimits(100, 10); // Parameters' timelock only
        vm.stopPrank();
        // Every authority: the Safe; no owner() on any module.
        assertEq(d.params.governor(), safe);
        assertEq(d.treasury.governor(), safe);
        address[7] memory mods = [
            address(d.pegLP), address(d.loop), address(d.dexHook), address(d.dexLens), address(d.seatJoin),
            address(d.seatFeed), address(d.seatSpot)
        ];
        for (uint256 i; i < mods.length; ++i) {
            (bool ok,) = mods[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "owner() exists");
        }
        _check();
    }

    // ------------------------------------------------------------ 1. Ledger (sIMD) x sImdUSD x Treasury meter

    /// @dev sIMD-backed imdUSD saved in sImdUSD: 30 days of interest split 35% to the savers, the rest metered by
    /// the Treasury; the saver leaves with more.
    function test_rehearsal_simdBorrowSaveInterestSplit() public {
        _keeperWeek();
        deal(Mainnet.IMD, alice, 20_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.IMD).approve(address(d.ledger), type(uint256).max);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition(SIMD, 0.05e18);
        (uint256 simdUsd,) = d.feeds[MainnetConfig.F_SIMD_LIVE].latestValue();
        uint256 shares = IERC4626(Mainnet.SIMD).convertToShares(20_000e18);
        uint256 debt = Math.mulDiv(shares, simdUsd, 1e18) / 4; // 25% LTV, far above any NHI-derived mat
        // The sIMD line follows IMD's measured depth, so it moves with the market: borrow at most half of what is left of it.
        (uint128 owed,,,,) = d.ledger.ilkState(SIMD);
        uint256 room = uint256(d.params.risk(SIMD).line) - owed;
        if (debt > room / 2) debt = room / 2;
        d.ledger.open(SIMD, 0, Adjust(int256(20_000e18), int256(debt), 0.05e18, p, n, true, type(uint256).max, address(0)));
        d.usd.approve(address(d.savings), debt);
        uint256 sv = d.savings.deposit(debt, alice);
        vm.stopPrank();
        _check();
        uint256 t0 = d.usd.balanceOf(address(d.treasury));
        uint256 s0 = d.usd.balanceOf(address(d.savings));
        uint256 x0 = d.usd.balanceOf(address(d.edge)); // the edge premium (20% of sIMD interest)
        uint256 m0 = d.treasury.trailingRevenue(); // already holds the upfront fees
        (uint128 a0,,,,) = d.ledger.ilkState(SIMD);
        (uint128 e0,,,,) = d.ledger.ilkState(ETH);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        // C6: each accrual pays savers min(35%, max(5%, saved / supply)), supply read before that accrual's mint.
        uint256 expected = _saversCut(SIMD);
        expected += _saversCut(ETH);
        (uint128 a1,,,,) = d.ledger.ilkState(SIMD);
        (uint128 e1,,,,) = d.ledger.ilkState(ETH);
        uint256 interest = uint256(a1) - a0 + e1 - e0;
        uint256 toSavers = d.usd.balanceOf(address(d.savings)) - s0;
        uint256 toTreasury = d.usd.balanceOf(address(d.treasury)) - t0;
        uint256 toEdge = d.usd.balanceOf(address(d.edge)) - x0;
        assertGt(toEdge, 0, "the edge sleeve earns its premium on sIMD interest");
        assertApproxEqAbs(toSavers + toTreasury + toEdge, interest, 10, "all interest minted to the three");
        assertApproxEqAbs(toSavers, expected, 2, "savers get the uptake-scaled share");
        assertLt(toSavers, interest * 35 / 100, "a vault holding a small slice of supply earns less than 35%");
        assertEq(d.treasury.trailingRevenue() - m0, toTreasury, "the Treasury's share is metered");
        d.savings.sync(); // the arrival starts vesting
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        uint256 got = d.savings.redeem(sv, alice, alice);
        assertGt(got, debt, "saver earned");
        _check();
    }

    /// @dev Accrue `ilk` and return what the savers' share of that accrual should be (C6's uptake rule).
    function _saversCut(bytes32 ilk) internal returns (uint256) {
        uint256 share = d.params.savingsShare();
        uint256 eff = Math.mulDiv(d.savings.totalAssets(), 1e18, d.usd.totalSupply());
        if (eff < 0.05e18) eff = 0.05e18;
        if (eff > share) eff = share;
        (uint128 x0,,,,) = d.ledger.ilkState(ilk);
        d.ledger.accrue(ilk);
        (uint128 x1,,,,) = d.ledger.ilkState(ilk);
        return Math.mulDiv(uint256(x1) - x0, eff, 1e18);
    }

    // ------------------------------------------------------------ 2. PegHook keeper x PegLPVault x Treasury

    function test_rehearsal_pegKeeperRoundTripWithLpVaultLiquidity() public {
        _govern(abi.encode(d.params.SET_KEEPER_CAP(), uint256(250_000e18)));
        _govern(abi.encode(d.params.SET_BUFFER_TARGET(), uint256(5_000e6)));

        // A wide band (borrowed imdUSD) gives the pool depth; then 30 min of history at the peg.
        pegRouter = new PegRouter(pm);
        vm.prank(desk);
        d.usd.transfer(address(pegRouter), 600_000e18);
        vm.prank(USDC_WHALE);
        IERC20(Mainnet.USDC).transfer(address(pegRouter), 1_000_000e6);
        int24 t = d.hook.pegTick();
        pegRouter.addLiquidity(d.pegKey, ModifyLiquidityParams(t - 1000, t + 1000, 1e18, 0));
        _holdPeg(0, 31 minutes);

        // PegLPVault: the first depositor (borrowed imdUSD + USDC) inside the at-peg band.
        vm.prank(desk);
        d.usd.transfer(bob, 100_000e18);
        vm.prank(USDC_WHALE);
        IERC20(Mainnet.USDC).transfer(bob, 100_000e6);
        vm.startPrank(bob);
        d.usd.approve(address(d.pegLP), type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(d.pegLP), type(uint256).max);
        (bool s0) = d.hook.stableIsToken0();
        (uint256 m0, uint256 m1) = s0 ? (uint256(50_000e18), uint256(50_000e6)) : (uint256(50_000e6), uint256(50_000e18));
        (uint256 lpShares,,) = d.pegLP.deposit(0, m0, m1, bob);
        vm.stopPrank();
        assertGt(d.pegLP.liquidity(), 0, "vault in the pool");
        _check();

        uint256 tUsd = d.usd.balanceOf(address(d.treasury));
        uint256 tUsdc = IERC20(Mainnet.USDC).balanceOf(address(d.treasury));
        _holdPeg(60, 31 minutes);
        _freshUsdc(); // fix A4: the hook's quote gate needs a fresh USDC/USD answer after the timelock warps
        uint256 minted = d.hook.provide();
        assertGt(minted, 0, "keeper sold minted imdUSD above the peg");
        _check();
        _holdPeg(-60, 31 minutes);
        _freshUsdc();
        (uint256 burned,) = d.hook.withdraw();
        assertGt(burned, 0, "keeper bought back below the peg");
        assertLe(burned, minted);
        _check();
        // Back at the peg (long enough that the TWAP forgets the excursion), the vault compounds its fees (10% to the
        // Treasury) and the LP exits.
        _holdPeg(0, 61 minutes);
        d.pegLP.compound();
        assertTrue(
            d.usd.balanceOf(address(d.treasury)) > tUsd || IERC20(Mainnet.USDC).balanceOf(address(d.treasury)) > tUsdc,
            "Treasury got the vault's performance fee and the keeper's profit"
        );
        vm.prank(bob);
        (uint256 o0, uint256 o1) = d.pegLP.withdraw(lpShares, 0, 0, bob);
        uint256 outUsd = s0 ? o0 + o1 * 1e12 : o1 + o0 * 1e12;
        emit log_named_decimal_uint("PegLPVault exit, USD at par (in 100,000)", outUsd, 18);
        assertGt(outUsd, 99_000e18, "LP whole within the excursions' price moves");
        _check();
    }

    function _movePeg(int24 ticks) internal {
        int24 t = d.hook.pegTick();
        uint160 limit = TickMath.getSqrtPriceAtTick(d.hook.stableIsToken0() ? t + ticks : t - ticks);
        (uint160 now_,,,) = pm.getSlot0(d.pegKey.toId());
        if (now_ == limit) return;
        pegRouter.swap(d.pegKey, SwapParams(limit < now_, -int256(1e30), limit));
    }

    function _holdPeg(int24 ticks, uint256 secs) internal {
        for (uint256 s; s < secs; s += 60) {
            _movePeg(ticks);
            pegRouter.swap(
                d.pegKey,
                SwapParams(true, -int256(uint256(d.hook.stableIsToken0() ? 1e12 : 1)), TickMath.MIN_SQRT_PRICE + 1)
            );
            vm.warp(vm.getBlockTimestamp() + 60);
            vm.roll(vm.getBlockNumber() + 5);
        }
        _movePeg(ticks);
        _attest();
    }

    // ------------------------------------------------------------ 3. LoopVault x the live IMD pool x the DEX

    function _seedDex() internal {
        // INFER is token0, IMD token1 on mainnet. Seed at the hook's opening price: 20,000 IMD of each side's value.
        uint256 sp = d.dexHook.sqrtPriceX96();
        uint256 px = Math.mulDiv(Math.mulDiv(1e18, sp, 1 << 96), sp, 1 << 96); // IMD per INFER, 1e18
        uint256 imdAmt = 20_000e18;
        uint256 inferAmt = Math.mulDiv(imdAmt, 1e18, px);
        _seed(makeAddr("dexLP"), inferAmt, imdAmt);
        _hold(makeAddr("dexLP"), 31 minutes);
        _attest();
    }

    /// @dev The vault levers through the REAL IMD/ETH pool while the DEX trades IMD on the side, IMD falls 15%
    /// in the real pool, the vault delevers back into its band, and exits.
    function test_rehearsal_loopLeverDeleverWithDexPresent() public {
        _keeperWeek();
        _seedDex();
        PoolKey memory imdEth =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(Mainnet.IMD), 10_000, 200, IHooks(address(0)));
        PoolRoute route = new PoolRoute(pm, imdEth, IERC20(address(d.usd)), d.feeds[MainnetConfig.F_ETH]);
        vm.deal(address(route), 1_000 ether);
        vm.prank(desk);
        d.usd.transfer(address(route), 500_000e18);

        deal(Mainnet.IMD, alice, 5_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.IMD).approve(address(d.loop), type(uint256).max);
        d.usd.approve(address(d.loop), type(uint256).max);
        d.loop.deposit(5_000e18, 0, alice);
        vm.stopPrank();
        _check();

        uint256 steps;
        for (; steps < 20; ++steps) {
            _next();
            _attest();
            try d.loop.lever(address(route), type(uint256).max, "") {}
            catch {
                break;
            }
            if (steps == 2) {
                // A DEX trade between steps: IMD -> INFER on the Compound DEX.
                _fundRaw(bob, 1, 10e18);
                _approveAll(bob);
                _swapPM(bob, false, -10e18, "");
            }
        }
        _next();
        _attest();
        uint256 cr = d.loop.collateralRatio();
        emit log_named_uint("lever steps", steps);
        emit log_named_decimal_uint("CR after levering", cr, 18);
        assertApproxEqRel(cr, 2.5e18, 0.02e18, "at target");
        _check();

        deal(Mainnet.IMD, address(route), IERC20(Mainnet.IMD).balanceOf(address(route)) + 3_000_000e18);
        route.pushDown(8_500);
        _next();
        _attest();
        assertLt(d.loop.collateralRatio(), 2.2e18, "out of band after the fall");
        uint256 dsteps;
        for (; dsteps < 10; ++dsteps) {
            _attest();
            try d.loop.delever(address(route), type(uint256).max, "") {}
            catch {
                break;
            }
            _next();
        }
        _attest();
        cr = d.loop.collateralRatio();
        emit log_named_decimal_uint("CR after delevering", cr, 18);
        assertGe(cr, 2.2e18);
        assertLe(cr, 2.8e18);
        (bool ok, bool priced) = d.ledger.healthy(_pid(SIMD, address(d.loop)));
        assertTrue(ok && priced, "loop vault healthy on the Ledger");
        _check();

        // Exit in kind: alice repays her slice in imdUSD (from the desk) and takes the IMD.
        vm.prank(desk);
        d.usd.transfer(alice, 100_000e18);
        _next();
        uint256 s = d.loop.balanceOf(alice);
        vm.prank(alice);
        (uint256 imdOut,) = d.loop.withdraw(s, 0, alice);
        assertGt(imdOut, 0);
        assertEq(d.loop.totalSupply(), d.loop.DEAD_SHARES(), "the last holder took everything");
        (uint256 lc, uint256 ld) = d.loop.position();
        assertEq(lc + ld, 0, "position closed");
        _check();
    }

    // ------------------------------------------------------------ 4. DEX x sINFER drip x Treasury

    function test_rehearsal_dexSwapAndDripPayTheTreasury() public {
        _seedDex();
        uint256 t0 = d.dexHook.balanceOf(address(d.treasury));
        _fundRaw(alice, 1, 1_000e18);
        _approveAll(alice);
        _swapPM(alice, false, -500e18, ""); // IMD in
        uint256 t1 = d.dexHook.balanceOf(address(d.treasury));
        assertGt(t1, t0, "swap fee: Treasury minted LP shares");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        _poke(alice);
        assertTrue(IDripperF(Mainnet.INFER_DRIPPER).canDrip(), "dripper ready");
        uint256 r0 = IERC4626(Mainnet.SINFER).convertToAssets(1e36);
        IDripperF(Mainnet.INFER_DRIPPER).drip();
        assertGt(IERC4626(Mainnet.SINFER).convertToAssets(1e36), r0, "real drip");
        uint256 t2 = d.dexHook.balanceOf(address(d.treasury));
        _next();
        _swapPM(alice, false, -100e18, "");
        assertGt(d.dexHook.balanceOf(address(d.treasury)) - t2, 0, "yield + fee shares");
        assertGt(d.dexHook.yieldCollected(0), 0, "sINFER yield recognised");
        _attest();
        _check();
    }

    // ------------------------------------------------------------ 5. SeatJoin x Ledger x Liquidator (exit path)

    function test_rehearsal_seatDepositBorrowExit() public {
        IERC721 nft = IERC721(MainnetConfig.IDMD);
        uint256 seat;
        address holder;
        for (uint256 id = 1; id <= 2000; ++id) {
            address o = nft.ownerOf(id);
            if (o.code.length == 0) {
                (seat, holder) = (id, o);
                break;
            }
        }
        vm.startPrank(holder);
        nft.setApprovalForAll(address(d.seatJoin), true);
        address account = d.seatJoin.deposit(seat);
        assertEq(nft.ownerOf(seat), account, "seat in its own account");
        // 1 seat at ~1.3 ETH x ETH/USD x the reflexive factor, 40% LTV: borrow a quarter of the value.
        (uint256 v,) = d.seatSpot.latestValue();
        uint256 debt = v / 5;
        d.ledger.open(SEAT, 0, Adjust(1e18, int256(debt), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        assertEq(d.usd.balanceOf(holder), debt);
        _check();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _attest();
        uint256 owed = d.ledger.debtOf(_pid(SEAT, holder));
        assertGt(owed, debt, "8% floor accrued");
        vm.prank(desk);
        d.usd.transfer(holder, owed - debt);
        vm.startPrank(holder);
        d.ledger.open(SEAT, 0, Adjust(-1e18, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        d.seatJoin.withdraw(seat, holder);
        vm.stopPrank();
        assertEq(nft.ownerOf(seat), holder, "seat back");
        assertEq(d.seatJoin.totalSupply(), 0);
        _check();
    }

    // ------------------------------------------------------------ 6. FeeNotes x Treasury revenue meter

    function test_rehearsal_feeNotesAgainstMeteredRevenue() public {
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _attest();
        d.ledger.accrue(ETH); // the desk's 1M at 3% for 30 days, no savers: all to the Treasury, metered
        uint256 revenue = d.treasury.trailingRevenue();
        // The desk's upfront fee (1M x 3% x 7/365 = 575.34) + 30 days of 3% on the debt incl. it.
        assertApproxEqRel(revenue, uint256(575.34e18) + uint256(1_000_575.34e18) * 3 * 30 / 36500, 0.001e18, "upfront fee + 1M x 3% x 30/365");
        _govern(abi.encode(d.params.OPEN_NOTE_SERIES(), uint64(30 days), uint32(300), uint128(50_000e18)));
        assertEq(d.notes.capacity(), 2 * d.treasury.trailingRevenue());
        address buyer = makeAddr("buyer");
        vm.prank(USDC_WHALE);
        IERC20(Mainnet.USDC).transfer(buyer, 10_000e6);
        uint256 face = 2_000e18;
        uint256 price = d.notes.priceOf(1, face);
        uint256 tUsdc = IERC20(Mainnet.USDC).balanceOf(address(d.treasury));
        vm.startPrank(buyer);
        IERC20(Mainnet.USDC).approve(address(d.notes), price);
        d.notes.buy(1, face);
        vm.stopPrank();
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(d.treasury)) - tUsdc, price, "USDC to the Treasury");
        assertEq(d.notes.outstanding(), d.notes.balanceOf(buyer, 1), "notes outstanding == held");
        _check();
        FeeNotes.Series memory s = d.notes.series(1);
        vm.warp(s.maturity);
        _attest();
        d.ledger.accrue(ETH);
        uint256 supply = d.usd.totalSupply();
        vm.prank(buyer);
        d.notes.redeem(1, face);
        assertEq(d.usd.balanceOf(buyer), face, "paid in imdUSD from the Treasury");
        assertEq(d.usd.totalSupply(), supply, "no mint");
        _check();
    }
}
