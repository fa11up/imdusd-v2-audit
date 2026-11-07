// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {System} from "../utils/System.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Join} from "../../src/Join.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IERC4626View {
    function convertToAssets(uint256) external view returns (uint256);
}

/// @notice The core collateral set against live mainnet contracts: real tokens, real Chainlink feeds,
/// real ERC-4626 vaults (sUSDS, Steakhouse USDC on Morpho, StakedIMD) and v1's live IMD feeds.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/Mainnet.t.sol
contract MainnetForkTest is System {
    using SafeERC20 for IERC20;

    bytes32 constant ETH = "ETH";
    bytes32 constant WSTETH = "WSTETH";
    bytes32 constant CBBTC = "CBBTC";
    bytes32 constant WBTC = "WBTC";
    bytes32 constant SUSDS = "S-USDS";
    bytes32 constant SUSDC = "S-USDC-STEAKHOUSE";
    bytes32 constant SIMD = "SIMD";
    bytes32 constant USDC = "USDC"; // held only, no yield
    bytes32 constant USDT = "USDT";

    bytes4 constant CONVERT = bytes4(keccak256("convertToAssets(uint256)"));
    uint256 constant CAP = uint256(0.001e18) / 1 days; // 0.1%/day

    address[] aggregators;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        aggregators = [
            Mainnet.CL_ETH_USD,
            Mainnet.CL_STETH_USD,
            Mainnet.CL_BTC_USD,
            Mainnet.CL_WBTC_BTC,
            Mainnet.CL_CBBTC_USD,
            Mainnet.CL_USDC_USD,
            Mainnet.CL_USDS_USD,
            Mainnet.CL_USDT_USD
        ];
        _freshenAll(); // fork state can be minutes old; every read below is "as if updated now"
        _deploySystem(IERC20(Mainnet.V1_IMDUSD));

        IFeed eth = new ChainlinkFeed(Mainnet.CL_ETH_USD, 18, 1 hours + 10 minutes);
        _addIlk(ETH, Mainnet.WETH, eth, eth, IFeed(address(0)), address(0), address(0), true, _r(1.4e18, 0.1e18, 0));

        IFeed steth = new ChainlinkFeed(Mainnet.CL_STETH_USD, 18, 1 hours + 10 minutes);
        RateFeed wst = new RateFeed(Mainnet.WSTETH, bytes4(keccak256("stEthPerToken()")), false, steth, CAP);
        _addIlk(WSTETH, Mainnet.WSTETH, wst, wst, IFeed(address(0)), address(wst), address(0), true, _r(1.45e18, 0.1e18, 0.1e18));

        IFeed cb = new ChainlinkFeed(Mainnet.CL_CBBTC_USD, 8, 1 days + 1 hours);
        _addIlk(CBBTC, Mainnet.CBBTC, cb, cb, IFeed(address(0)), address(0), address(0), true, _r(1.5e18, 0.12e18, 0));

        IFeed wbtc = new ProductFeed(
            new ChainlinkFeed(Mainnet.CL_BTC_USD, 8, 1 hours + 10 minutes),
            new ChainlinkFeed(Mainnet.CL_WBTC_BTC, 18, 1 days + 1 hours)
        );
        _addIlk(WBTC, Mainnet.WBTC, wbtc, wbtc, IFeed(address(0)), address(0), address(0), true, _r(1.5e18, 0.12e18, 0));

        RateFeed susds = new RateFeed(Mainnet.SUSDS, CONVERT, true, new ChainlinkFeed(Mainnet.CL_USDS_USD, 18, 1 days), CAP);
        _addIlk(SUSDS, Mainnet.SUSDS, susds, susds, IFeed(address(0)), address(susds), Mainnet.CL_USDS_USD, true, _stable());

        RateFeed susdc = new RateFeed(
            Mainnet.METAMORPHO_STEAKHOUSE_USDC, CONVERT, true, new ChainlinkFeed(Mainnet.CL_USDC_USD, 6, 1 days), CAP
        );
        _addIlk(SUSDC, Mainnet.METAMORPHO_STEAKHOUSE_USDC, susdc, susdc, IFeed(address(0)), address(susdc), Mainnet.CL_USDC_USD, true, _stable());

        // sIMD: median = v1's live collateral price feed; spot = v1's spot IMD/ETH x ETH/USD x sIMD's rate.
        RateFeed simdSpot =
            new RateFeed(Mainnet.SIMD, CONVERT, true, new ProductFeed(IFeed(Mainnet.V1_SPOT_FEED), eth), CAP);
        ParametersBase.Risk memory ir = _r(1.7e18, 0.2e18, 0);
        ir.skew = 0.1e18;
        _addIlk(SIMD, Mainnet.SIMD, IFeed(Mainnet.V1_COLLATERAL_PRICE_FEED), simdSpot, IFeed(Mainnet.V1_NHI_FEED), address(0), address(0), true, ir);

        // Held-only stablecoins: custody in their own join, no vault, no yield, no third-party risk.
        IFeed usdcFeed = new ChainlinkFeed(Mainnet.CL_USDC_USD, 6, 1 days);
        _addIlk(USDC, Mainnet.USDC, usdcFeed, usdcFeed, IFeed(address(0)), address(0), Mainnet.CL_USDC_USD, true, _held());
        IFeed usdtFeed = new ChainlinkFeed(Mainnet.CL_USDT_USD, 6, 1 days + 1 hours);
        _addIlk(USDT, Mainnet.USDT, usdtFeed, usdtFeed, IFeed(address(0)), address(0), Mainnet.CL_USDT_USD, true, _held());

        params.setGenesisMigratorLine(100_000e18);
        params.seal();
    }

    function _r(uint64 mat, uint64 chop, uint64 yieldFee) internal pure returns (ParametersBase.Risk memory r) {
        r = _risk(mat, 10_000_000e18);
        r.chop = chop;
        r.yieldFee = yieldFee;
    }

    function _stable() internal pure returns (ParametersBase.Risk memory r) {
        r = _r(1.08e18, 0.05e18, 0.1e18);
        r.rateFloor = 0.005e18;
        r.pegFloor = 0.98e18;
    }

    function _held() internal pure returns (ParametersBase.Risk memory r) {
        r = _r(1.05e18, 0.03e18, 0);
        r.rateFloor = 0.005e18;
        r.pegFloor = 0.98e18;
    }

    /// Re-stamp every Chainlink aggregator (and v1's swarm feeds) as updated now, keeping their answers.
    function _freshenAll() internal {
        for (uint256 i; i < aggregators.length; ++i) {
            (uint80 id, int256 answer,,, uint80 ans) = IAggregator(aggregators[i]).latestRoundData();
            vm.mockCall(
                aggregators[i],
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(id, answer, block.timestamp, block.timestamp, ans)
            );
        }
        address[4] memory v1 =
            [Mainnet.V1_PRICE_FEED, Mainnet.V1_SPOT_FEED, Mainnet.V1_USD_PRICE_FEED, Mainnet.V1_COLLATERAL_PRICE_FEED];
        for (uint256 i; i < 4; ++i) {
            vm.mockCall(v1[i], abi.encodeWithSignature("isStale()"), abi.encode(false));
        }
        vm.mockCall(Mainnet.V1_NHI_FEED, abi.encodeWithSignature("isStale()"), abi.encode(false));
    }

    function _setEthPrice(int256 answer8) internal {
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), answer8, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// Open at 60% of the limit, check the price is sane, then repay and withdraw everything.
    function _roundTrip(bytes32 ilk, address token, uint256 amount, uint256 minUsd, uint256 maxUsd) internal {
        deal(token, alice, amount);
        vm.startPrank(alice);
        IERC20(token).forceApprove(address(ledger), amount); // USDT's approve returns nothing
        ledger.open(ilk, 0, Adjust(int256(amount), 0, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();

        (,, uint256 low,,,) = _quote(ilk);
        uint256 value = amount * low / 1e18;
        assertGt(value, minUsd, "collateral value too low: wrong decimals or price?");
        assertLt(value, maxUsd, "collateral value too high: wrong decimals or price?");

        uint256 mat = params.risk(ilk).mat;
        if (address(params.config(ilk).nhi) != address(0)) (,,,, mat,) = _quoteMat(ilk);
        uint256 debt = value * 60 / 100 * 1e18 / mat;
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, 0.03e18);
        vm.prank(alice);
        ledger.open(ilk, 0, Adjust(0, int256(debt), 0.03e18, p, n, false, type(uint256).max, address(0)));
        assertEq(usd.balanceOf(alice), debt);
        (bool healthy, bool priced) = ledger.healthy(_pid(ilk, alice));
        assertTrue(healthy && priced);

        // Repay everything: the borrowed amount + the upfront fee, whose imdUSD the Treasury received.
        uint256 owed = ledger.debtOf(_pid(ilk, alice));
        assertGt(owed, debt, "the upfront fee is owed");
        vm.prank(address(treasury));
        usd.transfer(alice, owed - debt);
        int256 all = -int256(uint256(ledger.position(_pid(ilk, alice)).collateral));
        vm.prank(alice);
        ledger.open(ilk, 0, Adjust(all, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(IERC20(token).balanceOf(alice), amount, "all collateral back");
    }

    function _quote(bytes32 ilk) internal view returns (bool, bool, uint256, uint256, uint256, uint256) {
        (uint256 low, uint256 high, uint256 mat, uint256 lull, bool priced, bool borrowable) = _q(ilk);
        return (priced, borrowable, low, high, mat, lull);
    }

    function _quoteMat(bytes32 ilk) internal view returns (bool, bool, uint256, uint256, uint256, uint256) {
        return _quote(ilk);
    }

    function _q(bytes32 ilk) internal view returns (uint256, uint256, uint256, uint256, bool, bool) {
        Pricer.Quote memory q = pricer.quote(ilk);
        return (q.low, q.high, q.mat, q.lull, q.priced, q.borrowable);
    }

    // ------------------------------------------------------------ every collateral type, real contracts

    function test_fork_eth() public {
        _roundTrip(ETH, Mainnet.WETH, 10e18, 5_000e18, 100_000e18);
    }

    function test_fork_wsteth() public {
        _roundTrip(WSTETH, Mainnet.WSTETH, 10e18, 5_000e18, 150_000e18);
    }

    function test_fork_cbbtc() public {
        _roundTrip(CBBTC, Mainnet.CBBTC, 1e8, 20_000e18, 500_000e18);
    }

    function test_fork_wbtc() public {
        _roundTrip(WBTC, Mainnet.WBTC, 1e8, 20_000e18, 500_000e18);
    }

    function test_fork_susds() public {
        _roundTrip(SUSDS, Mainnet.SUSDS, 10_000e18, 10_000e18, 13_000e18);
    }

    function test_fork_steakhouseUsdcShares() public {
        uint256 shares = 10_000e18;
        uint256 assets = IERC4626View(Mainnet.METAMORPHO_STEAKHOUSE_USDC).convertToAssets(shares);
        _roundTrip(SUSDC, Mainnet.METAMORPHO_STEAKHOUSE_USDC, shares, assets * 1e12 * 99 / 100, assets * 1e12 * 101 / 100);
    }

    function test_fork_simdOnV1Feeds() public {
        uint256 shares = IERC20(Mainnet.SIMD).balanceOf(Mainnet.V1_VAULT) / 100; // a slice of real sIMD
        assertGt(shares, 0);
        uint256 imd = IERC4626View(Mainnet.SIMD).convertToAssets(shares);
        // v1's own USD price for IMD ($ per 1e18 raw), to bound the value independently
        (uint256 imdUsd,) = IFeed(Mainnet.V1_USD_PRICE_FEED).latestValue();
        uint256 expect = imd * imdUsd / 1e18;
        _roundTrip(SIMD, Mainnet.SIMD, shares, expect * 90 / 100, expect * 110 / 100);
        (,,,, uint256 mat, uint256 lull) = _quote(SIMD);
        assertGe(mat, 1.7e18);
        assertLe(mat, 2e18);
        lull;
    }

    // ------------------------------------------------------------ stake on deposit (real vaults)

    function test_fork_usdcStakedIntoMorphoOnDeposit() public {
        deal(Mainnet.USDC, alice, 50_000e6);
        vm.startPrank(alice);
        IERC20(Mainnet.USDC).approve(address(ledger), type(uint256).max);
        ledger.open(SUSDC, 0, Adjust(50_000e6, 25_000e18, 0.01e18, 0, 0, true, type(uint256).max, address(0)));
        vm.stopPrank();
        uint256 shares = ledger.position(_pid(SUSDC, alice)).collateral;
        Join join = Join(params.config(SUSDC).join);
        assertEq(IERC20(Mainnet.METAMORPHO_STEAKHOUSE_USDC).balanceOf(address(join)), shares);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(join)), 0, "never held raw");
        assertApproxEqRel(IERC4626View(Mainnet.METAMORPHO_STEAKHOUSE_USDC).convertToAssets(shares), 50_000e6, 0.0001e18);
        // Withdraw part back to USDC (the vault has liquidity).
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(-int256(uint256(shares / 10)), 0, 0, 0, 0, true, type(uint256).max, address(0)));
        assertApproxEqRel(IERC20(Mainnet.USDC).balanceOf(alice), 5_000e6, 0.0001e18);
    }

    function test_fork_usdsStakedIntoSusdsOnDeposit() public {
        deal(Mainnet.USDS, alice, 20_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.USDS).approve(address(ledger), type(uint256).max);
        ledger.open(SUSDS, 0, Adjust(20_000e18, 10_000e18, 0.01e18, 0, 0, true, type(uint256).max, address(0)));
        vm.stopPrank();
        assertApproxEqRel(
            IERC4626View(Mainnet.SUSDS).convertToAssets(ledger.position(_pid(SUSDS, alice)).collateral), 20_000e18, 0.0001e18
        );
    }

    function test_fork_imdStakedIntoSimdOnDeposit() public {
        deal(Mainnet.IMD, alice, 1_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.IMD).approve(address(ledger), type(uint256).max);
        ledger.open(SIMD, 0, Adjust(1_000e18, 0, 0, 0, 0, true, type(uint256).max, address(0)));
        vm.stopPrank();
        uint256 shares = ledger.position(_pid(SIMD, alice)).collateral;
        assertApproxEqRel(IERC4626View(Mainnet.SIMD).convertToAssets(shares), 1_000e18, 0.0001e18);
        // StakedIMD holds new shares for one block: unstaking in the same block reverts (its maxRedeem reads 0
        // for that holder, surfacing as RedeemMoreThanMax 0x4656425a; checked in the verified source), the
        // next block succeeds. NOTE the holder is the JOIN, shared by every sIMD depositor.
        int256 out = -int256(shares);
        vm.prank(alice);
        vm.expectRevert(bytes4(0x4656425a));
        ledger.open(SIMD, 0, Adjust(out, 0, 0, 0, 0, true, type(uint256).max, address(0)));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _freshenAll();
        vm.prank(alice);
        ledger.open(SIMD, 0, Adjust(out, 0, 0, 0, 0, true, type(uint256).max, address(0)));
        assertApproxEqRel(IERC20(Mainnet.IMD).balanceOf(alice), 1_000e18, 0.0001e18);
    }

    // ------------------------------------------------------------ held-only stablecoins (no vault)

    function test_fork_usdcHeldOnly() public {
        _roundTrip(USDC, Mainnet.USDC, 10_000e6, 9_900e18, 10_100e18);
        // Nothing went anywhere: the join holds plain USDC, never vault shares.
        assertEq(IERC20(Mainnet.USDC).balanceOf(params.config(USDC).join), 0);
    }

    /// USDT returns no bool from transfer/transferFrom; SafeERC20 must carry it both ways.
    function test_fork_usdtHeldOnly() public {
        _roundTrip(USDT, Mainnet.USDT, 10_000e6, 9_900e18, 10_100e18);
    }

    function test_fork_redeemIntoRawUsdc() public {
        deal(Mainnet.USDC, alice, 100_000e6);
        vm.startPrank(alice);
        IERC20(Mainnet.USDC).approve(address(ledger), type(uint256).max);
        ledger.open(USDC, 0, Adjust(100_000e6, 60_000e18, 0.01e18, 0, 0, false, type(uint256).max, address(0)));
        usd.transfer(bob, 10_000e18);
        vm.stopPrank();
        vm.prank(bob);
        (uint256 redeemed, uint256 out) = redeemer.redeem(USDC, 10_000e18, 0.05e18, 5, 0);
        assertEq(redeemed, 10_000e18);
        // ~$9,500 of plain USDC at the live USDC/USD reading: the outbound side of a swap facility, no reserve.
        assertApproxEqRel(out, 9_500e6, 0.005e18);
        assertEq(IERC20(Mainnet.USDC).balanceOf(bob), out);
    }

    function test_fork_usdcDepegStopsBorrowing() public {
        deal(Mainnet.USDC, alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(Mainnet.USDC).approve(address(ledger), type(uint256).max);
        ledger.open(USDC, 0, Adjust(10_000e6, 5_000e18, 0.01e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        vm.mockCall(
            Mainnet.CL_USDC_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(0.97e8), block.timestamp, block.timestamp, uint80(1))
        );
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(USDC, 0, Adjust(0, 100e18, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    // ------------------------------------------------------------ real yield repays real debt

    function test_fork_realYieldRepaysDebt() public {
        deal(Mainnet.USDS, alice, 100_000e18);
        deal(Mainnet.USDC, bob, 100_000e6);
        vm.startPrank(alice);
        IERC20(Mainnet.USDS).approve(address(ledger), type(uint256).max);
        ledger.open(SUSDS, 0, Adjust(100_000e18, 50_000e18, 0.01e18, 0, 0, true, type(uint256).max, address(0)));
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Mainnet.USDC).approve(address(ledger), type(uint256).max);
        ledger.open(SUSDC, 0, Adjust(100_000e6, 50_000e18, 0.01e18, 0, 0, true, type(uint256).max, address(0)));
        vm.stopPrank();

        // 30 days: sUSDS's savings rate and the Morpho vault's borrowers accrue in the views.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 30 * 7200);
        _freshenAll();

        uint256[] memory a = new uint256[](1);
        a[0] = _pid(SUSDS, alice);
        uint256 before = ledger.debtOf(_pid(SUSDS, alice));
        ledger.harvest(SUSDS, a);
        uint256 creditS = before - ledger.debtOf(_pid(SUSDS, alice));

        a[0] = _pid(SUSDC, bob);
        before = ledger.debtOf(_pid(SUSDC, bob));
        ledger.harvest(SUSDC, a);
        uint256 creditC = before - ledger.debtOf(_pid(SUSDC, bob));

        emit log_named_decimal_uint("sUSDS: 30 days of yield on $100k credited (imdUSD)", creditS, 18);
        emit log_named_decimal_uint("Steakhouse USDC: 30 days of yield on $100k credited (imdUSD)", creditC, 18);
        // Some yield, and not absurd: between 0.5% and 15% a year, after the 10% fee.
        uint256 principal = 100_000e18;
        uint256 floor_ = principal * 5 * 30 * 9 / (1000 * 365 * 10); // 0.5% a year, after fee
        uint256 ceiling = principal * 15 * 30 / (100 * 365); // 15% a year
        assertGt(creditS, floor_);
        assertLt(creditS, ceiling);
        assertGt(creditC, floor_);
        // Steakhouse USDC is a MetaMorpho vault: its view accrues each Morpho market at the AdaptiveCurve IRM's rate, which
        // compounds upward for as long as a market sits above target utilisation. Warping 30 days with nobody rebalancing
        // can therefore show any growth (the fork read ~33%/yr on 2026-10-29 while the real 7-day growth was ~4.4%/yr).
        // What the Ledger may credit is bounded by the RateFeed's growth cap (0.1%/day), net of the 10% fee: assert that.
        uint256 capped = principal * CAP * 30 days / 1e18 * 9 / 10;
        assertLe(creditC, capped * 1005 / 1000, "never more than the capped share-rate growth");
        assertGt(IERC20(Mainnet.SUSDS).balanceOf(address(treasury)), 0);
        assertGt(IERC20(Mainnet.METAMORPHO_STEAKHOUSE_USDC).balanceOf(address(treasury)), 0);
    }

    // ------------------------------------------------------------ liquidation and redemption on real tokens

    function test_fork_ethLiquidation() public {
        deal(Mainnet.WETH, alice, 10e18);
        (, int256 px,,,) = IAggregator(Mainnet.CL_ETH_USD).latestRoundData();
        uint256 value = 10 * uint256(px) * 1e10; // USD, 1e18
        vm.startPrank(alice);
        IERC20(Mainnet.WETH).approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(10e18, int256(value * 1e18 / 1.42e18), 0.02e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        // Bob mints imdUSD from USDC to liquidate with.
        deal(Mainnet.USDC, bob, 1_000_000e6);
        vm.startPrank(bob);
        IERC20(Mainnet.USDC).approve(address(ledger), type(uint256).max);
        ledger.open(SUSDC, 0, Adjust(1_000_000e6, 500_000e18, 0.01e18, 0, 0, true, type(uint256).max, address(0)));
        vm.stopPrank();

        _setEthPrice(px * 90 / 100);
        vm.prank(bob);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(_pid(ETH, alice));
        assertGt(repaid, 0);
        assertEq(bad, 0);
        assertGt(IERC20(Mainnet.WETH).balanceOf(bob), 0);
        assertGt(IERC20(Mainnet.WETH).balanceOf(address(treasury)), 0);
        assertLt(seized, 10e18);
    }

    function test_fork_redeemIntoMorphoShares() public {
        deal(Mainnet.USDC, alice, 100_000e6);
        vm.startPrank(alice);
        IERC20(Mainnet.USDC).approve(address(ledger), type(uint256).max);
        ledger.open(SUSDC, 0, Adjust(100_000e6, 60_000e18, 0.01e18, 0, 0, true, type(uint256).max, address(0)));
        usd.transfer(bob, 10_000e18);
        vm.stopPrank();
        vm.prank(bob);
        (uint256 redeemed, uint256 shares) = redeemer.redeem(SUSDC, 10_000e18, 0.05e18, 5, 0);
        assertEq(redeemed, 10_000e18);
        uint256 usdcOut = IERC4626View(Mainnet.METAMORPHO_STEAKHOUSE_USDC).convertToAssets(shares);
        // $10,000 less the fee (0.5% floor + 10k/60k/2 = 8.8%, capped at 5%) = ~$9,500 of shares
        assertApproxEqRel(usdcOut, 9_500e6, 0.001e18);
    }

    // ------------------------------------------------------------ v1 migration with the real token

    function test_fork_migrateV1() public {
        deal(Mainnet.V1_IMDUSD, alice, 1_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.V1_IMDUSD).approve(address(migrator), type(uint256).max);
        migrator.toV2(1_000e18);
        assertEq(usd.balanceOf(alice), 1_000e18);
        migrator.toV1(1_000e18);
        vm.stopPrank();
        assertEq(IERC20(Mainnet.V1_IMDUSD).balanceOf(alice), 1_000e18);
    }
}
