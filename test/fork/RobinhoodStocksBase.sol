// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployChain} from "../../script/DeployChain.s.sol";
import {DeployTypes, RobinhoodConfig} from "../../script/DeployConfig.sol";
import {Parameters} from "../../src/Parameters.sol";

/// @dev Stands in for the 4663 governance Safe (none exists yet), as in Robinhood.t.sol.
contract StockSafeStandIn {}

/// @notice Sells a stock token into a real Uniswap v4 pool on 4663 (exact input, one hop).
contract PoolSeller is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable pm;
    PoolKey internal _key;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function sell(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        _key = key;
        pm.unlock(abi.encode(zeroForOne, amountIn, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool zeroForOne, uint256 amountIn, address to) = abi.decode(data, (bool, uint256, address));
        BalanceDelta d = pm.swap(
            _key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _square(_key.currency0, BalanceDeltaLibrary.amount0(d), to);
        _square(_key.currency1, BalanceDeltaLibrary.amount1(d), to);
        return "";
    }

    function _square(Currency c, int128 delta, address to) private {
        if (delta < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(pm), uint128(-delta));
            pm.settle();
        } else if (delta > 0) {
            pm.take(c, to, uint128(delta));
        }
    }
}

/// @notice Shared set-up for the stock-token fork suites: RobinhoodConfig (stock types included) deployed through DeployChain on
/// a 4663 fork, clocks that walk the NYSE calendar with the keeper's 10-minute Pulse pokes, and the type's real Chainlink answer
/// re-stamped as time is warped (the feeds hold still between real updates; a moved answer is the scenario's price).
abstract contract RobinhoodStocksFork is Test {
    address internal constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // Uniswap v4 PoolManager on 4663
    // the issuer's role holders (AccessControl on the registry 0xe10b…1b00), read 2026-10-22: all EOAs
    address internal constant PAUSER = 0xFCcF56B674113d9C4eb0F9B3370930ceD9E6Ab23; // token pause()/unpause()
    address internal constant ORACLE_PAUSER = 0x7369d100c00F28E45D779ac9d4b1c7afa61e4aBC; // token pauseOracle()
    address internal constant BURNER = 0x957B6de6525C63349f7619743Ef1E0ad93cd74D4; // token adminBurn()
    address internal constant GLOBAL_PAUSER = 0xe7BCB188254Bc6eBBfF63014DfED4cD4A024F22A; // registry pause()
    address internal constant BLOCKER = 0x913cA87347391218e5De2C17c5A0AEba8B0b28fD; // registry blockAccounts()

    address internal alice = makeAddr("alice");
    address internal taker = makeAddr("taker");
    address internal safe;
    Deploy.Deployed internal d;
    uint256 internal spyIndex; // RobinhoodConfig.stocks() order: SPY first
    int256 internal spyAnswer; // the real SPY answer at the fork block
    bytes32 internal constant SPY = "STOCK-SPY";

    function _setUpFork() internal {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        safe = address(new StockSafeStandIn());
        DeployTypes.Config memory c = RobinhoodConfig.get();
        c.governor = safe;
        d = new DeployChain().deployAs(c, makeAddr("deployer"));
        (, spyAnswer,,,) = _round(RobinhoodConfig.CL_SPY);
    }

    function _round(address agg) internal view returns (uint80, int256, uint256, uint256, uint80) {
        (bool ok, bytes memory data) = agg.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok, "chainlink");
        return abi.decode(data, (uint80, int256, uint256, uint256, uint80));
    }

    /// @dev The SPY feed answers `usd8` as of now (a real round would; the answer is the scenario's).
    function _spy(int256 usd8) internal {
        vm.mockCall(
            RobinhoodConfig.CL_SPY,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), usd8, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
    }

    /// @dev Warp to `to`, the keeper poking the Pulse every 10 minutes on the way.
    function _walk(uint256 to) internal {
        while (vm.getBlockTimestamp() < to) {
            uint256 next = vm.getBlockTimestamp() + 10 minutes;
            vm.warp(next > to ? to : next);
            d.pulse.poke();
        }
    }

    /// @dev The next Friday's session close (16:00 New York, or 13:00 on an early close) after the fork block.
    function _nextFridayClose() internal view returns (uint256) {
        uint256 day = vm.getBlockTimestamp() / 1 days + 1;
        while ((day + 4) % 7 != 5 || !d.calendar.isOpen(day * 1 days + 17 hours)) ++day;
        uint256 t = day * 1 days + 17 hours;
        while (d.calendar.isOpen(t)) t += 5 minutes;
        return t;
    }

    /// @dev The first open minute at or after `t`.
    function _nextOpen(uint256 t) internal view returns (uint256) {
        t = t / 5 minutes * 5 minutes;
        while (!d.calendar.isOpen(t)) t += 5 minutes;
        return t;
    }

    /// @dev Real SPY tokens and USDG, moved out of the v4 PoolManager's balances (it holds every pool's reserves).
    function _give(address token, address to, uint256 amount) internal {
        vm.prank(PM);
        IERC20(token).transfer(to, amount);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        IERC20(RobinhoodConfig.SPY).approve(address(d.ledger), type(uint256).max);
        IERC20(RobinhoodConfig.USDG).approve(address(d.stockJoins[spyIndex]), type(uint256).max);
        vm.stopPrank();
    }

    function _spyPoolKey() internal pure returns (PoolKey memory) {
        // poolId 0xfe2a…26cd: SPY (currency0) / USDG, fee 0.30%, spacing 60, no hooks: $0.98M of bid depth within -5%
        return PoolKey(
            Currency.wrap(RobinhoodConfig.SPY), Currency.wrap(RobinhoodConfig.USDG), 3000, 60, IHooks(address(0))
        );
    }
}
