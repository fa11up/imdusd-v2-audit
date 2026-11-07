// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PegSystem} from "../utils/PegSystem.sol";
import {PegLPVault, IPegHookView} from "../../src/earn/PegLPVault.sol";

/// @notice Regressions from an earlier internal review, area earn-vaults,
/// turned from its PoC. Every test here FAILED before the fix.
///
/// E1 (medium): once the real supply was back to the dead shares, every later deposit had to match whatever dust the dead
/// shares owned: a $0.002 front-run before the seeder's deposit, or the seeder's own full exit, left a vault that only took
/// single-sided deposits. Now `supply == DEAD_SHARES` takes the first-deposit path again (as LoopVault does), and a first
/// deposit pulls the BAND's proportion of max0/max1, never the depositor's.
/// E2 (low): the balancing swap's limit was ±20 ticks from the PEG, so a refill could run the pool 39 ticks and trip the
/// vault's own ±10-tick TWAP gate for ~30 minutes. Now the limit is the nearer of peg ± 20 and TWAP ± 10.
abstract contract PegLPVaultReviewTest is PegSystem {
    PegLPVault vault;
    IERC20 t0;
    IERC20 t1;
    address alice = makeAddr("alice");
    address eve = makeAddr("eve");
    address team = makeAddr("team");

    function _quoteAddr() internal pure virtual returns (address);

    function setUp() public {
        vm.warp(1_800_000_000);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("USDC", uint8(6)), _quoteAddr());
        _deployPeg(IPoolManager(address(new PoolManager(address(this)))), IERC20(_quoteAddr()), 1e24);
        _hold(0, 31 minutes);
        vault = new PegLPVault(pm, IPegHookView(address(hook)), address(treasury), 100);
        t0 = vault.token0();
        t1 = vault.token1();
        address[3] memory us = [alice, eve, team];
        for (uint256 i; i < 3; ++i) {
            _fund(us[i], 10_000_000e18, 10_000_000e6);
            vm.startPrank(us[i]);
            t0.approve(address(vault), type(uint256).max);
            t1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Dollar value at $1 each, 1e18.
    function _usd(uint256 a0, uint256 a1) internal view returns (uint256) {
        (uint256 s, uint256 q) = address(t0) == address(usd) ? (a0, a1) : (a1, a0);
        return s + q * 1e12;
    }

    function _amounts(uint256 stableAmt, uint256 quoteAmt) internal view returns (uint256, uint256) {
        return address(t0) == address(usd) ? (stableAmt, quoteAmt) : (quoteAmt, stableAmt);
    }

    /// @dev The quote's (USDC's) share of a two-token amount, in bps of its dollar value.
    function _quoteShareBps(uint256 a0, uint256 a1) internal view returns (uint256) {
        (, uint256 q) = address(t0) == address(usd) ? (a0, a1) : (a1, a0);
        return q * 1e12 * 1e4 / _usd(a0, a1);
    }

    function _idleUsd() internal view returns (uint256) {
        return _usd(t0.balanceOf(address(vault)), t1.balanceOf(address(vault)));
    }

    /// @dev Shares that cost about `dollars` at the vault's current proportion.
    function _sharesForDollars(uint256 dollars) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = vault.totals();
        return dollars * 1e18 * vault.totalSupply() / _usd(a0, a1);
    }

    // ------------------------------------------------------------ E1

    /// @notice E1a: eve is first in with the smallest deposit that mints and straight out again; the seeder's two-sided seed
    /// still lands (first-deposit path), about 50/50, nearly all deployed, and the vault's gate stays open.
    function test_frontRunDustThenExit_teamSeedStillTwoSided() public {
        (uint256 d0, uint256 d1) = _amounts(1e15, 1e3); // 0.001 imdUSD + 0.001 USDC
        vm.prank(eve);
        (uint256 es,,) = vault.deposit(0, d0, d1, eve);
        vm.prank(eve);
        vault.withdraw(es, 0, 0, eve);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES(), "only the dead shares remain");

        (uint256 s0, uint256 s1) = _amounts(50_000e18, 50_000e6);
        vm.prank(team);
        (uint256 minted, uint256 p0, uint256 p1) = vault.deposit(0, s0, s1, team);
        assertGt(minted, 0, "the seed mints");
        assertEq(vault.totalSupply(), minted + vault.DEAD_SHARES(), "no second dead mint");
        uint256 share = _quoteShareBps(p0, p1);
        assertTrue(share > 4500 && share < 5500, "the band's proportion at the peg, not the dust's");
        assertApproxEqRel(_usd(p0, p1), 100_000e18, 0.001e18, "both maxima nearly used");
        assertLt(_idleUsd(), 1e18, "deployed, not parked");
        // Nothing was swapped, so the spot did not move and the vault's own gate still admits everyone.
        assertEq(hook.spotTicks(), 0);
        vault.compound();
        vm.prank(alice);
        vault.deposit(minted / 10, type(uint256).max, type(uint256).max, alice);
    }

    /// @notice E1b: no attacker. The sole LP exits above the band (the position was all USDC); the next depositor is a
    /// first depositor again and gets a two-sided position at the peg.
    function test_soleLpExitsAboveBand_thenVaultReseeds() public {
        (uint256 a0, uint256 a1) = _amounts(100_000e18, 100_000e6);
        vm.prank(alice);
        (uint256 as_,,) = vault.deposit(0, a0, a1, alice);
        _hold(150, 31 minutes); // $1.015 for the window: the position is all USDC
        vm.prank(alice);
        vault.withdraw(as_, 0, 0, alice);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES());
        _hold(0, 31 minutes); // back at the peg, TWAP settled

        vm.prank(team);
        (uint256 minted, uint256 p0, uint256 p1) = vault.deposit(0, a0, a1, team);
        assertGt(minted, 0);
        uint256 share = _quoteShareBps(p0, p1);
        assertTrue(share > 4500 && share < 5500, "a sane two-sided deposit exists again");
        // The seeder owns the whole vault but the dead shares' dust (worth well under a cent).
        (uint256 v0, uint256 v1) = vault.totals();
        assertApproxEqRel(_usd(v0, v1) * minted / vault.totalSupply(), _usd(p0, p1), 0.0001e18, "the seed owns what it paid");
    }

    /// @notice E1c: a lopsided first deposit (1 unit of USDC against 0.001 imdUSD) cannot set the proportion every later
    /// deposit must match: the first deposit pulls the band's proportion of what max0/max1 can buy.
    function test_lopsidedFirstDepositDoesNotBendTheProportion() public {
        (uint256 d0, uint256 d1) = _amounts(1e15, 1);
        vm.prank(eve);
        (, uint256 e0, uint256 e1) = vault.deposit(0, d0, d1, eve);
        uint256 share = _quoteShareBps(e0, e1);
        assertTrue(share > 4000 && share < 6000, "eve's deposit was cut to the band's proportion");
        // The seeder's proportional deposit is therefore two-sided too.
        uint256 s = _sharesForDollars(100_000);
        (uint256 p0, uint256 p1) = vault.previewDeposit(s);
        share = _quoteShareBps(p0, p1);
        assertTrue(share > 4000 && share < 6000, "about 50/50 at the peg");
        vm.prank(team);
        vault.deposit(s, p0 + 1, p1 + 1, team);
        assertLt(_idleUsd(), 1e18, "deployed, not parked");
    }

    // ------------------------------------------------------------ E2

    /// @notice E2: a one-sided excess (a donation of imdUSD straight to the vault) is swapped by `compound`, and the swap
    /// stops inside the TWAP gate (±10 ticks), never at ±20 from the peg: deposits stay open right after the refill.
    function test_balancingSwapNeverLeavesTheTwapGate() public {
        (uint256 a0, uint256 a1) = _amounts(100_000e18, 100_000e6);
        vm.prank(alice);
        vault.deposit(0, a0, a1, alice);
        // Enough idle imdUSD that half of it moves the pool well past 10 ticks if nothing stops it.
        vm.prank(eve);
        usd.transfer(address(vault), 400_000e18);
        vault.compound();
        int24 spot = hook.spotTicks();
        int24 twap = hook.twapTicks();
        int24 gap = spot > twap ? spot - twap : twap - spot;
        assertLe(gap, vault.MAX_SPOT_TWAP_TICKS(), "the refill stopped inside the vault's own gate");
        assertLt(spot, 0, "it did sell imdUSD (the excess side) into the pool");
        // The gate is still open: a deposit and another compound go through.
        vm.prank(team);
        vault.deposit(1e18, type(uint256).max, type(uint256).max, team);
        vault.compound();
    }
}

contract PegLPVaultReviewStable0Test is PegLPVaultReviewTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF); // USDC sorts after imdUSD
    }
}

contract PegLPVaultReviewStable1Test is PegLPVaultReviewTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001); // USDC sorts before imdUSD
    }
}
