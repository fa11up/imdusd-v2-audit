// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";
import {MockStockToken} from "../utils/StockMocks.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Stock tokens through the core: market hours on borrowing and liquidation, the stock group's cap, the USDG auction
/// (reserve-settled), and an issuer's admin burn realised as the type's bad debt (type surplus first, then the Treasury).
contract StockLendingTest is StockSystem {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address taker = makeAddr("taker");
    address marker = makeAddr("marker");

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
        usdg.mint(taker, 1_000_000e6);
        vm.prank(taker);
        usdg.approve(address(sjoin), type(uint256).max);
    }

    function _borrow(address who, int256 debt) internal {
        vm.prank(who);
        ledger.open(STK, 0, Adjust(0, debt, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    // ------------------------------------------------------------ market hours through the core

    function test_noDebtOutsideTheSessionRepayAlways() public {
        _open(alice, 100e18, 5_000e18); // $10,000 of SPY at 150%
        vm.warp(FRI_CLOSE);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        _borrow(alice, 100e18);
        // repayment needs no price
        _borrow(alice, -1_000e18);
        // a withdrawal with debt outstanding does
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(STK, 0, Adjust(-1e18, 0, 0, 0, 0, true, type(uint256).max, address(0)));
        vm.warp(NEXT_MON_OPEN);
        _price(100e8);
        _borrow(alice, 100e18);
        _supplyHolds();
    }

    function test_marketClosedLiquidationWaitsForTheOpen() public {
        _open(alice, 100e18, 6_000e18);
        vm.warp(FRI_CLOSE - 1);
        _price(95e8); // 9,500 vs 9,000 needed: still healthy
        vm.warp(FRI_CLOSE + 1 days); // the weekend: the real price falls
        vm.expectRevert(Liquidator.NotPriced.selector);
        liquidator.bark(_pid(STK, alice));
        vm.warp(NEXT_MON_OPEN - 13.5 hours);
        _price(85e8); // Sunday night: published, not priced
        vm.expectRevert(Liquidator.NotPriced.selector);
        liquidator.bark(_pid(STK, alice));
        vm.warp(NEXT_MON_OPEN);
        vm.prank(marker);
        liquidator.liquidate(_pid(STK, alice)); // marks and opens the auction at the open
        (uint64 at, address m) = sjoin.auctions(_pid(STK, alice));
        assertEq(at, NEXT_MON_OPEN);
        assertEq(m, marker);
    }

    // ------------------------------------------------------------ group cap

    function test_groupLineCapsStockDebtNotOtherTypes() public {
        _open(alice, 1_000e18, 49_000e18);
        _fund(bob, 1_000e18);
        // The room left in the group, net of the borrow's upfront fee (7 days at the type's 5% average).
        (, uint256 gl) = params.groupCap(STK);
        (uint128 gd,,,,) = ledger.ilkState(STK);
        uint256 b = (gl - gd) * 365 days / (365 days + 0.05e18 * 7 days / 1e18) / 1e18 * 1e18;
        vm.prank(bob);
        vm.expectRevert(LedgerBase.GroupLineExceeded.selector);
        ledger.open(STK, 0, Adjust(1_000e18, int256(b + 1e18), 0.05e18, 0, 0, true, type(uint256).max, address(0)));
        vm.prank(bob);
        ledger.open(STK, 0, Adjust(1_000e18, int256(b), 0.05e18, 0, 0, true, type(uint256).max, address(0))); // up to the line, fee included
        // ETH is outside the group
        weth.mint(bob, 100e18);
        vm.startPrank(bob);
        weth.approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(100e18, 60_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        // the line moves only through the timelock, inside its bound
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(13), bytes32(0), GROUP, uint256(50_000_001e18)));
        vm.prank(governor);
        params.propose(abi.encode(uint8(13), bytes32(0), GROUP, uint256(60_000e18)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _price(100e8);
        params.applyPending();
        (uint8 g, uint256 line) = params.groupCap(STK);
        assertEq(g, GROUP);
        assertEq(line, 60_000e18);
        _borrow(bob, 5_000e18);
        _supplyHolds();
    }

    function test_groupBoundsAndMembershipChange() public {
        vm.startPrank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(12), STK, uint8(8), uint256(1e18)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(12), STK, uint8(0), uint256(1e18)));
        vm.expectRevert(ParametersBase.UnknownIlk.selector);
        params.propose(abi.encode(uint8(12), bytes32("NOPE"), GROUP, uint256(1e18)));
        params.propose(abi.encode(uint8(12), ETH, GROUP, uint256(50_000e18)));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        assertEq(params.groupOf(ETH), GROUP);
    }

    // ------------------------------------------------------------ USDG auction

    function _unhealthyAtOpen() internal {
        _open(alice, 100e18, 6_000e18); // $10,000 at 150%: 9,000 needed
        vm.warp(MON_1400 + 1 hours);
        _price(80e8); // $8,000 < $9,000
        vm.prank(marker);
        liquidator.liquidate(_pid(STK, alice));
    }

    function test_auctionPriceIsLiveAndDecaysToTheFloor() public {
        _unhealthyAtOpen();
        // prices are per 1e18 vault SHARES = 1e-6 of a token (StockVault offset)
        assertEq(sjoin.price(_pid(STK, alice)), 80e12, "starts at the live quote");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertEq(sjoin.price(_pid(STK, alice)), 76e12, "halfway to the 90% floor");
        _price(70e8);
        assertEq(sjoin.price(_pid(STK, alice)), 66.5e12, "follows the feed, not a snapshot");
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertEq(sjoin.price(_pid(STK, alice)), 63e12, "floor");
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        assertEq(sjoin.price(_pid(STK, alice)), 0, "lapsed at 2x the auction time");
        // still unhealthy: marked and bitten again, a fresh auction from the live price
        vm.prank(marker);
        liquidator.liquidate(_pid(STK, alice));
        assertEq(sjoin.price(_pid(STK, alice)), 70e12);
    }

    function test_takeSettlesInUsdgReserveBackedAndDeliversStock() public {
        _unhealthyAtOpen();
        uint256 supplyBefore = usd.totalSupply();
        uint256 debt = ledger.debtOf(_pid(STK, alice));
        uint256 recorded = ledger.position(_pid(STK, alice)).debt; // 6,000 + its upfront fee, already minted
        (uint256 units, uint256 paid) = _take(80e18);
        // the whole position: debt ~6,000 covered (8,000 / 1.1 > 6,000); the penalty (10% of it) stays in units, ~7.5 SPY
        // units are vault shares (1e6 per token unit, StockVault offset, ); the auction prices 1e18 of them at 80e12
        uint256 bonus = debt * 0.1e18 / 80e12;
        uint256 toTreasuryUsdg = (debt + 1e12 - 1) / 1e12;
        assertEq(ledger.debtOf(_pid(STK, alice)), 0);
        assertEq(units, 100e24 - bonus, "the taker buys every unit but the penalty");
        assertEq(paid, (units * 80e12 / 1e18 + 1e12 - 1) / 1e12, "~92.5 tokens x $80, rounded up");
        assertApproxEqAbs(paid, 7_400e6, 1e6); // the debt includes the upfront fee: a few units' cents less
        assertApproxEqAbs(stock.balanceOf(taker), units / 1e6, 1, "redeemed to stock");
        assertEq(usdg.balanceOf(address(treasury)), toTreasuryUsdg, "the repaid debt, at par, rounded up");
        assertEq(ledger.reserveBacked(), debt, "imdUSD stays out, backed by the Treasury's USDG");
        assertApproxEqAbs(usd.totalSupply(), supplyBefore + (debt - recorded), 2, "nothing burned (only the hour's interest minted)");
        assertEq(sjoin.owed(alice), paid - toTreasuryUsdg, "the excess is the borrower's");
        assertEq(vault.balanceOf(marker), bonus / 10, "chip: 10% of the penalty, in vault shares");
        assertEq(vault.balanceOf(address(treasury)), bonus - bonus / 10, "the rest of the penalty");
        vm.prank(alice);
        sjoin.claim(alice);
        assertEq(usdg.balanceOf(alice), paid - toTreasuryUsdg);
        _supplyHolds();
    }

    function _take(uint256 maxPrice) internal returns (uint256, uint256) {
        vm.prank(taker);
        return sjoin.take(_pid(STK, alice), maxPrice);
    }

    function test_blocklistedTakerLeavesTheAuctionRunning() public {
        _unhealthyAtOpen();
        reg.setBlocked(taker, true);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.Blocked.selector, taker));
        _take(80e18);
        (uint64 at,) = sjoin.auctions(_pid(STK, alice));
        assertTrue(at != 0, "still live");
        reg.setBlocked(taker, false);
        _take(80e18);
        assertEq(ledger.debtOf(_pid(STK, alice)), 0);
    }

    function test_pausedTokenFreezesTheAuction() public {
        _unhealthyAtOpen();
        stock.setPaused(true);
        assertEq(sjoin.price(_pid(STK, alice)), 0);
        vm.expectRevert(StockJoin.NotPriced.selector);
        _take(80e18);
        vm.expectRevert(Liquidator.NotPriced.selector);
        liquidator.bark(_pid(STK, bob));
        stock.setPaused(false);
        _take(80e18);
    }

    function test_repairedPositionCancelsTheAuction() public {
        _unhealthyAtOpen();
        vm.expectRevert(StockJoin.StillUnhealthy.selector);
        sjoin.cancel(_pid(STK, alice));
        _borrow(alice, -3_000e18); // the repayment heals it, and the Ledger ends the auction there
        assertEq(sjoin.price(_pid(STK, alice)), 0);
        vm.expectRevert(StockJoin.NoAuction.selector);
        sjoin.cancel(_pid(STK, alice));
    }
}
