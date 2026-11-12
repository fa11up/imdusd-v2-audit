// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {Allocator} from "../../src/peg/Allocator.sol";
import {GovernedByKind as Governed} from "../../src/GovernedByKind.sol";
import {AllocatorTest, MockVault4626} from "./Allocator.t.sol";

/// @notice The rule-driven actions: anyone calls, the contract picks amount, price and route.
contract AllocatorRulesTest is AllocatorTest {
    bytes32 BS;
    address bob = makeAddr("bob"); // a buyer and caller with no role (eve is the inherited tests' thief)

    function setUp() public override {
        super.setUp();
        BS = al.BACKSTOP_SALE();
        usd.mint(bob, 1_000_000e18);
        vm.prank(bob);
        usd.approve(address(al), type(uint256).max);
    }

    // ---------------------------------------------------------------- collateral auction

    function test_auctionIdleUntilStarted() public {
        vm.expectRevert(Allocator.AuctionIdle.selector);
        al.auctionPrice(address(backstop), address(weth));
        vm.prank(bob);
        vm.expectRevert(Allocator.AuctionIdle.selector);
        al.buyCollateral(address(backstop), address(weth), 1e18, type(uint256).max);
    }

    function test_auctionFallsFromTopToFloorThenHolds() public {
        vm.prank(bob);
        al.startAuction(address(backstop), address(weth));
        assertEq(al.auctionPrice(address(backstop), address(weth)), 2060e18, "103% of low");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(al.auctionPrice(address(backstop), address(weth)), 2010e18, "half way");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(al.auctionPrice(address(backstop), address(weth)), 1960e18, "98% of low");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(al.auctionPrice(address(backstop), address(weth)), 1960e18, "stays at the floor");
    }

    function test_auctionStartsFromHighWhenAboveLow() public {
        backstop.prices().set(address(weth), 2000e18, 2200e18, false);
        al.startAuction(address(backstop), address(weth));
        assertEq(al.auctionPrice(address(backstop), address(weth)), 2266e18, "103% of high");
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertEq(al.auctionPrice(address(backstop), address(weth)), 1960e18, "floor still 98% of low");
    }

    function test_buyPaysTheSleeveAndDeliversCollateral() public {
        al.startAuction(address(backstop), address(weth));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 usdBefore = usd.balanceOf(address(backstop));
        vm.prank(bob);
        uint256 pay = al.buyCollateral(address(backstop), address(weth), 2e18, 3920e18);
        assertEq(pay, 3920e18);
        assertEq(usd.balanceOf(address(backstop)) - usdBefore, 3920e18, "imdUSD to the sleeve");
        assertEq(weth.balanceOf(bob), 2e18, "collateral to the buyer");
        assertEq(weth.balanceOf(address(al)), 0, "nothing left here");
        assertEq(backstop.sold(), 2e18);
        assertEq(al.available(BS, address(backstop)), 20_000e18 - 3920e18, "bucket drawn in USD at the price paid");
    }

    /// Audit-suite review (wave-2 snapshot): a run at its floor used to sell collateral that arrived later at the floor at once.
    function test_newCollateralStopsTheRunUntilARestart() public {
        al.startAuction(address(backstop), address(weth));
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        weth.mint(address(backstop), 10e18); // a later liquidation's collateral
        vm.prank(bob);
        vm.expectRevert(Allocator.AuctionStale.selector);
        al.buyCollateral(address(backstop), address(weth), 1e18, type(uint256).max);
        vm.prank(bob);
        al.startAuction(address(backstop), address(weth)); // anyone, at once
        assertEq(al.auctionPrice(address(backstop), address(weth)), 2060e18, "offered from the top");
    }

    function test_newCollateralAllowsARestartMidRun() public {
        al.startAuction(address(backstop), address(weth));
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.expectRevert(Allocator.AuctionRunning.selector);
        al.startAuction(address(backstop), address(weth));
        weth.mint(address(backstop), 1e18);
        al.startAuction(address(backstop), address(weth));
        assertEq(al.auctionPrice(address(backstop), address(weth)), 2060e18);
    }

    function test_buysLowerTheRecordedHolding() public {
        al.startAuction(address(backstop), address(weth));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(bob);
        al.buyCollateral(address(backstop), address(weth), 5e18, type(uint256).max);
        assertEq(al.auctionColl(keccak256(abi.encode(address(backstop), address(weth)))), 95e18);
        vm.prank(bob);
        al.buyCollateral(address(backstop), address(weth), 1e18, type(uint256).max); // the run goes on
    }

    /// The top follows the redemption payout (the type's live pool) when it is above the attested pair.
    function test_auctionTopFollowsThePayout() public {
        backstop.prices().setPayout(address(weth), 2400e18);
        al.startAuction(address(backstop), address(weth));
        assertEq(al.auctionPrice(address(backstop), address(weth)), 2472e18, "103% of the payout");
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertEq(al.auctionPrice(address(backstop), address(weth)), 1960e18, "the floor is still 98% of low");
    }

    function test_buyRefusesAbovemaxPay() public {
        al.startAuction(address(backstop), address(weth));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Allocator.PriceAbove.selector, 2060e18, 2000e18));
        al.buyCollateral(address(backstop), address(weth), 1e18, 2000e18);
    }

    function test_buyCappedByBucket() public {
        al.startAuction(address(backstop), address(weth));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Allocator.RateLimited.selector, BS, address(backstop), 21_560e18, 20_000e18));
        al.buyCollateral(address(backstop), address(weth), 11e18, type(uint256).max);
    }

    function test_restartOnlyAfterARun() public {
        al.startAuction(address(backstop), address(weth));
        vm.warp(vm.getBlockTimestamp() + 2 hours - 1);
        vm.expectRevert(Allocator.AuctionRunning.selector);
        al.startAuction(address(backstop), address(weth));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(bob);
        al.startAuction(address(backstop), address(weth));
        assertEq(al.auctionPrice(address(backstop), address(weth)), 2060e18, "back to the top");
    }

    function test_auctionNeedsAnAllowedSleeveAndAPrice() public {
        vm.expectRevert(abi.encodeWithSelector(Allocator.NotAllowed.selector, BS, eve));
        al.startAuction(eve, address(weth));
        al.startAuction(address(backstop), address(weth));
        backstop.prices().set(address(weth), 2000e18, 0, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Allocator.StaleFeed.selector, address(weth)));
        al.buyCollateral(address(backstop), address(weth), 1e18, type(uint256).max);
    }

    function test_freezeStopsRuleDrivenActions() public {
        al.startAuction(address(backstop), address(weth));
        vm.prank(freezer);
        al.freeze();
        vm.startPrank(bob);
        vm.expectRevert(Allocator.Frozen.selector);
        al.buyCollateral(address(backstop), address(weth), 1e18, type(uint256).max);
        vm.expectRevert(Allocator.Frozen.selector);
        al.startAuction(address(backstop), address(weth));
        vm.expectRevert(Allocator.Frozen.selector);
        al.rebalanceVault(address(usdc));
        vm.expectRevert(Allocator.Frozen.selector);
        al.topUpBuffer(address(hook));
        vm.expectRevert(Allocator.Frozen.selector);
        al.rebalanceLp(address(lp));
        vm.stopPrank();
    }

    /// @dev The auction's callback cannot be replayed to take collateral without paying: the context is gone after the sale.
    function test_auctionCallbackOutsideASaleRefused() public {
        bytes memory data = abi.encode(uint8(2), bob, uint256(0));
        vm.prank(address(backstop));
        vm.expectRevert(abi.encodeWithSelector(Allocator.NotAllowed.selector, BS, address(backstop)));
        al.onBackstopSell(address(weth), 1e18, data);
    }

    // ---------------------------------------------------------------- vault

    function test_rebalanceVaultDepositsAboveKeepThenRedeemsBack() public {
        _gov(abi.encode(al.SET_AUTO_VAULT(), address(usdc), address(vault), uint256(99_500e6)));
        vm.prank(bob);
        assertEq(al.rebalanceVault(address(usdc)), 500e6);
        assertEq(usdc.balanceOf(address(al)), 99_500e6);
        vm.prank(bob);
        vm.expectRevert(Allocator.NothingToDo.selector);
        al.rebalanceVault(address(usdc));

        _gov(abi.encode(al.SET_AUTO_VAULT(), address(usdc), address(vault), uint256(99_800e6)));
        vm.prank(bob);
        al.rebalanceVault(address(usdc));
        assertEq(usdc.balanceOf(address(al)), 99_800e6, "redeemed back to the liquid amount");
    }

    function test_rebalanceVaultCappedByBucket() public {
        _gov(abi.encode(al.SET_AUTO_VAULT(), address(usdc), address(vault), uint256(0)));
        al.rebalanceVault(address(usdc));
        assertEq(vault.totalAssets(), 1_000e6, "one bucket's worth, not 100k");
    }

    function test_autoVaultRules() public {
        vm.expectRevert(Allocator.NothingToDo.selector);
        al.rebalanceVault(address(usdc));
        MockVault4626 wrong = new MockVault4626(IERC20(address(usd)));
        uint8 k = al.SET_AUTO_VAULT();
        vm.prank(governor);
        vm.expectRevert(Allocator.BadPayload.selector);
        al.propose(abi.encode(k, address(usdc), address(wrong), uint256(0)));
    }

    // ---------------------------------------------------------------- buffer

    function test_topUpBufferToTheRoomAndBucket() public {
        hook.setTarget(300e6);
        vm.prank(bob);
        assertEq(al.topUpBuffer(address(hook)), 300e6);
        assertEq(hook.buffer(), 300e6);
        vm.expectRevert(Allocator.NothingToDo.selector);
        al.topUpBuffer(address(hook));

        hook.setTarget(10_000e6);
        al.topUpBuffer(address(hook));
        assertEq(hook.buffer(), 500e6, "the bucket refills slowly; it holds the rest");
    }

    // ---------------------------------------------------------------- LP

    /// An LP target never set is "no rule": shares the Allocator holds are not sold by anyone.
    function test_unsetLpTargetSellsNothing() public {
        vm.prank(keeper);
        al.lpDeposit(address(lp), 100e18, 100e18, 100e6);
        vm.prank(bob);
        vm.expectRevert(Allocator.NothingToDo.selector);
        al.rebalanceLp(address(lp));
        assertEq(lp.balanceOf(address(al)), 100e18);
    }

    function test_rebalanceLpNeverMakesTheFirstDeposit() public {
        _gov(abi.encode(al.SET_LP_TARGET(), address(lp), uint256(100e18)));
        vm.expectRevert(Allocator.NothingToDo.selector);
        al.rebalanceLp(address(lp));
    }

    function test_rebalanceLpTowardTarget() public {
        vm.prank(keeper);
        al.lpDeposit(address(lp), 100e18, 100e18, 100e6); // the seed
        _gov(abi.encode(al.SET_LP_TARGET(), address(lp), uint256(400e18)));
        vm.prank(bob);
        assertEq(al.rebalanceLp(address(lp)), 300e18);
        assertEq(lp.balanceOf(address(al)), 400e18);

        _gov(abi.encode(al.SET_LP_TARGET(), address(lp), uint256(150e18)));
        vm.prank(bob);
        assertEq(al.rebalanceLp(address(lp)), 250e18);
        assertEq(lp.balanceOf(address(al)), 150e18);
        vm.expectRevert(Allocator.NothingToDo.selector);
        al.rebalanceLp(address(lp));
    }

    function test_rebalanceLpBuysOnlyWhatTheBalancesAfford() public {
        vm.prank(keeper);
        al.lpDeposit(address(lp), 10e18, 10e18, 10e6);
        uint256 out = usdc.balanceOf(address(al)) - 50e6;
        vm.prank(governor);
        al.returnToTreasury(address(usdc), out); // 50 USDC left
        _gov(abi.encode(al.SET_LP_TARGET(), address(lp), uint256(1_000e18)));
        uint256 got = al.rebalanceLp(address(lp));
        assertLt(got, 50e18, "limited by USDC");
        assertGt(got, 49e18, "within the 0.5% headroom");
    }

    function test_rebalanceLpGatedByTwap() public {
        vm.prank(keeper);
        al.lpDeposit(address(lp), 10e18, 10e18, 10e6);
        _gov(abi.encode(al.SET_LP_TARGET(), address(lp), uint256(100e18)));
        lp.setTicks(30, 0);
        vm.expectRevert(abi.encodeWithSelector(Allocator.OffTwap.selector, int24(30), int24(0)));
        al.rebalanceLp(address(lp));
    }

    /// @dev A watcher reads an `Acted` from anyone but a keeper or the governor as a stolen key: a stranger's rule-driven call must
    /// never emit one, or the first buffer top-up would read as an attack.
    function test_ruleDrivenActionsNeverEmitActed() public {
        _gov(abi.encode(al.SET_AUTO_VAULT(), address(usdc), address(vault), uint256(99_000e6)));
        vm.prank(keeper);
        al.lpDeposit(address(lp), 10e18, 10e18, 10e6);
        _gov(abi.encode(al.SET_LP_TARGET(), address(lp), uint256(100e18)));
        hook.setTarget(100e6);
        al.startAuction(address(backstop), address(weth));
        vm.recordLogs();
        vm.startPrank(bob);
        al.rebalanceVault(address(usdc));
        al.topUpBuffer(address(hook));
        al.rebalanceLp(address(lp));
        al.buyCollateral(address(backstop), address(weth), 1e18, type(uint256).max);
        vm.stopPrank();
        bytes32 acted = Allocator.Acted.selector;
        bytes32 ruled = Allocator.Ruled.selector;
        uint256 rules;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(al)) continue;
            assertTrue(logs[i].topics[0] != acted, "no Acted from a rule");
            if (logs[i].topics[0] == ruled) ++rules;
        }
        assertEq(rules, 3, "vault, buffer, LP each say Ruled");
    }

    // ---------------------------------------------------------------- governance

    function test_newKindsAreTimelocked() public {
        uint8 k = al.SET_LP_TARGET();
        vm.prank(governor);
        al.propose(abi.encode(k, address(lp), uint256(1e18)));
        vm.expectRevert();
        al.applyPending();
        assertEq(al.lpTarget(address(lp)), 0);
        vm.prank(eve);
        vm.expectRevert(Governed.NotGovernor.selector);
        al.propose(abi.encode(k, address(lp), uint256(1e18)));
    }
}
