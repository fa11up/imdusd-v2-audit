// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployTypes, MainnetConfig} from "../../script/DeployConfig.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {MockERC20, MockFeed, MockSeatFeed, MockVault, MockLiveAggregator} from "./Mocks.sol";
import {MockSIMD, MockSINFER} from "./DexMocks.sol";
import {MockSeatNFT, MockAgentAdapter} from "./SeatMocks.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "./Pid.sol";

/// @notice A live pool price as LivePoolPrice reports it: never stale unless unreadable.
contract LiveMock is IFeed {
    uint256 public constant MAX_ALLOWANCE_BPS = 20_000; // stage 2 refuses an EXISTING feed without it

    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, value == 0 ? 0 : uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        return value == 0;
    }

    function maxAge() external pure returns (uint256) {
        return type(uint64).max;
    }
}

/// @notice The WHOLE v2 system, offline, built by the real `script/Deploy.s.sol` from an offline config: core, every
/// collateral kind (Chainlink-style ETH, a yield vault, sIMD with a live leg, the SEAT auction type), sImdUSD, fee notes,
/// the peg hook on a local v4 PoolManager, PegLPVault, LoopVault and the Compound DEX (sIMD/sINFER, CREATE2-mined
/// through the deterministic deployer etched at its mainnet address). Mocks copy the real holds: sIMD's whole-address
/// one-block hold and sINFER's per-lot hold (DexMocks), the identity.md NFT and the plane's adapter (SeatMocks).
/// Prices are mock feeds; sIMD's legs are RateFeeds over IMD/USD feeds, so drips move them as on mainnet.
abstract contract FullSystem is Test {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant CREATE2_DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    bytes32 constant ETH = "ETH";
    bytes32 constant SUSDC = "S-USDC";
    bytes32 constant SIMD = "SIMD";
    bytes32 constant SEAT = "SEAT";

    // node indices of the offline config
    uint8 constant N_ETH = 0;
    uint8 constant N_USDC = 1;
    uint8 constant N_SUSDC = 2;
    uint8 constant N_IMD_MEDIAN = 3;
    uint8 constant N_IMD_SPOT = 4;
    uint8 constant N_IMD_LIVE = 5;
    uint8 constant N_SIMD_MEDIAN = 6;
    uint8 constant N_SIMD_SPOT = 7;
    uint8 constant N_SIMD_LIVE = 8;
    uint8 constant N_SEAT_MEDIAN = 9;
    uint8 constant N_SEAT_SPOT = 10;

    uint256 constant IMD_USD = 5e18; // $5 per IMD at the start
    uint160 constant DEX_SQRT_P = uint160(1 << 96) * 3 / 2; // 2.25 token1 per token0

    address internal safe = makeAddr("safe");
    address internal deployer = makeAddr("deployer");
    address internal outsider = makeAddr("outsider");

    Deploy internal script;
    Deploy.Deployed internal d;
    IPoolManager internal pm;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal imd;
    MockERC20 internal infer;
    MockERC20 internal v1;
    MockVault internal vault; // the stable yield vault (S-USDC)
    MockSIMD internal simd;
    MockSINFER internal sinfer;
    MockSeatNFT internal nft;

    MockFeed internal ethFeed;
    MockFeed internal usdcFeed;
    MockFeed internal imdMedian;
    MockFeed internal imdSpot;
    LiveMock internal imdLive;
    MockSeatFeed internal seatMedian; // its figure is sales7d
    MockFeed internal seatSpot;

    function _deployFull() internal {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        vm.etch(CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE);
        pm = IPoolManager(address(new PoolManager(address(this))));

        weth = new MockERC20("WETH", 18);
        usdc = new MockERC20("USDC", 6);
        v1 = new MockERC20("imdUSDv1", 18);
        // Underlyings at fixed addresses so both DEX token orders are not left to chance: IMD sorts second (as on
        // mainnet, INFER is token0).
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("INFER", uint8(18)), address(0x1000000000000000000000000000000000000001));
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("IMD", uint8(18)), address(0xF000000000000000000000000000000000000001));
        infer = MockERC20(address(0x1000000000000000000000000000000000000001));
        imd = MockERC20(address(0xF000000000000000000000000000000000000001));
        vault = new MockVault(IERC20(address(usdc)));
        simd = new MockSIMD(IERC20(address(imd)));
        sinfer = new MockSINFER(IERC20(address(infer)));
        // Outsiders already staked and a drip arrived: share rates are not 1.
        _outsiderStake(address(vault), usdc, 1_000_000e6);
        _outsiderStake(address(simd), imd, 5_000_000e18);
        _outsiderStake(address(sinfer), infer, 50_000_000e18);
        simd.drip(1_250_000e18);
        sinfer.drip(7_500_000e18);
        nft = new MockSeatNFT();

        ethFeed = new MockFeed(2000e18);
        usdcFeed = new MockFeed(1e30); // USD per 1e18 raw units of a 6-decimal token
        imdMedian = new MockFeed(IMD_USD);
        imdSpot = new MockFeed(IMD_USD);
        imdLive = new LiveMock();
        imdLive.set(IMD_USD);
        seatMedian = new MockSeatFeed(2e18, 150); // wei per seat; 150 distinct seats sold in 7 days
        seatSpot = new MockFeed(2e18);
        v1.mint(outsider, 10_000e18);

        script = new Deploy();
        d = script.deployAs(_offlineConfig(), deployer);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _outsiderStake(address v, MockERC20 t, uint256 amount) private {
        t.mint(outsider, amount);
        vm.startPrank(outsider);
        t.approve(v, amount);
        IERC4626(v).deposit(amount, outsider);
        vm.stopPrank();
    }

    function _offlineConfig() internal returns (DeployTypes.Config memory c) {
        c.governor = safe;
        c.v1 = address(v1);
        c.flashCap = 10_000_000e18;
        c.migratorLine = 50_000e18;
        c.savingsShare = 0.35e18;
        c.poolManager = address(pm);
        c.pegQuote = address(usdc);
        c.pegQuoteFeed = address(new MockLiveAggregator(8, 1e8));
        c.pegQuoteFeedMaxAge = 1 days + 1 hours;

        bytes4 convert = bytes4(keccak256("convertToAssets(uint256)"));
        uint256 cap = uint256(1e18) / 1 days; // a 100%/day growth cap: drips in the suites are never clipped
        c.feeds = new DeployTypes.FeedNode[](11);
        c.feeds[N_ETH] = _existing(address(ethFeed));
        c.feeds[N_USDC] = _existing(address(usdcFeed));
        c.feeds[N_SUSDC] = _rate(address(vault), convert, N_USDC, cap);
        c.feeds[N_IMD_MEDIAN] = _existing(address(imdMedian));
        c.feeds[N_IMD_SPOT] = _existing(address(imdSpot));
        c.feeds[N_IMD_LIVE] = _existing(address(imdLive));
        c.feeds[N_SIMD_MEDIAN] = _rate(address(simd), convert, N_IMD_MEDIAN, cap);
        c.feeds[N_SIMD_SPOT] = _rate(address(simd), convert, N_IMD_SPOT, cap);
        c.feeds[N_SIMD_LIVE] = _rate(address(simd), convert, N_IMD_LIVE, cap);
        c.feeds[N_SEAT_MEDIAN] = _existing(address(seatMedian));
        c.feeds[N_SEAT_SPOT] = _existing(address(seatSpot));

        uint8 none = DeployTypes.NONE;
        c.ilks = new DeployTypes.IlkSpec[](3);
        c.ilks[0] = DeployTypes.IlkSpec(ETH, address(weth), N_ETH, N_ETH, none, none, address(0), none, true, _risk(1.4e18, 0.1e18, 0.01e18, 0, 100_000_000e18));
        ParametersBase.Risk memory sr = _risk(1.08e18, 0.05e18, 0.005e18, 0.1e18, 100_000_000e18);
        c.ilks[1] = DeployTypes.IlkSpec(SUSDC, address(vault), N_SUSDC, N_SUSDC, none, N_SUSDC, address(0), none, true, sr);
        ParametersBase.Risk memory ir = _risk(1.7e18, 0.2e18, 0.04e18, 0, 100_000_000e18);
        ir.skew = 0.1e18;
        ir.redeemDivisor = 2;
        ir.redeemCap = 20_000e18;
        c.ilks[2] = DeployTypes.IlkSpec(SIMD, address(simd), N_SIMD_MEDIAN, N_SIMD_SPOT, none, none, address(0), N_SIMD_LIVE, true, ir);

        c.lpVault = DeployTypes.LpVaultSpec({enabled: true, band: 100});
        c.loopVault = DeployTypes.LoopSpec({enabled: true, ilk: SIMD});
        c.seats = MainnetConfig.seatSpec(true, N_SEAT_MEDIAN, N_SEAT_SPOT, N_ETH);
        c.seats.nft = address(nft);
        c.seats.adapter = address(new MockAgentAdapter());
        c.seats.risk.line = 100_000e18;
        c.dex = DeployTypes.DexSpec({
            enabled: true, vaultA: address(simd), vaultB: address(sinfer), sqrtPriceX96: DEX_SQRT_P, marketPoolId: bytes32(0)
        });
    }

    function _existing(address f) private pure returns (DeployTypes.FeedNode memory n) {
        n.kind = DeployTypes.EXISTING;
        n.source = f;
    }

    function _rate(address src, bytes4 sel, uint8 underlying, uint256 cap)
        private
        pure
        returns (DeployTypes.FeedNode memory n)
    {
        n.kind = DeployTypes.RATE;
        n.source = src;
        n.selector = sel;
        n.passOneE18 = true;
        n.cap = cap;
        n.a = underlying;
    }

    function _risk(uint64 mat, uint64 chop, uint64 rateFloor, uint64 yieldFee, uint128 line)
        internal
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

    // ------------------------------------------------------------ governance + prices

    /// @dev The Safe's timelocked act on Parameters (or the Treasury): propose, 48h, apply; feeds re-stamped after.
    function _govern(Governed target, bytes memory payload) internal {
        vm.prank(safe);
        target.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.roll(vm.getBlockNumber() + 1);
        target.applyPending();
        _refreshFeeds();
    }

    function _refreshFeeds() internal {
        ethFeed.set(ethFeed.value());
        usdcFeed.set(usdcFeed.value());
        imdMedian.set(imdMedian.value());
        imdSpot.set(imdSpot.value());
        seatMedian.set(seatMedian.value());
        seatSpot.set(seatSpot.value());
    }

    /// @dev IMD's USD price on every leg (attested median and spot, the live pool).
    function _setImdPrice(uint256 p) internal {
        imdMedian.set(p);
        imdSpot.set(p);
        imdLive.set(p);
    }

    // ------------------------------------------------------------ the supply equation and module solvency

    function _ilkDebtAndBad() internal returns (uint256 total) {
        for (uint256 i; i < d.params.ilkCount(); ++i) {
            bytes32 ilk = d.params.ilks(i);
            d.ledger.accrue(ilk);
            (uint128 debt,,,, uint128 bad) = d.ledger.ilkState(ilk);
            total += uint256(debt) + bad;
        }
    }

    /// supply == Σ type debt + Σ bad debt + reserve-backed + migrated + peg keeper outstanding. Fee notes add no term:
    /// they are paid from imdUSD the Treasury already holds.
    function _assertSupply() internal {
        uint256 sum = _ilkDebtAndBad() + d.ledger.reserveBacked() + d.migrator.outstanding() + d.hook.outstanding();
        assertEq(d.usd.totalSupply(), sum, "supply equation");
    }

    function _assertKeeperSolvent() internal view {
        assertGe(usdc.balanceOf(address(d.hook)), d.hook.principal() + d.hook.buffer(), "keeper USDC >= principal + buffer");
    }

    function _assertSavingsSolvent() internal view {
        assertGe(d.usd.balanceOf(address(d.savings)), d.savings.tracked(), "savings balance >= tracked");
        assertGe(d.savings.tracked(), d.savings.totalAssets(), "savings tracked >= counted");
    }

    /// The DEX's curve never claims more than it holds.
    function _assertDexCovered() internal view {
        (uint256 x, uint256 y) = d.dexLens.curveBalances(d.dexHook);
        (uint256 h0, uint256 h1) = d.dexHook.totals();
        assertLe(x, h0, "dex curve x <= held0");
        assertLe(y, h1, "dex curve y <= held1");
    }

    /// The LoopVault's position is the vault's, and while it has holders it is solvent at the low leg or closed.
    function _assertLoopSound() internal view {
        (uint256 c, uint256 debt) = d.loop.position();
        assertEq(d.ledger.position(_pid(SIMD, address(d.loop))).collateral, c, "loop position");
        if (d.loop.totalSupply() <= d.loop.DEAD_SHARES()) assertEq(debt, 0, "no holders, no debt");
    }

    /// Every seat unit is a seat in its account; the pool is the recorded collateral.
    function _assertSeatCustody(uint256 maxId) internal view {
        uint256 held;
        for (uint256 id = 1; id <= maxId; ++id) {
            try nft.ownerOf(id) returns (address o) {
                if (o == d.seatJoin.accountOf(id)) held++;
            } catch {}
        }
        assertEq(d.seatJoin.totalSupply(), held * 1e18, "seat units == seats custodied");
        (, uint128 coll,,,) = d.ledger.ilkState(SEAT);
        assertEq(d.seatJoin.balanceOf(address(d.seatJoin)), coll, "seat pool == recorded collateral");
    }
}
