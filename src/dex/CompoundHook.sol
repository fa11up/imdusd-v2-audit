// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {CompoundCurve} from "./CompoundCurve.sol";
import {CompoundOracle} from "./CompoundOracle.sol";
import {CompoundPocket} from "./CompoundPocket.sol";

/// @title CompoundHook (Compound DEX phase 1)
/// @notice An AMM of two yield-bearing ERC-4626 tokens (first pool: sIMD and a second staked token) that trades their UNDERLYINGS.
/// One instance per pool. The hook custodies every reserve itself, mostly STAKED, and prices with its own curve
/// through v4 custom accounting: `beforeSwap` returns the whole delta, so the PoolManager's own pool never holds
/// liquidity or moves (its slot0 stays at the opening price; read this contract's `sqrtPriceX96`). This contract
/// is also the LP share (ERC-20, proportional).
///
/// RESERVES. Side i (token0 = the lower underlying address) holds raw underlying (an unstaked buffer), ERC-6909
/// claims on the PoolManager for raw underlying (a v4 swap's input, turned into tokens at the next action), and
/// vault shares. `held(i)` = raw + claims + convertToAssets(shares), rounded down. Everything is priced in
/// UNDERLYING units, so a share-rate rise (a drip) adds value without moving the price or the depth: the quote is
/// a function of (sqrtPriceX96, liquidity, centre) only, and a drip touches none of them.
///
/// CURVE (CompoundCurve). Core liquidity L on [centre / 1.0001^2000, centre * 1.0001^2000] (price ×/÷ 1.2214)
/// plus a full-range tail of L*tau, tau = (1 - 1.0001^-1000)/9, i.e. 10% of the book at the centre. The curve's
/// balances (what the shape holds at the price) never exceed `held`; the rest (fees, yield) is EXCESS, owned by
/// the LPs and folded into L by `compound()` or a deposit, both only while the spot is near the TWAP.
///
/// CENTRE. Follows the in-hook TWAP (30-minute mean of the curve's own tick) at most 55 milli-ticks per second
/// (198 ticks = 1.98% per hour), applied lazily at the first action of each block from the elapsed time, at most MAX_STEP_SECONDS' worth per
/// action (the rest is forfeited: D1). When the
/// centre's whole tick changes, the curve keeps its balances and re-solves the price and liquidity for the new
/// range (CompoundCurve.solve): no liquidity is withdrawn or re-added, there is nothing to sandwich, and in a
/// trending market the small price steps this makes are what arbitrage rebalances the book through.
///
/// BUFFER. Raw underlying (tokens + pending claims) pays unstaked outputs: target BUFFER_BPS of each side, kept
/// between half and three times the target. Low: it unstakes back to the target whenever it may redeem
/// (`maxWithdraw`: sIMD reports 0 for the whole block once an address is stamped; the second token's vault (per-lot hold) excludes
/// only newly received lots). High: it stakes down to twice the target. New stakes are minted to the POCKET (CompoundPocket), so the
/// hook never stamps its own address: two opposite swaps in one block never collide on its hold. There are POCKETS
/// pockets, rotating per block; at a block's first action the current pocket's redeemable shares and the hook's own
/// (staked deposits and inputs) are spread over the other pockets, so our own stakes never stamp the reserve. An output the buffer cannot pay is paid in the staked token if the swapper allowed it,
/// else the swap reverts (BufferShort). A stranger stamping every pocket each block (sIMD `deposit(1 wei, x)`, one per
/// pocket) only blocks the refill: allowed swaps still complete in shares, and the stamp's dust is a gift to the LPs.
///
/// FEES. FEE_PIPS on the input, rounded up, stays in the reserves (excess). 10% of every fee and 10% of the staking
/// yield go to the Treasury as newly minted LP shares, valued at the curve's price after the action:
/// m = supply * v / (V - v), V = the book's value, v = the Treasury's take. Yield = shares held × the rise of
/// `convertToAssets(1e36)` since the last action (a per-reserve rate checkpoint), so swaps, deposits, donations
/// of shares and price moves never count as yield.
///
/// LP. Deposits are proportional to `held` (rounded up), in raw or staked form per side, only while the spot is
/// within GATE_TICKS of the TWAP; withdrawals are proportional per component (raw slice raw, staked slice staked,
/// or unstaked for the LP when the hook may redeem), rounded down, never gated. 1,000 dead shares on the first
/// deposit. Every conversion rounds against the caller.
///
/// TRADING. Through the PoolManager (any v4 router), currencies = the two underlyings, exact input or output;
/// hookData = abi.encode(bool sharesIfShort, address shareRecipient) opts an exact-input swap into share payment
/// when the buffer is short. INTEGRATORS: a swap whose OUTPUT is a whole-address-hold underlying (IMD) MUST pass
/// hookData = abi.encode(true, recipient): without it, a stranger stamping every pocket each block for gas can make
/// any IMD output above the raw buffer revert BufferShort; exact-output swaps cannot opt in. Or directly with `swap`, which also takes and pays the staked tokens (any mix).
///
/// NO OWNER, NO PARAMETERS. Treasury, vaults and opening price are fixed at construction; everything else is a
/// constant. Not audited.
///
/// Implements only the four hook callbacks its address flags enable (the PoolManager calls no others), so it does
/// not inherit IHooks.
interface ITreasuryToken {
    function token() external view returns (address);
}

contract CompoundHook is ERC20, IUnlockCallback, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    uint24 public constant FEE_PIPS = 3000; // 0.30% of the input
    uint256 public constant TREASURY_BPS = 1000; // 10% of fees and of yield
    int24 public constant CORE_TICKS = 2000; // core half-width
    int24 public constant TICK_SPACING = 60; // the PoolKey's; unused by the curve
    /// @notice The centre's speed limit, in thousandths of a tick per second: 55 * 3600 / 1000 = 198 ticks per hour,
    /// and 1.0001^198 = 1.0200 (below 2%).
    int256 public constant CENTRE_MILLITICKS_PER_SECOND = 55;
    /// @notice D1: one action moves the centre by at most this much elapsed time's allowance
    /// (600 s x 55 = 33 ticks, about the fee); the rest of an idle period's allowance is forfeited, so the first
    /// action after a long idle cannot re-price the book by the whole accumulated step and capture it.
    uint256 public constant MAX_STEP_SECONDS = 10 minutes;
    uint32 public constant TWAP_WINDOW = 30 minutes; // CompoundOracle.WINDOW
    uint32 public constant OBS_GAP = 5 minutes; // CompoundOracle.GAP
    int24 public constant GATE_TICKS = 50; // deposits and compound need |spot - TWAP| <= 0.5%
    uint256 public constant BUFFER_BPS = 250; // raw buffer target: 2.5% of each side (kept within 1.25%-7.5%)
    uint256 public constant MIN_STAKE = 1e9; // never re-stake dust
    uint256 public constant DEAD_SHARES = 1000;
    uint256 public constant RATE_UNIT = 1e36;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant Q96 = 1 << 96;

    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager public immutable poolManager;
    address public immutable treasury;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    IERC4626 public immutable vault0;
    IERC4626 public immutable vault1;
    uint160 public immutable initialSqrtPriceX96;
    /// @notice Tail liquidity per unit of core liquidity, Q96.
    uint256 public immutable tauQ96;
    /// @notice D2: POCKETS pockets (see CompoundPocket). A block's new stakes are minted to
    /// `pockets[block.number % POCKETS]`; unstakes draw on the hook, then any pocket that may redeem; each pocket is
    /// swept into the hook in a later block. A stranger must stamp every pocket each block to deny the refill.
    uint256 public constant POCKETS = 4;
    address[4] public pockets;

    // ---- curve ----
    bytes32 public poolId;
    bool public initialized;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    int256 public centreMilli; // centre tick × 1000
    int24 public centreTick; // floor(centreMilli / 1000), clamped so the core's bounds are valid ticks
    uint32 public centreAt;

    // ---- oracle (the curve's own tick) ----
    CompoundOracle.State internal oracle;

    // ---- yield checkpoint + cumulative stats (underlying units) ----
    uint256[2] public rateMark;
    uint256[2] public feesCollected;
    uint256[2] public yieldCollected;

    error NotPoolManager();
    error WrongPool();
    error WrongPrice();
    error HookAddressMismatch();
    error ZeroAddress();
    error SameAsset();
    error ImdUsdSide();
    error NoPoolLiquidity();
    error NoTwap();
    error OffTwap(int24 spot, int24 twap);
    error BufferShort();
    error SameSide();
    error UnknownToken();
    error Slippage();
    error ZeroShares();
    error SharesShort();

    event Swapped(
        address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 fee, bool paidInShares
    );
    event Deposited(address indexed caller, address indexed to, uint256 shares, uint256 assets0, uint256 assets1);
    event Withdrawn(address indexed owner, address indexed to, uint256 shares, uint256 assets0, uint256 assets1);
    event Recentred(int24 centreTick, uint160 sqrtPriceX96, uint128 liquidity);
    event Compounded(uint128 added);
    event TreasuryMinted(uint256 shares, uint256 value1, bool yield);

    constructor(
        IPoolManager poolManager_,
        IERC4626 vaultA,
        IERC4626 vaultB,
        address treasury_,
        uint160 initialSqrtPriceX96_
    ) ERC20("Compound DEX LP", "cdxLP") {
        if (
            address(poolManager_) == address(0) || address(vaultA) == address(0) || address(vaultB) == address(0)
                || treasury_ == address(0)
        ) revert ZeroAddress();
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS) revert HookAddressMismatch();
        if (initialSqrtPriceX96_ <= TickMath.MIN_SQRT_PRICE || initialSqrtPriceX96_ >= TickMath.MAX_SQRT_PRICE) {
            revert WrongPrice();
        }
        address ua = vaultA.asset();
        address ub = vaultB.asset();
        if (ua == address(0) || ub == address(0)) revert ZeroAddress();
        if (ua == ub) revert SameAsset();
        // D3: no imdUSD side, nor a side whose underlying is a vault of imdUSD (the
        // SavingsVault): such a pool would be a toll-free imdUSD venue around the PegHook and would skim the savings
        // rate a second time. imdUSD is the Treasury's own token.
        address usd = ITreasuryToken(treasury_).token();
        if (_isUsd(ua, usd) || _isUsd(ub, usd)) revert ImdUsdSide();
        (IERC4626 v0, IERC4626 v1) = ua < ub ? (vaultA, vaultB) : (vaultB, vaultA);
        poolManager = poolManager_;
        treasury = treasury_;
        (vault0, vault1) = (v0, v1);
        (token0, token1) = (IERC20(v0.asset()), IERC20(v1.asset()));
        initialSqrtPriceX96 = initialSqrtPriceX96_;
        tauQ96 = CompoundCurve.tauFor(CORE_TICKS);
        rateMark[0] = v0.convertToAssets(RATE_UNIT);
        rateMark[1] = v1.convertToAssets(RATE_UNIT);
        for (uint256 k; k < POCKETS; ++k) {
            pockets[k] = address(new CompoundPocket(address(v0), address(v1)));
        }
        IERC20(v0.asset()).forceApprove(address(v0), type(uint256).max);
        IERC20(v1.asset()).forceApprove(address(v1), type(uint256).max);
    }

    /// @dev True if `a` is imdUSD or an ERC-4626 whose asset is imdUSD (constructor only).
    function _isUsd(address a, address usd) private view returns (bool) {
        if (a == usd) return true;
        (bool ok, bytes memory r) = a.staticcall(abi.encodeWithSelector(IERC4626.asset.selector));
        return ok && r.length >= 32 && abi.decode(r, (address)) == usd;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ================================================================ views

    /// @notice The pocket this block's new stakes are minted to.
    function pocket() public view returns (address) {
        return pockets[block.number % POCKETS];
    }

    /// @notice What the pool holds per side, in underlying units (raw + claims + staked at the vault's rate).
    function totals() public view returns (uint256 held0, uint256 held1) {
        return (_held(0), _held(1));
    }

    /// @notice The mean tick since the newest checkpoint at least TWAP_WINDOW old; reverts NoTwap before one exists.
    function twapTick() public view returns (int24) {
        (bool ok, int24 t) = _twap();
        if (!ok) revert NoTwap();
        return t;
    }

    /// @notice The state the next action will start from: (price, liquidity, centre × 1000, centre tick, whether
    /// the curve re-solves) after the centre's pending move. Read by CompoundLens for quotes.
    function pendingState() external view returns (uint160, uint128, int256, int24, bool) {
        return _pending();
    }

    // ================================================================ hooks

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96_)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (
            Currency.unwrap(key.currency0) != address(token0) || Currency.unwrap(key.currency1) != address(token1)
                || key.fee != FEE_PIPS || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert WrongPool();
        if (sqrtPriceX96_ != initialSqrtPriceX96) revert WrongPrice();
        poolId = PoolId.unwrap(key.toId());
        initialized = true;
        sqrtPriceX96 = sqrtPriceX96_;
        int24 tick = CompoundCurve.tickAt(sqrtPriceX96_);
        centreMilli = int256(tick) * 1000;
        centreTick = CompoundCurve.centreTickOf(int256(tick) * 1000, CORE_TICKS);
        centreAt = uint32(block.timestamp);
        CompoundOracle.init(oracle, tick);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Nobody may add liquidity to the PoolManager's pool: the reserves live in this hook.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NoPoolLiquidity();
    }

    /// @notice A v4 swap of the underlyings, priced by this hook's curve and settled by it in full (NoOp).
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata p, bytes calldata hookData)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != poolId) revert WrongPool();
        _sync();
        bool exactIn = p.amountSpecified < 0;
        CompoundCurve.Step memory r = _trade(p.zeroForOne, p.amountSpecified, p.sqrtPriceLimitX96);
        (uint8 sIn, uint8 sOut) = p.zeroForOne ? (0, 1) : (1, 0);
        uint256 paidIn = r.amountIn + r.fee;
        // The input: the swapper settles it with the PoolManager after this returns; take it as a claim now.
        poolManager.mint(address(this), _id(sIn), paidIn);
        bool inShares;
        if (_ensureRaw(sOut, r.amountOut)) {
            Currency c = Currency.wrap(address(_token(sOut)));
            poolManager.sync(c);
            _token(sOut).safeTransfer(address(poolManager), r.amountOut);
            poolManager.settle();
        } else {
            (bool allow, address to) =
                hookData.length >= 64 ? abi.decode(hookData, (bool, address)) : (false, address(0));
            if (!allow || !exactIn || to == address(0)) revert BufferShort();
            _payShares(sOut, r.amountOut, to);
            inShares = true;
        }
        int128 inD = int128(int256(paidIn));
        int128 outD = inShares ? int128(0) : -int128(int256(r.amountOut));
        BeforeSwapDelta d = exactIn ? toBeforeSwapDelta(inD, outD) : toBeforeSwapDelta(outD, inD);
        _afterTrade(sIn, r.fee);
        emit Swapped(sender, p.zeroForOne, paidIn, r.amountOut, r.fee, inShares);
        return (IHooks.beforeSwap.selector, d, 0);
    }

    // ================================================================ direct trading

    /// @notice Exact-input swap of any form of one side (underlying or its vault's share) for either form of the
    /// other. Staked input is valued at convertToAssets (rounded down); staked output is paid at convertToShares
    /// (rounded down). A raw output the buffer cannot pay is paid in shares if `sharesIfShort`, else reverts.
    /// `minOut` is in underlying units of what is delivered (shares valued at convertToAssets).
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, address to, bool sharesIfShort)
        external
        nonReentrant
        returns (address paidToken, uint256 paid, uint256 paidValue)
    {
        (uint8 sIn, bool stIn) = _form(tokenIn);
        (uint8 sOut, bool stOut) = _form(tokenOut);
        if (sIn == sOut) revert SameSide();
        _sync();
        uint256 assetsIn;
        if (stIn) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            assetsIn = _vault(sIn).convertToAssets(amountIn);
        } else {
            uint256 b = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            assetsIn = IERC20(tokenIn).balanceOf(address(this)) - b;
        }
        if (assetsIn == 0) revert Slippage();
        bool zeroForOne = sIn == 0;
        CompoundCurve.Step memory r = _trade(
            zeroForOne, -int256(assetsIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        if (!stOut && _ensureRaw(sOut, r.amountOut)) {
            (paidToken, paid, paidValue) = (address(_token(sOut)), r.amountOut, r.amountOut);
            _token(sOut).safeTransfer(to, r.amountOut);
        } else if (stOut || sharesIfShort) {
            paid = _payShares(sOut, r.amountOut, to);
            paidToken = address(_vault(sOut));
            paidValue = _vault(sOut).convertToAssets(paid);
        } else {
            revert BufferShort();
        }
        if (paidValue < minOut) revert Slippage();
        _afterTrade(sIn, r.fee);
        emit Swapped(msg.sender, zeroForOne, assetsIn, r.amountOut, r.fee, paidToken != address(_token(sOut)));
    }

    // ================================================================ LP

    /// @notice Buy `shares` with both sides in the pool's current proportion, rounded up. Per side, `staked` pays in
    /// vault shares (previewWithdraw of the amount, rounded up) instead of the underlying; `max` caps what is pulled,
    /// in the pulled token's units. The first deposit instead takes max0/max1 as given (in the chosen forms) and
    /// mints the curve liquidity they support as shares, less DEAD_SHARES.
    function deposit(uint256 shares, uint256 max0, uint256 max1, bool staked0, bool staked1, address to)
        external
        nonReentrant
        returns (uint256 minted, uint256 assets0, uint256 assets1)
    {
        _sync();
        uint256 supply = totalSupply();
        if (supply == 0) {
            _pull(0, staked0, max0, max0, true);
            _pull(1, staked1, max1, max1, true);
            (assets0, assets1) = totals();
            uint128 l = CompoundCurve.fitAt(sqrtPriceX96, centreTick, CORE_TICKS, tauQ96, assets0, assets1);
            if (l <= DEAD_SHARES) revert ZeroShares();
            liquidity = l;
            minted = l - DEAD_SHARES;
            _mint(DEAD, DEAD_SHARES);
        } else {
            if (shares == 0) revert ZeroShares();
            _checkGate();
            _compound();
            assets0 = Math.mulDiv(_held(0), shares, supply, Math.Rounding.Ceil);
            assets1 = Math.mulDiv(_held(1), shares, supply, Math.Rounding.Ceil);
            _pull(0, staked0, assets0, max0, false);
            _pull(1, staked1, assets1, max1, false);
            liquidity += uint128(Math.mulDiv(liquidity, shares, supply));
            minted = shares;
        }
        _mint(to, minted);
        _finish();
        emit Deposited(msg.sender, to, minted, assets0, assets1);
    }

    /// @notice Burn `shares` for their slice of every component: raw slice raw, staked slice staked (or redeemed for
    /// the underlying to `to` when `raw` asks and the hook may redeem now). `min` in underlying units. Never gated.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, bool raw0, bool raw1, address to)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        if (shares == 0) revert ZeroShares();
        _sync(); // claims become raw tokens, and the yield fee is taken before the slice is measured
        uint256 supply = totalSupply();
        uint256 l = liquidity;
        uint256 cut = Math.mulDiv(l, shares, supply, Math.Rounding.Ceil);
        liquidity = uint128(cut >= l ? 0 : l - cut);
        _burn(msg.sender, shares);
        out0 = _paySlice(0, shares, supply, raw0, to);
        out1 = _paySlice(1, shares, supply, raw1, to);
        if (out0 < min0 || out1 < min1) revert Slippage();
        _finish();
        emit Withdrawn(msg.sender, to, shares, out0, out1);
    }

    /// @notice Fold the excess (fees, yield, donations) into the curve's liquidity. Anyone; only near the TWAP.
    function compound() external nonReentrant returns (uint128 added) {
        if (totalSupply() == 0) revert ZeroShares();
        _sync();
        _checkGate();
        added = _compound();
        _finish();
    }

    // ================================================================ PoolManager

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        _claimsToRaw();
        return "";
    }

    // ================================================================ internals: state

    /// @dev Start of every action: take the yield fee, turn claims into tokens, apply the centre's pending move.
    function _sync() private {
        _accrue();
        if (poolManager.balanceOf(address(this), _id(0)) != 0 || poolManager.balanceOf(address(this), _id(1)) != 0) {
            if (TransientStateLibrary.isUnlocked(poolManager)) _claimsToRaw();
            else poolManager.unlock("");
        }
        // D2: before this block's stakes land in its pocket, that pocket's redeemable shares and the hook's own are
        // spread over the other pockets (a transfer from an unheld address carries no fresh stamp). The reserve thus
        // sits in POCKETS - 1 addresses that our own stakes do not stamp this block: a stranger must stamp all of them
        // every block to deny the raw refill, and stamping the hook alone blocks nothing.
        uint256 cur = block.number % POCKETS;
        for (uint8 i; i < 2; ++i) {
            IERC4626 v = _vault(i);
            _spread(v, address(this), cur);
            _spread(v, pockets[cur], cur);
        }
        (uint160 sp, uint128 l, int256 cm, int24 ct, bool moved) = _pending();
        centreAt = uint32(block.timestamp);
        if (cm == centreMilli) return;
        centreMilli = cm;
        centreTick = ct;
        if (!moved) return;
        sqrtPriceX96 = sp;
        liquidity = l;
        _observe(CompoundCurve.tickAt(sp));
        emit Recentred(centreTick, sp, l);
    }

    /// @dev The state after the centre's pending move: (price, liquidity, centre × 1000, centre tick, whether the
    /// curve was re-solved).
    function _pending() private view returns (uint160 sp, uint128 l, int256 cm, int24 ct, bool moved) {
        (sp, l, cm, ct) = (sqrtPriceX96, liquidity, centreMilli, centreTick);
        uint256 dt = Math.min(block.timestamp - centreAt, MAX_STEP_SECONDS);
        if (dt == 0) return (sp, l, cm, ct, false);
        (bool ok, int24 tw) = _twap();
        if (!ok) return (sp, l, cm, ct, false);
        return CompoundCurve.step(sp, l, cm, ct, tw, int256(dt) * CENTRE_MILLITICKS_PER_SECOND, CORE_TICKS, tauQ96);
    }

    function _trade(bool zeroForOne, int256 amountSpecified, uint160 limit)
        private
        returns (CompoundCurve.Step memory r)
    {
        r = CompoundCurve.swapAt(
            sqrtPriceX96, centreTick, CORE_TICKS, liquidity, tauQ96, zeroForOne, amountSpecified, limit, FEE_PIPS
        );
        sqrtPriceX96 = r.sp;
        _observe(CompoundCurve.tickAt(r.sp));
    }

    function _afterTrade(uint8 sIn, uint256 fee) private {
        feesCollected[sIn] += fee;
        _mintTreasury(_value(sIn, fee) * TREASURY_BPS / 10_000, false);
        _finish();
    }

    /// @dev End of every action: both buffers back inside their band, then the curve fitted to the reserves with a
    /// few wei of slack (a stake or unstake may lose a wei or two to the vault's rounding).
    function _finish() private {
        (uint256 h0, uint256 h1) = totals();
        _rebalance(0, h0);
        _rebalance(1, h1);
        _fitLiquidity(h0 > 4 ? h0 - 4 : 0, h1 > 4 ? h1 - 4 : 0);
    }

    /// @dev The yield fee: shares held × the rise of each vault's rate since the last action.
    function _accrue() private {
        uint256 v;
        for (uint8 i; i < 2; ++i) {
            IERC4626 vault = _vault(i);
            uint256 r;
            try vault.convertToAssets(RATE_UNIT) returns (uint256 x) {
                r = x;
            } catch {
                continue; // D5: an unreadable rate is no yield this action (the mark waits)
            }
            uint256 m = rateMark[i];
            if (r == m) continue;
            if (r > m) {
                uint256 y = Math.mulDiv(_shares(i), r - m, RATE_UNIT);
                if (y != 0) {
                    yieldCollected[i] += y;
                    v += _value(i, y);
                }
            }
            rateMark[i] = r;
        }
        if (v != 0) _mintTreasury(v * TREASURY_BPS / 10_000, true);
    }

    /// @dev Mint the Treasury LP shares worth `v1` (token1 units at the curve's price): m / (S + m) = v1 / V.
    function _mintTreasury(uint256 v1, bool yield_) private {
        uint256 s = totalSupply();
        if (v1 == 0 || s == 0) return;
        uint256 book = _value(0, _held(0)) + _held(1);
        if (book <= v1) return;
        uint256 m = Math.mulDiv(s, v1, book - v1);
        if (m == 0) return;
        _mint(treasury, m);
        emit TreasuryMinted(m, v1, yield_);
    }

    function _compound() private returns (uint128 added) {
        int24 ct = centreTick;
        (uint256 rx, uint256 ry) = CompoundCurve.required(sqrtPriceX96, ct, CORE_TICKS, liquidity, tauQ96);
        (uint256 h0, uint256 h1) = totals();
        added = CompoundCurve.fitAt(sqrtPriceX96, ct, CORE_TICKS, tauQ96, h0 > rx ? h0 - rx : 0, h1 > ry ? h1 - ry : 0);
        if (added != 0) {
            liquidity += added;
            emit Compounded(added);
        }
    }

    /// @dev The curve may never claim more than the reserves hold (a safety net: swaps preserve it up to a wei of
    /// rounding, which this absorbs by shaving liquidity).
    function _fitLiquidity(uint256 h0, uint256 h1) private {
        uint128 l = liquidity;
        if (l == 0) return;
        int24 ct = centreTick;
        (uint256 rx, uint256 ry) = CompoundCurve.required(sqrtPriceX96, ct, CORE_TICKS, l, tauQ96);
        if (rx <= h0 && ry <= h1) return;
        uint128 fit = CompoundCurve.fitAt(sqrtPriceX96, ct, CORE_TICKS, tauQ96, h0, h1);
        if (fit < l) liquidity = fit;
    }

    function _checkGate() private view {
        (bool ok, int24 tw) = _twap();
        if (!ok) revert NoTwap();
        int24 spot = CompoundCurve.tickAt(sqrtPriceX96);
        int24 gap = spot > tw ? spot - tw : tw - spot;
        if (gap > GATE_TICKS) revert OffTwap(spot, tw);
    }

    // ================================================================ internals: custody

    /// @dev Move `from`'s redeemable shares of `v` in equal parts to the pockets other than `cur`.
    function _spread(IERC4626 v, address from, uint256 cur) private {
        uint256 m = v.maxRedeem(from);
        if (m == 0) return;
        uint256 part = m / (POCKETS - 1);
        for (uint256 k = 1; k < POCKETS; ++k) {
            uint256 amt = k == POCKETS - 1 ? m - part * (POCKETS - 2) : part;
            address to = pockets[(cur + k) % POCKETS];
            if (amt == 0) continue;
            if (from == address(this)) IERC20(address(v)).safeTransfer(to, amt);
            else IERC20(address(v)).safeTransferFrom(from, to, amt);
        }
    }

    function _claimsToRaw() private {
        for (uint8 i; i < 2; ++i) {
            uint256 c = poolManager.balanceOf(address(this), _id(i));
            if (c == 0) continue;
            poolManager.burn(address(this), _id(i), c);
            poolManager.take(Currency.wrap(address(_token(i))), address(this), c);
        }
    }

    /// @dev Make at least `need` raw tokens available, unstaking (need + target) if the hook may redeem now.
    function _ensureRaw(uint8 i, uint256 need) private returns (bool) {
        IERC20 t = _token(i);
        uint256 raw = t.balanceOf(address(this));
        if (raw >= need) return true;
        _unstake(i, need - raw + _held(i) * BUFFER_BPS / 10_000);
        return t.balanceOf(address(this)) >= need;
    }

    /// @dev Unstake up to `want` underlying into the hook: from its own shares, then the pocket's, as each may redeem.
    function _unstake(uint8 i, uint256 want) private {
        IERC4626 v = _vault(i);
        uint256 a = Math.min(want, _free(v, address(this)));
        if (a != 0) v.withdraw(a, address(this), address(this));
        want -= a;
        for (uint256 k; k < POCKETS && want != 0; ++k) {
            address pk = pockets[k];
            a = Math.min(want, _free(v, pk));
            if (a != 0) v.withdraw(a, address(this), pk);
            want -= a;
        }
    }

    /// @dev Underlying `owner` may withdraw now, from its redeemable shares (a per-lot hold's fresh lot excluded;
    /// rounding down keeps the withdrawal's shares within maxRedeem).
    function _free(IERC4626 v, address owner) private view returns (uint256) {
        return v.convertToAssets(v.maxRedeem(owner));
    }

    /// @dev Pay `assets` of side i in vault shares, rounded down; stakes the raw buffer first if shares are short.
    function _payShares(uint8 i, uint256 assets, address to) private returns (uint256 shares) {
        IERC4626 v = _vault(i);
        shares = v.convertToShares(assets);
        if (_shares(i) < shares) {
            uint256 raw = _token(i).balanceOf(address(this));
            if (raw != 0) v.deposit(raw, pocket());
            if (_shares(i) < shares) revert SharesShort();
        }
        _sendShares(v, shares, to, false);
    }

    /// @dev Move `sh` shares to `to`: the hook's own first, the rest gathered from the pockets into the hook; redeemed
    /// for the underlying instead when `raw` asks and the hook may redeem them now (one conversion, so the value
    /// matches a preview of the whole slice). Returns the underlying value delivered.
    function _sendShares(IERC4626 v, uint256 sh, address to, bool raw) private returns (uint256) {
        if (sh == 0) return 0;
        uint256 rest = sh - Math.min(sh, v.balanceOf(address(this)));
        for (uint256 k; k < POCKETS && rest != 0; ++k) {
            address pk = pockets[k];
            uint256 a = Math.min(rest, v.balanceOf(pk));
            if (a != 0) IERC20(address(v)).safeTransferFrom(pk, address(this), a);
            rest -= a;
        }
        if (raw && v.maxRedeem(address(this)) >= sh) return v.redeem(sh, to, address(this));
        IERC20(address(v)).safeTransfer(to, sh);
        return v.convertToAssets(sh);
    }

    /// @dev Keep the raw buffer (tokens + claims, which become tokens at the next action) between half and three
    /// times its target: unstake to the target when low (if the hook may redeem), stake down to twice the target
    /// when high. Stakes are minted to the pocket, so they never stamp the hook's own address.
    function _rebalance(uint8 i, uint256 held) private {
        uint256 raw = _token(i).balanceOf(address(this));
        uint256 claims = poolManager.balanceOf(address(this), _id(i));
        uint256 target = held * BUFFER_BPS / 10_000;
        if (raw > 3 * target) {
            // D5: a vault that refuses deposits (paused, at a cap) leaves the surplus raw instead of reverting the action
            if (raw - 2 * target >= MIN_STAKE) try _vault(i).deposit(raw - 2 * target, pocket()) {} catch {}
        } else if (raw + claims < target / 2) {
            _unstake(i, target - raw - claims);
        }
    }

    /// @dev Pull `assets` of side i from the caller, raw or as vault shares worth at least that (rounded up).
    function _pull(uint8 i, bool staked, uint256 assets, uint256 max, bool exact) private {
        if (assets == 0) return;
        if (staked) {
            IERC4626 v = _vault(i);
            uint256 sh = exact ? assets : v.previewWithdraw(assets);
            if (sh > max) revert Slippage();
            IERC20(address(v)).safeTransferFrom(msg.sender, address(this), sh);
        } else {
            if (assets > max) revert Slippage();
            IERC20 t = _token(i);
            uint256 b = t.balanceOf(address(this));
            t.safeTransferFrom(msg.sender, address(this), assets);
            if (t.balanceOf(address(this)) - b < assets) revert Slippage(); // fee-on-transfer tokens are refused
        }
    }

    /// @dev Pay a withdrawal's slice of side i; returns its underlying value.
    function _paySlice(uint8 i, uint256 shares, uint256 supply, bool raw, address to) private returns (uint256 value) {
        IERC20 t = _token(i);
        IERC4626 v = _vault(i);
        uint256 r = Math.mulDiv(t.balanceOf(address(this)), shares, supply);
        uint256 sh = Math.mulDiv(_shares(i), shares, supply);
        if (r != 0) t.safeTransfer(to, r);
        value = r + _sendShares(v, sh, to, raw);
    }

    // ================================================================ internals: oracle

    function _observe(int24 tick) private {
        CompoundOracle.observe(oracle, tick);
    }

    function _twap() private view returns (bool, int24) {
        return CompoundOracle.twap(oracle);
    }

    // ================================================================ internals: helpers

    function _held(uint8 i) private view returns (uint256) {
        return _token(i).balanceOf(address(this)) + poolManager.balanceOf(address(this), _id(i))
            + _vault(i).convertToAssets(_shares(i));
    }

    /// @dev Vault shares of side i held by the hook and its pocket.
    function _shares(uint8 i) private view returns (uint256) {
        IERC4626 v = _vault(i);
        uint256 n = v.balanceOf(address(this));
        for (uint256 k; k < POCKETS; ++k) {
            n += v.balanceOf(pockets[k]);
        }
        return n;
    }

    /// @dev `amount` of side i in token1 units at the curve's price.
    function _value(uint8 i, uint256 amount) private view returns (uint256) {
        if (i == 1) return amount;
        uint160 sp = sqrtPriceX96;
        return Math.mulDiv(Math.mulDiv(amount, sp, Q96), sp, Q96);
    }

    function _token(uint8 i) private view returns (IERC20) {
        return i == 0 ? token0 : token1;
    }

    function _vault(uint8 i) private view returns (IERC4626) {
        return i == 0 ? vault0 : vault1;
    }

    function _id(uint8 i) private view returns (uint256) {
        return uint256(uint160(i == 0 ? address(token0) : address(token1)));
    }

    function _form(address token) private view returns (uint8 side, bool staked) {
        if (token == address(token0)) return (0, false);
        if (token == address(token1)) return (1, false);
        if (token == address(vault0)) return (0, true);
        if (token == address(vault1)) return (1, true);
        revert UnknownToken();
    }
}
