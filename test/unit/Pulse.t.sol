// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoChains} from "../utils/TwoChains.sol";
import {Pulse} from "../../src/Pulse.sol";
import {Ledger} from "../../src/Ledger.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice The sequencer-outage grace. Exit criterion: a liquidation after a simulated sequencer gap waits
/// out the grace.
contract PulseTest is TwoChains {
    address alice = makeAddr("alice");
    address liq = makeAddr("liquidator");

    function setUp() public {
        _setUpChains();
        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(rh.ledger), type(uint256).max);
        vm.prank(alice);
        weth.approve(address(home.ledger), type(uint256).max);
    }

    // ------------------------------------------------------------ Pulse alone

    function test_boundsAndWiring() public {
        assertEq(address(rh.ledger.pulse()), address(rh.pulse));
        assertEq(address(rh.liquidator.pulse()), address(rh.pulse));
        assertEq(address(home.ledger.pulse()), address(0), "mainnet-shaped: no pulse");
        assertEq(address(home.liquidator.pulse()), address(0));
        assertEq(rh.pulse.gap(), 15 minutes);
        assertEq(rh.pulse.grace(), 1 hours);
        vm.expectRevert(Pulse.OutOfBounds.selector);
        new Pulse(30 seconds, 1 hours);
        vm.expectRevert(Pulse.OutOfBounds.selector);
        new Pulse(15 minutes, 0);
        vm.expectRevert(Pulse.OutOfBounds.selector);
        new Pulse(15 minutes, 7 hours);
        vm.expectRevert(Pulse.OutOfBounds.selector);
        new Pulse(2 hours, 1 hours);
    }

    function test_shortGapsNeverOpenAGrace() public {
        for (uint256 i; i < 10; ++i) {
            vm.warp(vm.getBlockTimestamp() + 15 minutes); // exactly the gap: not longer
            rh.pulse.poke();
            assertFalse(rh.pulse.inGrace());
        }
        assertEq(rh.pulse.graceUntil(), 0);
    }

    function test_longGapOpensGraceAndPokesCannotEndIt() public {
        vm.warp(vm.getBlockTimestamp() + 15 minutes + 1);
        assertTrue(rh.pulse.inGrace(), "a pending long gap already reads as grace");
        rh.pulse.poke();
        assertEq(rh.pulse.graceUntil(), vm.getBlockTimestamp() + 1 hours);
        uint256 until = rh.pulse.graceUntil();
        for (uint256 i; i < 5; ++i) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            rh.pulse.poke();
            assertTrue(rh.pulse.inGrace());
            assertEq(rh.pulse.graceUntil(), until, "short pokes do not move it");
        }
        vm.warp(until);
        rh.pulse.poke();
        assertFalse(rh.pulse.inGrace());
    }

    function test_everyCoreActionPokes() public {
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.prank(alice);
        rh.ledger.open(ETH, 0, Adjust(1e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(rh.pulse.lastPulse(), vm.getBlockTimestamp(), "adjust");
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        rh.ledger.accrue(ETH);
        assertEq(rh.pulse.lastPulse(), vm.getBlockTimestamp(), "accrue");
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.expectRevert(); // nothing to liquidate, but bark pokes before it checks health
        rh.liquidator.bark(_pid(ETH, alice));
    }

    // ------------------------------------------------------------ the exit criterion

    function _openUnsafe(Deploy.Deployed memory d) internal {
        vm.prank(alice);
        d.ledger.open(ETH, 0, Adjust(10e18, 13_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0))); // 10 ETH at $2000, 140%
        ethFeed.set(1700e18); // now 130%: unhealthy
        deal(address(d.usd), liq, 20_000e18);
    }

    function test_liquidationAfterSequencerGapWaitsOutTheGrace() public {
        _openUnsafe(rh);
        // The sequencer halts for 2 hours; when it resumes the price is still down (the feed updates on resumption).
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        ethFeed.set(1700e18);
        vm.prank(liq);
        (uint256 repaid, uint256 seized,) = rh.liquidator.liquidate(_pid(ETH, alice));
        assertEq(repaid + seized, 0, "held: the first liquidation after the silence starts the grace");
        assertEq(rh.ledger.debtOf(_pid(ETH, alice)) > 0, true);
        (uint64 at,) = rh.liquidator.marks(_pid(ETH, alice));
        assertEq(at, vm.getBlockTimestamp(), "marking is allowed during the grace");
        assertEq(rh.pulse.graceUntil(), vm.getBlockTimestamp() + 1 hours, "the liquidation's own poke started it, and it persisted");

        // Inside the grace: still held, however often anyone pokes (the keeper pokes every 10 minutes: no new gap).
        _alive(50 minutes);
        vm.prank(liq);
        (repaid, seized,) = rh.liquidator.bite(_pid(ETH, alice));
        assertEq(repaid + seized, 0, "still in grace");

        // The grace has run: the bite closes the position.
        _alive(10 minutes);
        vm.prank(liq);
        (repaid, seized,) = rh.liquidator.bite(_pid(ETH, alice));
        assertGt(repaid, 0, "seized after the grace");
        assertEq(rh.ledger.debtOf(_pid(ETH, alice)), 0);
    }

    /// @dev A silence inside a grace (another long gap) restarts it: the chain was quiet again.
    function test_aSecondSilenceRestartsTheGrace() public {
        _openUnsafe(rh);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        ethFeed.set(1700e18);
        vm.prank(liq);
        rh.liquidator.liquidate(_pid(ETH, alice));
        vm.warp(vm.getBlockTimestamp() + 50 minutes); // silent again
        ethFeed.set(1700e18);
        vm.prank(liq);
        (uint256 repaid,,) = rh.liquidator.bite(_pid(ETH, alice));
        assertEq(repaid, 0);
        assertEq(rh.pulse.graceUntil(), vm.getBlockTimestamp() + 1 hours);
    }

    function _alive(uint256 dt) internal {
        uint256 end = vm.getBlockTimestamp() + dt;
        while (vm.getBlockTimestamp() < end) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes > end ? end : vm.getBlockTimestamp() + 10 minutes);
            rh.pulse.poke();
            ethFeed.set(1700e18);
        }
    }

    function test_borrowerRepairsDuringGrace() public {
        _openUnsafe(rh);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        ethFeed.set(1700e18);
        vm.prank(liq);
        rh.liquidator.liquidate(_pid(ETH, alice));
        vm.prank(alice);
        rh.ledger.open(ETH, 0, Adjust(5e18, 0, 0, 0, 0, false, type(uint256).max, address(0))); // repaired inside the grace
        _alive(1 hours);
        vm.prank(liq);
        vm.expectRevert(Liquidator.Healthy.selector);
        rh.liquidator.bite(_pid(ETH, alice));
    }

    function test_pokingFirstDoesNotSkipTheGrace() public {
        _openUnsafe(rh);
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        ethFeed.set(1700e18);
        rh.pulse.poke(); // the liquidator pokes first, hoping to "use up" the gap
        vm.prank(liq);
        (uint256 repaid,,) = rh.liquidator.liquidate(_pid(ETH, alice));
        assertEq(repaid, 0, "the poke that ended the gap started the grace");
    }

    function test_noGapNoGrace() public {
        _openUnsafe(rh);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        ethFeed.set(1700e18);
        vm.prank(liq);
        (uint256 repaid,,) = rh.liquidator.liquidate(_pid(ETH, alice));
        assertGt(repaid, 0, "a live chain liquidates at once");
    }

    function test_mainnetShapedLiquidatesAfterAnySilence() public {
        _openUnsafe(home);
        vm.warp(vm.getBlockTimestamp() + 5 hours);
        ethFeed.set(1700e18);
        vm.prank(liq);
        (uint256 repaid,,) = home.liquidator.liquidate(_pid(ETH, alice));
        assertGt(repaid, 0, "no Pulse: v2 mainnet behaviour unchanged");
    }
}
