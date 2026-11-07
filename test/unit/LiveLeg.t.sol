// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";

/// @notice A type priced by two attested legs with a live leg in its `liveSpot` slot, as sIMD is, and the liquidation guard.
contract LiveLegTest is System {
    bytes32 constant SIMD = "SIMD";
    bytes32 constant ETH = "ETH";
    uint256 constant TRUE_PRICE = 10e18;
    uint256 constant SKEW = 0.05e18;

    MockERC20 simd;
    MockERC20 weth;
    MockFeed median;
    MockFeed spot;
    MockFeed live;
    MockFeed ethFeed;

    address borrower = makeAddr("borrower");
    address caller = makeAddr("caller");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
        simd = new MockERC20("sIMD", 18);
        weth = new MockERC20("WETH", 18);
        median = new MockFeed(TRUE_PRICE);
        spot = new MockFeed(TRUE_PRICE);
        live = new MockFeed(TRUE_PRICE);
        ethFeed = new MockFeed(2000e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));

        ParametersBase.Risk memory r = _risk(1.7e18, 10_000_000e18);
        r.chop = 0.08e18;
        r.redeemCap = 20_000e18;
        r.skew = uint64(SKEW);
        IFeed no = IFeed(address(0));
        _addIlk(SIMD, address(simd), median, spot, no, address(0), address(0), IFeed(address(live)), true, r);
        _addIlk(ETH, address(weth), ethFeed, ethFeed, no, address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        params.setGenesisMigratorLine(10_000_000e18);
        params.seal();

        address[2] memory us = [borrower, caller];
        for (uint256 i; i < 2; ++i) {
            simd.mint(us[i], 1_000_000e18);
            weth.mint(us[i], 1_000e18);
            vm.startPrank(us[i]);
            simd.approve(address(ledger), type(uint256).max);
            weth.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _pair(uint256 v) internal {
        median.set(v);
        spot.set(v);
        ethFeed.set(2000e18);
    }

    function _open(uint256 salt, uint256 debt, uint256 cr) internal returns (uint256 id) {
        vm.prank(borrower);
        id = ledger.open(SIMD, salt, Adjust(int256(debt * cr / TRUE_PRICE), int256(debt), 0.04e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function _fundCaller(uint256 amount) internal {
        vm.prank(caller);
        ledger.open(ETH, 9, Adjust(int256(amount * 2 / 2000), int256(amount), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function test_liveLegSetsThePayoutAndAgreeOnly() public {
        _pair(6e18);
        Pricer.Quote memory q = pricer.quote(SIMD);
        assertEq(q.low, 6e18, "the raw pair");
        assertEq(q.high, 6e18);
        assertEq(q.payout, TRUE_PRICE, "max(high, live)");
        assertEq(q.borrow, 6e18);
        assertTrue(q.priced && q.borrowable && q.agree);
        live.set(3e18);
        q = pricer.quote(SIMD);
        assertEq(q.payout, 6e18);
        assertFalse(q.agree, "live under low past skew");
        assertTrue(q.borrowable);
        live.setStale(true);
        q = pricer.quote(SIMD);
        assertEq(q.payout, 0);
        assertFalse(q.agree);
        assertTrue(q.priced);
    }

    function test_typeWithoutLiveLegUnchanged() public view {
        Pricer.Quote memory q = pricer.quote(ETH);
        assertEq(q.low, 2000e18);
        assertEq(q.payout, 2000e18);
        assertTrue(q.priced && q.borrowable && q.agree);
    }

    /// The accepted risk (README, known issues): nothing on chain checks a pair against the market, so a -40% pair makes a book that is healthy at the market liquidatable.
    function test_acceptedRisk_aLowPairMakesTheBookLiquidatable() public {
        uint256 id1 = _open(1, 6_000e18, 1.75e18);
        uint256 id2 = _open(2, 6_000e18, 2.3e18);
        _pair(6e18);
        (bool ok,) = ledger.healthy(id1);
        assertFalse(ok);
        (ok,) = ledger.healthy(id2);
        assertFalse(ok);
    }

    /// A charged rate change adds debt, so a pair above the pool is not a price to add it at. Borrowing is not touched.
    function test_chargedRateChangeRefusedWithThePairAboveThePool() public {
        uint256 o = _open(2, 6_000e18, 3e18);
        vm.prank(borrower);
        ledger.setRate(o, 0.06e18, 0, 0);
        live.set(TRUE_PRICE * 90 / 100);
        assertFalse(pricer.quote(SIMD).agree);
        vm.prank(borrower);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.setRate(o, 0.07e18, 0, 0);
        vm.prank(borrower);
        ledger.adjust(o, Adjust(0, int256(10e18), 0.06e18, 0, 0, false, type(uint256).max, address(0)));
        live.set(TRUE_PRICE);
        vm.prank(borrower);
        ledger.setRate(o, 0.07e18, 0, 0);
    }

    function test_chargedRateChangeOnATypeWithoutLiveLeg() public {
        vm.startPrank(caller);
        uint256 e = ledger.open(ETH, 9, Adjust(int256(1e18 * 100), int256(10_000e18), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        ledger.setRate(e, 0.06e18, 0, 0);
        ledger.setRate(e, 0.07e18, 0, 0);
        vm.stopPrank();
    }

    /// `minSeized`: a price update landing ahead of a caller reverts instead of charging him the difference.
    function test_guardRefusesAPriceMovedAhead() public {
        uint256 id = _open(1, 6_000e18, 1.75e18);
        _fundCaller(30_000e18);
        _pair(9e18);
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (, uint256 seen,) = liquidator.liquidate(id);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        vm.prank(caller);
        (, uint256 ok,) = liquidator.liquidate(id, seen);
        assertEq(ok, seen, "no move: the guard passes at exactly what was seen");
        vm.revertToState(snap);

        _pair(9.5e18);
        vm.prank(caller);
        vm.expectPartialRevert(Liquidator.SeizedTooLow.selector);
        liquidator.liquidate(id, seen);
        vm.prank(caller);
        (, uint256 moved,) = liquidator.liquidate(id);
        assertLt(moved, seen, "unguarded, the caller is charged the move");
    }
}
