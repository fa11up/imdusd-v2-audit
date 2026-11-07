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
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Mainnet as A} from "./MainnetAddresses.sol";

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice DepthSampler on the live IMD/ETH v4 pool (key read from v4 PositionManager.poolKeys: ETH, IMD, fee 10000,
/// spacing 200, no hook; id 0xb07d…bfb3 = DeployConfig.IMD_ETH_POOL_ID). Feeds are mocks set from Chainlink ETH/USD and
/// the pool's own price, so the reference is the pool price and the reading is the pool's depth to -band.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/DepthSampler.fork.t.sol -vv (skips without one).
contract DepthSamplerForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    bytes32 constant IMD_ETH_POOL_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;

    function test_fork_liveImdEthDepth() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        IPoolManager pm = IPoolManager(A.UNIV4_POOL_MANAGER);
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0)));
        assertEq(PoolId.unwrap(key.toId()), IMD_ETH_POOL_ID, "pool key");

        (, int256 ethUsd8,,,) = IAggregatorV3(A.CL_ETH_USD).latestRoundData();
        uint256 pEth = uint256(ethUsd8) * 1e10; // USD per 1e18 wei
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        // pool price p = raw IMD per raw wei = sqrtP^2 / 2^192, so USD per 1e18 raw IMD = pEth / p
        uint256 pImd = Math.mulDiv(pEth, 1 << 192, Math.mulDiv(sqrtP, sqrtP, 1));
        MockFeed fEth = new MockFeed(pEth);
        MockFeed fImd = new MockFeed(pImd);
        console2.log("ETH USD (1e18)", pEth);
        console2.log("IMD USD (1e18)", pImd);

        uint256[3] memory bands = [uint256(200), 500, 1500];
        for (uint256 i; i < 3; ++i) {
            DepthSampler sm =
                new DepthSampler(pm, key, IFeed(address(fEth)), IFeed(address(fImd)), bands[i], 400, 4096, false);
            (uint256 sellEth, uint256 sellImd) = sm.measure();
            console2.log("band bps", bands[i]);
            console2.log("  IMD sold -> ETH out (USD 1e18)", sellImd);
            console2.log("  ETH sold -> IMD out (USD 1e18)", sellEth);
            assertGt(sellImd, 0);
            sm.sample();
            assertEq(sm.depth(), 0, "fail closed until 20 buckets");
        }
    }
}
