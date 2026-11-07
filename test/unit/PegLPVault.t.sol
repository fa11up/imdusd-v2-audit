// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PegSystem} from "../utils/PegSystem.sol";
import {PegLPVault, IPegHookView} from "../../src/earn/PegLPVault.sol";
import {Shield} from "../utils/Shield.sol";

/// @dev Donates to in-range liquidity (meme markets pay at-peg LPs this way).
contract Donor is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function donate(PoolKey memory key, uint256 a0, uint256 a1) external {
        pm.unlock(abi.encode(key, a0, a1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 a0, uint256 a1) = abi.decode(data, (PoolKey, uint256, uint256));
        BalanceDelta d = pm.donate(key, a0, a1, "");
        if (d.amount0() < 0) _pay(key.currency0, uint128(-d.amount0()));
        if (d.amount1() < 0) _pay(key.currency1, uint128(-d.amount1()));
        return "";
    }

    function _pay(Currency c, uint256 amt) private {
        pm.sync(c);
        IERC20(Currency.unwrap(c)).safeTransfer(address(pm), amt);
        pm.settle();
    }
}

/// @notice The peg-LP vault against a local v4 PoolManager and the real PegHook. Both token orders.
abstract contract PegLPVaultTest is PegSystem {
    using StateLibrary for IPoolManager;

    PegLPVault vault;
    IERC20 t0;
    IERC20 t1;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function _quoteAddr() internal pure virtual returns (address);

    function setUp() public {
        vm.warp(1_800_000_000);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("USDC", uint8(6)), _quoteAddr());
        _deployPeg(IPoolManager(address(new PoolManager(address(this)))), IERC20(_quoteAddr()), 1e24);
        _hold(0, 31 minutes);
        vault = new PegLPVault(pm, IPegHookView(address(hook)), address(treasury), 100);
        t0 = vault.token0();
        t1 = vault.token1();
        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, eve][i];
            _fund(u, 10_000_000e18, 10_000_000e6);
            vm.startPrank(u);
            t0.approve(address(vault), type(uint256).max);
            t1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    /// @dev Dollar value at $1 each, 1e18.
    function _usd(uint256 a0, uint256 a1) internal view returns (uint256) {
        (uint256 s, uint256 q) = address(t0) == address(usd) ? (a0, a1) : (a1, a0);
        return s + q * 1e12;
    }

    function _amounts(uint256 stableAmt, uint256 quoteAmt) internal view returns (uint256, uint256) {
        return address(t0) == address(usd) ? (stableAmt, quoteAmt) : (quoteAmt, stableAmt);
    }

    function _seed(address u, uint256 dollars) internal returns (uint256 shares) {
        (uint256 a0, uint256 a1) = _amounts(dollars * 1e18, dollars * 1e6);
        vm.prank(u);
        (shares,,) = vault.deposit(0, a0, a1, u);
    }

    function _buy(address u, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        vm.prank(u);
        (, a0, a1) = vault.deposit(shares, type(uint256).max, type(uint256).max, u);
    }

    function _sell(address u, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        vm.prank(u);
        (a0, a1) = vault.withdraw(shares, 0, 0, u);
    }

    /// @dev Trade back and forth inside the band (no surcharge) to earn fees.
    function _churn(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _moveTo(20);
            _moveTo(-20);
        }
        _moveTo(0);
    }

    function _vaultUsd() internal view returns (uint256) {
        (uint256 a0, uint256 a1) = vault.totals();
        return _usd(a0, a1);
    }

    // ------------------------------------------------------------ deposits and withdrawals

    function test_firstDepositMintsLiquidityLessDeadShares() public {
        uint256 shares = _seed(alice, 100_000);
        assertEq(vault.balanceOf(address(0xdEaD)), vault.DEAD_SHARES());
        assertEq(shares + vault.DEAD_SHARES(), vault.totalSupply());
        assertGt(vault.liquidity(), 0);
        // At the peg in a symmetric band nearly everything is deployed.
        assertApproxEqRel(_vaultUsd(), 200_000e18, 0.001e18);
    }

    function test_roundTripAtSamePriceLosesOnlyRounding() public {
        _seed(alice, 100_000);
        uint256 s = vault.totalSupply() / 4;
        uint256 b0 = t0.balanceOf(bob);
        uint256 b1 = t1.balanceOf(bob);
        (uint256 in0, uint256 in1) = _buy(bob, s);
        assertEq(b0 - t0.balanceOf(bob), in0);
        assertEq(b1 - t1.balanceOf(bob), in1);
        (uint256 out0, uint256 out1) = _sell(bob, s);
        assertLe(out0, in0);
        assertLe(out1, in1);
        assertApproxEqAbs(_usd(in0, in1) - _usd(out0, out1), 0, 2e12, "loss <= a few wei of USDC");
    }

    function test_depositPaysProportionally() public {
        _seed(alice, 100_000);
        (uint256 T0, uint256 T1) = vault.totals();
        uint256 supply = vault.totalSupply();
        (uint256 a0, uint256 a1) = _buy(bob, supply / 2);
        // Within 1e-12 + 1 wei (ceil, and idle wei compounded before pricing).
        assertApproxEqAbs(a0, T0 / 2, T0 / 1e12 + 1);
        assertApproxEqAbs(a1, T1 / 2, T1 / 1e12 + 1);
    }

    function test_slippageBoundsHold() public {
        _seed(alice, 100_000);
        uint256 s = vault.totalSupply() / 2;
        (uint256 p0, uint256 p1) = vault.previewDeposit(s);
        vm.prank(bob);
        vm.expectRevert(PegLPVault.Slippage.selector);
        vault.deposit(s, p0 / 2, p1, bob);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(PegLPVault.Slippage.selector);
        vault.withdraw(all, type(uint256).max, 0, alice);
    }

    // ------------------------------------------------------------ fees

    function test_feesCompoundAndTreasuryGetsTenPercent() public {
        uint256 shares = _seed(alice, 100_000);
        uint256 before = _vaultUsd();
        uint256 tr0 = t0.balanceOf(address(treasury));
        uint256 tr1 = t1.balanceOf(address(treasury));
        vm.recordLogs();
        _churn(20);
        vault.compound();
        uint256 gainVault = _vaultUsd() - before;
        uint256 gainTreasury = _usd(t0.balanceOf(address(treasury)) - tr0, t1.balanceOf(address(treasury)) - tr1);
        assertGt(gainVault, 0, "fees compounded");
        // treasury = 10% of fees, vault keeps 90% (within rounding).
        assertApproxEqRel(gainTreasury * 9, gainVault, 0.01e18, "10/90 split");
        // Alice's whole stake now redeems for more than she put in.
        (uint256 o0, uint256 o1) = _sell(alice, shares);
        assertGt(_usd(o0, o1), 199_000e18);
    }

    function test_lateDepositorDoesNotShareEarlierFees() public {
        uint256 sa = _seed(alice, 100_000);
        _churn(20); // fees accrued, not collected yet
        uint256 sb = vault.totalSupply() / 2;
        (uint256 in0, uint256 in1) = _buy(bob, sb); // collects first, so bob pays for them
        (uint256 out0, uint256 out1) = _sell(bob, sb);
        assertLe(_usd(out0, out1), _usd(in0, in1), "bob takes nothing of alice's fees");
        (uint256 a0, uint256 a1) = _sell(alice, sa);
        assertGt(_usd(a0, a1), 200_000e18 - 1e18, "alice keeps her fees");
    }

    function test_donationReachesVaultInRange() public {
        _seed(alice, 100_000);
        Donor donor = new Donor(pm);
        (uint256 d0, uint256 d1) = _amounts(10_000e18, 0);
        deal(address(t0), address(donor), d0);
        deal(address(t1), address(donor), d1);
        if (address(t0) == address(usd)) baseSupply += d0;
        else baseSupply += d1;
        uint128 total = pm.getLiquidity(key.toId());
        uint128 mine = vault.liquidity();
        uint256 before = _vaultUsd();
        uint256 trBefore = usd.balanceOf(address(treasury));
        donor.donate(key, d0, d1);
        vault.compound();
        uint256 expected = 10_000e18 * uint256(mine) / uint256(total);
        assertApproxEqRel(_vaultUsd() - before, expected * 9 / 10, 0.001e18, "vault gets its in-range share, 90%");
        assertApproxEqRel(usd.balanceOf(address(treasury)) - trBefore, expected / 10, 0.001e18, "Treasury 10%");
        // The one-sided imdUSD was half swapped and put to work: little is left idle.
        uint256 idle = usd.balanceOf(address(vault));
        assertLt(idle, expected / 20, "most of the donation deployed");
    }

    // ------------------------------------------------------------ manipulation

    function test_depositRefusedWhileSpotOffTwap() public {
        _seed(alice, 100_000);
        _moveTo(30); // pushed this block: the TWAP has not seen it
        uint256 s = vault.totalSupply() / 2;
        vm.prank(bob);
        vm.expectPartialRevert(PegLPVault.OffTwap.selector);
        vault.deposit(s, type(uint256).max, type(uint256).max, bob);
        vm.expectPartialRevert(PegLPVault.OffTwap.selector);
        vault.compound();
        // Withdrawals stay open.
        _sell(alice, vault.balanceOf(alice));
    }

    /// @dev The attack the gate stops, run where it would otherwise pay: push the price 10 ticks (the gate's edge),
    /// buy shares, push back, sell. The attacker must not end ahead (swap fees > the position's 10-tick loss).
    function test_pushDepositPushBackDoesNotPay() public {
        _seed(alice, 1_000_000);
        uint256 e0 = t0.balanceOf(eve);
        uint256 e1 = t1.balanceOf(eve);
        uint256 r0 = t0.balanceOf(address(router));
        uint256 r1 = t1.balanceOf(address(router));
        _moveTo(hook.twapTicks() + vault.MAX_SPOT_TWAP_TICKS()); // the gate's edge
        uint256 s = vault.totalSupply();
        _buy(eve, s);
        _moveTo(0);
        _sell(eve, s);
        // The router's swaps are eve's too.
        int256 pnl = int256(_usd(t0.balanceOf(eve), t1.balanceOf(eve))) - int256(_usd(e0, e1))
            + int256(_usd(t0.balanceOf(address(router)), t1.balanceOf(address(router)))) - int256(_usd(r0, r1));
        assertLe(pnl, 0, "attack loses");
    }

    function test_inflationAttackFails() public {
        // Eve opens with the smallest deposit that mints, then donates a large amount straight to the vault.
        (uint256 a0, uint256 a1) = _amounts(1e15, 1e3);
        vm.prank(eve);
        (uint256 es,,) = vault.deposit(0, a0, a1, eve);
        (uint256 g0, uint256 g1) = _amounts(100_000e18, 100_000e6);
        vm.startPrank(eve);
        t0.transfer(address(vault), g0);
        t1.transfer(address(vault), g1);
        vm.stopPrank();
        // Bob still buys a fair slice.
        uint256 s = vault.totalSupply();
        (uint256 in0, uint256 in1) = _buy(bob, s);
        (uint256 o0, uint256 o1) = _sell(bob, s);
        assertApproxEqRel(_usd(o0, o1), _usd(in0, in1), 0.0001e18, "bob whole");
        (uint256 x0, uint256 x1) = _sell(eve, es);
        assertLe(_usd(x0, x1), _usd(g0, g1) + _usd(a0, a1), "eve gains nothing");
    }

    // ------------------------------------------------------------ out of band

    function test_belowBandVaultHoldsOnlyImdUSD() public {
        uint256 shares = _seed(alice, 100_000);
        _hold(-150, 31 minutes); // $0.985 for the window: below the band
        (uint256 T0, uint256 T1) = vault.totals();
        (uint256 s, uint256 q) = address(t0) == address(usd) ? (T0, T1) : (T1, T0);
        assertGt(s, 190_000e18, "bought imdUSD all the way down");
        assertLt(q, 10e6, "no USDC left in the position");
        _sell(alice, shares); // exit open out of band
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_onlyPoolManagerCallsBack() public {
        vm.expectRevert(PegLPVault.NotPoolManager.selector);
        vault.unlockCallback(abi.encode(uint8(0), uint128(0)));
    }

    function test_constructorChecks() public {
        vm.expectRevert(PegLPVault.BadBand.selector);
        new PegLPVault(pm, IPegHookView(address(hook)), address(treasury), 0);
        vm.expectRevert(PegLPVault.ZeroAddress.selector);
        new PegLPVault(pm, IPegHookView(address(hook)), address(0), 100);
    }

    // ------------------------------------------------------------ fuzz

    /// @dev Random deposits, withdrawals and churn by two users: every share redeems for no more than its slice, and
    /// whatever is left after everyone exits is the dead shares' (no stranded or created value beyond rounding).
    function testFuzz_noValueCreated(uint256 seed) public {
        _seed(alice, 50_000);
        uint256 spent;
        uint256 got;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 3;
            if (op == 0) {
                uint256 s = 1e6 + (seed >> 8) % (vault.totalSupply() / 2);
                (uint256 a0, uint256 a1) = _buy(bob, s);
                spent += _usd(a0, a1);
            } else if (op == 1 && vault.balanceOf(bob) != 0) {
                uint256 s = 1 + (seed >> 8) % vault.balanceOf(bob);
                (uint256 a0, uint256 a1) = _sell(bob, s);
                got += _usd(a0, a1);
            } else {
                _moveTo(int24(int256((seed >> 16) % 41)) - 20);
                _moveTo(0);
            }
        }
        if (vault.balanceOf(bob) != 0) {
            (uint256 a0, uint256 a1) = _sell(bob, vault.balanceOf(bob));
            got += _usd(a0, a1);
        }
        // Bob shared in fees while in, so allow a small gain; never more than the fees the pool paid the vault.
        assertLe(got, spent + _usd(t0.balanceOf(address(treasury)), t1.balanceOf(address(treasury))) * 9 + 1e13);
        _sell(alice, vault.balanceOf(alice));
        assertEq(vault.totalSupply(), vault.DEAD_SHARES());
    }

    // ------------------------------------------------------------ shares can be shielded

    /// Shares minted in a transaction can be pulled by a shielded pool, paid out to someone else and redeemed, all in the
    /// same block: no hold, no transfer fee, no hook. A shielded pool holding the shares keeps the liquidity working.
    function test_sharesShieldInTheBlockTheyAreMinted() public {
        _seed(alice, 100_000);
        uint256 shares = vault.totalSupply() / 4;
        (uint256 p0, uint256 p1) = _buy(bob, shares);
        Shield pool = new Shield();
        vm.startPrank(bob);
        vault.approve(address(pool), shares);
        pool.shield(IERC20(address(vault)), shares);
        vm.stopPrank();
        assertEq(vault.balanceOf(address(pool)), shares);
        pool.unshield(IERC20(address(vault)), eve, shares);
        (uint256 a0, uint256 a1) = _sell(eve, shares);
        assertApproxEqRel(_usd(a0, a1), _usd(p0, p1), 0.0001e18);
    }
}

contract PegLPVaultStable0Test is PegLPVaultTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }
}

contract PegLPVaultStable1Test is PegLPVaultTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001);
    }
}
