// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice An issuer's `adminBurn` on our custody, or a blocklisted custody, cannot be prevented, only capped and
/// realised: pro rata through the vault's share rate, as the type's bad debt, covered by the type's own surplus first.
contract StockBadDebtTest is StockSystem {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address taker = makeAddr("taker");

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        usdg.mint(taker, 1_000_000e6);
        vm.prank(taker);
        usdg.approve(address(sjoin), type(uint256).max);
    }

    function test_partialBurnMarksEveryPositionDownProRata() public {
        _open(alice, 100e18, 5_000e18);
        _open(bob, 100e18, 0);
        stock.adminBurn(address(vault), 80e18); // 40% of the pool
        (uint256 v,) = price.latestValue();
        assertApproxEqRel(v, 60e12, 1e9, "every share is worth 60% of a token (per 1e18 shares = 1e-6 token, F5 offset)");
        (bool ok,) = ledger.healthy(_pid(STK, alice));
        assertFalse(ok, "$6,000 against $5,000 at 150%");
        // bob, with no debt, lost the same 40%, and can still leave with what remains
        vm.prank(bob);
        ledger.open(STK, 0, Adjust(-100e24, 0, 0, 0, 0, true, type(uint256).max, address(0))); // 100 tokens of shares
        assertApproxEqAbs(stock.balanceOf(bob), 60e18, 1);
    }

    function test_burnBeyondTheDebtIsBadDebtCoveredBySurplusFirst() public {
        _open(alice, 100e18, 6_000e18);
        _open(bob, 100e18, 6_000e18); // $20,000 against $12,000
        vm.warp(vm.getBlockTimestamp() + 10 days); // interest paid by the type: its surplus
        _price(100e8);
        ledger.accrue(STK);
        uint256 surplus = treasury.surplusOf(STK);
        assertGt(surplus, 0);
        stock.adminBurn(address(vault), 140e18); // 70%: every share now redeems for 0.3 tokens, $30
        // alice: 100 shares x $30 = $3,000 against ~$6,016 of debt -> liquidated; the sale cannot cover it
        liquidator.liquidate(_pid(STK, alice));
        // The sale covers its own shortfall in the same transaction (audit wave 1), the type's own interest first: the
        // Treasury holds only that interest here, so all of it goes and the rest stays booked.
        uint256 held = usd.balanceOf(address(treasury));
        assertEq(held, surplus, "the Treasury's imdUSD is the type's interest");
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Treasury.BadDebtCovered(STK, surplus, 0);
        vm.prank(taker);
        sjoin.take(_pid(STK, alice), type(uint256).max);
        assertEq(treasury.surplusOf(STK), 0, "the type's surplus is spent first");
        (,,,, uint128 bad) = ledger.ilkState(STK);
        assertGt(bad, 3_000e18 - surplus, "the rest of the shortfall is the type's bad debt");
        // the rest of the Treasury's imdUSD covers what is left
        uint256 ethInterest = 50_000e18; // stands in for other types' interest held by the Treasury
        deal(address(usd), address(treasury), usd.balanceOf(address(treasury)) + ethInterest, true);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Treasury.BadDebtCovered(STK, 0, bad);
        treasury.coverBadDebt(STK);
        (,,,, bad) = ledger.ilkState(STK);
        assertEq(bad, 0);
        _supplyHoldsWithDeal(ethInterest);
    }

    function test_totalBurnIsWrittenOffWithoutAPrice() public {
        _open(alice, 100e18, 6_000e18);
        vm.expectRevert(LedgerBase.NotWorthless.selector);
        ledger.writeOff(_pid(STK, alice));
        stock.adminBurn(address(vault), 100e18); // the issuer seizes the whole custody
        assertTrue(price.isStale(), "a share worth nothing reads unpriced");
        // permissionless: two worthless readings >= 1 h apart; the first only arms
        ledger.writeOff(_pid(STK, alice));
        assertEq(ledger.worthlessSince(STK), vm.getBlockTimestamp());
        assertGt(ledger.debtOf(_pid(STK, alice)), 0, "armed, nothing written off yet");
        vm.warp(vm.getBlockTimestamp() + ledger.WRITEOFF_DELAY());
        uint256 debt = ledger.debtOf(_pid(STK, alice));
        uint256 shares = ledger.position(_pid(STK, alice)).collateral;
        ledger.writeOff(_pid(STK, alice));
        assertEq(vault.balanceOf(address(treasury)), shares, "seized shares go to the Treasury, not stranded (F5)");
        assertEq(ledger.debtOf(_pid(STK, alice)), 0);
        assertEq(ledger.position(_pid(STK, alice)).collateral, 0);
        (uint128 d, uint128 coll,,, uint128 bad) = ledger.ilkState(STK);
        // the type's aggregate accrues rounding UP (Ledger._accrue, Ceil): after the F5 delay's hour of interest it may
        // carry 1 wei over the sum of its positions
        assertApproxEqAbs(d, 0, 1);
        assertEq(coll, 0);
        assertEq(bad, debt);
        _supplyHolds();
        vm.expectRevert(LedgerBase.NoDebt.selector);
        ledger.writeOff(_pid(STK, alice));
    }

    function test_blocklistedCustodyFreezesThenASeizureIsWrittenOff() public {
        _open(alice, 100e18, 6_000e18);
        reg.setBlocked(address(vault), true);
        assertTrue(price.isStale(), "frozen: no debt, no liquidation");
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(STK, 0, Adjust(0, 1e18 * 100, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        // the issuer's usual next step for a blocked holder: seize the balance
        stock.adminBurn(address(vault), 100e18);
        _writeOff(alice);
        (,,,, uint128 bad) = ledger.ilkState(STK);
        assertGt(bad, 6_000e18 - 1);
        _supplyHolds();
    }

    function test_badDebtCountsAgainstTheGroupLine() public {
        _open(alice, 100e18, 6_000e18);
        stock.adminBurn(address(vault), 100e18);
        _writeOff(alice); // 6,000 of bad debt in the group
        // The unbacked brake is a separate rule: with the hole covered by Treasury imdUSD it stays open, and
        // the group line binds on its own.
        deal(address(usd), address(treasury), usd.balanceOf(address(treasury)) + 6_000e18, true);
        // the group's line binds every member: move ETH into it (48h) and its new debt meets the stock type's bad debt
        vm.prank(governor);
        params.propose(abi.encode(uint8(12), ETH, GROUP, uint256(10_000e18)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        weth.mint(bob, 100e18);
        ethFeed.set(2_000e18);
        vm.startPrank(bob);
        weth.approve(address(ledger), type(uint256).max);
        vm.expectRevert(LedgerBase.GroupLineExceeded.selector);
        ledger.open(ETH, 0, Adjust(100e18, 4_100e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(ETH, 0, Adjust(100e18, 3_900e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
    }

    /// @dev The first worthless reading arms, the second (>= WRITEOFF_DELAY later) writes off.
    function _writeOff(address who) internal {
        ledger.writeOff(_pid(STK, who));
        vm.warp(vm.getBlockTimestamp() + ledger.WRITEOFF_DELAY());
        ledger.writeOff(_pid(STK, who));
    }

    function _bad() internal view returns (uint128 bad) {
        (,,,, bad) = ledger.ilkState(STK);
    }

    function _supplyHoldsWithDeal(uint256 dealt) internal view {
        (uint128 debt,,,, uint128 bad) = ledger.ilkState(STK);
        (uint128 eDebt,,,, uint128 eBad) = ledger.ilkState(ETH);
        uint256 sum = uint256(debt) + bad + eDebt + eBad + ledger.reserveBacked() + dealt;
        assertApproxEqAbs(sum, usd.totalSupply(), 2, "supply equation (+ the dealt stand-in)");
    }
}
