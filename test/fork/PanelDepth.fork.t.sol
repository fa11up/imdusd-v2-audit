// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";
import {LivePoolPrice} from "../../src/feeds/LivePoolPrice.sol";
import {ProductFeed} from "../../src/feeds/ProductFeed.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {DeployTypes, MainnetConfig} from "../../script/DeployConfig.sol";

/// @dev A feed a warp keeps fresh (Chainlink would read stale after vm.warp).
contract PanelFreshFeed is IFeed {
    uint256 public v;

    constructor(uint256 v_) {
        v = v_;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (v, uint64(block.timestamp));
    }

    function isStale() external pure returns (bool) {
        return false;
    }

    function maxAge() external pure returns (uint256) {
        return 1 hours;
    }
}

/// @dev A one-transaction attacker: inside one unlock, push IMD down on 0xb07d,
/// sample, poke, buy back, settle the fees. `trySample` keeps going when the sample is refused, so the poke still runs.
contract PanelPushAttacker is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;
    PoolKey key;
    DepthSampler immutable sampler;
    ImdDepth immutable agg;
    IERC20 immutable imd;
    bool public sampleRefused;

    constructor(IPoolManager pm_, PoolKey memory key_, DepthSampler s_, ImdDepth a_) {
        (pm, key, sampler, agg) = (pm_, key_, s_, a_);
        imd = IERC20(Currency.unwrap(key_.currency1));
    }

    receive() external payable {}

    function attack(uint160 pushLimit) external {
        pm.unlock(abi.encode(pushLimit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint160 pushLimit = abi.decode(data, (uint160));
        (uint160 sqrtStart,,,) = StateLibrary.getSlot0(pm, key.toId());
        BalanceDelta d1 = pm.swap(key, SwapParams(false, -int256(1e30), pushLimit), "");
        try sampler.sample() {}
        catch (bytes memory err) {
            sampleRefused = bytes4(err) == DepthSampler.ManagerUnlocked.selector;
        }
        agg.poke();
        BalanceDelta d2 = pm.swap(key, SwapParams(true, -int256(int128(d1.amount0())), sqrtStart / 2), "");
        int256 net0 = int256(d1.amount0()) + d2.amount0();
        int256 net1 = int256(d1.amount1()) + d2.amount1();
        if (net0 > 0) pm.take(key.currency0, address(this), uint256(net0));
        if (net0 < 0) pm.settle{value: uint256(-net0)}();
        if (net1 < 0) {
            pm.sync(key.currency1);
            imd.transfer(address(pm), uint256(-net1));
            pm.settle();
        }
        if (net1 > 0) pm.take(key.currency1, address(this), uint256(net1));
        return "";
    }
}

/// @notice Depth griefing on a mainnet fork, sampler 0 of the config (IMD/ETH 0xb07d, 77% of the depth):
///  - the one-transaction push-sample-poke (PoC DepthPushDeflate) is refused, and the line does not move;
///  - with capital held across separate calls (a sandwich), against the config's LIVE reference, one sandwiched hour does
///    not move the depth (4th-lowest bucket / 4th-lowest hour);
///  - with a reference the push cannot move (a fixed feed at the honest price: NOT the deployed wiring, which stays on the
///    LIVE reference, see DeployConfig._depthSamplers), a push inside the deviation bound does not change the
///    reading at all.
/// Failed before the fix (the one-transaction attack lowered ImdDepth.depth() for 7 days).
contract PanelDepthForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    PoolKey key;
    DeployTypes.SamplerSpec sp;
    DepthSampler sampler;
    ImdDepth agg;
    PanelFreshFeed fEth;
    IFeed imdUsdLive;

    function _setUpFork() internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc);
        sp = MainnetConfig.get().depth.samplers[0];
        key = PoolKey(Currency.wrap(sp.currency0), Currency.wrap(sp.currency1), sp.fee, sp.tickSpacing, IHooks(sp.hooks));
        assertEq(PoolId.unwrap(key.toId()), sp.poolId);
        (, int256 e8,,,) = IAgg(CL_ETH_USD).latestRoundData();
        fEth = new PanelFreshFeed(uint256(e8) * 1e10);
        imdUsdLive = IFeed(address(new ProductFeed(IFeed(address(new LivePoolPrice(PM, sp.poolId, false))), IFeed(address(fEth)))));
        return true;
    }

    function _deploy(IFeed imdRef) internal {
        sampler = new DepthSampler(PM, key, IFeed(address(fEth)), imdRef, sp.bandBps, sp.maxDeviationTicks, sp.maxSteps, sp.soldIsToken0);
        agg = new ImdDepth(address(this)); // this test plays Parameters
        agg.addSampler(address(sampler));
    }

    function _honestHours(uint256 n) internal {
        for (uint256 h; h < n; ++h) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            sampler.sample();
            agg.poke();
        }
    }

    function _limitDown(uint256 pushBps) internal view returns (uint160) {
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        return uint160(Math.mulDiv(sqrtP, Math.sqrt(uint256(1e36) / (10_000 - pushBps) * 10_000), 1e18));
    }

    function test_M6_oneTxPushIsRefusedAndTheLineHolds() public {
        if (!_setUpFork()) return vm.skip(true);
        _deploy(imdUsdLive); // the config as it stands (live reference): the unlock refusal alone stops this form
        _honestHours(9 * 24);
        uint256 dHonest = agg.depth();
        assertGt(dHonest, 0);
        PanelPushAttacker att = new PanelPushAttacker(PM, key, sampler, agg);
        deal(IMD, address(att), 100_000e18);
        att.attack(_limitDown(6_500));
        assertTrue(att.sampleRefused(), "sample inside the unlock: ManagerUnlocked");
        console2.log("honest depth (USD)", dHonest / 1e18);
        console2.log("after the one-tx 65% push (USD)", agg.depth() / 1e18);
        assertEq(agg.depth(), dHonest, "the 65% push no longer moves the depth");
        _honestHours(24);
        // The attacker's round trip leaves the live pool slightly off where it was, so later honest hours read a real, smaller depth. It drifts with the fork block (seen -1.0% to -1.6%).
        assertApproxEqRel(agg.depth(), dHonest, 0.03e18);
    }

    function test_M6_oneSandwichedHourDoesNotMoveTheDepth() public {
        if (!_setUpFork()) return vm.skip(true);
        _deploy(imdUsdLive);
        _honestHours(9 * 24);
        uint256 dHonest = agg.depth();
        // Capital held across calls (a bundle): push 50%, sample + poke, unpush.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        deal(IMD, address(this), 1e30);
        (uint160 sqrtStart,,,) = PM.getSlot0(key.toId());
        uint256 ethOut = _swap(false, -int256(1e30), _limitDown(5_000));
        (, uint256 pushed) = sampler.measure();
        sampler.sample();
        agg.poke();
        _swap(true, -int256(ethOut), sqrtStart / 2);
        console2.log("reading at the pushed price (USD)", pushed / 1e18);
        console2.log("depth after one sandwiched hour (USD)", agg.depth() / 1e18);
        assertLt(pushed, dHonest * 80 / 100, "the live reference still deflates the single reading");
        assertApproxEqRel(agg.depth(), dHonest, 0.01e18, "one low bucket / hour no longer sets the depth");
    }

    function test_M6_unmovableReferenceIgnoresThePush() public {
        if (!_setUpFork()) return vm.skip(true);
        (uint256 honestImdUsd,) = imdUsdLive.latestValue();
        _deploy(IFeed(address(new PanelFreshFeed(honestImdUsd)))); // not the deployed wiring: shows the reference's role only
        (, uint256 honest) = sampler.measure();
        deal(IMD, address(this), 1e30);
        _swap(false, -int256(1e30), _limitDown(300)); // 3% push: inside maxDeviationTicks (400)
        (, uint256 pushed) = sampler.measure();
        console2.log("honest (USD)", honest / 1e18);
        console2.log("after a 3% push (USD)", pushed / 1e18);
        assertEq(pushed, honest, "positions only: the push does not change the reading");
        _swap(false, -int256(1e30), _limitDown(1_500)); // further: off the reference, refused
        vm.expectPartialRevert(DepthSampler.PoolOffReference.selector);
        sampler.sample();
    }

    // ---------------------------------------------------------------- swaps from this contract

    function _swap(bool zeroForOne, int256 amount, uint160 limit) internal returns (uint256 out) {
        bytes memory r = PM.unlock(abi.encode(zeroForOne, amount, limit));
        out = abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool zeroForOne, int256 amount, uint160 limit) = abi.decode(data, (bool, int256, uint160));
        BalanceDelta d = PM.swap(key, SwapParams(zeroForOne, amount, limit), "");
        uint256 out;
        if (zeroForOne) {
            PM.settle{value: uint128(-d.amount0())}();
            out = uint128(d.amount1());
            PM.take(key.currency1, address(this), out);
        } else {
            out = uint128(d.amount0());
            PM.take(key.currency0, address(this), out);
            PM.sync(key.currency1);
            IERC20(IMD).transfer(address(PM), uint128(-d.amount1()));
            PM.settle();
        }
        return abi.encode(out);
    }

    receive() external payable {}
}

interface IAgg {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
