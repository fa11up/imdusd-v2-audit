// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {LedgerSettlement} from "../../src/LedgerSettlement.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {ILedgerCover, IBackstopOracle} from "../../src/backstop/IBackstop.sol";
import {PricerOracle} from "../../src/backstop/PricerOracle.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice The standing bid wired into the core: the standing bid in `Liquidator.bite`, partial liquidation to a target,
/// the edge premium, the SUMMED edge capacity bound and the Treasury's waterfall (sleeve first).
contract StandingBidTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";
    bytes32 constant SIMD2 = "SIMD2";

    MockERC20 weth;
    MockERC20 simd;
    MockERC20 simd2;
    MockFeed ethFeed;
    MockFeed simdFeed;
    MockFeed simd2Feed;
    PricerOracle oracle;
    Backstop blue;
    Backstop edge;

    address alice = makeAddr("alice"); // borrower who gets liquidated
    address bob = makeAddr("bob"); // backstop depositor
    address carol = makeAddr("carol"); // kicker
    address dave = makeAddr("dave"); // second edge borrower

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        simd = new MockERC20("sIMD", 18);
        simd2 = new MockERC20("sIMD2", 18);
        ethFeed = new MockFeed(2000e18);
        simdFeed = new MockFeed(5e18);
        simd2Feed = new MockFeed(5e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        ParametersBase.Risk memory ir = _risk(1.7e18, 10_000_000e18);
        ir.chop = 0.2e18;
        _addIlk(SIMD, address(simd), simdFeed, simdFeed, IFeed(address(0)), address(0), address(0), true, ir);
        _addIlk(SIMD2, address(simd2), simd2Feed, simd2Feed, IFeed(address(0)), address(0), address(0), true, ir);

        oracle = new PricerOracle(pricer, address(params));
        oracle.setIlk(address(weth), ETH);
        oracle.setIlk(address(simd), SIMD);
        oracle.setIlk(address(simd2), SIMD2);
        oracle.seal();
        blue = new Backstop(IERC20(address(usd)), ILedgerCover(address(ledger)), IBackstopOracle(address(oracle)), false, "blue", "bBACK");
        edge = new Backstop(IERC20(address(usd)), ILedgerCover(address(ledger)), IBackstopOracle(address(oracle)), true, "edge", "eBACK");
        blue.wire(address(liquidator), address(params), address(0));
        edge.wire(address(liquidator), address(params), address(0));
        blue.addIlk(ETH, address(weth), 0, type(uint128).max, 0);
        edge.addIlk(SIMD, address(simd), 20_000e18, type(uint128).max, 0);
        edge.addIlk(SIMD2, address(simd2), 20_000e18, type(uint128).max, 0);
        blue.seal();
        edge.seal();

        params.setGenesisBackstops(address(blue), address(edge), 0.2e18);
        params.setGenesisEdgeIlk(SIMD);
        params.setGenesisEdgeIlk(SIMD2);
        params.setGenesisMigratorLine(10_000_000e18);
        params.seal();

        address[4] memory us = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            weth.mint(us[i], 10_000e18);
            simd.mint(us[i], 1_000_000e18);
            simd2.mint(us[i], 1_000_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            simd.approve(address(ledger), type(uint256).max);
            simd2.approve(address(ledger), type(uint256).max);
            usd.approve(address(blue), type(uint256).max);
            usd.approve(address(edge), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _open(address u, bytes32 ilk, uint256 coll, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        vm.prank(u);
        ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _refresh() internal {
        ethFeed.set(ethFeed.value());
        simdFeed.set(simdFeed.value());
        simd2Feed.set(simd2Feed.value());
    }

    /// @dev Bob borrows `amount` imdUSD against ETH and deposits it into `sleeve`; two days later it is bid room.
    function _fund(Backstop sleeve, uint256 amount, bool mature) internal {
        _open(bob, ETH, 2 * amount / 1000e18 * 1e18 + 10e18, amount, 0.05e18);
        vm.prank(bob);
        sleeve.deposit(amount, bob);
        if (mature) {
            vm.warp(vm.getBlockTimestamp() + 2 days);
            _refresh();
        }
    }

    function _setTarget(bytes32 ilk, uint64 buffer) internal {
        uint8 kind = params.SET_TARGET();
        vm.prank(governor);
        params.propose(abi.encode(kind, ilk, buffer));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _refresh();
        params.applyPending();
    }

    // ------------------------------------------------------------ standing bid

    function test_standingBidBuysTheCollateralAndKeepsThePenalty() public {
        _fund(blue, 50_000e18, true);
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        uint256 debt = ledger.debtOf(_pid(ETH, alice));
        ethFeed.set(1800e18);
        uint256 carolUsd = usd.balanceOf(carol);
        blue.realize(bob); // convert the matured bucket now so the room can be read before the bite
        uint256 roomBefore = blue.bidRoom(ETH);

        vm.prank(carol);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(_pid(ETH, alice));

        assertEq(repaid, debt, "closes in full: no target set");
        assertEq(bad, 0);
        assertEq(usd.balanceOf(carol), carolUsd, "the kicker paid nothing: the sleeve did");
        assertEq(blue.bidRoom(ETH), roomBefore - repaid, "the sleeve spent exactly what was repaid");
        uint256 got = blue.coll(address(weth));
        // seized = debt/1800 * 1.1; Treasury 50% of the bonus, marker (carol) 10% of it; the sleeve the rest
        uint256 bonus = seized - debt * 1e18 / 1800e18;
        assertApproxEqAbs(weth.balanceOf(address(treasury)), bonus / 2, 2);
        assertApproxEqAbs(weth.balanceOf(carol) - 10_000e18, bonus / 10, 2, "kicker earns only the marker's chip");
        assertApproxEqAbs(got, seized - bonus / 2 - bonus / 10, 3, "the sleeve keeps the collateral and the rest of the penalty");
        assertGt(got * 1800e18 / 1e18, repaid, "bought below the price it is worth");
    }

    function test_noRoomFallsBackToTheCaller() public {
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(carol, ETH, 100e18, 30_000e18, 0.05e18);
        uint256 debt = ledger.debtOf(_pid(ETH, alice));
        ethFeed.set(1800e18);
        uint256 before = usd.balanceOf(carol);
        vm.prank(carol);
        liquidator.liquidate(_pid(ETH, alice));
        assertEq(before - usd.balanceOf(carol), debt, "no sleeve room: the caller pays, as before");
        assertEq(blue.coll(address(weth)), 0);
    }

    function test_immatureDepositsDoNotBid() public {
        _fund(blue, 50_000e18, false); // deposited, not yet two days old
        assertEq(blue.bidRoom(ETH), 0);
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(carol, ETH, 100e18, 30_000e18, 0.05e18);
        ethFeed.set(1800e18);
        uint256 before = usd.balanceOf(carol);
        vm.prank(carol);
        liquidator.liquidate(_pid(ETH, alice));
        assertGt(before - usd.balanceOf(carol), 0, "a fresh deposit cannot be flashed in to take the bid");
    }

    function test_openBidConvertsMaturedBucketsWithoutRealize() public {
        _fund(blue, 50_000e18, true); // nobody called realize
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        ethFeed.set(1800e18);
        vm.prank(carol);
        liquidator.liquidate(_pid(ETH, alice));
        assertGt(blue.coll(address(weth)), 0, "the bid filled from the matured bucket");
    }

    // ------------------------------------------------------------ partial to target

    function test_partialLiquidationRestoresTheTarget() public {
        _setTarget(ETH, 0.2e18); // target 160% on a 140% type
        _fund(blue, 50_000e18, false);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _refresh();
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        uint256 debt = ledger.debtOf(_pid(ETH, alice));
        ethFeed.set(1900e18); // 19,000 / 14,0xx ~ 135%
        vm.prank(carol);
        (uint256 repaid,,) = liquidator.liquidate(_pid(ETH, alice));
        assertLt(repaid, debt, "only part of the debt");
        uint256 left = ledger.debtOf(_pid(ETH, alice));
        assertEq(left, debt - repaid, "the rest stays a live position");
        uint256 coll = ledger.position(_pid(ETH, alice)).collateral;
        uint256 cr = coll * 1900e18 / left;
        assertApproxEqRel(cr, 1.6e18, 0.001e18, "back at mat + buffer");
        assertGe(cr, 1.6e18, "rounded in the system's favour");
        assertTrue(sorted.contains(ETH, _pid(ETH, alice)), "still in the redemption order at its own rate");
        assertEq(ledger.position(_pid(ETH, alice)).rate, 0.05e18);
    }

    function test_partialThatWouldLeaveDustClosesInFull() public {
        _setTarget(ETH, 0.2e18);
        _fund(blue, 50_000e18, false);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _refresh();
        // 150 imdUSD of debt: any partial repay leaves under the 100 imdUSD dust
        _open(alice, ETH, 0.12e18, 150e18, 0.05e18);
        uint256 debt = ledger.debtOf(_pid(ETH, alice));
        ethFeed.set(1700e18);
        vm.prank(carol);
        (uint256 repaid,,) = liquidator.liquidate(_pid(ETH, alice));
        assertEq(repaid, debt);
        assertEq(ledger.debtOf(_pid(ETH, alice)), 0);
    }

    function test_liquidationNeedMatchesTheSettlement() public {
        _setTarget(ETH, 0.2e18);
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(carol, ETH, 100e18, 30_000e18, 0.05e18);
        ethFeed.set(1900e18);
        uint256 need = ledger.liquidationNeed(_pid(ETH, alice), 1900e18);
        vm.prank(carol);
        (uint256 repaid,,) = liquidator.liquidate(_pid(ETH, alice));
        assertEq(repaid, need);
    }

    // ------------------------------------------------------------ edge premium and capacity

    function test_edgePremiumIsMintedToTheEdgeSleeve() public {
        _open(alice, SIMD, 100_000e18, 10_000e18, 0.1e18);
        uint256 edgeBefore = usd.balanceOf(address(edge));
        uint256 tBefore = usd.balanceOf(address(treasury));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _refresh();
        ledger.accrue(SIMD);
        uint256 toEdge = usd.balanceOf(address(edge)) - edgeBefore;
        uint256 toTreasury = usd.balanceOf(address(treasury)) - tBefore;
        assertGt(toEdge, 0);
        assertApproxEqRel(toEdge * 1e18 / (toEdge + toTreasury), 0.2e18, 0.0001e18, "20% of the edge type's interest");
        assertLt(edge.vested(), toEdge / 2, "it streams: most of it is not vested at arrival");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(edge.vested(), usd.balanceOf(address(edge)), 1, "fully vested after the 7-day stream");
    }

    function test_blueInterestPaysNoEdgePremium() public {
        _open(alice, ETH, 10e18, 10_000e18, 0.1e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _refresh();
        ledger.accrue(ETH);
        assertEq(usd.balanceOf(address(edge)), 0);
    }

    function test_edgeCapacityIsSummedOverEdgeTypes() public {
        // No edge deposits: capacity is the 60-day bootstrap allowance, 20,000 per type, but the BOUND is on the sum.
        _open(alice, SIMD, 1_000_000e18, 15_000e18, 0.1e18);
        uint256 used = ledger.ilkDebt(SIMD);
        uint256 room = edge.edgeCapacity(SIMD2, 0) - used; // 20,000 shared, not 20,000 more for the second type
        assertLt(room, 6_000e18);
        vm.prank(dave);
        vm.expectRevert(); // EdgeCapacityExceeded: the second type's debt counts against the same sleeve
        ledger.open(SIMD2, 0, Adjust(1_000_000e18, int256(room + 1_000e18), 0.1e18, 0, 0, false, type(uint256).max, address(0)));
        // within the shared room it is fine
        _open(dave, SIMD2, 1_000_000e18, 2_000e18, 0.1e18);
    }

    function test_edgeCapacityShrinksWithDebtUnderAMark() public {
        _open(alice, SIMD, 10_000e18, 25_000e18 / 2, 0.1e18);
        _open(carol, ETH, 100e18, 30_000e18, 0.05e18); // the kicker pays: no edge deposits
        simdFeed.set(2e18);
        vm.prank(carol);
        liquidator.bark(_pid(SIMD, alice));
        assertEq(liquidator.edgeInAuction(), ledger.debtOf(_pid(SIMD, alice)));
        vm.prank(carol);
        liquidator.bite(_pid(SIMD, alice));
        assertEq(liquidator.edgeInAuction(), 0, "cleared at the bite");
    }

    function _markedSimd() private returns (uint256 id) {
        _open(alice, SIMD, 10_000e18, 25_000e18 / 2, 0.1e18);
        id = _pid(SIMD, alice);
        simdFeed.set(2e18);
        liquidator.bark(id);
        assertGt(liquidator.edgeInAuction(), 0);
    }

    /// One dead feed must not shrink every edge type's room for good: `bite` and `clear` both refuse while it is unpriced.
    function test_releaseEdgeMark_afterALongOutage() public {
        uint256 id = _markedSimd();
        vm.expectRevert(Liquidator.EdgeMarkLive.selector);
        liquidator.releaseEdgeMark(id); // priced: `bite` or `clear` can end it
        simdFeed.setStale(true);
        liquidator.tick(SIMD);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(Liquidator.EdgeMarkLive.selector);
        liquidator.releaseEdgeMark(id);
        vm.expectRevert(Liquidator.NotPriced.selector);
        liquidator.clear(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        liquidator.releaseEdgeMark(id);
        assertEq(liquidator.edgeInAuction(), 0, "stops counting");
        (uint64 at,) = liquidator.marks(id);
        assertGt(at, 0, "the mark itself stays");
    }

    /// A repaid position's mark no longer stands for any debt, priced or not.
    function test_releaseEdgeMark_noDebtLeft() public {
        uint256 id = _markedSimd();
        simdFeed.setStale(true);
        deal(address(usd), alice, ledger.debtOf(id), true);
        vm.startPrank(alice);
        ledger.adjust(id, Adjust(0, -int256(ledger.debtOf(id)), 0, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        vm.expectRevert(Liquidator.NotPriced.selector);
        liquidator.clear(id);
        liquidator.releaseEdgeMark(id);
        assertEq(liquidator.edgeInAuction(), 0);
    }

    function test_bootstrapAllowanceDecaysToZero() public {
        assertEq(edge.edgeCapacity(SIMD, 0), 20_000e18);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(edge.edgeCapacity(SIMD, 0), 10_000e18);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(edge.edgeCapacity(SIMD, 0), 0, "after 60 days only deposits stand behind edge debt");
    }

    // ------------------------------------------------------------ waterfall

    function test_treasuryCoverTakesTheEdgeSleeveFirst() public {
        _fund(edge, 50_000e18, true);
        _open(alice, SIMD, 1_000e18, 2_000e18, 0.1e18);
        edge.realize(bob);
        simdFeed.set(1e18); // collateral worth 1,000 against ~2,000 debt: bad debt
        uint256 edgeBefore = edge.vested();
        uint256 tBefore = usd.balanceOf(address(treasury));
        vm.prank(carol);
        (,, uint256 bad) = liquidator.liquidate(_pid(SIMD, alice));
        assertGt(bad, 0, "bad debt was booked");
        // Covered inside the liquidation, edge sleeve first.
        (,,,, uint128 left) = ledger.ilkState(SIMD);
        assertEq(left, 0);
        assertEq(usd.balanceOf(address(treasury)), tBefore, "the Treasury paid nothing: the sleeve had room");
        assertLt(edge.vested(), edgeBefore, "the edge sleeve took the first loss");
    }
}
