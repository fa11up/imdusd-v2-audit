// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

interface IPegHookView {
    function poolKey() external view returns (PoolKey memory);
    function pegTick() external view returns (int24);
    function initialized() external view returns (bool);
    function twapTicks() external view returns (int24);
    function spotTicks() external view returns (int24);
    function stable() external view returns (address);
}

/// @title PegLPVault (imdUSD v2)
/// @notice One shared liquidity position in the imdUSD/USDC peg pool, in the peg band (±BAND ticks around $1, ≈ $0.99-
/// $1.01 at 100). Depositors own it pro rata through this ERC-20 share. Fees (and v4 donations to in-range liquidity)
/// are collected on every action, 10% to the Treasury, the rest compounded into the position.
///
/// NOT ERC-4626: the vault holds two assets, and pricing one in the other at a moment's
/// pool price is what manipulation attacks on LP vaults feed on. Deposits and withdrawals are PROPORTIONAL to what the
/// vault holds (position at the current price + idle balances), so no price is ever used to value a share. A single-
/// asset 4626 wrapper (with a zap) can sit on top later for integrations.
///
/// MANIPULATION. Valued at $1 a token, a band position is worth least at $1 and more either side of it (at the beta's
/// ±100-tick band: about +0.06% at 50 ticks, +0.25% at the edge): a push sells the position tokens at off-$1 prices, and
/// the pusher pays for that. So a proportional deposit at a pushed price pays a small premium, and a withdrawal at a
/// pushed price receives a little more, out of the pusher's loss. Deposits (and `compound`) still require the spot to be
/// within MAX_SPOT_TWAP_TICKS of the peg hook's 30-minute TWAP, which keeps entries at a price near the market's; a push
/// large enough to matter also pays the hook's surcharge beyond ±0.25%. Withdrawals are never gated: an exit must always
/// be open. Callers bound both with min/max amounts.
///
/// THE BAND IS FIXED. A peg LP's job is to be at $1. If imdUSD leaves the band the position is all one asset by design:
/// below $0.99 it has bought imdUSD all the way down (the peg's buyer), above $1.01 it has sold it. It is not moved to
/// follow the price, so it is never used to cement a depeg. Fees therefore stop out of band, as for any peg-band LP.
///
/// ONE-SIDED INCOME. Fees and donations can arrive mostly in one token (a donor may pay only imdUSD), which the band cannot
/// absorb alone. `compound` swaps half of the idle excess (valued at $1 a token) into the other token in the peg pool,
/// only while the spot is within ±SWAP_TICKS of the peg and within ±MAX_SPOT_TWAP_TICKS of the TWAP, with the nearer
/// bound as the price limit, so the swap never pays the hook's surcharge (±0.25%), never trips the vault's own deposit
/// gate, and a pushed pool fills it only partly or not at all. Anything left stays idle and counted.
///
/// NO OWNER, NO PARAMETERS. Treasury, band and pool are fixed at construction.
contract PegLPVault is ERC20, IUnlockCallback, TransientReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 public constant PERFORMANCE_FEE_BPS = 1000; // 10% of collected fees to the Treasury
    int24 public constant MAX_SPOT_TWAP_TICKS = 10; // ≈ 0.1%
    int24 public constant SWAP_TICKS = 20; // balancing swaps only inside ±0.2% (surcharge starts at ±0.25%)
    uint256 public constant MIN_SWAP_USD = 10e18; // ignore idle excess under $10
    uint256 public constant DEAD_SHARES = 1000; // minted to 0xdead on the first deposit (inflation attack)
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    IPegHookView public immutable hook;
    address public immutable treasury;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint160 private immutable sqrtLower;
    uint160 private immutable sqrtUpper;
    int24 private immutable pegTick;
    bool private immutable stableIs0;
    uint256 private immutable quoteScale; // 1e12 for imdUSD 18 / USDC 6

    error NotPoolManager();
    error PoolNotInitialized();
    error BadBand();
    error ZeroAddress();
    error OffTwap(int24 spot, int24 twap);
    error ZeroShares();
    error Slippage();

    event Deposited(address indexed caller, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed owner, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Collected(uint256 fees0, uint256 fees1, uint256 toTreasury0, uint256 toTreasury1);
    event Compounded(uint128 liquidity);

    uint8 private constant ACT_SYNC = 0; // collect fees, then deploy idle balances
    uint8 private constant ACT_EXIT = 1; // collect fees, then remove liquidity

    constructor(IPoolManager poolManager_, IPegHookView hook_, address treasury_, int24 band)
        ERC20("imdUSD Peg LP", "pegLP")
    {
        if (address(poolManager_) == address(0) || address(hook_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (!hook_.initialized()) revert PoolNotInitialized();
        if (band <= 0 || band > 2000) revert BadBand();
        poolManager = poolManager_;
        hook = hook_;
        treasury = treasury_;
        PoolKey memory k = hook_.poolKey();
        token0 = IERC20(Currency.unwrap(k.currency0));
        token1 = IERC20(Currency.unwrap(k.currency1));
        int24 t = hook_.pegTick(); // tick spacing 1: any tick is usable
        pegTick = t;
        stableIs0 = hook_.stable() == address(token0);
        (IERC20 st, IERC20 qt) = stableIs0 ? (token0, token1) : (token1, token0);
        quoteScale = 10 ** (IDecimals(address(st)).decimals() - IDecimals(address(qt)).decimals());
        (tickLower, tickUpper) = (t - band, t + band);
        sqrtLower = TickMath.getSqrtPriceAtTick(t - band);
        sqrtUpper = TickMath.getSqrtPriceAtTick(t + band);
    }

    // ================================================================ views

    function poolKey() public view returns (PoolKey memory) {
        return hook.poolKey();
    }

    /// @notice Liquidity of the vault's position.
    function liquidity() public view returns (uint128) {
        return poolManager.getPositionLiquidity(poolKey().toId(), _positionId());
    }

    /// @notice What the vault holds at the current pool price: the position's amounts plus idle balances. Uncollected
    /// fees are not included (every action collects them first).
    function totals() public view returns (uint256 amount0, uint256 amount1) {
        (uint160 sp,,,) = poolManager.getSlot0(poolKey().toId());
        (amount0, amount1) = _amountsFor(sp, liquidity());
        amount0 += token0.balanceOf(address(this));
        amount1 += token1.balanceOf(address(this));
    }

    /// @notice The position alone at the current pool price, without idle balances (a donation sits idle: PEG's mix read).
    function positionAmounts() external view returns (uint256 amount0, uint256 amount1) {
        (uint160 sp,,,) = poolManager.getSlot0(poolKey().toId());
        return _amountsFor(sp, liquidity());
    }

    /// @notice Amounts a deposit of `shares` would take (rounded up), at the current price, before fees are collected.
    function previewDeposit(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        if (supply == 0 || supply == DEAD_SHARES) return (0, 0); // a first deposit: max0/max1 decide
        (uint256 t0, uint256 t1) = totals();
        amount0 = Math.mulDiv(t0, shares, supply, Math.Rounding.Ceil);
        amount1 = Math.mulDiv(t1, shares, supply, Math.Rounding.Ceil);
    }

    // ================================================================ actions

    /// @notice Buy `shares` with both tokens in the vault's current proportion (at most max0/max1). The first deposit
    /// instead takes the liquidity max0/max1 buy at the current price, pulls exactly what that liquidity needs (the
    /// band's proportion, never the depositor's: a lopsided first deposit cannot set the proportion every later deposit
    /// must match) and mints it as shares (less DEAD_SHARES, burned to 0xdead).
    ///
    /// A vault whose real holders have all left (supply back to DEAD_SHARES: a dust deposit withdrawn, the sole LP's exit)
    /// takes the first-deposit path AGAIN, as LoopVault does. Without this every later
    /// deposit was priced to whatever dust the dead shares happened to own: a $0.002 front-run before the seed, or the
    /// seeder's own exit, left a vault that refused any sane two-sided deposit. The dust the dead shares own then accrues
    /// to the new first depositor (worth well under a cent).
    function deposit(uint256 shares, uint256 max0, uint256 max1, address to)
        external
        nonReentrant
        returns (uint256 minted, uint256 amount0, uint256 amount1)
    {
        _checkTwap();
        _unlock(ACT_SYNC, 0); // collect fees (they belong to existing holders) and deploy anything idle
        uint256 supply = totalSupply();
        if (supply == 0 || supply == DEAD_SHARES) {
            (uint160 sp,,,) = poolManager.getSlot0(poolKey().toId());
            uint256 l = _liquidityFor(sp, max0, max1);
            if (l <= DEAD_SHARES) revert ZeroShares();
            // Round up: the PoolManager rounds the amounts owed for `l` up too, and the idle wei stay counted.
            (amount0, amount1) = _amountsForUp(sp, uint128(l));
            if (amount0 > max0 || amount1 > max1) revert Slippage();
            if (supply == 0) {
                minted = l - DEAD_SHARES;
                _mint(DEAD, DEAD_SHARES);
            } else {
                minted = l; // the dead shares already exist; whatever dust they own is the new depositor's
            }
        } else {
            if (shares == 0) revert ZeroShares();
            (uint256 t0, uint256 t1) = totals();
            amount0 = Math.mulDiv(t0, shares, supply, Math.Rounding.Ceil);
            amount1 = Math.mulDiv(t1, shares, supply, Math.Rounding.Ceil);
            if (amount0 > max0 || amount1 > max1) revert Slippage();
            minted = shares;
        }
        if (amount0 != 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
        _mint(to, minted);
        _unlock(ACT_SYNC, 0);
        emit Deposited(msg.sender, to, minted, amount0, amount1);
    }

    /// @notice Burn `shares` from msg.sender for its share of the position and of idle balances. Never price-gated.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        // Fees first, so the leaver takes its share of them; then the leaver's slice of the idle balances, measured
        // before the liquidity it removes lands here too.
        _unlock(ACT_SYNC_COLLECT_ONLY, 0);
        amount0 = Math.mulDiv(token0.balanceOf(address(this)), shares, supply);
        amount1 = Math.mulDiv(token1.balanceOf(address(this)), shares, supply);
        uint128 l = uint128(Math.mulDiv(liquidity(), shares, supply));
        _burn(msg.sender, shares);
        if (l != 0) {
            (uint256 r0, uint256 r1) = abi.decode(_unlock(ACT_EXIT, l), (uint256, uint256));
            amount0 += r0;
            amount1 += r1;
        }
        if (amount0 < min0 || amount1 < min1) revert Slippage();
        if (amount0 != 0) token0.safeTransfer(to, amount0);
        if (amount1 != 0) token1.safeTransfer(to, amount1);
        emit Withdrawn(msg.sender, to, shares, amount0, amount1);
    }

    /// @notice Collect fees and put idle balances to work. Anyone may call (bots, the keeper, a depositor).
    function compound() external nonReentrant {
        _checkTwap();
        _unlock(ACT_SYNC, 0);
    }

    // ================================================================ PoolManager

    uint8 private constant ACT_SYNC_COLLECT_ONLY = 2;

    function _unlock(uint8 action, uint128 removeLiquidity) private returns (bytes memory) {
        return poolManager.unlock(abi.encode(action, removeLiquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, uint128 removeL) = abi.decode(data, (uint8, uint128));
        PoolKey memory key = poolKey();
        uint128 l = poolManager.getPositionLiquidity(key.toId(), _positionId());

        // 1. Fees (incl. donations): a zero-liquidity modify credits exactly the fees accrued.
        if (l != 0) {
            (BalanceDelta fees,) = poolManager.modifyLiquidity(key, _params(0), "");
            _collectFees(key, uint128(fees.amount0()), uint128(fees.amount1()));
        }

        if (action == ACT_EXIT) {
            (BalanceDelta d,) = poolManager.modifyLiquidity(key, _params(-int256(uint256(removeL))), "");
            uint256 r0 = uint128(d.amount0());
            uint256 r1 = uint128(d.amount1());
            if (r0 != 0) poolManager.take(key.currency0, address(this), r0);
            if (r1 != 0) poolManager.take(key.currency1, address(this), r1);
            return abi.encode(r0, r1);
        }
        if (action == ACT_SYNC) {
            _balance(key);
            (uint160 sp,,,) = poolManager.getSlot0(key.toId());
            uint256 b0 = token0.balanceOf(address(this));
            uint256 b1 = token1.balanceOf(address(this));
            // One wei below each balance: the PoolManager rounds the amounts owed up.
            uint256 add = _liquidityFor(sp, b0 == 0 ? 0 : b0 - 1, b1 == 0 ? 0 : b1 - 1);
            if (add != 0) {
                (BalanceDelta d,) = poolManager.modifyLiquidity(key, _params(int256(add)), "");
                _pay(key.currency0, d.amount0());
                _pay(key.currency1, d.amount1());
                emit Compounded(uint128(add));
            }
        }
        return "";
    }

    /// @dev Swap half the idle excess of one token for the other, inside ±SWAP_TICKS of the peg AND inside
    /// ±MAX_SPOT_TWAP_TICKS of the hook's TWAP (the nearer bound is the price limit). The second bound:
    /// limited by the peg alone, a refill could run the pool from +19 to -20 ticks and leave the
    /// spot further from the TWAP than `_checkTwap` allows, so the vault's own compound locked its deposits and compounds
    /// for the next ~30 minutes. Now a balancing swap can never take the spot out of the deposit gate.
    function _balance(PoolKey memory key) private {
        (uint160 sp, int24 tick,,) = poolManager.getSlot0(key.toId());
        (int24 lowTick, int24 highTick) = _swapBounds();
        if (tick <= lowTick || tick >= highTick) return;
        uint256 b0 = token0.balanceOf(address(this));
        uint256 b1 = token1.balanceOf(address(this));
        (uint256 u0, uint256 u1) = _amountsFor(sp, uint128(_liquidityFor(sp, b0, b1)));
        uint256 e0 = b0 > u0 ? b0 - u0 : 0;
        uint256 e1 = b1 > u1 ? b1 - u1 : 0;
        uint256 v0 = stableIs0 ? e0 : e0 * quoteScale;
        uint256 v1 = stableIs0 ? e1 * quoteScale : e1;
        bool zeroForOne = v0 > v1; // sell the token in excess
        uint256 excessUsd = zeroForOne ? v0 - v1 : v1 - v0;
        if (excessUsd < MIN_SWAP_USD) return;
        uint256 amountIn = (zeroForOne ? e0 : e1) / 2;
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? lowTick : highTick);
        BalanceDelta d = poolManager.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        _pay(key.currency0, d.amount0());
        _pay(key.currency1, d.amount1());
        if (d.amount0() > 0) poolManager.take(key.currency0, address(this), uint128(d.amount0()));
        if (d.amount1() > 0) poolManager.take(key.currency1, address(this), uint128(d.amount1()));
    }

    /// @dev The raw ticks a balancing swap may move the pool between: the nearer of peg ± SWAP_TICKS and TWAP ±
    /// MAX_SPOT_TWAP_TICKS on each side. Without a TWAP yet (the hook's first 30 minutes) the peg bounds alone apply;
    /// `deposit` and `compound` have already required one by then, so only a direct sync could reach this.
    function _swapBounds() private view returns (int24 lowTick, int24 highTick) {
        (lowTick, highTick) = (pegTick - SWAP_TICKS, pegTick + SWAP_TICKS);
        try hook.twapTicks() returns (int24 twap) {
            // The hook reports the STABLE's ticks from the peg; raw ticks run the other way when the stable is token1.
            int24 twapRaw = stableIs0 ? pegTick + twap : pegTick - twap;
            if (twapRaw - MAX_SPOT_TWAP_TICKS > lowTick) lowTick = twapRaw - MAX_SPOT_TWAP_TICKS;
            if (twapRaw + MAX_SPOT_TWAP_TICKS < highTick) highTick = twapRaw + MAX_SPOT_TWAP_TICKS;
        } catch {}
    }

    function _collectFees(PoolKey memory key, uint256 f0, uint256 f1) private {
        uint256 t0 = f0 * PERFORMANCE_FEE_BPS / 10_000;
        uint256 t1 = f1 * PERFORMANCE_FEE_BPS / 10_000;
        if (t0 != 0) poolManager.take(key.currency0, treasury, t0);
        if (t1 != 0) poolManager.take(key.currency1, treasury, t1);
        if (f0 - t0 != 0) poolManager.take(key.currency0, address(this), f0 - t0);
        if (f1 - t1 != 0) poolManager.take(key.currency1, address(this), f1 - t1);
        if (f0 != 0 || f1 != 0) emit Collected(f0, f1, t0, t1);
    }

    function _pay(Currency c, int128 delta) private {
        if (delta >= 0) return; // adding liquidity never credits (fees were collected just before)
        poolManager.sync(c);
        IERC20(Currency.unwrap(c)).safeTransfer(address(poolManager), uint128(-delta));
        poolManager.settle();
    }

    function _params(int256 delta) private view returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(tickLower, tickUpper, delta, bytes32(0));
    }

    function _positionId() private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), tickLower, tickUpper, bytes32(0)));
    }

    function _checkTwap() private view {
        int24 spot = hook.spotTicks();
        int24 twap = hook.twapTicks(); // reverts NoTwap until the pool has 30 minutes of history
        int24 gap = spot > twap ? spot - twap : twap - spot;
        if (gap > MAX_SPOT_TWAP_TICKS) revert OffTwap(spot, twap);
    }

    // ================================================================ liquidity maths

    function _amountsFor(uint160 sp, uint128 l) private view returns (uint256 a0, uint256 a1) {
        if (l == 0) return (0, 0);
        if (sp <= sqrtLower) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, l, false);
        } else if (sp < sqrtUpper) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sqrtUpper, l, false);
            a1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sp, l, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, l, false);
        }
    }

    /// @dev `_amountsFor` rounded up: what a depositor pays for `l` (the PoolManager rounds what it is owed up too).
    function _amountsForUp(uint160 sp, uint128 l) private view returns (uint256 a0, uint256 a1) {
        if (l == 0) return (0, 0);
        if (sp <= sqrtLower) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, l, true);
        } else if (sp < sqrtUpper) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sqrtUpper, l, true);
            a1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sp, l, true);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, l, true);
        }
    }

    function _liquidityFor(uint160 sp, uint256 a0, uint256 a1) private view returns (uint256 l) {
        if (sp <= sqrtLower) {
            l = _l0(sqrtLower, sqrtUpper, a0);
        } else if (sp < sqrtUpper) {
            l = Math.min(_l0(sp, sqrtUpper, a0), _l1(sqrtLower, sp, a1));
        } else {
            l = _l1(sqrtLower, sqrtUpper, a1);
        }
        if (l > type(uint128).max) l = type(uint128).max;
    }

    function _l0(uint160 a, uint160 b, uint256 amount) private pure returns (uint256) {
        return FullMath.mulDiv(amount, FullMath.mulDiv(a, b, FixedPoint96.Q96), b - a);
    }

    function _l1(uint160 a, uint160 b, uint256 amount) private pure returns (uint256) {
        return FullMath.mulDiv(amount, FixedPoint96.Q96, b - a);
    }
}
