// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockFeed} from "../utils/Mocks.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {DeployTypes, MainnetConfig, BetaConfig} from "../../script/DeployConfig.sol";
import {Mainnet as A} from "./MainnetAddresses.sol";

interface IAggregatorV3Depth {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Measured depth on the live pools: the mainnet config's three IMD exit-pool samplers (band -15%), each measured,
/// then a simulated keeper week (hourly samples, daily pokes) through ImdDepth, and the day-7 sIMD line D1 admits at k 0.8
/// on that measured depth (Robinhood's IMD line counted). The fork freezes the pools, so the week reads today's book.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/DepthRule.fork.t.sol -vv (skips without one).
contract DepthRuleForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_fork_measuredDepthAndDay7Line() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        IPoolManager pm = IPoolManager(A.UNIV4_POOL_MANAGER);
        DeployTypes.Config memory cfg = MainnetConfig.get();
        assertTrue(cfg.depth.enabled);

        // The config's IMD reference is the live 0xb07d price x ETH/USD; stand it in with mocks the warp can refresh.
        (, int256 ethUsd8,,,) = IAggregatorV3Depth(A.CL_ETH_USD).latestRoundData();
        uint256 pEth = uint256(ethUsd8) * 1e10;
        (uint160 sqrtP,,,) = pm.getSlot0(PoolId.wrap(MainnetConfig.IMD_ETH_POOL_ID));
        uint256 pImd = Math.mulDiv(pEth, 1 << 192, Math.mulDiv(sqrtP, sqrtP, 1));
        MockFeed fEth = new MockFeed(pEth);
        MockFeed fImd = new MockFeed(pImd);
        console2.log("IMD USD (1e18)", pImd);

        ImdDepth agg = new ImdDepth(address(this)); // this test plays Parameters
        uint256 n = cfg.depth.samplers.length;
        DepthSampler[] memory sm = new DepthSampler[](n);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            DeployTypes.SamplerSpec memory sp = cfg.depth.samplers[i];
            PoolKey memory key = PoolKey(Currency.wrap(sp.currency0), Currency.wrap(sp.currency1), sp.fee, sp.tickSpacing, IHooks(sp.hooks));
            assertEq(PoolId.unwrap(key.toId()), sp.poolId, "pool key");
            IFeed f0 = sp.feed0 == DeployTypes.NO_FEED ? IFeed(address(0)) : IFeed(address(fEth));
            sm[i] = new DepthSampler(pm, key, f0, IFeed(address(fImd)), sp.bandBps, sp.maxDeviationTicks, sp.maxSteps, sp.soldIsToken0);
            try sm[i].measure() returns (uint256, uint256 sellImd) {
                console2.log("sampler", i, "IMD sold to -15% (USD 1e18)", sellImd);
                sum += sellImd;
            } catch {
                console2.log("sampler", i, "refuses (pool off the reference): contributes 0");
            }
            agg.addSampler(address(sm[i]));
        }
        console2.log("sum of exit pools to -15% (USD 1e18)", sum);
        assertGt(sum, 0);

        // A keeper week: sample every pool hourly, poke daily.
        for (uint256 h; h < 7 * 24; ++h) {
            fEth.set(pEth);
            fImd.set(pImd);
            for (uint256 i; i < n; ++i) {
                try sm[i].sample() {} catch {}
            }
            if (h % 24 == 0) agg.poke();
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        fEth.set(pEth);
        fImd.set(pImd);
        agg.poke();
        uint256 depth = agg.depth();
        console2.log("ImdDepth.depth() after a week (USD 1e18)", depth);
        assertApproxEqRel(depth, sum, 0.001e18, "a week of the same book reads the same depth");

        uint128 line = MainnetConfig.simdLineFor(BetaConfig.SIMD_LINE_TARGET, depth);
        console2.log("day-7 sIMD line at k 0.8 (imdUSD 1e18)", line);
    }
}
