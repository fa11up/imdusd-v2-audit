// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {CompoundCurve} from "../../src/dex/CompoundCurve.sol";
import {CompoundSystem} from "../utils/CompoundSystem.sol";
import {Mainnet} from "./MainnetAddresses.sol";

interface IDripper {
    function drip() external returns (uint256 toVault, uint256 toKeeper);
    function canDrip() external view returns (bool);
}

interface IStakedIMD {
    function lastDepositBlock(address) external view returns (uint256);
}

/// @notice The Compound DEX on the REAL mainnet PoolManager with the REAL sIMD (whole-address hold) and sINFER (per-lot
/// hold) and their underlyings; a real InferDripper.drip() raises sINFER's rate.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/CompoundHook.fork.t.sol
contract CompoundHookForkTest is CompoundSystem {
    IERC20 constant IMD = IERC20(Mainnet.IMD);
    IERC20 constant INFER = IERC20(Mainnet.INFER);
    IERC4626 constant SIMD = IERC4626(Mainnet.SIMD);
    IERC4626 constant SINFER = IERC4626(Mainnet.SINFER);
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address eve = makeAddr("eve");
    uint8 iImd;
    uint8 iInf;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        // INFER sorts first: token0 = INFER, token1 = IMD; open at 0.001 IMD per INFER
        uint160 sqrtP = uint160(uint256(1 << 96) * 31622777 / 1e9); // sqrt(0.001) = 0.031622777
        _deployDex(IPoolManager(Mainnet.UNIV4_POOL_MANAGER), SIMD, SINFER, sqrtP);
        iImd = address(hook.token0()) == Mainnet.IMD ? 0 : 1;
        iInf = 1 - iImd;
        assertEq(address(_tok(iInf)), Mainnet.INFER, "INFER is token0");
        // seed: 20,000,000 INFER + 20,000 IMD
        uint256 a0 = iInf == 0 ? 20_000_000e18 : 20_000e18;
        uint256 a1 = iInf == 0 ? 20_000e18 : 20_000_000e18;
        _seed(lp, a0, a1);
        _hold(lp, 31 minutes);
        for (uint8 i; i < 2; ++i) {
            _fundRaw(alice, i, i == iImd ? 50_000e18 : 50_000_000e18);
            _fundRaw(eve, i, 100e18);
        }
        _approveAll(alice);
        vm.startPrank(eve);
        IMD.approve(address(SIMD), type(uint256).max);
        INFER.approve(address(SINFER), type(uint256).max);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function _fundRaw(address to, uint8 i, uint256 amount) internal override {
        deal(address(_tok(i)), to, _tok(i).balanceOf(to) + amount);
    }

    function _held(uint8 i) internal view returns (uint256) {
        (uint256 h0, uint256 h1) = hook.totals();
        return i == 0 ? h0 : h1;
    }

    function test_fork_vaultsAreTheRealOnes() public view {
        assertEq(SIMD.asset(), Mainnet.IMD);
        assertEq(SINFER.asset(), Mainnet.INFER);
        assertEq(address(hook.vault0()), Mainnet.SINFER);
        assertEq(address(hook.vault1()), Mainnet.SIMD);
        _assertCovered();
    }

    function test_fork_swapBothWays() public {
        // IMD -> INFER, then all of it back
        uint256 imd0 = IMD.balanceOf(alice);
        uint256 inf0 = INFER.balanceOf(alice);
        _swapPM(alice, iImd == 0, -1_000e18, "");
        uint256 got = INFER.balanceOf(alice) - inf0;
        assertGt(got, 0);
        emit log_named_uint("INFER for 1,000 IMD", got);
        vm.roll(vm.getBlockNumber() + 1);
        _swapPM(alice, iInf == 0, -int256(got), "");
        uint256 back = IMD.balanceOf(alice) - (imd0 - 1_000e18);
        assertLt(back, 1_000e18, "round trip loses");
        assertGt(back, 993e18, "about two fees");
        _assertCovered();
    }

    /// @dev A real drip raises sINFER's rate: the quote in underlying units does not move (no arbitrage), and the
    /// next action takes exactly 10% of the reserves' growth for the Treasury.
    function test_fork_realDripNoArbitrageAndYieldFee() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        _poke(lp); // apply the hour's re-centring before measuring
        CompoundCurve.Step memory q0 = lens.quote(hook, iImd == 0, -500e18);
        CompoundCurve.Step memory q1 = lens.quote(hook, iInf == 0, -500_000e18);
        uint256 shares = _pocketShares(SINFER);
        uint256 r0 = SINFER.convertToAssets(1e36);
        assertTrue(IDripper(Mainnet.INFER_DRIPPER).canDrip(), "dripper ready");
        IDripper(Mainnet.INFER_DRIPPER).drip();
        uint256 r1 = SINFER.convertToAssets(1e36);
        assertGt(r1, r0, "the drip raised sINFER's rate");
        CompoundCurve.Step memory p0 = lens.quote(hook, iImd == 0, -500e18);
        CompoundCurve.Step memory p1 = lens.quote(hook, iInf == 0, -500_000e18);
        assertEq(p0.amountOut, q0.amountOut, "IMD->INFER quote unchanged");
        assertEq(p1.amountOut, q1.amountOut, "INFER->IMD quote unchanged");
        uint256 expectY = Math.mulDiv(shares, r1 - r0, 1e36);
        uint256 y0 = hook.yieldCollected(iInf);
        uint256 t0 = hook.balanceOf(treasury);
        uint256 b = INFER.balanceOf(alice);
        _swapPM(alice, iImd == 0, -500e18, "");
        assertEq(INFER.balanceOf(alice) - b, q0.amountOut, "traded at the pre-drip quote");
        assertEq(hook.yieldCollected(iInf) - y0, expectY, "yield = shares x rate rise");
        assertGt(hook.balanceOf(treasury), t0, "treasury paid in shares");
        emit log_named_uint("sINFER yield to the pool (INFER wei)", expectY);
    }

    /// @dev The grief on the real sIMD: a stranger stamps the hook with deposit(1 wei); an IMD-out swap past the
    /// buffer completes in sIMD when allowed, reverts when not; the next block pays raw.
    function test_fork_stampGriefOnRealSimd() public {
        // D2: the reserve sits at the hook and its pockets; the whole hold takes one 1-wei deposit at each
        vm.startPrank(eve);
        SIMD.deposit(1, address(hook));
        for (uint256 k; k < hook.POCKETS(); ++k) {
            SIMD.deposit(1, hook.pockets(k));
        }
        vm.stopPrank();
        assertEq(IStakedIMD(Mainnet.SIMD).lastDepositBlock(address(hook)), vm.getBlockNumber(), "stamped");
        assertEq(SIMD.maxWithdraw(address(hook)), 0);
        for (uint256 k; k < hook.POCKETS(); ++k) {
            assertEq(SIMD.maxWithdraw(hook.pockets(k)), 0, "pocket stamped");
        }
        uint256 big = _held(iInf) / 8; // INFER in: pays ~12% of the IMD side, past the buffer
        uint160 lim = iImd == 0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        bool z = iImd == 1; // paying token1 = IMD needs zeroForOne
        vm.prank(alice);
        vm.expectRevert();
        router.swap(key, SwapParams(z, -int256(big), z ? TickMath.MIN_SQRT_PRICE + 1 : lim), "");
        uint256 sh = SIMD.balanceOf(alice);
        uint256 raw = IMD.balanceOf(alice);
        _swapPM(alice, z, -int256(big), abi.encode(true, alice));
        assertEq(IMD.balanceOf(alice), raw, "no raw IMD");
        assertGt(SIMD.balanceOf(alice), sh, "paid in real sIMD");
        _assertCovered();
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        raw = IMD.balanceOf(alice);
        _swapPM(alice, z, -int256(big / 4), "");
        assertGt(IMD.balanceOf(alice), raw, "next block: raw IMD");
    }

    /// @dev sINFER's per-lot hold on the real vault: a fresh lot stamped on the hook leaves its older shares
    /// redeemable, so INFER outputs past the buffer still pay raw.
    function test_fork_perLotHoldOnRealSinfer() public {
        vm.prank(eve);
        SINFER.deposit(1e18, address(hook));
        uint256 big = _held(iImd) / 8;
        bool z = iInf == 1;
        uint256 raw = INFER.balanceOf(alice);
        _swapPM(alice, z, -int256(big), "");
        assertGt(INFER.balanceOf(alice), raw, "raw INFER past the buffer");
    }

    /// @dev The direct path with the real staked tokens: sINFER in, sIMD out (and back), priced in underlying units.
    function test_fork_directStakedSwap() public {
        address bob = makeAddr("bob");
        deal(Mainnet.INFER, bob, 1_000_000e18);
        vm.startPrank(bob);
        INFER.approve(address(SINFER), type(uint256).max);
        uint256 sh = SINFER.deposit(1_000_000e18, bob);
        IERC20(address(SINFER)).approve(address(hook), type(uint256).max);
        IERC20(address(SIMD)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        CompoundCurve.Step memory q = lens.quote(hook, iInf == 0, -int256(SINFER.convertToAssets(sh)));
        vm.prank(bob);
        (address pt, uint256 paid, uint256 value) = hook.swap(address(SINFER), sh, address(SIMD), 0, bob, false);
        assertEq(pt, Mainnet.SIMD);
        assertEq(paid, SIMD.convertToShares(q.amountOut), "sIMD at convertToShares, rounded down");
        assertLe(value, q.amountOut);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        (pt,, value) = hook.swap(address(SIMD), paid, address(SINFER), 0, bob, false);
        assertEq(pt, Mainnet.SINFER);
        assertLt(value, 1_000_000e18, "round trip loses");
        assertGt(value, 990_000e18);
        _assertCovered();
    }

    /// @dev An LP who sits through a real drip leaves with 90% of its share of the yield (the Treasury's 10% is
    /// minted as shares); one who sits through trades leaves with its share of the fees.
    function test_fork_lpExitWithYieldAndFees() public {
        address lp2 = makeAddr("lp2");
        _fundRaw(lp2, iInf, 40_000_000e18);
        _fundRaw(lp2, iImd, 40_000e18);
        _approveAll(lp2);
        uint256 sup = hook.totalSupply();
        vm.prank(lp2);
        (, uint256 in0, uint256 in1) = hook.deposit(sup, type(uint256).max, type(uint256).max, false, false, lp2);
        uint256 frac = hook.balanceOf(lp2) * 1e18 / hook.totalSupply();
        // yield only: an hour, a real drip, exit
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        uint256 shares = _pocketShares(SINFER);
        uint256 r0 = SINFER.convertToAssets(1e36);
        IDripper(Mainnet.INFER_DRIPPER).drip();
        uint256 yieldInf = Math.mulDiv(shares, SINFER.convertToAssets(1e36) - r0, 1e36);
        uint256 half = hook.balanceOf(lp2) / 2;
        vm.prank(lp2);
        (uint256 o0, uint256 o1) = hook.withdraw(half, 0, 0, true, true, lp2);
        (uint256 oInf, uint256 oImd) = iInf == 0 ? (o0, o1) : (o1, o0);
        (uint256 inInf, uint256 inImd) = iInf == 0 ? (in0, in1) : (in1, in0);
        // The Treasury's 10% is a pro-rata claim on the whole book, so it comes half from each side: valued at the
        // curve's price, the LP's gain is 90% of its share of the yield.
        uint256 px0 = Math.mulDiv(Math.mulDiv(1e18, hook.sqrtPriceX96(), 1 << 96), hook.sqrtPriceX96(), 1 << 96);
        int256 gainImd = int256(oInf * px0 / 1e18) - int256(inInf / 2 * px0 / 1e18) + int256(oImd) - int256(inImd / 2);
        uint256 expectImd = yieldInf * frac / 1e18 * 9 / 10 / 2 * px0 / 1e18;
        emit log_named_int("yield gain on half (IMD value)", gainImd);
        emit log_named_uint("90% of its yield share (IMD value)", expectImd);
        assertApproxEqRel(uint256(gainImd), expectImd, 0.01e18, "LP keeps 90% of its yield");
        assertLt(oImd, inImd / 2, "the Treasury's share comes from both sides");
        // fees: trades both ways, then exit the rest
        for (uint256 n; n < 5; ++n) {
            _swapPM(alice, iImd == 0, -500e18, "");
            _swapPM(alice, iInf == 0, -500_000e18, "");
        }
        uint256 rest = hook.balanceOf(lp2);
        vm.prank(lp2);
        (o0, o1) = hook.withdraw(rest, 0, 0, false, false, lp2);
        uint256 sp = hook.sqrtPriceX96();
        uint256 px = Math.mulDiv(Math.mulDiv(1e18, sp, 1 << 96), sp, 1 << 96); // token1 per token0, 1e18
        uint256 vin = (in0 + in1 * 1e18 / px) / 2;
        uint256 vout = o0 + o1 * 1e18 / px;
        assertGt(vout, vin, "fees earned");
        _assertCovered();
    }
}
