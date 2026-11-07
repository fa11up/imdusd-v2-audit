// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

interface IMintBurn {
    function mint(address to, uint256 amount) external returns (bool);
    function burn(address from, uint256 amount) external returns (bool);
}

interface IKeeperCap {
    function keeperCap() external view returns (uint256);
    function bufferTarget() external view returns (uint256);
    function governor() external view returns (address);
}

/// @title PegHook (imdUSD v2)
/// @notice The imdUSD/USDC v4 pool's hook: a toll on swaps that push the price away from $1, and a capped peg
/// keeper in the style of crvUSD's PegKeeper, gated by an in-hook TWAP. It does not hold the peg: redemption is the
/// floor and stablecoin borrowing the ceiling. It shapes how the pool behaves between them.
///
/// TOLL: a swap that ends beyond ±0.25% of $1, having pushed the price there, pays a surcharge priced from where it
/// ends: rising in a straight line to 1.5% at ±1% (the soft leg). BELOW $1 a step to 5% (the wall) follows, rising to
/// 20% at -2%, capped there; ABOVE $1 it stays flat at 1.5% (no wall above the peg). Swaps toward $1 pay nothing extra. Minted as ERC-6909 claims and swept to the Treasury by anyone.
/// The soft leg's cap must stay at or below the cheapest other exit, or sellers leave before reaching the wall
/// (measured by replaying historical peg-pool swaps).
///
/// KEEPER: permissionless, no key.
///  - `provide()`: while the pool's TWAP is above $1.0025, mint imdUSD and SELL it into the pool down to $1.0005
///    (a swap with that price limit), up to `Parameters.keeperCap` outstanding. The USDC received stays here as the
///    keeper's principal.
///  - `withdraw()`: while the TWAP is below $0.9975, BUY imdUSD back from the pool up to $0.9995 with that USDC and
///    burn it, at most the outstanding amount. Once nothing is outstanding, the BUFFER buys imdUSD up to $0.9995 too
///    and sends it to the Treasury, HELD (not burned: no debt or reserve term matches it, so the supply equation needs
///    no new term). A buffer purchase realises nothing and pays no caller reward.
///  It sells only above $1 and buys only below $1 (after the 0.01% LP fee), so the USDC it holds is always at least the
///  outstanding imdUSD at $1 (`principal()`), checked after every action. Anything above the principal and the buffer
///  is realised profit: the caller gets REWARD_BPS of what the call realised; the rest fills the BUFFER up to
///  `Parameters.bufferTarget` and only then goes to the Treasury. The governor (the Safe) may move the buffer to the
///  Treasury at once: it can only go there. Outstanding imdUSD is non-position supply, backed 1:1 (or better) by the
///  USDC: in the supply equation it is the `outstanding` term.
///
/// HOW THE BUFFER IS FUNDED (before this, keeper profit was the ONLY source, so in the beta's
/// first week, cap 0, the below-peg bid was $0 and USDC sent to the hook sat as `surplus` until a `provide()` happened to
/// fold it in). Three more ways, none touching the principal rule, all stopping at `bufferTarget`:
///  - `withdraw()` first folds any surplus (a donation, a transfer from the Safe) into the buffer, so USDC sent here bids
///    the moment the TWAP is below $0.9975;
///  - `sweep(quote)` routes the toll's USDC into the buffer before the Treasury: what a pusher pays becomes the bid
///    against him (the toll's stable side still goes to the Treasury);
///  - `fundBuffer(amount)`: anyone may pay USDC straight into the buffer (up to the room left under the target).
///
/// WHY A SWAP AND NOT ONE-SIDED LIQUIDITY (differs from the sketch): while the price is above $1.0025, liquidity
/// "just above $1" lies below the current price and can only hold USDC, never imdUSD; and imdUSD-only liquidity above
/// the current price only caps a further rise, it does not bring the price back. Selling with a price limit is the act
/// crvUSD's PegKeeper performs through Curve's `add_liquidity`, done directly.
///
/// TWAP: a tick accumulator updated after every swap (the v3 oracle's rule: the tick that prevailed since the last
/// update, weighted by time), checkpointed into a ring of OBSERVATIONS slots at most every OBS_GAP seconds. The keeper
/// reads the mean tick over at least TWAP_WINDOW. A price moved inside one block has had zero seconds of weight when
/// the same block calls the keeper, so it cannot trigger it; holding a price for the window costs the arbitrage. And
/// manipulation cannot extract from the keeper: it only sells above $1 and buys below.
/// The hook's own swaps skip its callbacks (v4 does not call a hook for its own swaps), so it records them itself.
///
/// QUOTE GATE: `provide()` and the buffer purchase in `withdraw()` act only while the paired stablecoin's own Chainlink USD
/// feed reads at least QUOTE_FLOOR ($0.98) and was updated within `quoteFeedMaxAge`. A depegged USDC makes imdUSD read
/// high in this pool, and minting imdUSD to sell for that USDC would issue against a falling asset (crvUSD v1's
/// paired-stablecoin lesson). Burning OUTSTANDING imdUSD in `withdraw()` is never gated: it only shrinks supply.
///
/// It attaches to exactly one pool: (imdUSD, USDC), fee BASE_FEE, TICK_SPACING, this hook, opening at exactly $1.
contract PegHook is IHooks, IUnlockCallback, TransientReentrancyGuard {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ---- toll ----
    uint24 public constant BASE_FEE = 100; // 0.01%
    uint256 public constant BAND_BPS = 25; // ±0.25%: free inside
    uint256 public constant WALL_BPS = 100; // ±1%: the soft leg ends and the wall begins
    uint256 public constant CAP_AT_BPS = 200; // ±2%: the surcharge reaches MAX_SURCHARGE
    uint256 public constant SOFT_CAP = 15_000; // 1.5% at the wall, approached from inside
    uint256 public constant WALL_SURCHARGE = 50_000; // 5% from the wall
    uint256 public constant MAX_SURCHARGE = 200_000; // 20% from ±2%
    int24 public constant TICK_SPACING = 1;
    uint256 private constant PIPS = 1_000_000;

    // ---- keeper ----
    /// @notice The keeper acts when the TWAP is this many ticks from the peg (1.0001^25 ≈ 0.25%).
    int24 public constant TRIGGER_TICKS = 25;
    /// @notice It trades the price back to this many ticks from the peg (≈ 0.05%), so its average price stays on the
    /// profitable side of $1 after the LP fee.
    int24 public constant TARGET_TICKS = 5;
    uint32 public constant TWAP_WINDOW = 30 minutes;
    uint32 public constant OBS_GAP = 60;
    uint256 public constant OBSERVATIONS = 64;
    /// @notice Caller's share of the profit a call realises, in bps.
    uint256 public constant REWARD_BPS = 1000;

    uint160 public constant FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager public immutable poolManager;
    address public immutable stable; // imdUSD v2
    address public immutable quote; // USDC
    address public immutable treasury;
    IKeeperCap public immutable params;
    bool public immutable stableIsToken0;
    uint160 public immutable pegSqrtPriceX96;
    int24 public immutable pegTick;
    uint256 private immutable quoteScale; // 10^(stable decimals − quote decimals)
    /// @notice The quote stablecoin's Chainlink USD aggregator (mainnet USDC/USD, 4663 USDG/USD) and the oldest answer it
    /// accepts (the feed's heartbeat plus a margin).
    address public immutable quoteUsdFeed;
    uint256 public immutable quoteFeedMaxAge;
    /// @notice The lowest quote-stablecoin price (1e18 = $1) at which the keeper mints or the buffer buys.
    uint256 public constant QUOTE_FLOOR = 0.98e18;

    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    // ---- oracle state ----
    PoolKey internal _key;
    bool public initialized;
    int24 public lastTick;
    uint32 public lastTimestamp;
    int56 public tickCumulative;
    uint16 public obsIndex; // newest written slot
    uint16 public obsCount;
    Observation[64] public observations;

    /// @notice imdUSD minted by the keeper and not yet bought back and burned.
    uint256 public outstanding;
    /// @notice Keeper profit kept as the below-peg buyer (not principal), up to `Parameters.bufferTarget`.
    uint256 public buffer;

    uint8 private constant SWEEP = 0;
    uint8 private constant PROVIDE = 1;
    uint8 private constant WITHDRAW = 2;
    uint8 private constant BUFFER_BUY = 3;

    error NotPoolManager();
    error WrongPool();
    error NotAtPeg();
    error HookAddressMismatch();
    error OddDecimalGap();
    error ZeroAddress();
    error NotImplemented();
    error NotInitialized();
    error NoTwap();
    error TwapInBand(int24 twapTicks);
    error NothingToDo();
    error CapReached();
    error Undercollateralised();
    error NotGovernor();
    error ExceedsBuffer();
    error ExceedsTarget(uint256 room);
    error QuoteUnsound();

    event Swept(Currency indexed currency, uint256 amount);
    event Provided(address indexed caller, uint256 minted, uint256 quoteIn, uint256 reward, uint256 toTreasury);
    event Withdrawn(address indexed caller, uint256 burned, uint256 quoteOut, uint256 reward, uint256 toTreasury);
    event BufferBought(address indexed caller, uint256 bought, uint256 quoteSpent);
    event BufferKept(uint256 amount);
    event BufferPulled(uint256 amount);
    event BufferFunded(address indexed from, uint256 amount);

    constructor(
        IPoolManager poolManager_,
        address stable_,
        address quote_,
        address treasury_,
        IKeeperCap params_,
        address quoteUsdFeed_,
        uint256 quoteFeedMaxAge_
    ) {
        if (
            stable_ == address(0) || quote_ == address(0) || treasury_ == address(0) || address(params_) == address(0)
                || quoteUsdFeed_ == address(0) || quoteFeedMaxAge_ == 0
        ) revert ZeroAddress();
        (quoteUsdFeed, quoteFeedMaxAge) = (quoteUsdFeed_, quoteFeedMaxAge_);
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS) revert HookAddressMismatch();
        poolManager = poolManager_;
        (stable, quote, treasury, params) = (stable_, quote_, treasury_, params_);
        stableIsToken0 = stable_ < quote_;
        (uint8 sd, uint8 qd) = (IDecimals(stable_).decimals(), IDecimals(quote_).decimals());
        if (sd < qd) revert OddDecimalGap(); // imdUSD 18 vs USDC 6; the principal maths assumes stable >= quote
        quoteScale = 10 ** (sd - qd);
        (uint8 d0, uint8 d1) = stableIsToken0 ? (sd, qd) : (qd, sd);
        uint256 gap = d0 > d1 ? d0 - d1 : d1 - d0;
        if (gap % 2 != 0) revert OddDecimalGap();
        uint256 root = 10 ** (gap / 2);
        uint160 peg = uint160(d1 >= d0 ? (uint256(1) << 96) * root : (uint256(1) << 96) / root);
        pegSqrtPriceX96 = peg;
        // The tick NEAREST the peg (for 18 vs 6 decimals the peg sits 0.03 tick from one), so the keeper's ±ticks are
        // symmetric around $1 whichever token sorts first.
        int24 t = TickMath.getTickAtSqrtPrice(peg);
        if (TickMath.getSqrtPriceAtTick(t + 1) - peg < peg - TickMath.getSqrtPriceAtTick(t)) ++t;
        pegTick = t;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    // ---------------------------------------------------------------- hooks

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        (address c0, address c1) = stableIsToken0 ? (stable, quote) : (quote, stable);
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1 || key.fee != BASE_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert WrongPool();
        if (sqrtPriceX96 != pegSqrtPriceX96) revert NotAtPeg();
        // The PoolManager refuses a second initialize of the same key, and any other key is refused above.
        _key = key;
        initialized = true;
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        lastTick = tick;
        lastTimestamp = uint32(block.timestamp);
        observations[0] = Observation(uint32(block.timestamp), 0);
        obsCount = 1;
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata p, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        _observe(tick);
        uint256 pips = surchargeFor(sqrtPriceX96, p.zeroForOne);
        if (pips == 0) return (IHooks.afterSwap.selector, 0);
        bool specifiedIs0 = p.amountSpecified < 0 == p.zeroForOne;
        (Currency currency, int128 amount) =
            specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        uint256 abs = amount < 0 ? uint256(-int256(amount)) : uint256(int256(amount));
        uint256 surcharge = abs * pips / PIPS;
        if (surcharge == 0) return (IHooks.afterSwap.selector, 0);
        poolManager.mint(address(this), currency.toId(), surcharge);
        return (IHooks.afterSwap.selector, int128(int256(surcharge)));
    }

    // ---------------------------------------------------------------- oracle

    /// @dev Credit the tick that prevailed since the last update with the time it prevailed, then adopt `tick`.
    function _observe(int24 tick) private {
        uint32 nowTs = uint32(block.timestamp);
        uint32 dt = nowTs - lastTimestamp;
        if (dt != 0) {
            tickCumulative += int56(lastTick) * int56(uint56(dt));
            lastTimestamp = nowTs;
            if (nowTs >= observations[obsIndex].timestamp + OBS_GAP) {
                uint16 next = uint16((obsIndex + 1) % OBSERVATIONS);
                observations[next] = Observation(nowTs, tickCumulative);
                obsIndex = next;
                if (obsCount < OBSERVATIONS) ++obsCount;
            }
        }
        lastTick = tick;
    }

    /// @notice The mean tick since the newest checkpoint at least TWAP_WINDOW old, as ticks of the STABLE's price
    /// from the peg (positive = imdUSD above $1). Reverts with NoTwap if no checkpoint is old enough yet.
    function twapTicks() public view returns (int24) {
        if (!initialized) revert NotInitialized();
        uint32 nowTs = uint32(block.timestamp);
        int56 cumNow = tickCumulative + int56(lastTick) * int56(uint56(nowTs - lastTimestamp));
        uint256 i = obsIndex;
        for (uint256 n; n < obsCount; ++n) {
            Observation memory o = observations[i];
            if (o.timestamp + TWAP_WINDOW <= nowTs) {
                int56 mean = (cumNow - o.tickCumulative) / int56(uint56(nowTs - o.timestamp));
                return _stableTicks(int24(mean));
            }
            i = i == 0 ? OBSERVATIONS - 1 : i - 1;
        }
        revert NoTwap();
    }

    /// @notice The spot price as ticks of the stable's price from the peg.
    function spotTicks() public view returns (int24) {
        if (!initialized) revert NotInitialized();
        (, int24 tick,,) = poolManager.getSlot0(_key.toId());
        return _stableTicks(tick);
    }

    function _stableTicks(int24 rawTick) private view returns (int24) {
        return stableIsToken0 ? rawTick - pegTick : pegTick - rawTick;
    }

    /// @dev The raw sqrt price at `ticks` of the stable's price from the peg.
    function _sqrtAtStableTicks(int24 ticks) private view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(stableIsToken0 ? pegTick + ticks : pegTick - ticks);
    }

    // ---------------------------------------------------------------- keeper

    /// @notice USDC the keeper must hold: the outstanding imdUSD at $1, rounded up.
    function principal() public view returns (uint256) {
        return (outstanding + quoteScale - 1) / quoteScale;
    }

    /// @notice USDC above the principal and the buffer (realised profit not yet paid out, or a donation).
    function surplus() public view returns (uint256) {
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 held = principal() + buffer;
        return bal > held ? bal - held : 0;
    }

    /// @notice True while the quote stablecoin's USD feed reads >= QUOTE_FLOOR and is no older than `quoteFeedMaxAge`.
    /// An unreadable, non-positive, future-dated or stale answer is unsound (fail closed).
    function quoteSound() public view returns (bool) {
        (bool ok, bytes memory data) = quoteUsdFeed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        (bool okd, bytes memory dd) = quoteUsdFeed.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || !okd || data.length < 160 || dd.length < 32) return false;
        (, int256 answer,, uint256 updatedAt,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        uint256 dec = abi.decode(dd, (uint256));
        if (answer <= 0 || dec > 36 || updatedAt == 0 || updatedAt > block.timestamp) return false;
        if (block.timestamp - updatedAt > quoteFeedMaxAge) return false;
        return uint256(answer) * 10 ** (36 - dec) / 1e18 >= QUOTE_FLOOR;
    }

    /// @notice USDC the buffer can still take: `Parameters.bufferTarget` less what it holds.
    function bufferRoom() public view returns (uint256) {
        uint256 target = params.bufferTarget();
        return target > buffer ? target - buffer : 0;
    }

    /// @notice Pay `amount` of USDC into the buffer (anyone: the Safe arming the bid, a donor). At most `bufferRoom()`,
    /// so a donor cannot be surprised by a target of 0 (genesis): the Safe sets the target through the timelock first.
    function fundBuffer(uint256 amount) external nonReentrant {
        uint256 room = bufferRoom();
        if (amount == 0 || amount > room) revert ExceedsTarget(room);
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        buffer += amount;
        emit BufferFunded(msg.sender, amount);
    }

    /// @dev Fold USDC that is neither principal nor buffer (a donation, a Safe transfer) into the buffer up to the target.
    function _foldSurplus() private {
        uint256 keep = Math.min(surplus(), bufferRoom());
        if (keep != 0) {
            buffer += keep;
            emit BufferKept(keep);
        }
    }

    /// @notice Move `amount` of the buffer to the Treasury. The governor only; no delay (it can only reach the
    /// Treasury).
    function pullBuffer(uint256 amount) external nonReentrant {
        if (msg.sender != params.governor()) revert NotGovernor();
        if (amount > buffer) revert ExceedsBuffer();
        buffer -= amount;
        IERC20(quote).safeTransfer(treasury, amount);
        emit BufferPulled(amount);
    }

    /// @notice imdUSD above the peg: sell newly minted imdUSD back to $1.0005, within the cap. Anyone may call.
    function provide() external nonReentrant returns (uint256 minted) {
        if (!quoteSound()) revert QuoteUnsound();
        int24 twap = twapTicks();
        if (twap <= TRIGGER_TICKS) revert TwapInBand(twap);
        if (spotTicks() <= TARGET_TICKS) revert NothingToDo();
        uint256 cap = params.keeperCap();
        if (outstanding >= cap) revert CapReached();
        uint256 before = surplus();
        uint256 quoteIn;
        (minted, quoteIn) = abi.decode(poolManager.unlock(abi.encode(PROVIDE, cap - outstanding)), (uint256, uint256));
        if (minted == 0) revert NothingToDo();
        (uint256 reward, uint256 toTreasury) = _settleProfit(before);
        emit Provided(msg.sender, minted, quoteIn, reward, toTreasury);
    }

    /// @notice imdUSD below the peg: buy back outstanding imdUSD up to $0.9995 with the keeper's USDC and burn it;
    /// then, once nothing is outstanding, buy imdUSD up to $0.9995 with the buffer and send it to the Treasury.
    /// Returns what was burned and what the buffer bought.
    function withdraw() external nonReentrant returns (uint256 burned, uint256 bought) {
        int24 twap = twapTicks();
        if (twap >= -TRIGGER_TICKS) revert TwapInBand(twap);
        _foldSurplus(); // USDC sent here arms the bid now, not after the next provide()
        if (outstanding != 0 && spotTicks() < -TARGET_TICKS) {
            uint256 before = surplus();
            uint256 quoteOut;
            (burned, quoteOut) = abi.decode(poolManager.unlock(abi.encode(WITHDRAW, outstanding)), (uint256, uint256));
            (uint256 reward, uint256 toTreasury) = _settleProfit(before);
            emit Withdrawn(msg.sender, burned, quoteOut, reward, toTreasury);
        }
        if (outstanding == 0 && buffer != 0 && spotTicks() < -TARGET_TICKS) {
            // The buffer buys only against a sound quote stablecoin; a burn already done in this call stands.
            if (!quoteSound()) {
                if (burned == 0) revert QuoteUnsound();
                return (burned, 0);
            }
            uint256 spent;
            (bought, spent) = abi.decode(poolManager.unlock(abi.encode(BUFFER_BUY, buffer)), (uint256, uint256));
            buffer -= spent;
            _settleProfit(surplus()); // solvency check; a buffer purchase realises nothing, so no reward
            emit BufferBought(msg.sender, bought, spent);
        }
        if (burned == 0 && bought == 0) revert NothingToDo();
    }

    /// @dev After a keeper trade: the principal must still be covered. Pay the caller its share of what this call
    /// realised, keep the rest of the surplus as the buffer up to the target, and send what is left to the Treasury.
    function _settleProfit(uint256 before) private returns (uint256 reward, uint256 toTreasury) {
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 p = principal() + buffer;
        if (bal < p) revert Undercollateralised();
        uint256 s = bal - p;
        uint256 realised = s > before ? s - before : 0;
        reward = realised * REWARD_BPS / 10_000;
        uint256 rest = s - reward;
        uint256 target = params.bufferTarget();
        uint256 keep = target > buffer ? target - buffer : 0;
        if (keep > rest) keep = rest;
        if (keep != 0) {
            buffer += keep;
            emit BufferKept(keep);
        }
        toTreasury = rest - keep;
        if (reward != 0) IERC20(quote).safeTransfer(msg.sender, reward);
        if (toTreasury != 0) IERC20(quote).safeTransfer(treasury, toTreasury);
    }

    // ---------------------------------------------------------------- surcharge sweep

    /// @notice Send the toll claims in `currency` to the Treasury; the quote's (USDC) fill the buffer up to its target
    /// first (the surcharge a pusher paid is the bid against him). Anyone may call.
    function sweep(Currency currency) external nonReentrant returns (uint256 amount) {
        amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount == 0) return 0;
        uint256 keep = Currency.unwrap(currency) == quote ? Math.min(amount, bufferRoom()) : 0;
        poolManager.unlock(abi.encode(SWEEP, uint256(uint160(Currency.unwrap(currency))), amount, keep));
        if (keep != 0) {
            buffer += keep;
            emit BufferKept(keep);
        }
        emit Swept(currency, amount - keep);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));
        if (action == SWEEP) {
            (, uint256 c, uint256 amount, uint256 keep) = abi.decode(data, (uint8, uint256, uint256, uint256));
            Currency currency = Currency.wrap(address(uint160(c)));
            poolManager.burn(address(this), currency.toId(), amount);
            if (keep != 0) poolManager.take(currency, address(this), keep);
            if (amount != keep) poolManager.take(currency, treasury, amount - keep);
            return "";
        }
        (, uint256 limitAmount) = abi.decode(data, (uint8, uint256));
        PoolKey memory key = _key;
        if (action == BUFFER_BUY) return _bufferBuy(key, limitAmount);
        bool sell = action == PROVIDE;
        // Selling the stable lowers its price: zeroForOne when it is token0.
        bool zeroForOne = sell == stableIsToken0;
        uint160 limit = _sqrtAtStableTicks(sell ? TARGET_TICKS : -TARGET_TICKS);
        // Provide: exact input of up to the cap room. Withdraw: exact output of up to the outstanding amount.
        int256 specified = sell ? -int256(limitAmount) : int256(limitAmount);
        BalanceDelta d = poolManager.swap(key, SwapParams(zeroForOne, specified, limit), "");
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        _observe(tick);
        (int128 s, int128 q) = stableIsToken0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        Currency cs = Currency.wrap(stable);
        Currency cq = Currency.wrap(quote);
        uint256 stableAmt;
        uint256 quoteAmt;
        if (sell) {
            // We owe the stable (s <= 0) and are owed the quote (q >= 0).
            stableAmt = uint256(int256(-s));
            quoteAmt = uint256(int256(q));
            if (stableAmt != 0) {
                poolManager.sync(cs);
                IMintBurn(stable).mint(address(poolManager), stableAmt);
                poolManager.settle();
                outstanding += stableAmt;
            }
            if (quoteAmt != 0) poolManager.take(cq, address(this), quoteAmt);
        } else {
            stableAmt = uint256(int256(s));
            quoteAmt = uint256(int256(-q));
            if (stableAmt > outstanding) stableAmt = outstanding; // exact output: cannot happen; never burn more
            if (quoteAmt != 0) {
                poolManager.sync(cq);
                IERC20(quote).safeTransfer(address(poolManager), quoteAmt);
                poolManager.settle();
            }
            if (s != 0) {
                poolManager.take(cs, address(this), uint256(int256(s)));
                IMintBurn(stable).burn(address(this), stableAmt);
                outstanding -= stableAmt;
            }
        }
        return abi.encode(stableAmt, quoteAmt);
    }

    /// @dev Inside the unlock: exact input of up to `budget` USDC for imdUSD, stopping at $0.9995; the imdUSD goes
    /// straight to the Treasury. Returns (imdUSD bought, USDC spent).
    function _bufferBuy(PoolKey memory key, uint256 budget) private returns (bytes memory) {
        bool zeroForOne = !stableIsToken0; // buying the stable raises its price
        BalanceDelta d = poolManager.swap(
            key, SwapParams(zeroForOne, -int256(budget), _sqrtAtStableTicks(-TARGET_TICKS)), ""
        );
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        _observe(tick);
        (int128 s, int128 q) = stableIsToken0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 spent = uint256(int256(-q));
        uint256 got = uint256(int256(s));
        if (spent != 0) {
            poolManager.sync(Currency.wrap(quote));
            IERC20(quote).safeTransfer(address(poolManager), spent);
            poolManager.settle();
        }
        if (got != 0) poolManager.take(Currency.wrap(stable), treasury, got);
        return abi.encode(got, spent);
    }

    // ---------------------------------------------------------------- views (v1)

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function stablePrice(uint160 sqrtPriceX96) public view returns (uint256) {
        uint256 ratioX96 = FullMath.mulDiv(sqrtPriceX96, 1 << 96, pegSqrtPriceX96);
        if (ratioX96 >= 1 << 140) return stableIsToken0 ? type(uint256).max : 0;
        uint256 r = FullMath.mulDiv(FullMath.mulDiv(ratioX96, ratioX96, 1 << 96), 1e18, 1 << 96);
        return stableIsToken0 ? r : (r == 0 ? type(uint256).max : 1e36 / r);
    }

    function feeFor(uint160 sqrtPriceX96, bool zeroForOne) public view returns (uint24) {
        return uint24(BASE_FEE + surchargeFor(sqrtPriceX96, zeroForOne));
    }

    function surchargeFor(uint160 sqrtPriceX96, bool zeroForOne) public view returns (uint256) {
        uint256 p = stablePrice(sqrtPriceX96);
        bool below = p < 1e18;
        uint256 dev = below ? 1e18 - p : p - 1e18;
        uint256 band = BAND_BPS * 1e14;
        if (dev <= band) return 0;
        bool sellsStable = stableIsToken0 == zeroForOne;
        bool away = below ? sellsStable : !sellsStable;
        if (!away) return 0;
        uint256 wall = WALL_BPS * 1e14;
        if (dev < wall) return SOFT_CAP * (dev - band) / (wall - band);
        // ABOVE $1 there is no wall (2026-10-29): past +1% the toll stays at SOFT_CAP. Buyers above the peg are mostly
        // borrowers buying imdUSD to repay in a crash (the deleveraging the system needs); the keeper defends that side.
        if (!below) return SOFT_CAP;
        uint256 cap = CAP_AT_BPS * 1e14;
        if (dev >= cap) return MAX_SURCHARGE;
        return WALL_SURCHARGE + (MAX_SURCHARGE - WALL_SURCHARGE) * (dev - wall) / (cap - wall);
    }

    // ---------------------------------------------------------------- unused

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert NotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }
}
