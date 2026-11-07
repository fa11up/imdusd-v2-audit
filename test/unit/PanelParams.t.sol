// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {GovernedByKind} from "../../src/GovernedByKind.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Parameters / governance: regression tests moved from the 2026-11 internal review's PoCs. Each failed before
/// the fix.
contract PanelParamsTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant NHI = "NHI";

    MockERC20 weth;
    MockERC20 simd;
    MockFeed ethMedian;
    MockFeed ethSpot;
    MockFeed simdFeed;
    MockFeed nhiFeed;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        simd = new MockERC20("sIMD", 18);
        ethMedian = new MockFeed(2000e18);
        ethSpot = new MockFeed(2000e18);
        simdFeed = new MockFeed(10e18);
        nhiFeed = new MockFeed(1e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethMedian, ethSpot, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1_000_000e18));
        ParametersBase.Risk memory nr = _risk(1.7e18, 1_000_000e18);
        nr.chop = 0.2e18;
        _addIlk(NHI, address(simd), simdFeed, simdFeed, nhiFeed, address(0), address(0), true, nr);
        params.setGenesisCap(ETH, 3000e18);
        params.setGenesisTarget(ETH, 0.1e18);
        params.seal();
        address[2] memory us = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            weth.mint(us[i], 1000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    mapping(uint256 => bool) internal _opened;

    function _adjust(address u, int256 coll, int256 debt) internal {
        Adjust memory a = Adjust(coll, debt, 0.05e18, 0, 0, false, type(uint256).max, address(0));
        uint256 id = _pid(ETH, u);
        bool exists = _opened[id];
        vm.prank(u);
        if (exists) ledger.adjust(id, a);
        else ledger.open(ETH, 0, a);
        _opened[id] = ledger.ilkOf(id) != bytes32(0);
    }

    function adjustAs(address u, int256 coll, int256 debt) external {
        _adjust(u, coll, debt);
    }

    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
        simdFeed.set(simdFeed.value());
        nhiFeed.set(nhiFeed.value());
    }

    function _ethTo(uint256 p) internal {
        ethMedian.set(p);
        ethSpot.set(p);
    }

    function _propose(bytes memory payload) internal {
        vm.prank(governor);
        params.propose(payload);
    }

    function _setRisk(bytes32 ilk, uint64 mat, uint64 chop) internal view returns (bytes memory) {
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        r.mat = mat;
        r.chop = chop;
        return abi.encode(params.SET_RISK(), ilk, r);
    }

    function _applyRiskIn48h(bytes memory payload) internal {
        _propose(payload);
        _skip(48 hours);
        params.applyPending(params.SET_RISK());
    }

    // ================================================================ RISK_GRACE bypass

    /// A BATCH of a harsh SET_RISK (pending 7 days) then a milder one "kinder" than it used to bind the milder one at
    /// once for every v0 position. It is harsher than v0, so it now waits the grace.
    function test_panelM10_batchCannotSkipTheRiskGrace() public {
        _adjust(bob, 100e18, 30_000e18);
        _adjust(alice, 10e18, 13_300e18); // ~150% at $2,000, mat 140%
        bytes[] memory items = new bytes[](2);
        items[0] = _setRisk(ETH, 3e18, 0.25e18);
        items[1] = _setRisk(ETH, 1.6e18, 0.2e18);
        _propose(abi.encode(params.BATCH(), items));
        _skip(48 hours);
        params.applyPending(params.BATCH());
        (uint256 mat, uint256 chop) = params.liqRisk(ETH, 0);
        assertEq(mat, 1.4e18, "v0 keeps 140% for the grace");
        assertEq(chop, 0.1e18);
        vm.prank(bob);
        vm.expectRevert(Liquidator.Healthy.selector);
        liquidator.liquidate(_pid(ETH, alice));
        // After the grace the milder item (the newest) is what binds, never the harsh 300% one.
        _skip(7 days);
        (mat, chop) = params.liqRisk(ETH, 0);
        assertEq(mat, 1.6e18);
        assertEq(chop, 0.2e18);
    }

    /// An honest softening of a pending raise (160% pending, then 150%) used to bind 150% at once for v0 positions. It
    /// now binds no earlier than the raise it softens, and the superseded 160% never binds for v0 positions.
    function test_panelM10_honestSofteningKeepsTheGrace() public {
        _adjust(bob, 100e18, 50_000e18);
        _adjust(alice, 10e18, 13_750e18); // ~145%
        _applyRiskIn48h(_setRisk(ETH, 1.6e18, 0.1e18)); // v1 160%, binds day 9
        uint256 v1Bind = vm.getBlockTimestamp() + 7 days;
        _applyRiskIn48h(_setRisk(ETH, 1.5e18, 0.1e18)); // v2 150% (kinder than v1, harsher than v0)
        (uint256 mat,) = params.liqRisk(ETH, 0);
        assertEq(mat, 1.4e18, "v0 still on 140%");
        vm.prank(bob);
        vm.expectRevert(Liquidator.Healthy.selector);
        liquidator.liquidate(_pid(ETH, alice));
        // At v1's old bindAt the superseded 160% does not bind for v0 positions.
        vm.warp(v1Bind + 1);
        (mat,) = params.liqRisk(ETH, 0);
        assertEq(mat, 1.4e18, "the softened raise never binds on its own");
        // A full grace after the softening: 150%.
        _skip(2 days);
        (mat,) = params.liqRisk(ETH, 0);
        assertEq(mat, 1.5e18);
    }

    /// A change kinder than the version in force AND every pending one still binds at once.
    function test_panelM10_kinderThanAllBindsNow() public {
        _applyRiskIn48h(_setRisk(ETH, 1.6e18, 0.1e18)); // pending 160%
        _applyRiskIn48h(_setRisk(ETH, 1.3e18, 0.1e18)); // kinder than v0 and v1
        (uint256 mat,) = params.liqRisk(ETH, 0);
        assertEq(mat, 1.3e18);
        (mat,) = params.liqRisk(ETH, 1);
        assertEq(mat, 1.3e18, "positions on the pending 160% too");
    }

    /// An NHI-linked type compares chop only (its mat is live); a lower chop binds at once whatever the stored mat says.
    function test_panelM10_nhiTypeComparesChopOnly() public {
        _applyRiskIn48h(_setRisk(NHI, 2.5e18, 0.15e18)); // mat field meaningless; chop 20% -> 15%
        (, uint256 chop) = params.liqRisk(NHI, 0);
        assertEq(chop, 0.15e18, "kinder chop binds now");
    }

    // ================================================================ dust bounded, no one-step full-close switch

    /// The PoC: SET_RISK line 0 + dust 2^128-1 used to pass and, at apply, turn every partial liquidation into a full close
    /// and refuse partial repayments. Now dust is bounded by MAX_DUST at any line, and one change at most doubles it.
    function test_panelV1_dustBoundedAndStepped() public {
        _adjust(bob, 100e18, 50_000e18);
        _adjust(alice, 10e18, 13_300e18);
        uint8 k = params.SET_RISK();
        ParametersBase.Risk memory r = params.storedRisk(ETH);
        r.line = 0;
        r.dust = type(uint128).max;
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, ETH, r)); // the PoC's payload
        r.dust = 5_000e18; // = MAX_DUST: inside the source bound, but 50x the dust in force in one step
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, ETH, r));
        r = params.storedRisk(ETH);
        r.dust = r.dust * 2; // a doubling is allowed
        _propose(abi.encode(k, ETH, r));
        _skip(48 hours);
        params.applyPending(k);
        _ethTo(1850e18);
        uint256 id = _pid(ETH, alice);
        assertLt(ledger.liquidationNeed(id, 1850e18), ledger.debtOf(id), "liquidation stays partial");
        _adjust(alice, 0, -1_000e18); // a partial repayment still works
    }

    // ================================================================ an instant lower is not undone

    /// The PoC: a routine SET_RISK pending, then the emergency `lowerLine(ETH, 0)`; after the ETA a stranger applied the stale
    /// proposal and the line was back at 1M. The lower now cancels it: nothing is left to apply and the type stays frozen.
    function test_panelM8_lowerLineCancelsStaleSetRisk() public {
        _adjust(alice, 10e18, 10_000e18);
        ParametersBase.Risk memory r = params.storedRisk(ETH);
        r.redeemFloor = 0.01e18;
        uint8 k = params.SET_RISK();
        _propose(abi.encode(k, ETH, r));
        _skip(24 hours);
        vm.prank(governor);
        params.lowerLine(ETH, 0);
        _skip(24 hours);
        vm.prank(stranger);
        vm.expectRevert(GovernedByKind.NothingPending.selector);
        params.applyPending(k);
        assertEq(params.risk(ETH).line, 0, "still frozen");
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        this.adjustAs(bob, 10e18, 5_000e18);
    }

    /// The PoC: a pending SET_CAP 3,000 -> 4,500 survived `lowerCap(2,300)` and landed above the pre-emergency cap.
    function test_panelM8_lowerCapCancelsPendingRaise() public {
        uint8 k = params.SET_CAP();
        _propose(abi.encode(k, ETH, uint256(4500e18)));
        _skip(24 hours);
        vm.prank(governor);
        params.lowerCap(ETH, 2300e18);
        _skip(24 hours);
        vm.prank(stranger);
        vm.expectRevert(GovernedByKind.NothingPending.selector);
        params.applyPending(k);
        assertEq(params.cap(ETH), 2300e18);
    }

    /// A BATCH carrying the field is cancelled whole; a per-type lower leaves another type's proposal alone.
    function test_panelM8_batchCancelledAndOtherTypesKept() public {
        bytes[] memory items = new bytes[](2);
        items[0] = _setRisk(NHI, 1.7e18, 0.15e18);
        items[1] = abi.encode(params.SET_KEEPER_CAP(), uint256(1_000e18));
        _propose(abi.encode(params.BATCH(), items));
        vm.prank(governor);
        params.lowerLine(ETH, 1); // another type: the batch stays
        assertEq(params.pendingKinds(), uint256(1) << params.BATCH());
        vm.prank(governor);
        params.lowerLine(NHI, 1); // the batch carries SET_RISK on NHI: cancelled
        assertEq(params.pendingKinds(), 0);
        assertEq(params.locked(), 0);
    }

    /// Every other instant lower cancels its field's pending raise.
    function test_panelM8_everyInstantLowerCancels() public {
        // keeper cap
        _propose(abi.encode(params.SET_KEEPER_CAP(), uint256(2_000e18)));
        _skip(48 hours);
        params.applyPending(params.SET_KEEPER_CAP());
        _propose(abi.encode(params.SET_KEEPER_CAP(), uint256(5_000e18)));
        vm.prank(governor);
        params.lowerKeeperCap(1_000e18);
        assertEq(params.pendingKinds(), 0, "SET_KEEPER_CAP cancelled");
        // unbacked brake (genesis 1%)
        _propose(abi.encode(params.SET_UNBACKED_BRAKE(), uint64(0.02e18)));
        vm.prank(governor);
        params.lowerUnbackedBrake(0.005e18);
        assertEq(params.pendingKinds(), 0, "SET_UNBACKED_BRAKE cancelled");
    }

    // ================================================================ the cap (Parameters part)

    /// A mistaken cap far below the market used to take one doubling per 48h to undo (34 proposals for an 8-decimal unit
    /// error). SET_CAP may now raise straight to the live low in one step; past both 2x and the low it is still refused, and
    /// the bound is re-checked at apply against the low then.
    function test_panelM9_capLiftsToTheLiveLowInOneStep() public {
        vm.prank(governor);
        params.lowerCap(ETH, 500e18); // ETH at $2,000
        uint8 k = params.SET_CAP();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, ETH, uint256(2001e18))); // above 2x and above the low
        _propose(abi.encode(k, ETH, uint256(2000e18))); // 4x, = the live low: allowed
        _skip(48 hours);
        _ethTo(1500e18); // the low fell in the window: 2,000 > max(2 x 500, 1,500) at apply
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.applyPending(k);
        _ethTo(2000e18);
        params.applyPending(k);
        assertEq(params.cap(ETH), 2000e18);
    }

    /// lowerCap refuses a cap below 1/100 of the live low (a unit error); a cap at or above it is still instant.
    function test_panelM9_lowerCapRefusesAUnitError() public {
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerCap(ETH, 19e18); // < $2,000 / 100
        vm.prank(governor);
        params.lowerCap(ETH, 20e18);
        assertEq(params.cap(ETH), 20e18);
    }
}
