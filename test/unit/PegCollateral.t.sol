// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PegPositionsTest} from "./PegPositions.t.sol";
import {PegCollateral} from "../../src/earn/PegCollateral.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Pricer} from "../../src/Pricer.sol";

/// @notice One-sided PEG loops at their root: PEG collateral exists only through the zap, with real USDC. Both token orders.
abstract contract PegCollateralTest is PegPositionsTest, IERC3156FlashBorrower {
    int24 pushFrom;
    int24 pushTo;
    uint256 total;
    bool openFailed;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// The second re-check's route, whole: flash-mint, deposit imdUSD-only shares before the push (spot == TWAP), push, try to
    /// open against them. The shares are not the type's collateral, so the Ledger pulls a token the attacker cannot have.
    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata) external returns (bytes32) {
        (uint256 t0, uint256 t1) = vault.totals();
        uint256 tImd = hook.stableIsToken0() ? t0 : t1;
        uint256 want = total * vault.totalSupply() / tImd * 9990 / 10_000;
        (uint256 m0, uint256 m1) = hook.stableIsToken0() ? (total, uint256(1e6)) : (uint256(1e6), total);
        usd.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vault.approve(address(ledger), type(uint256).max);
        vault.approve(address(coll), type(uint256).max);
        (uint256 shares,,) = vault.deposit(want, m0, m1, address(this));
        _moveTo(pushTo);
        assertTrue(pricer.quote(PEG).borrowable, "the door is open in the push");
        try ledger.open(PEG, 77, Adjust(int256(shares), int256(amount), RATE, 0, 0, false, type(uint256).max, address(this))) {
            openFailed = false;
        } catch {
            openFailed = true;
        }
        try coll.wrap(shares, address(this)) {
            openFailed = false;
        } catch {}
        _moveTo(pushFrom);
        vault.withdraw(shares, 0, 0, address(this));
        usd.approve(address(usd), amount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function _flashLoop(int24 from, int24 to, uint256 total_) private {
        _hold(from, 31 minutes);
        (pushFrom, pushTo, total) = (from, to, total_);
        uint256 borrow = total_ * 89 / 100;
        _fund(address(this), total_ - borrow + 2e18, 1e6);
        usd.flashLoan(this, address(usd), borrow, "");
        assertTrue(openFailed, "no PEG debt against raw shares, in any order");
        assertEq(coll.balanceOf(address(this)), 0);
        (uint128 d,,,,) = ledger.ilkState(PEG);
        assertEq(d, 0, "no debt on the type");
    }

    function test_R2_flashLoop_150_40_50k() public {
        _flashLoop(-150, -40, 50_000e18);
    }

    function test_R2_flashLoop_300_49_50k() public {
        _flashLoop(-300, -49, 50_000e18);
    }

    function test_R2_flashLoop_150_49_500k() public {
        _flashLoop(-150, -49, 500_000e18);
    }

    /// Medium 2: a USDC donation sits idle below the band and used to flip the leg for everyone, across blocks.
    function test_R2_idleDonationDoesNotOpenBorrowing() public {
        address bob = makeAddr("bob");
        _bobCollateral(bob, 2_000e6);
        uint256 held = coll.balanceOf(bob);
        _hold(-150, 31 minutes);
        (uint256 t0, uint256 t1) = vault.totals();
        uint256 v = hook.stableIsToken0() ? t0 + t1 * 1e12 : t1 + t0 * 1e12;
        uint256 d = (v / 2) / 1e12;
        _fund(bob, 0, d);
        vm.prank(bob);
        usdc.transfer(address(vault), d);
        assertFalse(pricer.quote(PEG).borrowable, "a donation is not a two-sided position");
        vault.compound(); // the band refuses USDC at this price: it stays idle
        assertFalse(pricer.quote(PEG).borrowable, "nor after a compound");
        vm.prank(bob);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(PEG, 1, Adjust(int256(held), 100e18, RATE, 0, 0, false, type(uint256).max, bob));
        (uint256 m,) = feed.latestValue();
        assertGt(m * vault.totalSupply() / 1e18, v, "the median does count it: it is real value");
    }

    function test_R2_idleDonationSmallVault() public {
        address bob = makeAddr("bob");
        _bobCollateral(bob, 2_000e6);
        uint256 seedShares = vault.balanceOf(seed);
        vm.prank(seed);
        vault.withdraw(seedShares * 97 / 100, 0, 0, seed);
        _hold(-150, 31 minutes);
        (uint256 t0, uint256 t1) = vault.totals();
        uint256 d = (hook.stableIsToken0() ? t0 + t1 * 1e12 : t1 + t0 * 1e12) / 2e12; // lands the mix at a third USDC
        _fund(bob, 0, d);
        vm.prank(bob);
        usdc.transfer(address(vault), d);
        assertFalse(pricer.quote(PEG).borrowable);
    }

    // ------------------------------------------------------------ the wrapper

    function test_onlyTheZapWraps() public {
        address bob = makeAddr("bob");
        vm.prank(seed);
        vault.approve(address(coll), type(uint256).max);
        vm.prank(seed);
        vm.expectRevert(PegCollateral.Unauthorized.selector);
        coll.wrap(1e18, seed);
        vm.prank(bob);
        vm.expectRevert(PegCollateral.Unauthorized.selector);
        coll.setZap(bob);
        vm.expectRevert(PegCollateral.AlreadySet.selector);
        coll.setZap(address(this)); // this test is the wirer: once only
    }

    function test_rawSharesCannotTopUp() public {
        uint256 id = _open(10_000e6);
        vm.startPrank(seed);
        vault.approve(address(ledger), type(uint256).max);
        vm.expectRevert();
        ledger.adjust(id, Adjust(1e18, 0, 0, 0, 0, false, 0, seed));
        vm.stopPrank();
    }

    function test_oneToOneAndRedeemable() public {
        address bob = makeAddr("bob");
        uint256 id = _bobCollateral(bob, 2_000e6);
        uint256 held = coll.balanceOf(bob);
        assertEq(vault.balanceOf(address(coll)), coll.totalSupply(), "fully backed");
        assertEq(coll.totalSupply(), held + ledger.position(id).collateral);
        vm.prank(bob);
        coll.redeem(held, bob);
        assertEq(vault.balanceOf(bob), held, "1:1");
        vm.prank(bob);
        vault.withdraw(held, 0, 0, bob);
        assertEq(vault.balanceOf(address(coll)), coll.totalSupply());
    }

    /// A holder of collateral tokens may still top up with them, and repay and unwind work as before.
    function test_collateralTokensTopUpAndUnwind() public {
        address bob = makeAddr("bob");
        uint256 id = _bobCollateral(bob, 2_000e6);
        uint256 held = coll.balanceOf(bob);
        vm.prank(bob);
        ledger.adjust(id, Adjust(int256(held), 0, 0, 0, 0, false, 0, bob));
        assertEq(coll.balanceOf(bob), 0);
        vm.prank(bob);
        nft.approveOperator(id, address(zap), 32);
        _fund(bob, 100e18, 0);
        vm.startPrank(bob);
        usd.approve(address(zap), type(uint256).max);
        zap.unwind(id, 0, type(uint256).max);
        vm.stopPrank();
        assertEq(ledger.debtOf(id), 0);
        assertEq(coll.balanceOf(address(zap)), 0);
        _assertZapEmpty();
    }

    /// A liquidator receives the wrapper and redeems it to the vault, then the vault's tokens: liquidation is unchanged.
    function test_liquidatorReceivesAndRedeems() public {
        uint256 id = _open(10_000e6);
        uint256 debt = ledger.debtOf(id);
        (uint256 m,) = feed.latestValue();
        uint256 keep = Math.mulDiv(debt, 1.104e18, m);
        uint256 held = ledger.position(id).collateral;
        vm.prank(alice);
        ledger.adjust(id, Adjust(-int256(held - keep), 0, 0, 0, 0, false, 0, alice));
        quoteUsd.set(0.95e8); // USDC down: the USDC half counts for less; 110.4% -> ~107.6%
        address eve = makeAddr("eve");
        _fund(eve, 30_000e18, 0);
        vm.startPrank(eve);
        usd.approve(address(ledger), type(uint256).max);
        (uint256 repaid, uint256 seized,) = liquidator.liquidate(id);
        vm.stopPrank();
        assertGt(repaid, 0);
        uint256 got = coll.balanceOf(eve);
        assertGt(got, 0, "the wrapper");
        assertLe(got, seized);
        vm.prank(eve);
        coll.redeem(got, eve);
        assertEq(vault.balanceOf(eve), got);
        uint256 u0 = usdc.balanceOf(eve);
        vm.prank(eve);
        vault.withdraw(got, 0, 0, eve);
        assertGt(usdc.balanceOf(eve), u0, "real tokens at the end");
    }

    // ------------------------------------------------------------ what real USDC buys

    /// @dev Sell imdUSD held by `who` into the pool; USDC comes back to `who`.
    function _sell(address who, uint256 imd) private returns (uint256 got) {
        vm.prank(who);
        usd.transfer(address(router), imd);
        uint256 q0 = usdc.balanceOf(address(router));
        bool zeroForOne = hook.stableIsToken0();
        router.swap(key, SwapParams(zeroForOne, -int256(imd), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
        got = usdc.balanceOf(address(router)) - q0;
        vm.prank(address(router));
        usdc.transfer(who, got);
    }

    /// @dev Open through the zap with `usdcIn`, borrow to `crBps` at the full value, sell what was borrowed.
    function _openBorrowSell(address who, uint256 usdcIn, uint256 crBps) private returns (uint256 id, uint256 usdcBack) {
        vm.startPrank(who);
        usdc.approve(address(zap), type(uint256).max);
        id = zap.open(usdcIn, RATE, 0, type(uint256).max, 0, 0);
        (uint256 m,) = feed.latestValue();
        uint256 room = Math.mulDiv(ledger.position(id).collateral, m, 1e18) * 10_000 / crBps;
        uint256 d = ledger.debtOf(id);
        uint256 extra = (room - d) * 99 / 100; // room for the upfront fee
        ledger.adjust(id, Adjust(0, int256(extra), 0, 0, 0, false, type(uint256).max, who));
        vm.stopPrank();
        usdcBack = _sell(who, extra);
    }

    /// With NO USDC of one's own a flash-borrowed USDC cannot come back: the position's equity at par is what is missing.
    function test_flashBorrowedUsdcAloneCannotRepay() public {
        address eve = makeAddr("eve");
        uint256 flash = 10_000e6;
        _fund(eve, 0, flash);
        (, uint256 back) = _openBorrowSell(eve, flash, 11_100);
        assertLt(usdc.balanceOf(eve), flash, "short of the flash");
        console2.log("USDC recovered of 10,000 flash", back);
    }

    /// What is left of the one-sided-loop finding, stated: real USDC equity, levered through a USDC flash loan, reaches about the mat's own bound. It
    /// is a borrower's leveraged short of imdUSD, solvent at par, with its own USDC in; not the free loop. See Known issues in the README.
    function test_ownUsdcLeverageIsTheMatBound() public {
        address eve = makeAddr("eve");
        uint256 own = 1_000e6;
        uint256 flash = 3_800e6;
        _fund(eve, 0, own + flash);
        (uint256 id,) = _openBorrowSell(eve, own + flash, 11_100);
        assertGe(usdc.balanceOf(eve), flash, "the flash is repaid");
        uint256 debt = ledger.debtOf(id);
        console2.log("own USDC", own);
        console2.log("USDC left after repaying the flash", usdc.balanceOf(eve) - flash);
        console2.log("debt", debt);
        assertLt(debt, 11 * 1_000e18, "under mat's 11x of the equity");
        Pricer.Quote memory q = pricer.quote(PEG);
        assertTrue(q.borrowable, "the pool stays in range at this size");
    }
}

contract PegCollateralStable0Test is PegCollateralTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }
}

contract PegCollateralStable1Test is PegCollateralTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001);
    }
}
