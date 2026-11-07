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
import {MockFeed} from "../utils/Mocks.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {LivePoolPrice} from "../../src/feeds/LivePoolPrice.sol";
import {MainnetConfig} from "../../script/DeployConfig.sol";
import {LoopVault, ILoopRouter} from "../../src/earn/LoopVault.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IAggregatorRound {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev A route through the REAL IMD/ETH v4 pool (1% fee), with the imdUSD<->ETH leg as an OTC desk at Chainlink's
/// ETH/USD (v2 imdUSD has no mainnet market yet). Also pushes the pool for the price-move scenario.
contract PoolRoute is ILoopRouter, IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager immutable pm;
    IERC20 immutable usd;
    IERC20 immutable imd;
    IFeed immutable ethUsd;
    PoolKey key;

    constructor(IPoolManager pm_, PoolKey memory key_, IERC20 usd_, IFeed ethUsd_) {
        pm = pm_;
        key = key_;
        usd = usd_;
        imd = IERC20(Currency.unwrap(key_.currency1));
        ethUsd = ethUsd_;
    }

    receive() external payable {}

    function loopSwap(address tokenIn, uint256 amountIn, address, bytes calldata) external {
        (uint256 eth,) = ethUsd.latestValue(); // USD per 1e18 wei
        if (tokenIn == address(usd)) {
            uint256 imdOut = _swap(true, Math.mulDiv(amountIn, 1e18, eth), TickMath.MIN_SQRT_PRICE + 1);
            imd.safeTransfer(msg.sender, imdOut);
        } else {
            uint256 ethOut = _swap(false, amountIn, TickMath.MAX_SQRT_PRICE - 1);
            usd.safeTransfer(msg.sender, Math.mulDiv(ethOut, eth, 1e18));
        }
    }

    /// @dev Sell IMD until the pool's price of IMD has fallen to `bps` of where it is.
    function pushDown(uint256 bps) external {
        (uint160 sp,,,) = StateLibrary.getSlot0(pm, PoolIdLibrary.toId(key));
        // IMD is token1: IMD per ETH = sqrtP^2, so IMD x bps cheaper => sqrtP / sqrt(bps).
        uint160 limit = uint160(Math.mulDiv(sp, 1e9, Math.sqrt(bps * 1e14)));
        _swap(false, imd.balanceOf(address(this)), limit);
    }

    function _swap(bool ethIn, uint256 amountIn, uint160 limit) private returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(ethIn, amountIn, limit)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool ethIn, uint256 amountIn, uint160 limit) = abi.decode(data, (bool, uint256, uint160));
        BalanceDelta d = pm.swap(key, SwapParams(ethIn, -int256(amountIn), limit), "");
        int128 a0 = BalanceDeltaLibrary.amount0(d);
        int128 a1 = BalanceDeltaLibrary.amount1(d);
        if (a0 < 0) {
            pm.sync(key.currency0);
            pm.settle{value: uint128(-a0)}();
        }
        if (a1 < 0) {
            pm.sync(key.currency1);
            imd.safeTransfer(address(pm), uint128(-a1));
            pm.settle();
        }
        uint256 out = a0 > 0 ? uint128(a0) : a1 > 0 ? uint128(a1) : 0;
        if (a0 > 0) pm.take(key.currency0, address(this), uint128(a0));
        if (a1 > 0) pm.take(key.currency1, address(this), uint128(a1));
        return abi.encode(out);
    }
}

/// @notice Exit criterion: "the loop vault holds its target through a price move", on mainnet with
/// the REAL StakedIMD (sIMD) as collateral and the REAL IMD/ETH v4 pool as both the live price leg and the swap venue.
/// The attested legs are mocks set to the live pool's reading (the keeper's fresh attestation after each move).
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/LoopVault.fork.t.sol
contract LoopVaultForkTest is System {
    using StateLibrary for IPoolManager;

    bytes32 constant SIMD = "SIMD";
    bytes4 constant CONVERT = bytes4(keccak256("convertToAssets(uint256)"));
    uint256 constant CAP = uint256(0.001e18) / 1 days;

    IPoolManager pm = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
    PoolKey key;
    IFeed simdLive;
    MockFeed median;
    MockFeed spot;
    LoopVault vault;
    PoolRoute route;
    address alice = makeAddr("alice");
    int256 ethAnswer;

    /// @dev Chainlink ETH/USD at its forked answer, stamped now (fork state can be minutes old).
    function _freshEth() internal {
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), ethAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(Mainnet.IMD), 10_000, 200, IHooks(address(0)));
        (, ethAnswer,,,) = IAggregatorRound(Mainnet.CL_ETH_USD).latestRoundData();
        _freshEth();
        _deploySystem(IERC20(Mainnet.V1_IMDUSD));
        IFeed eth = new ChainlinkFeed(Mainnet.CL_ETH_USD, 18, 1 hours + 10 minutes);
        simdLive = new RateFeed(
            Mainnet.SIMD,
            CONVERT,
            true,
            new ProductFeed(new LivePoolPrice(pm, MainnetConfig.IMD_ETH_POOL_ID, false), eth),
            CAP
        );
        (uint256 v,) = simdLive.latestValue();
        median = new MockFeed(v);
        spot = new MockFeed(v);
        ParametersBase.Risk memory ir = _risk(1.7e18, 10_000_000e18);
        ir.chop = 0.2e18;
        ir.skew = 0.1e18;
        ir.redeemCap = 20_000e18;
        _addIlk(SIMD, Mainnet.SIMD, median, spot, IFeed(address(0)), address(0), address(0), simdLive, true, ir);
        // E3: the debt cap reads the posted depth (the genesis config's 7-day low, $80.1k).
        params.setGenesisDepthRule(SIMD, 0.8e18, 80_100e18, 0, 0);
        params.seal();
        vault = new LoopVault(ledger, SIMD, address(treasury));
        route = new PoolRoute(pm, key, IERC20(address(usd)), eth);
        vm.deal(address(route), 1_000 ether);
        deal(address(usd), address(route), 1_000_000e18, true);
        deal(Mainnet.IMD, alice, 5_000e18);
        deal(address(usd), alice, 100_000e18, true);
        vm.startPrank(alice);
        IERC20(Mainnet.IMD).approve(address(vault), type(uint256).max);
        usd.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The keeper's fresh attestation: both attested legs = the live pool, now.
    function _attest() internal {
        _freshEth();
        (uint256 v,) = simdLive.latestValue();
        median.set(v);
        spot.set(v);
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function test_fork_holdsTargetThroughAFifteenPercentFall() public {
        vm.prank(alice);
        vault.deposit(5_000e18, 0, alice);
        (uint256 c0,) = vault.position();
        assertGt(c0, 0, "staked into the real sIMD");

        // Lever to 250% through the real pool, one capped step per block, attested before each.
        uint256 steps;
        for (; steps < 20; ++steps) {
            _attest();
            try vault.lever(address(route), type(uint256).max, "") {}
                catch {
                break;
            }
            _nextBlock();
        }
        _attest();
        uint256 cr = vault.collateralRatio();
        emit log_named_uint("lever steps", steps);
        emit log_named_decimal_uint("CR after levering", cr, 18);
        assertApproxEqRel(
            cr, 2.5e18, 0.01e18, "at the 250% target (its own buys move the pool before the next attestation)"
        );
        (int256 navStart,) = _navs();

        // IMD falls 15% in the real pool; the fall is attested.
        deal(Mainnet.IMD, address(route), IERC20(Mainnet.IMD).balanceOf(address(route)) + 2_000_000e18);
        (uint256 before,) = simdLive.latestValue();
        route.pushDown(8_500);
        (uint256 afterPush,) = simdLive.latestValue();
        assertApproxEqRel(afterPush, before * 85 / 100, 0.005e18, "a 15% fall");
        _nextBlock();
        _attest();
        cr = vault.collateralRatio();
        emit log_named_decimal_uint("CR after the fall", cr, 18);
        assertLt(cr, 2.2e18, "out of the band");
        assertGt(cr, 1.7e18, "not liquidatable");

        // Delever through the same pool until back in the band.
        uint256 dsteps;
        for (; dsteps < 10; ++dsteps) {
            _attest();
            try vault.delever(address(route), type(uint256).max, "") {}
                catch {
                break;
            }
            _nextBlock();
        }
        _attest();
        cr = vault.collateralRatio();
        emit log_named_uint("delever steps", dsteps);
        emit log_named_decimal_uint("CR after delevering", cr, 18);
        assertGt(dsteps, 0);
        assertGe(cr, 2.2e18, "back above 220%");
        assertLe(cr, 2.8e18);
        (bool healthy, bool priced) = ledger.healthy(_pid(SIMD, address(vault)));
        assertTrue(healthy && priced, "solvent on the Ledger");
        (int256 navEnd,) = _navs();
        assertGt(navEnd, 0, "solvent: positive net value");
        emit log_named_decimal_int("net value at start (IMD)", navStart, 18);
        emit log_named_decimal_int("net value after the fall + delever (IMD)", navEnd, 18);

        // Exit open: alice repays her debt in imdUSD and takes the IMD.
        uint256 s = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 imdOut,) = vault.withdraw(s, 0, alice);
        assertGt(imdOut, 0);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES());
        (uint256 c, uint256 d) = vault.position();
        assertEq(c + d, 0, "position closed");
    }

    function _navs() internal view returns (int256 n, uint256 p) {
        (p,) = simdLive.latestValue();
        n = vault.nav(p);
    }
}
