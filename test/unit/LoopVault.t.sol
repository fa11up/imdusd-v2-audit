// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed, MockVault} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Ledger} from "../../src/Ledger.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {TransientReentrancyGuard} from "../../src/TransientReentrancyGuard.sol";
import {LoopVault, ILoopRouter} from "../../src/earn/LoopVault.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice A live pool price as LivePoolPrice reports it: never stale unless unreadable.
contract LoopLiveMock is IFeed {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, value == 0 ? 0 : uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        return value == 0;
    }

    function maxAge() external pure returns (uint256) {
        return type(uint64).max;
    }
}

/// @notice An OTC desk at a settable IMD price, keeping `haircutBps` of every fill (a malicious router keeps all it
/// can get away with).
contract MockLoopRouter is ILoopRouter {
    IERC20 immutable usd;
    uint256 public price; // USD per 1e18 IMD, 1e18
    uint256 public haircutBps;

    constructor(IERC20 usd_) {
        usd = usd_;
    }

    function set(uint256 price_, uint256 haircutBps_) external {
        (price, haircutBps) = (price_, haircutBps_);
    }

    function loopSwap(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata) external virtual {
        uint256 out = tokenIn == address(usd) ? amountIn * 1e18 / price : amountIn * price / 1e18;
        out = out * (10_000 - haircutBps) / 10_000;
        IERC20(tokenOut).transfer(msg.sender, out);
    }
}

/// @dev Tries to re-enter the vault from inside a swap.
contract ReentrantLoopRouter is MockLoopRouter {
    LoopVault vault;

    constructor(IERC20 usd_) MockLoopRouter(usd_) {}

    function setVault(LoopVault v) external {
        vault = v;
    }

    function loopSwap(address, uint256, address, bytes calldata) external override {
        vault.deposit(1e18, 0, address(this));
    }
}

/// @dev A peg keeper's TWAP (PegHook.twapTicks), settable; `broken` reverts like NoTwap.
contract MockPegTwap {
    int24 public tick;
    bool public broken;

    function set(int24 t, bool b) external {
        (tick, broken) = (t, b);
    }

    function twapTicks() external view returns (int24) {
        require(!broken, "NoTwap");
        return tick;
    }
}

/// @dev Calls imdUSD's flash mint with the vault as the receiver, trying to drive its callback.
contract FlashPoker {
    function poke(ImdUSD usd, address vault, bytes calldata data) external {
        usd.flashLoan(IERC3156FlashBorrower(vault), address(usd), 1e18, data);
    }
}

/// @notice The loop vault against the real Ledger, Pricer and imdUSD, with sIMD as a local
/// ERC-4626 over a mock IMD and a settable live-pool leg.
contract LoopVaultTest is System {
    bytes32 constant SIMD = "SIMD";
    bytes32 constant ETH = "ETH";
    uint256 constant P = 5e18; // $5 per IMD at the start

    MockERC20 imd;
    MockVault simd;
    MockFeed median;
    MockFeed spot;
    LoopLiveMock live;
    MockLoopRouter router;
    LoopVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new MockERC20("IMD", 18);
        simd = new MockVault(IERC20(address(imd)));
        // Seed the share vault so its rate is not at the virtual-share edge.
        imd.mint(address(this), 1_000e18);
        imd.approve(address(simd), type(uint256).max);
        simd.deposit(1_000e18, address(0xbeef));
        median = new MockFeed(P);
        spot = new MockFeed(P);
        live = new LoopLiveMock();
        live.set(P);

        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        ParametersBase.Risk memory ir = _risk(1.7e18, 100_000_000e18);
        ir.chop = 0.2e18;
        ir.skew = 0.1e18;
        ir.redeemCap = 20_000e18;
        _addIlk(
            SIMD, address(simd), median, spot, IFeed(address(0)), address(0), address(0), IFeed(address(live)), true, ir
        );
        MockFeed ethFeed = new MockFeed(2000e18);
        _addIlk(
            ETH,
            address(new MockERC20("WETH", 18)),
            ethFeed,
            ethFeed,
            IFeed(address(0)),
            address(0),
            address(0),
            true,
            _risk(1.4e18, 100_000_000e18)
        );
        // E3: the vault's debt cap reads the posted IMD depth; a large one here so only the cap tests feel it.
        params.setGenesisDepthRule(SIMD, 0.8e18, 1_000_000_000e18, 0, 0);
        params.seal();

        vault = new LoopVault(ledger, SIMD, address(treasury));
        router = new MockLoopRouter(IERC20(address(usd)));
        router.set(P, 0);
        imd.mint(address(router), 100_000_000e18);
        deal(address(usd), address(router), 100_000_000e18, true);

        address[4] memory us = [alice, bob, eve, address(treasury)];
        for (uint256 i; i < 4; ++i) {
            imd.mint(us[i], 1_000_000e18);
            deal(address(usd), us[i], 1_000_000e18, true);
            vm.startPrank(us[i]);
            imd.approve(address(vault), type(uint256).max);
            usd.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _rate() internal view returns (uint256) {
        return simd.convertToAssets(1e18);
    }

    /// @dev All three legs and the router at `p` USD per IMD, stamped now.
    function _price(uint256 p) internal {
        uint256 sp = p * _rate() / 1e18;
        median.set(sp);
        spot.set(sp);
        live.set(sp);
        router.set(p, router.haircutBps());
    }

    function _deposit(address u, uint256 amount) internal returns (uint256 shares) {
        vm.prank(u);
        shares = vault.deposit(amount, 0, u);
    }

    function _leverAll() internal returns (uint256 steps) {
        for (; steps < 30; ++steps) {
            try vault.lever(address(router), type(uint256).max, "") {}
                catch {
                break;
            }
        }
    }

    function _cr() internal view returns (uint256) {
        return vault.collateralRatio();
    }

    /// @dev IMD value of an IMD amount and an imdUSD amount at `p`.
    function _val(uint256 imdAmt, uint256 usdAmt, uint256 p) internal pure returns (uint256) {
        return imdAmt + usdAmt * 1e18 / p;
    }

    /// @dev Net value of the vault in IMD at a fair price `p` (all legs equal).
    function _navAt(uint256 p) internal view returns (uint256) {
        int256 n = vault.nav(p * _rate() / 1e18);
        return n > 0 ? uint256(n) : 0;
    }

    function _withdrawAll(address u) internal returns (uint256 imdOut, uint256 usdOut) {
        vm.roll(vm.getBlockNumber() + 1); // E7: new shares exit from the next block
        uint256 s = vault.balanceOf(u);
        vm.prank(u);
        (imdOut, usdOut) = vault.withdraw(s, 0, u);
    }

    // ------------------------------------------------------------ deposits and share pricing

    function test_firstDepositMintsLessDeadShares() public {
        uint256 shares = _deposit(alice, 10_000e18);
        assertEq(shares, 10_000e18 - vault.DEAD_SHARES());
        assertEq(vault.balanceOf(address(0xdEaD)), vault.DEAD_SHARES());
        assertEq(vault.totalSupply(), 10_000e18);
        (uint256 c, uint256 d) = vault.position();
        assertApproxEqAbs(simd.convertToAssets(c), 10_000e18, 1, "all of it staked as collateral");
        assertEq(d, 0);
        vm.prank(bob);
        vm.expectRevert(LoopVault.ZeroAmount.selector);
        vault.deposit(0, 0, bob);
    }

    function test_depositPricedAtTheHighestLeg() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        uint256 sp = P * _rate() / 1e18;
        // Legs disagree inside the skew: spot +4%, live +2% (inside the gate).
        spot.set(sp * 104 / 100);
        live.set(sp * 102 / 100);
        uint256 supply = vault.totalSupply();
        uint256 atHigh = Math.mulDiv(1_000e18, supply, uint256(vault.nav(sp * 104 / 100)));
        uint256 atLow = Math.mulDiv(1_000e18, supply, uint256(vault.nav(sp)));
        assertLt(atHigh, atLow, "the highest leg gives the fewest shares");
        assertEq(vault.previewDeposit(1_000e18), atHigh);
        assertEq(_deposit(bob, 1_000e18), atHigh);
        // Live above every attested leg: then IT is the deposit leg.
        live.set(sp * 1045 / 1000);
        assertEq(
            vault.previewDeposit(1_000e18),
            Math.mulDiv(1_000e18, vault.totalSupply(), uint256(vault.nav(sp * 1045 / 1000)))
        );
    }

    function test_depositRefusedOffMarketWithdrawalStillOpen() public {
        uint256 s = _deposit(alice, 10_000e18);
        _leverAll();
        uint256 sp = P * _rate() / 1e18;
        live.set(sp * 102 / 100); // above high by 2% > the 1% gate
        vm.prank(bob);
        vm.expectPartialRevert(LoopVault.OffMarket.selector);
        vault.deposit(1_000e18, 0, bob);
        live.set(sp * 98 / 100);
        vm.prank(bob);
        vm.expectPartialRevert(LoopVault.OffMarket.selector);
        vault.deposit(1_000e18, 0, bob);
        assertEq(vault.previewDeposit(1_000e18), 0);
        // Stale: refused too.
        live.set(sp);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bob);
        vm.expectRevert(LoopVault.NotPriced.selector);
        vault.deposit(1_000e18, 0, bob);
        // The vault never gates an exit; the last holder repays everything and needs no price.
        _withdrawAll(alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES());
        s;
    }

    /// @notice A pushed pool only hurts the pusher. Push the live pool to the gate's upper edge, deposit, push back,
    /// withdraw in kind: the round trip pays less than it put in. Pushed down, it pays nothing either.
    function test_pushDepositPushBackWithdrawDoesNotPay() public {
        _deposit(alice, 100_000e18);
        _leverAll();
        uint256 sp = P * _rate() / 1e18;
        for (uint256 dir; dir < 2; ++dir) {
            uint256 imd0 = imd.balanceOf(eve);
            uint256 usd0 = usd.balanceOf(eve);
            live.set(dir == 0 ? sp * 101 / 100 : sp * 99 / 100); // the gate's edge
            uint256 s = _deposit(eve, 10_000e18);
            live.set(sp);
            vm.roll(vm.getBlockNumber() + 1); // E7
            vm.prank(eve);
            vault.withdraw(s, 0, eve);
            uint256 imd1 = imd.balanceOf(eve);
            uint256 usd1 = usd.balanceOf(eve);
            // Eve paid imdUSD for her debt slice: value her change at the fair price.
            int256 pnl = int256(imd1) - int256(imd0) - int256((usd0 - usd1) * 1e18 / P);
            assertLe(pnl, 0, "the push paid");
            if (dir == 0) assertLt(pnl, -1e18, "pushing up costs the pusher");
        }
    }

    // ------------------------------------------------------------ lever

    function test_leverMovesTheRatioIntoTheBand() public {
        _deposit(alice, 10_000e18);
        assertEq(_cr(), type(uint256).max);
        uint256 steps = _leverAll();
        assertGt(steps, 1, "size-capped: more than one step");
        uint256 cr = _cr();
        assertGe(cr, vault.TARGET_CR() - 1e15);
        assertLe(cr, vault.BAND_HIGH());
        vm.expectRevert(LoopVault.InBand.selector);
        vault.lever(address(router), type(uint256).max, "");
    }

    function test_leverStepIsCapped() public {
        _deposit(alice, 10_000e18);
        (uint256 c,) = vault.position();
        uint256 v = c * (P * _rate() / 1e18) / 1e18;
        (uint256 borrowed,) = vault.lever(address(router), type(uint256).max, "");
        assertEq(borrowed, v * vault.MAX_STEP_BPS() / 10_000);
    }

    function test_leverRefusedWhenStaleSkewedOrOffMarket() public {
        _deposit(alice, 10_000e18);
        uint256 sp = P * _rate() / 1e18;
        // Off market: live 1.5% above the low leg.
        live.set(sp * 1015 / 1000);
        vm.expectPartialRevert(LoopVault.OffMarket.selector);
        vault.lever(address(router), type(uint256).max, "");
        // Legs disagree past the skew (10%): not borrowable.
        live.set(sp);
        spot.set(sp * 112 / 100);
        vm.expectRevert(LoopVault.NotPriced.selector);
        vault.lever(address(router), type(uint256).max, "");
        // Stale.
        spot.set(sp);
        vm.warp(block.timestamp + 61 minutes);
        vm.expectRevert(LoopVault.NotPriced.selector);
        vault.lever(address(router), type(uint256).max, "");
        // Unreadable live leg.
        _price(P);
        live.set(0);
        vm.expectRevert(LoopVault.NotPriced.selector);
        vault.lever(address(router), type(uint256).max, "");
    }

    // ------------------------------------------------------------ delever

    function test_deleverAtFreshFeedsStepsBackIntoTheBand() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        vm.expectRevert(LoopVault.InBand.selector);
        vault.delever(address(router), type(uint256).max, "");
        _price(P * 85 / 100); // -15%
        uint256 cr = _cr();
        assertLt(cr, vault.BAND_LOW());
        (uint256 repaid,) = vault.delever(address(router), type(uint256).max, "");
        assertGt(repaid, 0);
        assertGe(_cr(), vault.BAND_LOW(), "back above 220%");
        assertLe(_cr(), vault.BAND_HIGH());
        assertEq(usd.balanceOf(address(vault)), 0, "flash repaid, nothing idle");
    }

    /// @notice Feeds stale: the Ledger will not release collateral from an indebted position, so the vault unwinds
    /// fully through a flash mint (repaying all the debt needs no price), bounded by the last attested low leg.
    function test_deleverAtStaleFeedsUnwindsViaFlash() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        _price(P * 85 / 100); // the fall is attested...
        vm.warp(block.timestamp + 61 minutes); // ...then the feeds go stale before anyone delevers
        (,,,, bool priced,) = _q();
        assertFalse(priced);
        uint256 navBefore = _navAt(P * 85 / 100);
        (uint256 repaid, uint256 sold) = vault.delever(address(router), type(uint256).max, "");
        (uint256 c, uint256 d) = vault.position();
        assertEq(d, 0, "unwound");
        assertGt(c, 0, "kept the rest of the collateral");
        assertGt(repaid, 0);
        assertGt(sold, 0);
        // Selling at the fair price with the worst-fill margin: the surplus stays idle, no value lost.
        assertApproxEqRel(_navAt(P * 85 / 100), navBefore, 1e12);
    }

    /// @notice Stale feeds and a market more than the slippage allowance below the last attested price: the
    /// unwind cannot fill, the vault waits (it never sells under the last attested low leg less slippage).
    function test_staleUnwindWaitsWhenTheMarketIsBelowTheLastAttestation() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        _price(P * 85 / 100);
        vm.warp(block.timestamp + 61 minutes);
        router.set(P * 80 / 100, 0); // the market fell further, unattested
        live.set((P * 80 / 100) * _rate() / 1e18);
        vm.expectPartialRevert(LoopVault.ShortFill.selector);
        vault.delever(address(router), type(uint256).max, "");
    }

    /// @notice E6: stale feeds in a fast fall. The unwind's bound starts at the last attested low and decays by
    /// UNWIND_DECAY_BPS_PER_HOUR per hour of staleness down to the live market, so the vault unwinds at the market
    /// instead of riding to the bite while it waits for an attestation; a pushed pool cannot undercut the decayed floor.
    function test_review_E6_staleUnwindBoundDecaysToTheLiveMarket() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        _price(P * 85 / 100); // last attestation: -15%
        uint256 attestedAt = block.timestamp;
        // The market falls 6% more, unattested; the feeds go stale (maxAge 1h).
        router.set(P * 80 / 100, 0);
        live.set((P * 80 / 100) * _rate() / 1e18);
        vm.warp(attestedAt + 1 hours + 5 minutes);
        vm.expectPartialRevert(LoopVault.ShortFill.selector);
        vault.delever(address(router), type(uint256).max, ""); // 5 min stale: the floor is still ~0.8% below last
        // A pool pushed far below the market cannot buy the vault's IMD under the decayed floor.
        vm.warp(attestedAt + 1 hours + 30 minutes); // floor = last - 5%
        router.set(P * 70 / 100, 0);
        live.set((P * 70 / 100) * _rate() / 1e18);
        vm.expectPartialRevert(LoopVault.ShortFill.selector);
        vault.delever(address(router), type(uint256).max, "");
        // 45 minutes stale: floor = last - 7.5% < the real market (-5.9%): the unwind fills at the market.
        vm.warp(attestedAt + 1 hours + 45 minutes);
        router.set(P * 80 / 100, 0);
        live.set((P * 80 / 100) * _rate() / 1e18);
        uint256 navBefore = _navAt(P * 80 / 100);
        (uint256 repaid,) = vault.delever(address(router), type(uint256).max, "");
        (, uint256 d) = vault.position();
        assertEq(d, 0, "unwound at the market");
        assertGt(repaid, 0);
        assertApproxEqRel(_navAt(P * 80 / 100), navBefore, 1e12, "no value lost at a fair fill");
    }

    // ------------------------------------------------------------ routers

    function test_shortRouterRefused() public {
        _deposit(alice, 10_000e18);
        router.set(P, vault.MAX_SLIPPAGE_BPS() + 1); // a hair past the allowance
        vm.expectPartialRevert(LoopVault.ShortFill.selector);
        vault.lever(address(router), type(uint256).max, "");
        router.set(P, 0);
        _leverAll();
        _price(P * 85 / 100);
        router.set(P * 85 / 100, vault.MAX_SLIPPAGE_BPS() + 1);
        vm.expectPartialRevert(LoopVault.ShortFill.selector);
        vault.delever(address(router), type(uint256).max, "");
    }

    /// @notice The most a router can keep in one call is the slippage allowance on one size-capped step:
    /// MAX_SLIPPAGE_BPS × MAX_STEP_BPS = 0.2% of the collateral's value.
    function test_maliciousRouterTakesAtMostTheAllowance() public {
        _deposit(alice, 10_000e18);
        uint256 sp = P * _rate() / 1e18;
        (uint256 c,) = vault.position();
        uint256 v = c * sp / 1e18; // USD
        router.set(P, vault.MAX_SLIPPAGE_BPS() - 1); // keeps all but a hair of the allowance
        uint256 navBefore = _navAt(P);
        uint256 debtBefore = ledger.debtOf(_pid(SIMD, address(vault)));
        (uint256 borrowed, uint256 bought) = vault.lever(address(router), type(uint256).max, "");
        // The Ledger's upfront fee on the step's borrow is a known cost, not the router's take.
        uint256 upfront = ledger.debtOf(_pid(SIMD, address(vault))) - debtBefore - borrowed;
        assertGt(upfront, 0);
        uint256 keptUsd = borrowed - bought * P / 1e18;
        assertLe(keptUsd, borrowed * vault.MAX_SLIPPAGE_BPS() / 10_000, "kept more than the allowance");
        assertLe(keptUsd, v * vault.MAX_STEP_BPS() * vault.MAX_SLIPPAGE_BPS() / 1e8, "more than 0.2% of the value");
        uint256 lost = navBefore - _navAt(P);
        assertLe(lost, navBefore * vault.MAX_STEP_BPS() * vault.MAX_SLIPPAGE_BPS() / 1e8 + upfront + 1e9);
        // The same on the way down.
        router.set(P, 0);
        _leverAll();
        _price(P * 85 / 100);
        router.set(P * 85 / 100, vault.MAX_SLIPPAGE_BPS() - 1);
        navBefore = _navAt(P * 85 / 100);
        (c,) = vault.position();
        v = c * (P * 85 / 100 * _rate() / 1e18) / 1e18;
        vault.delever(address(router), type(uint256).max, "");
        lost = navBefore - _navAt(P * 85 / 100);
        assertLe(lost * (P * 85 / 100) / 1e18, v * vault.MAX_STEP_BPS() * vault.MAX_SLIPPAGE_BPS() / 1e8 * 102 / 100);
    }

    function test_routerCannotReenter() public {
        _deposit(alice, 10_000e18);
        ReentrantLoopRouter r = new ReentrantLoopRouter(IERC20(address(usd)));
        r.setVault(vault);
        vm.expectRevert(TransientReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.lever(address(r), type(uint256).max, "");
    }

    // ------------------------------------------------------------ withdraw

    function test_withdrawRepayingInImdUSD() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        uint256 s = _deposit(bob, 5_000e18);
        (uint256 collImd, uint256 debt,,) = vault.previewWithdraw(s);
        uint256 usd0 = usd.balanceOf(bob);
        uint256 imd0 = imd.balanceOf(bob);
        vm.roll(vm.getBlockNumber() + 1); // E7: new shares exit from the next block
        vm.prank(bob);
        (uint256 imdOut, uint256 usdOut) = vault.withdraw(s, collImd, bob);
        assertEq(usd0 - usd.balanceOf(bob), debt, "paid exactly the debt slice");
        assertEq(imd.balanceOf(bob) - imd0, imdOut);
        assertEq(usdOut, 0);
        assertApproxEqAbs(imdOut, collImd, 2);
        // Paid in kind: worth no more than went in (at the fair price; entry was at the highest leg = fair here).
        assertLe(_val(imdOut, 0, P), 5_000e18 + debt * 1e18 / P);
        assertGe(_cr(), vault.TARGET_CR() - 1e15, "the leaver's exit does not move the others' ratio");
    }

    function test_withdrawSellingThroughTheLeaversRoute() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        uint256 s = _deposit(bob, 5_000e18);
        (uint256 collImd, uint256 debt,,) = vault.previewWithdraw(s);
        uint256 sell = debt * 1e18 / P * 103 / 100; // 3% over, the leaver's own margin
        uint256 usd0 = usd.balanceOf(bob);
        vm.roll(vm.getBlockNumber() + 1); // E7: new shares exit from the next block
        // Too little sold to cover the slice's debt: refused.
        vm.prank(bob);
        vm.expectPartialRevert(LoopVault.ShortFill.selector);
        vault.withdrawSelling(s, 0, bob, debt * 1e18 / P / 2, address(router), "");
        vm.prank(bob);
        (uint256 imdOut, uint256 usdOut) = vault.withdrawSelling(s, 0, bob, sell, address(router), "");
        assertEq(usd.balanceOf(bob), usd0 + usdOut, "pulled no imdUSD from the leaver");
        assertApproxEqAbs(imdOut, collImd - sell, 2);
        assertApproxEqAbs(usdOut, sell * P / 1e18 - debt, 1e6);
        assertEq(usd.balanceOf(address(vault)), 0);
    }

    function test_withdrawLeavingDustRefusedLastHolderTakesAll() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        uint256 s = vault.balanceOf(alice);
        vm.roll(vm.getBlockNumber() + 1); // E7: new shares exit from the next block
        vm.prank(alice);
        vm.expectRevert(LoopVault.DustRemainder.selector);
        vault.withdraw(s - 1e15, 0, alice);
        _withdrawAll(alice);
        (uint256 c, uint256 d) = vault.position();
        assertEq(c, 0);
        assertEq(d, 0);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES());
        // And it restarts cleanly behind the dead shares.
        assertEq(_deposit(bob, 1_000e18), 1_000e18);
    }

    // ------------------------------------------------------------ fee

    /// @notice 10% of the collateral's yield over the borrow cost, exactly, as shares to the Treasury.
    function test_feeIsExactlyTenPercentOfYieldOverCost() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        uint256 sharesMark = vault.sharesMark();
        uint256 rateMark = vault.rateMark();
        uint256 debtMark = vault.debtMark();
        uint256 markAt = vault.markAt();
        // 30 days: sIMD's rate grows 2%, the debt accrues interest at the floor rate.
        simd.accrue(simd.totalAssets() * 2 / 100);
        vm.warp(block.timestamp + 30 days);
        _price(P);
        uint256 rateNow = _rate();
        uint256 yieldImd = sharesMark * rateNow / 1e18 - sharesMark * rateMark / 1e18;
        uint256 posRate = ledger.position(_pid(SIMD, address(vault))).rate;
        uint256 costUsd =
            Math.mulDiv(debtMark, posRate * (block.timestamp - markAt), 365 days * 1e18, Math.Rounding.Ceil);
        uint256 costImd = Math.mulDiv(costUsd, 1e18, P, Math.Rounding.Ceil);
        assertGt(yieldImd, costImd, "a net gain to charge");
        uint256 fee = (yieldImd - costImd) / 10;
        vault.checkpoint();
        uint256 t = vault.balanceOf(address(treasury));
        uint256 valueT = Math.mulDiv(t, _navAt(P), vault.totalSupply());
        // E4: the bounty budget is topped up out of the fee first (up to BOUNTY_BUDGET_USD); the Treasury gets the rest.
        uint256 budget = vault.bountyBudget();
        assertEq(budget, Math.min(fee, vault.BOUNTY_BUDGET_USD() * 1e18 / P), "budget topped up from the fee");
        assertApproxEqAbs(valueT + budget, fee, 1e6, "Treasury + bounty budget hold 10% of yield over cost");
        assertEq(vault.pendingYield(), 0);
        // A second checkpoint with nothing new charges nothing.
        vault.checkpoint();
        assertEq(vault.balanceOf(address(treasury)), t);
    }

    function test_noFeeOnALossAndTheDeficitCarries() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        vm.warp(block.timestamp + 30 days); // interest, no yield
        _price(P);
        vault.checkpoint();
        assertEq(vault.balanceOf(address(treasury)), 0);
        int256 carried = vault.pendingYield();
        assertEq(carried, 0);
        assertGt(vault.pendingCost(), 0, "the cost carries");
        // Yield smaller than the carried cost: still nothing.
        simd.accrue(1e15);
        _price(P);
        vault.checkpoint();
        assertEq(vault.balanceOf(address(treasury)), 0);
    }

    function test_noFeeWhileUnpriced() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        simd.accrue(simd.totalAssets() * 2 / 100);
        vm.warp(block.timestamp + 2 hours); // stale
        vault.checkpoint();
        assertEq(vault.balanceOf(address(treasury)), 0);
        assertGt(vault.pendingYield(), 0, "carried, charged later");
        _price(P);
        vault.checkpoint();
        assertGt(vault.balanceOf(address(treasury)) + vault.bountyBudget(), 0);
    }

    function test_lateDepositorTakesNoneOfEarlierYield() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        simd.accrue(simd.totalAssets() * 5 / 100);
        vm.warp(block.timestamp + 10 days);
        _price(P);
        vault.checkpoint(); // the fee on alice's yield is the Treasury's either way
        uint256 aliceBefore = Math.mulDiv(vault.balanceOf(alice), _navAt(P), vault.totalSupply());
        uint256 s = _deposit(bob, 10_000e18); // charges the fee first, then prices bob in
        uint256 usd0 = usd.balanceOf(bob);
        vm.roll(vm.getBlockNumber() + 1); // E7: new shares exit from the next block
        vm.prank(bob);
        (uint256 imdOut,) = vault.withdraw(s, 0, bob);
        uint256 paid = usd0 - usd.balanceOf(bob);
        assertLe(_val(imdOut, 0, P), 10_000e18 + paid * 1e18 / P + 1, "bob took earlier yield");
        uint256 aliceAfter = Math.mulDiv(vault.balanceOf(alice), _navAt(P), vault.totalSupply());
        assertGe(aliceAfter + 1e6, aliceBefore, "alice kept hers");
    }

    // ------------------------------------------------------------ E3 size caps

    /// @notice E3's scenario: a $500k vault with IMD depth to -15% of ~$95k. Before the fix it levered to $200k of
    /// debt (250%) and, after a 15% fall, had to sell a 10% step (~$42k of IMD) through a market holding ~$95k: the
    /// step could not fill within the slippage bound and the vault rode to the bite. Now its debt stops at
    /// K_LOOP x depth, so the fall leaves it far above the band and no forced sale exists at all.
    function test_review_E3_debtCappedAtPostedDepth_500kFifteenPercentFall() public {
        uint256 depth = 95_000e18;
        vm.prank(governor);
        params.postLowerDepth(depth);
        uint256 cap = vault.debtCap();
        assertEq(cap, depth * vault.K_LOOP() / 1e18, "cap = K_LOOP x depth");
        _deposit(alice, 100_000e18); // $500k of IMD at $5
        _leverAll();
        (uint256 c, uint256 d) = vault.position();
        assertLe(d, cap, "debt stops at the cap");
        assertGt(d, cap * 99 / 100, "and reaches it");
        // Uncapped, 250% on ~$500k of collateral is ~$200k of debt (the review's figure): the cap binds far below.
        uint256 v = c * (P * _rate() / 1e18) / 1e18;
        assertGt(v * 1e18 / 2.5e18, 5 * cap, "the cap binds well below the old target debt");
        vm.expectPartialRevert(LoopVault.AtCap.selector);
        vault.lever(address(router), type(uint256).max, "");
        // -15%: still far above the band, nothing to sell.
        _price(P * 85 / 100);
        assertGt(_cr(), vault.BAND_HIGH());
        vm.expectRevert(LoopVault.InBand.selector);
        vault.delever(address(router), type(uint256).max, "");
        // Even a full delever from 250% to the 170% mat sells (2.5 - 1.7) / 1.5 of the debt: a small slice of depth.
        assertLe(d * 8 / 15, depth * 14 / 100, "worst full delever <= 14% of the posted depth");
        // A depth posted lower than the debt stops levering at once (positions untouched).
        vm.prank(governor);
        params.postLowerDepth(depth / 2);
        _price(P);
        vm.expectPartialRevert(LoopVault.AtCap.selector);
        vault.lever(address(router), type(uint256).max, "");
    }

    /// @notice E3: a step is min(10% of the collateral, the flash room, the caller's maxStep), both ways.
    function test_review_E3_stepCappedByMaxStepAndFlashRoom() public {
        _deposit(alice, 10_000e18);
        (uint256 borrowed,) = vault.lever(address(router), 100e18, "");
        assertEq(borrowed, 100e18, "caller's maxStep");
        vm.mockCall(address(usd), abi.encodeWithSelector(usd.maxFlashLoan.selector, address(usd)), abi.encode(70e18));
        (borrowed,) = vault.lever(address(router), type(uint256).max, "");
        assertEq(borrowed, 70e18, "flash room");
        vm.clearMockedCalls();
        _leverAll();
        _price(P * 85 / 100);
        // A router filling exactly at the bound: no surplus to pay further debt down, so `repaid` is the step.
        router.set(P * 85 / 100, vault.MAX_SLIPPAGE_BPS() - 1);
        (uint256 repaid,) = vault.delever(address(router), 50e18, "");
        assertApproxEqRel(repaid, 50e18, 2e14, "delever step = caller's maxStep");
        assertEq(vault.rebalancing(), 2, "and the rebalance continues");
        vm.mockCall(address(usd), abi.encodeWithSelector(usd.maxFlashLoan.selector, address(usd)), abi.encode(30e18));
        (repaid,) = vault.delever(address(router), type(uint256).max, "");
        assertApproxEqRel(repaid, 30e18, 2e14, "delever step = flash room");
    }

    /// @notice E3: `lever` never sells borrowed imdUSD into a peg pool already under the peg (TWAP < -25 ticks);
    /// an unreadable TWAP refuses too. Delevering (which buys imdUSD) is not gated.
    function test_review_E3_leverRefusedBelowPegTwap() public {
        _deposit(alice, 10_000e18);
        MockPegTwap peg = new MockPegTwap();
        vm.prank(usd.bridgeSetter());
        usd.setKeeper(address(peg));
        peg.set(-26, false);
        vm.expectRevert(abi.encodeWithSelector(LoopVault.BelowPeg.selector, int24(-26)));
        vault.lever(address(router), type(uint256).max, "");
        peg.set(0, true);
        vm.expectPartialRevert(LoopVault.BelowPeg.selector);
        vault.lever(address(router), type(uint256).max, "");
        peg.set(-25, false);
        _leverAll();
        assertGe(_cr(), vault.TARGET_CR() - 1e15, "at the floor it levers");
        peg.set(-200, false);
        _price(P * 85 / 100);
        (uint256 repaid,) = vault.delever(address(router), type(uint256).max, "");
        assertGt(repaid, 0, "delever is not gated by the peg");
    }

    // ------------------------------------------------------------ E4 caller pay, upfront fee

    /// @notice E4: the lever step's maths includes the Ledger's upfront fee, so an uncapped step lands ON 250%
    /// (before the fix it landed below by ~T x f x step / debt and the hysteresis paid another fee to fix it).
    function test_review_E4_leverStepLandsOnTargetWithUpfrontFee() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        _price(P * 115 / 100); // +15%: CR ~287%, above the band
        assertGt(_cr(), vault.BAND_HIGH());
        uint256 debt0 = ledger.debtOf(_pid(SIMD, address(vault)));
        (uint256 borrowed,) = vault.lever(address(router), type(uint256).max, "");
        uint256 upfront = ledger.debtOf(_pid(SIMD, address(vault))) - debt0 - borrowed;
        assertGt(upfront, 0, "the step paid an upfront fee");
        assertEq(vault.rebalancing(), 0, "one uncapped step");
        assertApproxEqRel(_cr(), vault.TARGET_CR(), 1e12, "lands on the target, fee included");
        // The fee-blind formula would have missed by more than 100x that tolerance.
        assertGt(upfront * 2.5e18 / ledger.debtOf(_pid(SIMD, address(vault))), 5e13);
    }

    /// @notice E4: the rebalance caller is paid min($2, 0.1% of the step) in shares, only out of the budget set aside
    /// from the performance fee; a vault that has charged no fee pays nothing (never principal); many tiny steps earn
    /// no more than one big one; the budget leaves with the last holder.
    function test_review_E4_bountyFromFeeBudgetOnly() public {
        _deposit(alice, 10_000e18);
        vm.prank(eve);
        vault.lever(address(router), type(uint256).max, "");
        assertEq(vault.balanceOf(eve), 0, "no fee charged yet: no bounty");
        _leverAll();
        simd.accrue(simd.totalAssets() * 2 / 100);
        vm.warp(block.timestamp + 30 days);
        _price(P);
        vault.checkpoint();
        uint256 budget = vault.bountyBudget();
        assertGt(budget, 0, "budget set aside from the fee");
        // A tiny step earns 0.1% of itself.
        _price(P * 115 / 100);
        uint256 navBefore = _navAt(P * 115 / 100);
        vm.prank(eve);
        (uint256 tiny,) = vault.lever(address(router), 100e18, "");
        uint256 sTiny = vault.balanceOf(eve);
        uint256 paidTiny = budget - vault.bountyBudget();
        assertEq(paidTiny, tiny * vault.BOUNTY_STEP_BPS() / 10_000 * 1e18 / (P * 115 / 100));
        // Minted at the richest known price, so worth at most the bounty at the fair one.
        assertApproxEqRel(Math.mulDiv(sTiny, _navAt(P * 115 / 100), vault.totalSupply()), paidTiny, 1e13);
        // A full step earns the fixed $2.
        budget = vault.bountyBudget();
        vm.prank(eve);
        vault.lever(address(router), type(uint256).max, "");
        uint256 paid = budget - vault.bountyBudget();
        assertEq(paid, vault.BOUNTY_USD() * 1e18 / (P * 115 / 100), "the fixed $2, in IMD");
        assertApproxEqRel(
            Math.mulDiv(vault.balanceOf(eve), _navAt(P * 115 / 100), vault.totalSupply()), paidTiny + paid, 1e13
        );
        assertLe(_navAt(P * 115 / 100) + 1e9, navBefore + 1e9, "bounties move value, they create none");
        // The last holders out take the budget's value with them; it resets.
        _withdrawAll(eve);
        if (vault.balanceOf(address(treasury)) != 0) _withdrawAll(address(treasury));
        _withdrawAll(alice);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES());
        assertEq(vault.bountyBudget(), 0, "budget reset with the last exit");
    }

    // ------------------------------------------------------------ E7 one-block hold

    /// @notice E7: new shares cannot exit in the block they arrive, directly or after a hand-off to another address;
    /// old shares are never blocked (a holder of old shares passes no stamp), and the next block exits normally.
    function test_review_E7_newSharesHeldOneBlock() public {
        _deposit(alice, 10_000e18);
        _leverAll();
        vm.roll(vm.getBlockNumber() + 1);
        uint256 s = _deposit(eve, 1_000e18);
        vm.prank(eve);
        vm.expectRevert(LoopVault.Held.selector);
        vault.withdraw(s, 0, eve);
        // Handing the fresh shares to a clean address passes the hold on.
        vm.prank(eve);
        vault.transfer(bob, s);
        vm.prank(bob);
        vm.expectRevert(LoopVault.Held.selector);
        vault.withdraw(s, 0, bob);
        // Alice's shares are old: she can send some to carol and carol can exit at once.
        address carol = makeAddr("carol");
        deal(address(usd), carol, 1_000_000e18, true);
        vm.prank(carol);
        usd.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.transfer(carol, 1_000e18);
        vm.prank(carol);
        vault.withdraw(1_000e18, 0, carol);
        // Next block: bob's shares are free.
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        vault.withdraw(s, 0, bob);
        assertEq(vault.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------ guards

    function test_flashCallbackGuards() public {
        _deposit(alice, 10_000e18);
        bytes memory data =
            abi.encode(uint8(1), uint256(1), uint256(1), uint256(1), address(router), uint256(0), bytes(""));
        // Direct call.
        vm.expectRevert(LoopVault.BadFlash.selector);
        vault.onFlashLoan(address(vault), address(usd), 1e18, 0, data);
        // A flash someone else started, with the vault as the receiver.
        FlashPoker poker = new FlashPoker();
        vm.expectRevert(LoopVault.BadFlash.selector);
        poker.poke(usd, address(vault), data);
        // Even pretending to be the token, without a pending flash.
        vm.prank(address(usd));
        vm.expectRevert(LoopVault.BadFlash.selector);
        vault.onFlashLoan(address(vault), address(usd), 1e18, 0, data);
    }

    function test_constructorChecks() public {
        vm.expectRevert(LoopVault.ZeroAddress.selector);
        new LoopVault(Ledger(address(0)), SIMD, address(treasury));
        vm.expectRevert(LoopVault.ZeroAddress.selector);
        new LoopVault(ledger, SIMD, address(0));
        vm.expectRevert(LoopVault.BadType.selector);
        new LoopVault(ledger, ETH, address(treasury)); // no live leg
        vm.expectRevert(LoopVault.BadType.selector);
        new LoopVault(ledger, "NOPE", address(treasury));
        assertEq(address(vault.staked()), address(simd));
        assertEq(address(vault.imd()), address(imd));
        vm.expectRevert(LoopVault.ZeroAddress.selector);
        vault.lever(address(0), type(uint256).max, "");
    }

    // ------------------------------------------------------------ fuzz

    /// @dev Random deposits, withdrawals, levers, delevers, fair price moves and time. No action hands its caller
    /// more than its slice at the fair price, and once everyone (the Treasury included) exits, the supply is the dead
    /// shares and the position is closed.
    function testFuzz_noValueCreated(uint256 seed) public {
        uint256 p = P;
        _deposit(alice, 20_000e18);
        address[3] memory who = [alice, bob, address(treasury)];
        for (uint256 i; i < 14; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 6;
            address u = who[(seed >> 8) % 2];
            if (op == 0) {
                uint256 amount = 1_000e18 + (seed >> 16) % 20_000e18;
                vm.prank(u);
                try vault.deposit(amount, 0, u) returns (uint256 s) {
                    // The new shares are worth no more than the deposit, at the fair price.
                    assertLe(Math.mulDiv(s, _navAt(p), vault.totalSupply()), amount + 1e6, "deposit created value");
                } catch {}
            } else if (op == 1 && vault.balanceOf(u) != 0) {
                uint256 s = 1 + (seed >> 16) % vault.balanceOf(u);
                uint256 slice = Math.mulDiv(s, _navAt(p), vault.totalSupply());
                uint256 usd0 = usd.balanceOf(u);
                vm.prank(u);
                try vault.withdraw(s, 0, u) returns (uint256 imdOut, uint256 usdOut) {
                    uint256 paid = usd0 + usdOut - usd.balanceOf(u);
                    assertLe(imdOut + usdOut * 1e18 / p, slice + paid * 1e18 / p + 1e6, "withdraw created value");
                } catch {}
            } else if (op == 2) {
                _leverAll();
            } else if (op == 3) {
                try vault.delever(address(router), type(uint256).max, "") {} catch {}
            } else if (op == 4) {
                p = p * (88 + (seed >> 16) % 25) / 100; // -12% .. +12%
                _price(p);
            } else {
                simd.accrue(simd.totalAssets() * ((seed >> 16) % 3) / 100);
                vm.warp(block.timestamp + (seed >> 24) % 7 days);
                _price(p);
            }
        }
        // Everyone out. Bob, the Treasury (fee shares) and this contract (rebalance bounties) try to leave on their own; a slice that would leave the
        // position under the Ledger's dust is handed to alice, who leaves last and takes everything.
        // Settle the fee first, so no new fee shares appear during the exits (all in this block).
        vm.roll(vm.getBlockNumber() + 1); // E7: and from a block after the last mint
        vault.checkpoint();
        address[3] memory others = [bob, address(treasury), address(this)];
        for (uint256 i; i < 3; ++i) {
            uint256 s = vault.balanceOf(others[i]);
            if (s == 0) continue;
            vm.prank(others[i]);
            try vault.withdraw(s, 0, others[i]) {}
            catch {
                vm.prank(others[i]);
                vault.transfer(alice, s);
            }
        }
        if (vault.balanceOf(alice) != 0) _withdrawAll(alice);
        assertEq(vault.totalSupply(), vault.DEAD_SHARES(), "supply back to the dead shares");
        (uint256 c, uint256 d2) = vault.position();
        assertEq(c, 0);
        assertEq(d2, 0);
    }

    function _q() internal view returns (uint256, uint256, uint256, uint256, bool, bool) {
        Pricer.Quote memory q = pricer.quote(SIMD);
        return (q.low, q.high, q.payout, q.mat, q.priced, q.borrowable);
    }
}
