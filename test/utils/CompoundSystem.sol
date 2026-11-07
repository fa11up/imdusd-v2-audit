// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {CompoundLens} from "../../src/dex/CompoundLens.sol";
import {CompoundCurve} from "../../src/dex/CompoundCurve.sol";
import {CdxRouter, DexTreasuryStub} from "./DexMocks.sol";

/// @notice A Compound DEX pool on a v4 PoolManager: the hook at a mined CREATE2 address, its pool initialised, a
/// lens and a router. Funding is virtual (mocks mint, the fork deals).
abstract contract CompoundSystem is Test {
    IPoolManager internal pm;
    CompoundHook internal hook;
    CompoundLens internal lens;
    CdxRouter internal router;
    PoolKey internal key;
    /// @dev A contract answering `token()` (the hook reads imdUSD from the Treasury); its token is a placeholder.
    address internal treasury = address(new DexTreasuryStub(address(0x1D05D)));

    function _deployDex(IPoolManager pm_, IERC4626 vaultA, IERC4626 vaultB, uint160 sqrtP) internal {
        pm = pm_;
        // a fork selected after construction does not hold the stub deployed by the initializer
        if (treasury.code.length == 0) treasury = address(new DexTreasuryStub(address(0x1D05D)));
        hook = _mineHook(vaultA, vaultB, sqrtP);
        lens = new CompoundLens();
        router = new CdxRouter(pm);
        key = PoolKey(
            Currency.wrap(address(hook.token0())),
            Currency.wrap(address(hook.token1())),
            hook.FEE_PIPS(),
            hook.TICK_SPACING(),
            IHooks(address(hook))
        );
        pm.initialize(key, sqrtP);
    }

    function _mineHook(IERC4626 vaultA, IERC4626 vaultB, uint160 sqrtP) internal returns (CompoundHook h) {
        bytes memory args = abi.encode(pm, vaultA, vaultB, treasury, sqrtP);
        bytes32 initHash = keccak256(abi.encodePacked(type(CompoundHook).creationCode, args));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        for (uint256 salt;; ++salt) {
            address a = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags && a.code.length == 0) {
                h = new CompoundHook{salt: bytes32(salt)}(pm, vaultA, vaultB, treasury, sqrtP);
                require(address(h) == a, "mined address");
                return h;
            }
        }
    }

    // ------------------------------------------------------------ sides

    function _tok(uint8 i) internal view returns (IERC20) {
        return i == 0 ? hook.token0() : hook.token1();
    }

    function _vlt(uint8 i) internal view returns (IERC4626) {
        return i == 0 ? hook.vault0() : hook.vault1();
    }

    function _fundRaw(address to, uint8 i, uint256 amount) internal virtual;

    /// @dev Give `to` vault shares of side i bought with `assets` of fresh underlying.
    function _fundStaked(address to, uint8 i, uint256 assets) internal returns (uint256 shares) {
        address funder = makeAddr("stakeFunder");
        _fundRaw(funder, i, assets);
        vm.startPrank(funder);
        _tok(i).approve(address(_vlt(i)), assets);
        shares = _vlt(i).deposit(assets, to);
        vm.stopPrank();
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        for (uint8 i; i < 2; ++i) {
            _tok(i).approve(address(hook), type(uint256).max);
            _tok(i).approve(address(router), type(uint256).max);
            IERC20(address(_vlt(i))).approve(address(hook), type(uint256).max);
        }
        vm.stopPrank();
    }

    /// @dev The first deposit: raw amounts of each side.
    function _seed(address lp, uint256 a0, uint256 a1) internal returns (uint256 minted) {
        _fundRaw(lp, 0, a0);
        _fundRaw(lp, 1, a1);
        _approveAll(lp);
        vm.prank(lp);
        (minted,,) = hook.deposit(0, a0, a1, false, false, lp);
    }

    // ------------------------------------------------------------ trading

    function _swapPM(address who, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta d)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(who);
        d = router.swap(key, SwapParams(zeroForOne, amountSpecified, limit), hookData);
    }

    /// @dev Hold the curve's price where it is for `secs`, one tiny alternating swap per OBS_GAP, so observations are
    /// written and the TWAP converges to the spot.
    function _hold(address who, uint256 secs) internal {
        for (uint256 s; s < secs; s += 300) {
            vm.warp(vm.getBlockTimestamp() + 300);
            vm.roll(vm.getBlockNumber() + 25);
            _poke(who);
        }
    }

    /// @dev An arbitrageur: trade the curve's price to `tick` (bisection on the lens quote, within a tick or two).
    function _moveTo(address who, int24 tick) internal {
        (uint160 spNow,,,,) = hook.pendingState();
        int24 nowT = TickMath.getTickAtSqrtPrice(spNow);
        if (nowT == tick) return;
        bool z = tick < nowT;
        (uint256 h0, uint256 h1) = hook.totals();
        uint256 lo;
        uint256 hi = (z ? h0 : h1) * 4;
        for (uint256 n; n < 96 && hi - lo > 1; ++n) {
            uint256 mid = (lo + hi) / 2;
            try lens.quote(hook, z, -int256(mid)) returns (CompoundCurve.Step memory q) {
                int24 t = TickMath.getTickAtSqrtPrice(q.sp);
                if (z ? t > tick : t < tick) lo = mid;
                else hi = mid;
            } catch {
                hi = mid;
            }
        }
        if (lo == 0) return;
        _fundRaw(who, z ? 0 : 1, lo);
        _approveAll(who);
        _swapPM(who, z, -int256(lo), "");
    }

    /// @dev Hold the market at `tick` for `secs`: every OBS_GAP the arbitrageur trades the pool back to it.
    function _holdAt(address who, int24 tick, uint256 secs) internal {
        for (uint256 s; s < secs; s += 300) {
            vm.warp(vm.getBlockTimestamp() + 300);
            vm.roll(vm.getBlockNumber() + 25);
            _moveTo(who, tick);
            _poke(who);
        }
    }

    function _poke(address who) internal {
        _fundRaw(who, 0, 1e15);
        _fundRaw(who, 1, 1e15);
        _approveAll(who);
        _swapPM(who, true, -1e12, "");
        _swapPM(who, false, -1e12, "");
    }

    /// @dev Side-wise value of an address (underlying units): raw + staked at the vault rate + LP shares' slice.
    function _worth(address who) internal view returns (uint256 v0, uint256 v1) {
        (uint256 l0, uint256 l1) = lens.previewWithdraw(hook, hook.balanceOf(who));
        v0 = _tok(0).balanceOf(who) + _vlt(0).convertToAssets(_vlt(0).balanceOf(who)) + l0;
        v1 = _tok(1).balanceOf(who) + _vlt(1).convertToAssets(_vlt(1).balanceOf(who)) + l1;
    }

    /// @dev Vault shares held by the hook and all its pockets.
    function _pocketShares(IERC4626 v) internal view returns (uint256 n) {
        n = v.balanceOf(address(hook));
        for (uint256 k; k < hook.POCKETS(); ++k) {
            n += v.balanceOf(hook.pockets(k));
        }
    }

    /// @dev The curve may never claim more than the hook holds.
    function _assertCovered() internal view {
        (uint256 x, uint256 y) = lens.curveBalances(hook);
        (uint256 h0, uint256 h1) = hook.totals();
        assertLe(x, h0, "curve x <= held0");
        assertLe(y, h1, "curve y <= held1");
    }
}
