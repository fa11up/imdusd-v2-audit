// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {System} from "../utils/System.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {LivePoolPrice} from "../../src/feeds/LivePoolPrice.sol";
import {MainnetConfig} from "../../script/DeployConfig.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IAggregatorRound {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev Swaps on a native-ETH v4 pool, then optionally redeems in the SAME transaction.
contract PushThenRedeem is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager immutable pm;
    Redeemer immutable redeemer;

    constructor(IPoolManager pm_, Redeemer redeemer_) {
        pm = pm_;
        redeemer = redeemer_;
    }

    receive() external payable {}

    /// @param ethIn > 0: buy IMD with that much ETH (pushes the IMD price UP); imdIn > 0: sell IMD (DOWN).
    function run(PoolKey memory key, uint256 ethIn, uint256 imdIn, bytes32 ilk, uint256 amount)
        external
        returns (uint256 out)
    {
        if (ethIn != 0 || imdIn != 0) pm.unlock(abi.encode(key, ethIn, imdIn));
        (, out) = redeemer.redeem(ilk, amount, 0.05e18, 10, 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 ethIn, uint256 imdIn) = abi.decode(data, (PoolKey, uint256, uint256));
        bool zeroForOne = ethIn != 0;
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(zeroForOne ? ethIn : imdIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _square(key.currency0, BalanceDeltaLibrary.amount0(d));
        _square(key.currency1, BalanceDeltaLibrary.amount1(d));
        return "";
    }

    function _square(Currency c, int128 delta) private {
        if (delta < 0) {
            pm.sync(c);
            if (Currency.unwrap(c) == address(0)) {
                pm.settle{value: uint128(-delta)}();
            } else {
                IERC20(Currency.unwrap(c)).safeTransfer(address(pm), uint128(-delta));
                pm.settle();
            }
        } else if (delta > 0) {
            pm.take(c, address(this), uint128(delta));
        }
    }
}

/// @notice on mainnet: the live leg against IMD's real v4 pool and real sIMD, and an in-transaction
/// push of that pool, which can only shrink the redeemer's take.
contract RedemptionForkTest is System {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";
    bytes4 constant CONVERT = bytes4(keccak256("convertToAssets(uint256)"));
    uint256 constant CAP = uint256(0.001e18) / 1 days;

    IPoolManager pm = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
    PoolKey key;
    LivePoolPrice imdLive;
    IFeed simdLive;
    IFeed eth;
    PushThenRedeem bot;

    address alice = makeAddr("alice");
    address dave = makeAddr("dave");

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(Mainnet.IMD),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        _freshen();
        _deploySystem(IERC20(Mainnet.V1_IMDUSD));
        eth = new ChainlinkFeed(Mainnet.CL_ETH_USD, 18, 1 hours + 10 minutes);
        _addIlk(ETH, Mainnet.WETH, eth, eth, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));

        imdLive = new LivePoolPrice(pm, MainnetConfig.IMD_ETH_POOL_ID, false);
        simdLive = new RateFeed(Mainnet.SIMD, CONVERT, true, new ProductFeed(imdLive, eth), CAP);
        RateFeed simdSpot =
            new RateFeed(Mainnet.SIMD, CONVERT, true, new ProductFeed(IFeed(Mainnet.V1_SPOT_FEED), eth), CAP);
        ParametersBase.Risk memory ir = _risk(1.7e18, 10_000_000e18);
        ir.chop = 0.2e18;
        ir.skew = 0.1e18;
        ir.redeemCap = 20_000e18;
        _addIlk(
            SIMD,
            Mainnet.SIMD,
            IFeed(Mainnet.V1_COLLATERAL_PRICE_FEED),
            simdSpot,
            IFeed(Mainnet.V1_NHI_FEED),
            address(0),
            address(0),
            simdLive,
            true,
            ir
        );
        params.seal();
        bot = new PushThenRedeem(pm, redeemer);
    }

    function _freshen() internal {
        (uint80 id, int256 answer,,, uint80 ans) = IAggregatorRound(Mainnet.CL_ETH_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer, block.timestamp, block.timestamp, ans)
        );
        vm.mockCall(Mainnet.V1_SPOT_FEED, abi.encodeWithSignature("isStale()"), abi.encode(false));
        vm.mockCall(Mainnet.V1_COLLATERAL_PRICE_FEED, abi.encodeWithSignature("isStale()"), abi.encode(false));
        vm.mockCall(Mainnet.V1_NHI_FEED, abi.encodeWithSignature("isStale()"), abi.encode(false));
    }

    // ------------------------------------------------------------ LivePoolPrice on the real pool

    function test_poolIdIsTheDeepImdEthPool() public view {
        assertEq(PoolId.unwrap(key.toId()), MainnetConfig.IMD_ETH_POOL_ID);
        assertGt(pm.getLiquidity(key.toId()), 0, "pool has no liquidity");
    }

    /// @notice Direction and scale: wei ETH per 1e18 IMD = 1e18 * 2^192 / sqrtP^2 (IMD is token1), and it
    /// agrees with v1's attested IMD/ETH spot to within 15% (the two are hours apart; inverted it would be ~1e20x off).
    function test_livePriceDirectionAndScale() public {
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        uint256 independent = Math.mulDiv(1e18, 1 << 192, uint256(sqrtP) * uint256(sqrtP));
        (uint256 v, uint64 at) = imdLive.latestValue();
        assertApproxEqRel(v, independent, 1e9, "formula");
        assertEq(at, block.timestamp);
        assertFalse(imdLive.isStale());
        (uint256 attested,) = IFeed(Mainnet.V1_SPOT_FEED).latestValue();
        assertApproxEqRel(v, attested, 0.15e18, "live vs v1 spot");
        // In USD: IMD traded between $1 and $100 in 2026; a wrong direction or scale lands far outside.
        (uint256 usdPerImd,) = new ProductFeed(imdLive, eth).latestValue();
        assertGt(usdPerImd, 1e18);
        assertLt(usdPerImd, 100e18);
    }

    // ------------------------------------------------------------ an sIMD redemption on real contracts

    function _book() internal {
        // Alice borrows against real sIMD; dave borrows against WETH and redeems against sIMD.
        uint256 shares = IERC20(Mainnet.SIMD).balanceOf(Mainnet.V1_VAULT) / 2;
        deal(Mainnet.SIMD, alice, shares);
        Pricer.Quote memory q = pricer.quote(SIMD);
        uint256 debt = Math.mulDiv(shares, q.low, 1e18) * 1e18 / q.mat / 2; // at 2x mat
        vm.startPrank(alice);
        IERC20(Mainnet.SIMD).approve(address(ledger), type(uint256).max);
        (uint256 p, uint256 n) = sorted.findInsertPosition(SIMD, 0.04e18);
        ledger.open(SIMD, 0, Adjust(int256(shares), int256(debt), 0.04e18, p, n, false, type(uint256).max, address(0)));
        vm.stopPrank();
        deal(Mainnet.WETH, dave, 1_000e18);
        vm.startPrank(dave);
        IERC20(Mainnet.WETH).approve(address(ledger), type(uint256).max);
        (p, n) = sorted.findInsertPosition(ETH, 0.05e18);
        ledger.open(ETH, 0, Adjust(1_000e18, 100_000e18, 0.05e18, p, n, false, type(uint256).max, address(0)));
        usd.transfer(address(bot), 50_000e18);
        vm.stopPrank();
        vm.deal(address(bot), 200 ether);
    }

    function test_simdRedemptionPaysAtTheHighestLeg() public {
        _book();
        Pricer.Quote memory q = pricer.quote(SIMD);
        (uint256 live,) = simdLive.latestValue();
        assertTrue(q.priced);
        assertEq(q.payout, Math.max(q.high, live), "payout = max(median, spot, live)");
        uint256 amount = 1_000e18;
        uint256 fee = redeemer.feeFor(SIMD, amount);
        uint256 out = bot.run(key, 0, 0, SIMD, amount);
        assertEq(out, Math.mulDiv(Math.mulDiv(amount, 1e18, q.payout), 1e18 - fee, 1e18));
        assertEq(IERC20(Mainnet.SIMD).balanceOf(address(bot)), out);
        // Valued at the live market, a redeemed imdUSD never buys more than $1 of sIMD.
        assertLe(Math.mulDiv(out, live, 1e18), amount);
    }

    /// @notice Pushing the live pool UP inside the redeeming transaction only lowers what it receives.
    function test_pushUpInTheSameTransactionOnlyHurtsTheRedeemer() public {
        _book();
        uint256 snap = vm.snapshotState();
        uint256 clean = bot.run(key, 0, 0, SIMD, 5_000e18);
        vm.revertToState(snap);
        (uint256 liveBefore,) = simdLive.latestValue();
        uint256 pushed = bot.run(key, 50 ether, 0, SIMD, 5_000e18);
        (uint256 liveAfter,) = simdLive.latestValue();
        assertGt(liveAfter, liveBefore, "the push moved the pool up");
        assertGt(pushed, 0, "nothing redeemed");
        assertLt(pushed, clean, "a pushed-up pool paid the redeemer more");
    }

    /// @notice Pushing it DOWN cannot pay more than the attested legs allow.
    function test_pushDownInTheSameTransactionPaysNoMoreThanTheAttestedLegs() public {
        _book();
        deal(Mainnet.IMD, address(bot), 20_000e18);
        Pricer.Quote memory q = pricer.quote(SIMD);
        uint256 amount = 5_000e18;
        uint256 fee = redeemer.feeFor(SIMD, amount);
        uint256 bound = Math.mulDiv(Math.mulDiv(amount, 1e18, q.high), 1e18 - fee, 1e18);
        uint256 pushed = bot.run(key, 0, 20_000e18, SIMD, amount);
        assertGt(pushed, 0, "nothing redeemed");
        assertLe(pushed, bound);
    }
}
