// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CompoundCurve} from "./CompoundCurve.sol";
import {CompoundHook} from "./CompoundHook.sol";

/// @title CompoundLens
/// @notice Read-only previews for a CompoundHook (kept out of the hook for its size limit): swap quotes including
/// the re-centring the next action applies, LP previews, and the curve's own balances. Stateless; holds nothing.
contract CompoundLens {
    /// @notice A swap's result now. For an IMD output, route with hookData = abi.encode(true, recipient):
    /// a quote is a price, not a promise that the raw buffer can pay it in a block where a stranger stamped the holds.
    /// `amountSpecified` < 0 is exact input (v4 sign), underlying units; `amountIn`
    /// excludes `fee`. Reverts as the swap would (PriceLimit at a bound, NoLiquidity before the first deposit).
    function quote(CompoundHook hook, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (CompoundCurve.Step memory)
    {
        (uint160 sp, uint128 l,, int24 ct,) = hook.pendingState();
        return CompoundCurve.swapAt(
            sp,
            ct,
            hook.CORE_TICKS(),
            l,
            hook.tauQ96(),
            zeroForOne,
            amountSpecified,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            hook.FEE_PIPS()
        );
    }

    /// @notice The curve's tick (spot).
    function spotTick(CompoundHook hook) external view returns (int24) {
        return TickMath.getTickAtSqrtPrice(hook.sqrtPriceX96());
    }

    /// @notice What the curve itself holds now (the rest of `totals()` is excess: fees and yield not yet compounded).
    function curveBalances(CompoundHook hook) external view returns (uint256 x, uint256 y) {
        return CompoundCurve.required(
            hook.sqrtPriceX96(), hook.centreTick(), hook.CORE_TICKS(), hook.liquidity(), hook.tauQ96()
        );
    }

    /// @notice Amounts (underlying) a deposit of `shares` takes now, rounded up; (0, 0) before the first deposit.
    function previewDeposit(CompoundHook hook, uint256 shares)
        external
        view
        returns (uint256 assets0, uint256 assets1)
    {
        uint256 s = hook.totalSupply();
        if (s == 0) return (0, 0);
        (uint256 h0, uint256 h1) = hook.totals();
        assets0 = Math.mulDiv(h0, shares, s, Math.Rounding.Ceil);
        assets1 = Math.mulDiv(h1, shares, s, Math.Rounding.Ceil);
    }

    /// @notice Underlying value `shares` withdraw for now, rounded down per component (before any yield fee the
    /// next action takes).
    function previewWithdraw(CompoundHook hook, uint256 shares)
        external
        view
        returns (uint256 assets0, uint256 assets1)
    {
        uint256 s = hook.totalSupply();
        if (s == 0) return (0, 0);
        assets0 = _slice(hook, hook.token0(), hook.vault0(), shares, s);
        assets1 = _slice(hook, hook.token1(), hook.vault1(), shares, s);
    }

    function _slice(CompoundHook hook, IERC20 t, IERC4626 v, uint256 shares, uint256 s) private view returns (uint256) {
        uint256 raw =
            t.balanceOf(address(hook)) + hook.poolManager().balanceOf(address(hook), uint256(uint160(address(t))));
        uint256 staked = v.balanceOf(address(hook));
        for (uint256 k; k < hook.POCKETS(); ++k) {
            staked += v.balanceOf(hook.pockets(k));
        }
        return Math.mulDiv(raw, shares, s) + v.convertToAssets(Math.mulDiv(staked, shares, s));
    }
}
