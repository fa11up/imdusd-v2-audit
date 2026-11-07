// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GovernedByKind} from "../GovernedByKind.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {IFeed} from "../interfaces/IFeed.sol";

interface IERC4626Alloc {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

interface IPegBufferAlloc {
    function quote() external view returns (address);
    function fundBuffer(uint256 amount) external;
}

interface IPegLPVaultAlloc {
    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);
    function deposit(uint256 shares, uint256 max0, uint256 max1, address to)
        external
        returns (uint256 minted, uint256 amount0, uint256 amount1);
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address to) external returns (uint256 a0, uint256 a1);
    function hook() external view returns (IPegLPHookAlloc);
}

interface IPegLPHookAlloc {
    function twapTicks() external view returns (int24);
    function spotTicks() external view returns (int24);
}

/// @notice An allowlisted swap adapter. It must pull at most `amountIn` of `tokenIn` from the caller (via the exact
/// allowance the Allocator grants) and deliver `tokenOut` to `recipient`. The Allocator checks what actually arrived.
interface ISwapRoute {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut);
}

/// @notice What the Backstop (built separately) exposes to the Allocator for collateral sales. Only the
/// Allocator may call either. `releaseForSale` sends `amount` of `collateral` to the Allocator; `settleSale` is called
/// right after with the proceeds already transferred to the Backstop, so it can book them against that collateral.
interface IBackstopSale {
    function imdUSD() external view returns (IERC20);
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata data) external returns (uint256 got);
}

/// @title Allocator: the keeper's only way to move protocol funds.
/// @notice Modelled on Spark's ALM controller (sparkdotfi/spark-alm-controller: relayer + freezer, a refilling rate
/// limit per action, allowlisted targets, slippage bounds). Funds held here belong to the protocol: the Treasury (or the
/// Safe through a Treasury payout) sends them here, and every action keeps them inside protocol addresses.
///
/// WHERE FUNDS CAN GO. There is no recipient argument anywhere. Each action moves value between this contract and one
/// allowlisted protocol target:
///  - vault deposit / redeem: this contract <-> an approved ERC-4626 (shares are held here);
///  - peg buffer: this contract -> PegHook.fundBuffer (the buffer only ever leaves the hook to the Treasury, by the Safe);
///  - peg LP: this contract <-> PegLPVault (shares held here, withdrawals paid here);
///  - collateral sale: Backstop -> this contract -> allowlisted route -> proceeds to the Backstop;
///  - swap: this contract -> allowlisted route -> this contract (e.g. USDC <-> USDS for an sUSDS vault);
///  - `returnToTreasury`: the governor (or the keeper within its bucket) sends funds back to the Treasury.
/// A swap route receives only an exact allowance of `amountIn` for one call (reset to zero after), so it cannot reach
/// any other balance; what it must deliver is checked by balance difference against a minimum derived from two price
/// feeds and `maxSlippageBps`, never from the keeper's own figure alone.
///
/// RATE LIMITS. Every action draws on a bucket keyed by (action, target): `maxAmount` refilled at `slope` per second.
/// UNITS: SWAP and BACKSTOP_SALE buckets are in USD (1e18 = $1), the input's value at its feed
/// (the same feed the slippage bound reads), because their target (a route, a sleeve) does not fix the token: a raw-unit
/// bucket meant nothing across 6/8/18-decimal tokens priced $1 to $100k. Every other bucket's target fixes its token and
/// stays in raw units: VAULT_DEPOSIT in the vault's asset, VAULT_REDEEM and LP_* in shares, BUFFER_FUND in the hook's
/// quote token, TO_TREASURY in the token itself. A zero bucket refuses. Lowering a bucket or the slippage bound, removing a
/// target or a keeper, or clearing the freezer is instant by the governor, and cancels a pending proposal touching the same
/// field, so anyone's `applyPending` cannot undo it; raising or adding goes through the 48h timelock, ONE PENDING SLOT
/// PER KIND (`GovernedByKind`), and BATCH carries a whole setup (targets, limits, feeds) in one proposal.
///
/// ROLES. KEEPERs act. The FREEZER (the operator's guardian key) can only `freeze()` (every keeper action stops)
/// and `removeKeeper`. Unfreezing is the governor's, at once (freezing is the emergency; resuming is a decision).
contract Allocator is GovernedByKind, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    // Actions (the bucket key is keccak256(abi.encode(action, target))).
    bytes32 public constant VAULT_DEPOSIT = "VAULT_DEPOSIT";
    bytes32 public constant VAULT_REDEEM = "VAULT_REDEEM";
    bytes32 public constant BUFFER_FUND = "BUFFER_FUND";
    bytes32 public constant LP_DEPOSIT = "LP_DEPOSIT";
    bytes32 public constant LP_WITHDRAW = "LP_WITHDRAW";
    bytes32 public constant SWAP = "SWAP";
    bytes32 public constant BACKSTOP_SALE = "BACKSTOP_SALE";
    /// @dev Transient slot holding the one Backstop callback a running `sellForBackstop` accepts.
    bytes32 private constant SALE_CTX_SLOT = 0xc956fb4533f6ddaacf4a24570a9beff674dbcca973d8e9f36476fe7a57ccd3b8; // keccak256("imdusd.allocator.saleCtx")
    bytes32 public constant TO_TREASURY = "TO_TREASURY";

    // Governed payload kinds (raises and additions; each goes through the 48h timelock).
    uint8 public constant SET_LIMIT = 1; // (bytes32 action, address target, uint128 maxAmount, uint128 slope)
    uint8 public constant ADD_TARGET = 2; // (bytes32 action, address target)
    uint8 public constant ADD_KEEPER = 3; // (address keeper)
    uint8 public constant SET_FREEZER = 4; // (address freezer)
    uint8 public constant SET_FEED = 5; // (address token, address feed): USD feed used to bound swaps and sales
    uint8 public constant SET_SLIPPAGE = 6; // (uint16 maxSlippageBps) <= MAX_SLIPPAGE_BPS
    uint8 public constant BATCH = 7; // (bytes[] items): kinds 1-6, applied in order; locks BATCH and every item's kind

    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    /// @notice LP actions need the peg pool's spot within this many ticks of its 30-minute TWAP: a push
    /// inside the keeper's own transaction cannot move the TWAP, so it cannot pick the price an exit or entry happens at.
    int24 public constant MAX_LP_SPOT_TWAP_TICKS = 10;

    address public immutable treasury;

    struct Limit {
        uint128 maxAmount;
        uint128 slope; // per second
        uint128 lastAmount;
        uint64 lastUpdated;
    }

    mapping(bytes32 key => Limit) public limits;
    mapping(bytes32 key => bool) public allowed; // keccak256(action, target)
    mapping(address => bool) public isKeeper;
    mapping(address token => IFeed) public feedOf;
    address public freezer;
    bool public frozen;
    uint16 public maxSlippageBps;

    error NotKeeper();
    error NotFreezer();
    error Frozen();
    error NotAllowed(bytes32 action, address target);
    error RateLimited(bytes32 action, address target, uint256 amount, uint256 available);
    error BadPayload();
    error NoFeed(address token);
    error StaleFeed(address token);
    error Slippage(uint256 got, uint256 minOut);
    error TokenMismatch();
    error OffTwap(int24 spot, int24 twap);

    event LimitSet(bytes32 indexed action, address indexed target, uint256 maxAmount, uint256 slope);
    event TargetSet(bytes32 indexed action, address indexed target, bool allowed);
    event KeeperSet(address indexed keeper, bool isKeeper);
    event FreezerSet(address freezer);
    event FrozenSet(bool frozen);
    event FeedSet(address indexed token, address feed);
    event SlippageSet(uint256 bps);
    event Acted(bytes32 indexed action, address indexed target, uint256 amount, uint256 result);

    constructor(address governor_, address treasury_, address freezer_, uint16 maxSlippageBps_) GovernedByKind(governor_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert BadPayload();
        treasury = treasury_;
        freezer = freezer_;
        maxSlippageBps = maxSlippageBps_;
    }

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        if (frozen) revert Frozen();
        _;
    }

    // ---------------------------------------------------------------- keeper actions

    /// @notice Deposit `assets` of the vault's asset (held here) into an approved ERC-4626; shares stay here.
    function vaultDeposit(address vault, uint256 assets) external onlyKeeper nonReentrant returns (uint256 shares) {
        _draw(VAULT_DEPOSIT, vault, assets);
        IERC20 a = IERC20(IERC4626Alloc(vault).asset());
        a.forceApprove(vault, assets);
        shares = IERC4626Alloc(vault).deposit(assets, address(this));
        a.forceApprove(vault, 0);
        emit Acted(VAULT_DEPOSIT, vault, assets, shares);
    }

    /// @notice Redeem `shares` of an approved ERC-4626 back to this contract.
    function vaultRedeem(address vault, uint256 shares) external onlyKeeper nonReentrant returns (uint256 assets) {
        _draw(VAULT_REDEEM, vault, shares);
        assets = IERC4626Alloc(vault).redeem(shares, address(this), address(this));
        emit Acted(VAULT_REDEEM, vault, shares, assets);
    }

    /// @notice Pay `amount` of the hook's quote stablecoin into the peg buffer (the below-peg bid).
    function fundBuffer(address hook, uint256 amount) external onlyKeeper nonReentrant {
        _draw(BUFFER_FUND, hook, amount);
        IERC20 q = IERC20(IPegBufferAlloc(hook).quote());
        q.forceApprove(hook, amount);
        IPegBufferAlloc(hook).fundBuffer(amount);
        q.forceApprove(hook, 0);
        emit Acted(BUFFER_FUND, hook, amount, amount);
    }

    /// @notice Buy `shares` of protocol-owned peg liquidity (both tokens held here; amounts bounded by max0/max1).
    /// The bucket is drawn in shares.
    function lpDeposit(address lpVault, uint256 shares, uint256 max0, uint256 max1)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 minted)
    {
        _draw(LP_DEPOSIT, lpVault, shares);
        IPegLPVaultAlloc v = IPegLPVaultAlloc(lpVault);
        _checkLpTwap(v);
        (IERC20 t0, IERC20 t1) = (v.token0(), v.token1());
        t0.forceApprove(lpVault, max0);
        t1.forceApprove(lpVault, max1);
        (minted,,) = v.deposit(shares, max0, max1, address(this));
        t0.forceApprove(lpVault, 0);
        t1.forceApprove(lpVault, 0);
        emit Acted(LP_DEPOSIT, lpVault, shares, minted);
    }

    /// @notice Sell `shares` of protocol-owned peg liquidity back to this contract. Refused while the pool's spot is off
    /// its TWAP (PegLPVault.withdraw itself is never price-gated, so ordinary holders can always leave; the protocol's
    /// own exit, driven by a keeper key, is).
    function lpWithdraw(address lpVault, uint256 shares, uint256 min0, uint256 min1) external onlyKeeper nonReentrant {
        _draw(LP_WITHDRAW, lpVault, shares);
        _checkLpTwap(IPegLPVaultAlloc(lpVault));
        IPegLPVaultAlloc(lpVault).withdraw(shares, min0, min1, address(this));
        emit Acted(LP_WITHDRAW, lpVault, shares, 0);
    }

    /// @notice Swap `amountIn` of `tokenIn` held here for `tokenOut`, through an allowlisted route, back to this
    /// contract. The bucket is keyed by the route and drawn in USD: `amountIn` at `tokenIn`'s feed (so a round trip
    /// draws both legs' value).
    function swap(address route, address tokenIn, address tokenOut, uint256 amountIn, uint256 keeperMinOut)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 got)
    {
        _draw(SWAP, route, _usd(tokenIn, amountIn));
        got = _routeSwap(route, tokenIn, tokenOut, amountIn, keeperMinOut, address(this));
        emit Acted(SWAP, route, amountIn, got);
    }

    /// @notice Sell `amount` of collateral a Backstop sleeve holds, through an allowlisted route, for imdUSD that goes
    /// straight back to the sleeve. The sleeve drives the sale (`Backstop.sell`): it hands the collateral here, calls
    /// `onBackstopSell`, and itself refuses less than `keeperMinOut` or 98% of the collateral's low price. The bucket is
    /// keyed by the sleeve and drawn in USD (`amount` at the collateral's feed); the route must also be allowlisted for SWAP.
    function sellForBackstop(address backstop, address route, address collateral, uint256 amount, uint256 keeperMinOut)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 proceeds)
    {
        _draw(BACKSTOP_SALE, backstop, _usd(collateral, amount));
        if (!allowed[_key(SWAP, route)]) revert NotAllowed(SWAP, route);
        // The one callback this sale may receive: from this sleeve, for this token and amount, through this route.
        bytes32 ctx = keccak256(abi.encode(backstop, collateral, amount, route, keeperMinOut));
        assembly ("memory-safe") {
            tstore(SALE_CTX_SLOT, ctx)
        }
        proceeds = IBackstopSale(backstop).sell(collateral, amount, keeperMinOut, abi.encode(route, keeperMinOut));
        assembly ("memory-safe") {
            tstore(SALE_CTX_SLOT, 0)
        }
        emit Acted(BACKSTOP_SALE, backstop, amount, proceeds);
    }

    /// @notice Backstop callback inside `sellForBackstop` only: swap the collateral just received for imdUSD, to the sleeve.
    function onBackstopSell(address token, uint256 amount, bytes calldata data) external {
        (address route, uint256 keeperMinOut) = abi.decode(data, (address, uint256));
        bytes32 ctx = keccak256(abi.encode(msg.sender, token, amount, route, keeperMinOut));
        bytes32 expected;
        assembly ("memory-safe") {
            expected := tload(SALE_CTX_SLOT)
        }
        if (expected == bytes32(0) || ctx != expected) revert NotAllowed(BACKSTOP_SALE, msg.sender);
        assembly ("memory-safe") {
            tstore(SALE_CTX_SLOT, 0) // one callback per sale
        }
        _routeSwap(route, token, address(IBackstopSale(msg.sender).imdUSD()), amount, keeperMinOut, msg.sender);
    }

    /// @notice Send `amount` of `token` back to the Treasury (keeper, within its bucket keyed by the token).
    function returnToTreasury(address token, uint256 amount) external nonReentrant {
        if (msg.sender != governor) {
            if (!isKeeper[msg.sender]) revert NotKeeper();
            if (frozen) revert Frozen();
            _draw(TO_TREASURY, token, amount);
        }
        IERC20(token).safeTransfer(treasury, amount);
        emit Acted(TO_TREASURY, token, amount, amount);
    }

    // ---------------------------------------------------------------- freezer + instant (risk-reducing) governor acts

    function freeze() external {
        if (msg.sender != freezer && msg.sender != governor) revert NotFreezer();
        frozen = true;
        emit FrozenSet(true);
    }

    function unfreeze() external onlyGovernor {
        frozen = false;
        emit FrozenSet(false);
    }

    /// @notice Remove the freezer at once: a leaked guardian key could otherwise re-freeze after every
    /// unfreeze for the 48h a SET_FREEZER takes. Only reduces who can act; a new freezer still goes through SET_FREEZER.
    function clearFreezer() external onlyGovernor {
        _cancelPending(SET_FREEZER, 0);
        freezer = address(0);
        emit FreezerSet(address(0));
    }

    function removeKeeper(address keeper) external {
        if (msg.sender != freezer && msg.sender != governor) revert NotFreezer();
        if (keeper != address(0)) _cancelPending(ADD_KEEPER, bytes32(uint256(uint160(keeper))));
        isKeeper[keeper] = false;
        emit KeeperSet(keeper, false);
    }

    /// @notice Lower a bucket at once (max and slope may only fall; the available amount is clipped to the new max).
    function lowerLimit(bytes32 action, address target, uint128 maxAmount, uint128 slope) external onlyGovernor {
        bytes32 k = _key(action, target);
        Limit storage l = limits[k];
        if (maxAmount > l.maxAmount || slope > l.slope) revert BadPayload();
        _cancelPending(SET_LIMIT, k);
        uint256 avail = _available(l);
        (l.maxAmount, l.slope, l.lastAmount, l.lastUpdated) =
            (maxAmount, slope, uint128(Math.min(avail, maxAmount)), uint64(block.timestamp));
        emit LimitSet(action, target, maxAmount, slope);
    }

    function removeTarget(bytes32 action, address target) external onlyGovernor {
        _cancelPending(ADD_TARGET, _key(action, target));
        allowed[_key(action, target)] = false;
        emit TargetSet(action, target, false);
    }

    function lowerSlippage(uint16 bps) external onlyGovernor {
        if (bps > maxSlippageBps) revert BadPayload();
        _cancelPending(SET_SLIPPAGE, 0);
        maxSlippageBps = bps;
        emit SlippageSet(bps);
    }

    /// @dev Parameters' rule: an instant lower wins over every older proposal that would change the same field. It
    /// cancels the pending slot carrying `kind` (its own, or the BATCH carrying it) if that proposal touches `field`
    /// (0 = the kind has one field). The governor re-proposes whatever else a batch carried. `removeKeeper` also runs for the
    /// freezer: it can drop only a proposal that adds the keeper it names, and the governor can replace a bad freezer.
    function _cancelPending(uint8 kind, bytes32 field) private {
        if (locked & (uint256(1) << kind) == 0) return;
        uint8 slot = pendingKinds & (uint256(1) << kind) != 0 ? kind : BATCH;
        if (!_touches(_slots[slot].payload, kind, field)) return;
        emit Cancelled(_take(slot).payload);
    }

    function _touches(bytes memory p, uint8 kind, bytes32 field) private pure returns (bool) {
        uint8 k = abi.decode(p, (uint8));
        if (k == BATCH) {
            bytes[] memory items = _items(p);
            for (uint256 i; i < items.length; ++i) {
                if (_touches(items[i], kind, field)) return true;
            }
            return false;
        }
        if (k != kind) return false;
        if (field == 0) return true;
        if (k == ADD_KEEPER) {
            (, address a) = abi.decode(p, (uint8, address));
            return bytes32(uint256(uint160(a))) == field;
        }
        (, bytes32 action, address target) = abi.decode(p, (uint8, bytes32, address)); // ADD_TARGET, SET_LIMIT
        return _key(action, target) == field;
    }

    // ---------------------------------------------------------------- views

    function key(bytes32 action, address target) external pure returns (bytes32) {
        return _key(action, target);
    }

    function available(bytes32 action, address target) external view returns (uint256) {
        return _available(limits[_key(action, target)]);
    }

    /// @notice The least `tokenOut` (raw) an `amountIn` of `tokenIn` (raw) must fetch: feed value less maxSlippageBps.
    function oracleMinOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 pIn = _feedPrice(tokenIn);
        uint256 pOut = _feedPrice(tokenOut);
        uint256 fair = Math.mulDiv(amountIn, pIn, pOut);
        return Math.mulDiv(fair, 10_000 - maxSlippageBps, 10_000);
    }

    // ---------------------------------------------------------------- governed (timelocked) raises and additions

    function _validate(bytes memory payload) internal view override {
        if (payload.length < 32) revert BadPayload();
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == BATCH) {
            bytes[] memory items = _items(payload);
            for (uint256 i; i < items.length; ++i) {
                if (items[i].length < 32 || abi.decode(items[i], (uint8)) == BATCH) revert BadPayload();
                _validate(items[i]);
            }
        } else if (kind == SET_LIMIT) {
            (, bytes32 action,,,) = abi.decode(payload, (uint8, bytes32, address, uint128, uint128));
            if (action == bytes32(0)) revert BadPayload();
        } else if (kind == ADD_TARGET) {
            (,, address target) = abi.decode(payload, (uint8, bytes32, address));
            if (target == address(0) || target.code.length == 0) revert BadPayload();
        } else if (kind == ADD_KEEPER || kind == SET_FREEZER) {
            (, address a) = abi.decode(payload, (uint8, address));
            if (a == address(0)) revert BadPayload();
        } else if (kind == SET_FEED) {
            (,, address feed) = abi.decode(payload, (uint8, address, address));
            if (feed.code.length == 0) revert BadPayload();
        } else if (kind == SET_SLIPPAGE) {
            (, uint16 bps) = abi.decode(payload, (uint8, uint16));
            if (bps > MAX_SLIPPAGE_BPS) revert BadPayload();
        } else {
            revert BadPayload();
        }
    }

    function _apply(bytes memory payload) internal override {
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == BATCH) {
            bytes[] memory items = _items(payload);
            for (uint256 i; i < items.length; ++i) {
                _apply(items[i]);
            }
        } else if (kind == SET_LIMIT) {
            (, bytes32 action, address target, uint128 maxAmount, uint128 slope) =
                abi.decode(payload, (uint8, bytes32, address, uint128, uint128));
            Limit storage l = limits[_key(action, target)];
            uint256 avail = _available(l);
            (l.maxAmount, l.slope, l.lastAmount, l.lastUpdated) =
                (maxAmount, slope, uint128(Math.min(avail, maxAmount)), uint64(block.timestamp));
            emit LimitSet(action, target, maxAmount, slope);
        } else if (kind == ADD_TARGET) {
            (, bytes32 action, address target) = abi.decode(payload, (uint8, bytes32, address));
            allowed[_key(action, target)] = true;
            emit TargetSet(action, target, true);
        } else if (kind == ADD_KEEPER) {
            (, address k) = abi.decode(payload, (uint8, address));
            isKeeper[k] = true;
            emit KeeperSet(k, true);
        } else if (kind == SET_FREEZER) {
            (, address f) = abi.decode(payload, (uint8, address));
            freezer = f;
            emit FreezerSet(f);
        } else if (kind == SET_FEED) {
            (, address token, address feed) = abi.decode(payload, (uint8, address, address));
            feedOf[token] = IFeed(feed);
            emit FeedSet(token, feed);
        } else {
            (, uint16 bps) = abi.decode(payload, (uint8, uint16));
            maxSlippageBps = bps;
            emit SlippageSet(bps);
        }
    }

    /// @dev A batch locks BATCH and every item's kind, so no field is pending twice (GovernedByKind).
    function _kindsOf(bytes memory payload) internal pure override returns (uint256 bits) {
        uint8 kind = abi.decode(payload, (uint8));
        bits = uint256(1) << kind;
        if (kind == BATCH) {
            bytes[] memory items = _items(payload);
            if (items.length == 0) revert BadPayload();
            for (uint256 i; i < items.length; ++i) {
                bits |= uint256(1) << abi.decode(items[i], (uint8));
            }
        }
    }

    function _items(bytes memory payload) private pure returns (bytes[] memory items) {
        (, items) = abi.decode(payload, (uint8, bytes[]));
    }

    // ---------------------------------------------------------------- internals

    /// @dev USD value (1e18 = $1) of `amount` raw of `token` at its feed (IFeed: USD per 1e18 raw, 1e18-scaled).
    function _usd(address token, uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, _feedPrice(token), 1e18);
    }

    function _checkLpTwap(IPegLPVaultAlloc v) internal view {
        IPegLPHookAlloc h = v.hook();
        int24 spot = h.spotTicks();
        int24 twap = h.twapTicks();
        if ((spot > twap ? spot - twap : twap - spot) > MAX_LP_SPOT_TWAP_TICKS) revert OffTwap(spot, twap);
    }

    function _key(bytes32 action, address target) internal pure returns (bytes32) {
        return keccak256(abi.encode(action, target));
    }

    function _draw(bytes32 action, address target, uint256 amount) internal {
        bytes32 k = _key(action, target);
        if (!allowed[k]) revert NotAllowed(action, target);
        Limit storage l = limits[k];
        uint256 avail = _available(l);
        if (amount > avail) revert RateLimited(action, target, amount, avail);
        l.lastAmount = uint128(avail - amount);
        l.lastUpdated = uint64(block.timestamp);
    }

    function _available(Limit storage l) internal view returns (uint256) {
        uint256 refilled = uint256(l.lastAmount) + uint256(l.slope) * (block.timestamp - l.lastUpdated);
        return Math.min(refilled, l.maxAmount);
    }

    function _feedPrice(address token) internal view returns (uint256 p) {
        IFeed f = feedOf[token];
        if (address(f) == address(0)) revert NoFeed(token);
        if (f.isStale()) revert StaleFeed(token);
        (p,) = f.latestValue();
        if (p == 0) revert StaleFeed(token);
    }

    function _routeSwap(
        address route,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 keeperMinOut,
        address recipient
    ) internal returns (uint256 got) {
        if (tokenIn == tokenOut) revert TokenMismatch();
        uint256 minOut = Math.max(keeperMinOut, oracleMinOut(tokenIn, tokenOut, amountIn));
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(recipient);
        IERC20(tokenIn).forceApprove(route, amountIn);
        ISwapRoute(route).swap(tokenIn, tokenOut, amountIn, minOut, recipient);
        IERC20(tokenIn).forceApprove(route, 0);
        if (inBefore - IERC20(tokenIn).balanceOf(address(this)) > amountIn) revert TokenMismatch();
        got = IERC20(tokenOut).balanceOf(recipient) - outBefore;
        if (got < minOut) revert Slippage(got, minOut);
    }
}
