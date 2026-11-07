// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {RobinhoodFork} from "./Robinhood.t.sol";
import {RobinhoodConfig} from "../../script/DeployConfig.sol";
import {DeployChain} from "../../script/DeployChain.s.sol";
import {DeployTypes} from "../../script/DeployConfig.sol";
import {PegRouter} from "../utils/PegSystem.sol";
import {PegHook} from "../../src/peg/PegHook.sol";
import {SafeStandIn} from "./Robinhood.t.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice The imdUSD/USDG peg pool + PegHook as DeployRobinhood builds them, on the REAL 4663 Uniswap v4
/// PoolManager with REAL USDG. Liquidity is added, swaps run through the hook, a swap past the ±0.25% band pays the surcharge
/// and anyone sweeps it to the 4663 Treasury. Skipped unless ROBINHOOD_RPC_URL is set:
///   ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/fork/RobinhoodPeg.t.sol
contract RobinhoodPegForkTest is RobinhoodFork {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(RobinhoodConfig.UNIV4_POOL_MANAGER);
    PegRouter router;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    bytes32 salt;

    function setUp() public {
        _forkRobinhood();
        if (!live) return;
        safe = address(new SafeStandIn());
        DeployTypes.Config memory c = RobinhoodConfig.get();
        c.governor = safe;
        DeployChain script = new DeployChain();
        d = script.deployAs(c, deployer);
        salt = script.pegHookSalt();
        _freshChainlink();
        router = new PegRouter(PM);
        // the LP's imdUSD is borrowed against real WETH (no supply is conjured, so the supply equation is checked as-is)
        deal(RobinhoodConfig.WETH, alice, 30e18);
        _approve(RobinhoodConfig.WETH);
        _adjust("ETH", 30e18, 19_900e18, false); // under the 20k ETH line once its upfront fee is added
    }

    function _usdg() internal pure returns (IERC20) {
        return IERC20(RobinhoodConfig.USDG);
    }

    function _spot() internal view returns (uint256) {
        (uint160 sp,,,) = PM.getSlot0(d.pegKey.toId());
        return d.hook.stablePrice(sp);
    }

    function _addLiquidity(int24 halfWidth, uint256 liquidity) internal {
        vm.startPrank(alice);
        d.usd.transfer(address(router), 12_000e18);
        vm.stopPrank();
        deal(RobinhoodConfig.USDG, address(router), 12_000e6);
        int24 t = d.hook.pegTick();
        router.addLiquidity(d.pegKey, ModifyLiquidityParams(t - halfWidth, t + halfWidth, int256(liquidity), bytes32(0)));
    }

    /// @dev Exact input of `usdgIn` USDG for imdUSD (pushes the imdUSD price up).
    function _buyImdUsd(uint256 usdgIn) internal returns (uint256 got) {
        deal(RobinhoodConfig.USDG, address(router), _usdg().balanceOf(address(router)) + usdgIn);
        bool zeroForOne = Currency.unwrap(d.pegKey.currency0) == RobinhoodConfig.USDG;
        uint256 before = d.usd.balanceOf(address(router));
        router.swap(
            d.pegKey,
            SwapParams(zeroForOne, -int256(usdgIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
        got = d.usd.balanceOf(address(router)) - before;
    }

    function test_pegPoolDeployedAtOneDollar() public {
        assertTrue(address(d.hook) != address(0), "PegHook deployed");
        assertEq(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK, d.hook.FLAGS(), "mined address carries exactly its flags");
        assertEq(d.hook.stable(), address(d.usd));
        assertEq(d.hook.quote(), RobinhoodConfig.USDG);
        assertEq(d.hook.treasury(), address(d.treasury));
        assertEq(address(d.hook.params()), address(d.params));
        assertEq(address(d.hook.poolManager()), RobinhoodConfig.UNIV4_POOL_MANAGER);
        assertTrue(d.hook.initialized());
        assertEq(d.usd.keeper(), address(d.hook), "the hook is the keeper minter");
        assertEq(d.params.keeperCap(), 0, "and may mint nothing until the Safe raises the cap");
        assertEq(d.hook.buffer(), 0);
        (uint160 sp,,,) = PM.getSlot0(d.pegKey.toId());
        assertEq(sp, d.hook.pegSqrtPriceX96(), "opened at exactly $1");
        assertEq(d.pegKey.fee, 100);
        assertEq(address(d.notes.quote()), RobinhoodConfig.USDG, "fee notes sold for USDG (dormant)");
        emit log_named_address("4663 PegHook (this rehearsal)", address(d.hook));
        emit log_named_bytes32("its CREATE2 salt", salt);
        emit log_named_bytes32("pool id", PoolId.unwrap(d.pegKey.toId()));
        assertEq(d.usd.totalSupply(), d.ledger.debtOf(_pid("ETH", alice)), "nothing minted by genesis");
    }

    function test_swapsThroughTheHookAndSurchargeSwept() public {
        _addLiquidity(100, 2e18); // ~10k of each token over ±1%
        // inside the band: the base fee only, nothing accrues to the hook
        uint256 got = _buyImdUsd(1_000e6);
        assertGt(got, 995e18, "about $1 per imdUSD at the peg");
        assertLt(_spot(), 1.0025e18, "still inside the band");
        assertEq(PM.balanceOf(address(d.hook), d.pegKey.currency0.toId()) + PM.balanceOf(address(d.hook), d.pegKey.currency1.toId()), 0);
        // past the band: the surcharge is minted to the hook as ERC-6909 claims
        _buyImdUsd(5_000e6);
        assertGt(_spot(), 1.0025e18, "pushed past +0.25%");
        uint256 claims = PM.balanceOf(address(d.hook), d.pegKey.currency0.toId()) + PM.balanceOf(address(d.hook), d.pegKey.currency1.toId());
        assertGt(claims, 0, "surcharge accrued");
        uint256 t0 = _usdg().balanceOf(address(d.treasury)) + d.usd.balanceOf(address(d.treasury)) / 1e12;
        vm.prank(trader);
        d.hook.sweep(d.pegKey.currency0);
        vm.prank(trader);
        d.hook.sweep(d.pegKey.currency1);
        assertGt(_usdg().balanceOf(address(d.treasury)) + d.usd.balanceOf(address(d.treasury)) / 1e12, t0, "swept to the Treasury");
        _supplyHolds();
    }

    /// @dev The keeper is wired but capped at 0: above the band, `provide` mints nothing (the cap is a 48h Safe act).
    function test_keeperInertAtGenesis() public {
        _addLiquidity(100, 2e18); // ~10k of each token over ±1%
        for (uint256 i; i < 40; ++i) {
            _buyImdUsd(i == 0 ? 4_000e6 : 1e6);
            vm.warp(vm.getBlockTimestamp() + 60);
            vm.roll(vm.getBlockNumber() + 5);
        }
        assertGt(_spot(), 1.0025e18);
        // Fix A4: the hook gates on the real 4663 USDG/USD feed, sound here, so the cap is what stops it.
        assertEq(d.hook.quoteUsdFeed(), RobinhoodConfig.CL_USDG_USD);
        assertEq(d.hook.quoteFeedMaxAge(), RobinhoodConfig.CL_MAX_AGE);
        assertTrue(d.hook.quoteSound(), "USDG/USD fresh and >= $0.98");
        vm.expectRevert(PegHook.CapReached.selector);
        d.hook.provide();
        assertEq(d.hook.outstanding(), 0);
    }
}
