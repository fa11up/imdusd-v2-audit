// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {System} from "./System.sol";
import {MockERC20, MockLiveAggregator} from "./Mocks.sol";
import {PegHook, IKeeperCap} from "../../src/peg/PegHook.sol";

/// @dev The smallest router: one unlock per action, settling what it owes and taking what it is owed.
contract PegRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function addLiquidity(PoolKey memory key, ModifyLiquidityParams memory p) external {
        pm.unlock(abi.encode(true, key, abi.encode(p)));
    }

    function swap(PoolKey memory key, SwapParams memory p) external returns (BalanceDelta d) {
        d = abi.decode(pm.unlock(abi.encode(false, key, abi.encode(p))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external virtual returns (bytes memory) {
        (bool liquidity, PoolKey memory key, bytes memory inner) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta d;
        if (liquidity) (d,) = pm.modifyLiquidity(key, abi.decode(inner, (ModifyLiquidityParams)), "");
        else d = pm.swap(key, abi.decode(inner, (SwapParams)), "");
        _square(key.currency0, BalanceDeltaLibrary.amount0(d));
        _square(key.currency1, BalanceDeltaLibrary.amount1(d));
        return abi.encode(d);
    }

    function _square(Currency c, int128 delta) internal {
        if (delta < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(pm), uint128(-delta));
            pm.settle();
        } else if (delta > 0) {
            pm.take(c, address(this), uint128(delta));
        }
    }
}

/// @dev Tries to drive the keeper from inside a PoolManager unlock (i.e. from a swap's callback context).
contract ReentryRouter is PegRouter {
    PegHook immutable hook;
    uint8 public mode; // 1 = provide, 2 = withdraw, 3 = sweep

    constructor(IPoolManager pm_, PegHook hook_) PegRouter(pm_) {
        hook = hook_;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (bool liquidity, PoolKey memory key, bytes memory inner) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta d = pm.swap(key, abi.decode(inner, (SwapParams)), "");
        liquidity;
        if (mode == 1) hook.provide();
        else if (mode == 2) hook.withdraw();
        else if (mode == 3) hook.sweep(key.currency0);
        _square(key.currency0, BalanceDeltaLibrary.amount0(d));
        _square(key.currency1, BalanceDeltaLibrary.amount1(d));
        return abi.encode(d);
    }
}

/// @notice v2 system + the peg pool: deploys the hook at a mined CREATE2 address, wires it as the keeper minter
/// through the 48h timelock, opens the pool at $1 and seeds a band of liquidity.
abstract contract PegSystem is System {
    using StateLibrary for IPoolManager;

    IPoolManager internal pm;
    IERC20 internal usdc;
    PegHook internal hook;
    /// @dev The quote stablecoin's USD feed the hook gates on (8 decimals, $1, always fresh unless a test ages it).
    MockLiveAggregator internal quoteUsd;
    uint256 internal constant QUOTE_MAX_AGE = 1 days + 1 hours;
    PegRouter internal router;
    PoolKey internal key;
    /// @dev imdUSD that exists outside the keeper (the LP's and traders', dealt in tests).
    uint256 internal baseSupply;

    function _deployPeg(IPoolManager pm_, IERC20 usdc_, uint256 cap) internal {
        pm = pm_;
        usdc = usdc_;
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        params.seal();
        _openPeg(cap);
        _fund(address(router), 50_000_000e18, 50_000_000e6);
        // ±1000 ticks (~±10%) around the peg, about 1M of each side.
        int24 t = hook.pegTick();
        router.addLiquidity(key, ModifyLiquidityParams(t - 1000, t + 1000, 2e19, 0));
    }

    /// @dev On a sealed system: mine + deploy the hook, name it keeper minter and set its cap (each through the
    /// timelock), open the pool at $1. No liquidity: the caller adds its own.
    function _openPeg(uint256 cap) internal {
        hook = _mineHook();
        // The keeper minter and its cap, each through the timelock.
        bytes memory pk = abi.encode(params.SET_KEEPER(), address(hook));
        vm.prank(governor);
        params.propose(pk);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        bytes memory pc = abi.encode(params.SET_KEEPER_CAP(), cap);
        vm.prank(governor);
        params.propose(pc);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();

        router = new PegRouter(pm);
        (address c0, address c1) =
            hook.stableIsToken0() ? (address(usd), address(usdc)) : (address(usdc), address(usd));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 100, 1, IHooks(address(hook)));
        pm.initialize(key, hook.pegSqrtPriceX96());
    }

    function _mineHook() internal returns (PegHook h) {
        if (address(quoteUsd) == address(0)) quoteUsd = new MockLiveAggregator(8, 1e8);
        bytes memory args = abi.encode(
            pm, address(usd), address(usdc), address(treasury), IKeeperCap(address(params)), address(quoteUsd), QUOTE_MAX_AGE
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(PegHook).creationCode, args));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        for (uint256 salt;; ++salt) {
            address a = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags && a.code.length == 0) {
                h = new PegHook{salt: bytes32(salt)}(
                    pm,
                    address(usd),
                    address(usdc),
                    address(treasury),
                    IKeeperCap(address(params)),
                    address(quoteUsd),
                    QUOTE_MAX_AGE
                );
                require(address(h) == a, "mined address");
                return h;
            }
        }
    }

    /// @dev Set the buffer target through the timelock, the way the Safe does after launch.
    function _setBufferTarget(uint256 target) internal {
        bytes memory pb = abi.encode(params.SET_BUFFER_TARGET(), target);
        vm.prank(governor);
        params.propose(pb);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
    }

    function _fund(address to, uint256 stableAmt, uint256 quoteAmt) internal virtual {
        deal(address(usd), to, usd.balanceOf(to) + stableAmt, true);
        baseSupply += stableAmt;
        deal(address(usdc), to, usdc.balanceOf(to) + quoteAmt);
    }

    // ------------------------------------------------------------ trading helpers

    /// @dev Swap until the stable's price is `ticks` from the peg (positive = above $1).
    function _moveTo(int24 ticks) internal {
        int24 t = hook.pegTick();
        uint160 limit = TickMath.getSqrtPriceAtTick(hook.stableIsToken0() ? t + ticks : t - ticks);
        (uint160 now_,,,) = pm.getSlot0(key.toId());
        if (now_ == limit) return;
        // zeroForOne lowers the raw price.
        router.swap(key, SwapParams(limit < now_, -int256(1e30), limit));
    }

    /// @dev The stable's spot price, 1e18 = $1.
    function _spotPrice() internal view returns (uint256) {
        (uint160 sp,,,) = pm.getSlot0(key.toId());
        return hook.stablePrice(sp);
    }

    /// @dev A small swap that records an observation without moving the price meaningfully.
    function _poke() internal {
        bool zeroForOne = true;
        router.swap(key, SwapParams(zeroForOne, -int256(uint256(hook.stableIsToken0() ? 1e12 : 1)), TickMath.MIN_SQRT_PRICE + 1));
    }

    /// @dev Hold the price at `ticks` for `secs`, poking once a minute so observations are written.
    function _hold(int24 ticks, uint256 secs) internal {
        for (uint256 s; s < secs; s += 60) {
            _moveTo(ticks);
            _poke();
            vm.warp(vm.getBlockTimestamp() + 60);
            vm.roll(vm.getBlockNumber() + 5);
        }
        _moveTo(ticks);
    }

    function _assertKeeperSolvent() internal view {
        assertGe(usdc.balanceOf(address(hook)), hook.principal() + hook.buffer(), "keeper USDC >= outstanding at $1 + buffer");
        // Supply equation, peg keeper term: dealt imdUSD + keeper outstanding (no positions in these tests). imdUSD the
        // buffer bought is HELD by the Treasury, so it is part of the dealt supply: no extra term.
        assertEq(usd.totalSupply(), baseSupply + hook.outstanding(), "supply == base + keeper outstanding");
    }
}
