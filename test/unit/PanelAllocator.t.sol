// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AllocatorTest, MockLPVault} from "./Allocator.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {Allocator, ISwapRoute} from "../../src/peg/Allocator.sol";
import {GovernedByKind} from "../../src/GovernedByKind.sol";

/// @dev The PoC's route: pays exactly the oracle floor and
/// keeps the input (a sandwiched or keeper-influenced route).
contract FloorRoute is ISwapRoute {
    address public immutable thief;

    constructor(address t) {
        thief = t;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, thief, amountIn);
        MockERC20(tokenOut).mint(recipient, minOut);
        return minOut;
    }
}

/// @notice Regressions from the 2026-11 internal review: SWAP/BACKSTOP_SALE buckets in raw units of a keeper-chosen
/// token, no instant way to drop a leaked freezer, one pending slot for the whole setup, LP exits bounded only by the
/// keeper's own mins. Each failed before the fix.
contract PanelAllocatorTest is AllocatorTest {
    FloorRoute floor;
    address thief = makeAddr("thief");

    function setUp() public override {
        super.setUp();
        floor = new FloorRoute(thief);
        // "At most $1,000 a day through this route", the bucket now in USD.
        _allow(al.SWAP(), address(floor), 1_000e18, uint128(1_000e18 / uint256(1 days)));
        vm.warp(vm.getBlockTimestamp() + 1 days); // buckets start empty and fill at their slope
    }

    // ---------------------------------------------------------------- buckets in USD

    function test_A01_usdcSwapDrawsItsUsdValue() public {
        vm.prank(keeper);
        vm.expectPartialRevert(Allocator.RateLimited.selector);
        al.swap(address(floor), address(usdc), address(usd), 100_000e6, 0); // $100k against a $1k bucket
        vm.prank(keeper);
        al.swap(address(floor), address(usdc), address(usd), 600e6, 0);
        assertApproxEqAbs(al.available(al.SWAP(), address(floor)), 400e18, 1e15, "drew $600 of the $1,000");
    }

    function test_A01_wethSwapDrawsItsUsdValue() public {
        weth.mint(address(al), 100e18);
        vm.prank(keeper);
        vm.expectPartialRevert(Allocator.RateLimited.selector);
        al.swap(address(floor), address(weth), address(usd), 1e18, 0); // $2,000 > $1,000
        vm.prank(keeper);
        al.swap(address(floor), address(weth), address(usd), 0.25e18, 0);
        assertApproxEqAbs(al.available(al.SWAP(), address(floor)), 500e18, 1e15, "0.25 WETH = $500");
    }

    function test_A01_roundTripsDrawEveryLeg() public {
        uint256 v0 = usdc.balanceOf(address(al));
        vm.startPrank(keeper);
        uint256 w = al.swap(address(floor), address(usdc), address(weth), 400e6, 0);
        al.swap(address(floor), address(weth), address(usdc), w, 0);
        vm.expectPartialRevert(Allocator.RateLimited.selector);
        al.swap(address(floor), address(usdc), address(weth), 400e6, 0); // ~$792 drawn already
        vm.stopPrank();
        assertGt(usdc.balanceOf(address(al)), v0 - 20e6, "at most ~2% of $1k lost in a day, not a third of the balance");
    }

    function test_A01_backstopSaleDrawsUsd() public {
        assertEq(al.available(al.BACKSTOP_SALE(), address(backstop)), 20_000e18);
        // 11 WETH = $22,000 > the $20,000 sale bucket.
        vm.prank(keeper);
        vm.expectPartialRevert(Allocator.RateLimited.selector);
        al.sellForBackstop(address(backstop), address(route), address(weth), 11e18, 0);
    }

    // ---------------------------------------------------------------- clearing a leaked freezer

    function test_A02_governorClearsTheFreezerAtOnce() public {
        vm.prank(eve);
        vm.expectRevert(GovernedByKind.NotGovernor.selector);
        al.clearFreezer();
        vm.prank(governor);
        al.clearFreezer();
        assertEq(al.freezer(), address(0));
        vm.prank(freezer);
        vm.expectRevert(Allocator.NotFreezer.selector);
        al.freeze();
    }

    // ---------------------------------------------------------------- one pending slot per kind

    function test_A03_kindsHaveTheirOwnSlots() public {
        address k2 = makeAddr("k2");
        (uint8 addKeeper, uint8 setFeed) = (al.ADD_KEEPER(), al.SET_FEED());
        vm.startPrank(governor);
        al.propose(abi.encode(addKeeper, k2));
        al.propose(abi.encode(setFeed, address(weth), address(fUsd))); // emergency feed swap does not wait
        vm.expectRevert(GovernedByKind.ProposalPending.selector);
        al.propose(abi.encode(addKeeper, eve)); // same kind: one at a time
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        al.applyPending(addKeeper);
        al.applyPending(setFeed);
        assertTrue(al.isKeeper(k2));
        assertEq(address(al.feedOf(address(weth))), address(fUsd));
    }

    function test_A03_batchCarriesAWholeSetup() public {
        MockLPVault lp2 = new MockLPVault(usd, usdc);
        bytes[] memory items = new bytes[](3);
        items[0] = abi.encode(al.ADD_TARGET(), al.LP_DEPOSIT(), address(lp2));
        items[1] = abi.encode(al.SET_LIMIT(), al.LP_DEPOSIT(), address(lp2), uint128(1_000e18), uint128(1e18));
        items[2] = abi.encode(al.SET_SLIPPAGE(), uint16(50));
        bytes memory batch = abi.encode(al.BATCH(), items);
        bytes memory slip = abi.encode(al.SET_SLIPPAGE(), uint16(60));
        vm.prank(governor);
        al.propose(batch);
        vm.prank(governor);
        vm.expectRevert(GovernedByKind.ProposalPending.selector); // a kind inside the batch is locked
        al.propose(slip);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        al.applyPending();
        assertTrue(al.allowed(al.key(al.LP_DEPOSIT(), address(lp2))));
        (uint128 max, uint128 slope,,) = al.limits(al.key(al.LP_DEPOSIT(), address(lp2)));
        assertEq(max, 1_000e18);
        assertEq(slope, 1e18);
        assertEq(al.maxSlippageBps(), 50);
    }

    function test_A03_batchItemsAreValidated() public {
        bytes[] memory items = new bytes[](1);
        items[0] = abi.encode(al.SET_SLIPPAGE(), uint16(600));
        bytes memory batch = abi.encode(al.BATCH(), items);
        vm.prank(governor);
        vm.expectRevert(Allocator.BadPayload.selector);
        al.propose(batch);
    }

    // ---------------------------------------------------------------- LP actions bounded by the TWAP

    function test_A04_lpActionsNeedSpotAtTwap() public {
        vm.prank(keeper);
        al.lpDeposit(address(lp), 500e18, 500e18, 500e6);
        lp.setTicks(-150, 0); // a push inside the keeper's bundle: the 30-minute TWAP has not moved
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.OffTwap.selector, int24(-150), int24(0)));
        al.lpWithdraw(address(lp), 200e18, 0, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.OffTwap.selector, int24(-150), int24(0)));
        al.lpDeposit(address(lp), 100e18, 100e18, 100e6);
        lp.setTicks(-8, 0);
        vm.prank(keeper);
        al.lpWithdraw(address(lp), 200e18, 0, 0);
        assertEq(lp.balanceOf(address(al)), 300e18);
    }

    // ---------------------------------------------------------------- re-check: an instant lower on the Allocator

    function _gone(uint8 kind) private {
        (, uint256 eta) = al.pendingOf(kind);
        assertEq(eta, 0, "the instant lower cancelled it");
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(GovernedByKind.NothingPending.selector);
        al.applyPending(kind);
    }

    /// The recheck's PoC turned round: a keeper key leaks while its addition is pending; the removal also ends the addition.
    function test_RD_allocatorPendingUndoesInstantRemove() public {
        address bad = makeAddr("badKeeper");
        uint8 k = al.ADD_KEEPER();
        vm.prank(governor);
        al.propose(abi.encode(k, bad));
        vm.prank(governor);
        al.removeKeeper(bad);
        _gone(k);
        assertFalse(al.isKeeper(bad));
    }

    function test_M8_freezerRemovalAlsoCancels() public {
        address bad = makeAddr("badKeeper");
        uint8 k = al.ADD_KEEPER();
        vm.prank(governor);
        al.propose(abi.encode(k, bad));
        vm.prank(freezer);
        al.removeKeeper(bad);
        _gone(k);
    }

    function test_M8_removeOtherKeeperLeavesThePending() public {
        address good = makeAddr("goodKeeper");
        uint8 k = al.ADD_KEEPER();
        vm.prank(governor);
        al.propose(abi.encode(k, good));
        vm.prank(governor);
        al.removeKeeper(keeper);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        al.applyPending(k);
        assertTrue(al.isKeeper(good));
    }

    function test_M8_removeTargetCancelsItsAddition() public {
        MockLPVault other = new MockLPVault(IERC20(address(usd)), IERC20(address(usdc)));
        uint8 k = al.ADD_TARGET();
        bytes32 act = al.LP_DEPOSIT();
        vm.prank(governor);
        al.propose(abi.encode(k, act, address(other)));
        vm.prank(governor);
        al.removeTarget(act, address(other));
        _gone(k);
        assertFalse(al.allowed(al.key(act, address(other))));
    }

    function test_M8_removeOtherTargetLeavesThePending() public {
        MockLPVault other = new MockLPVault(IERC20(address(usd)), IERC20(address(usdc)));
        uint8 k = al.ADD_TARGET();
        bytes32 act = al.LP_DEPOSIT();
        bytes32 other2 = al.LP_WITHDRAW();
        vm.prank(governor);
        al.propose(abi.encode(k, act, address(other)));
        vm.prank(governor);
        al.removeTarget(other2, address(other)); // same target, another action: another field
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        al.applyPending(k);
        assertTrue(al.allowed(al.key(act, address(other))));
    }

    function test_M8_lowerLimitCancelsItsRaise() public {
        uint8 k = al.SET_LIMIT();
        bytes32 act = al.SWAP();
        vm.prank(governor);
        al.propose(abi.encode(k, act, address(floor), uint128(1_000_000e18), uint128(1e18)));
        vm.prank(governor);
        al.lowerLimit(act, address(floor), 0, 0);
        _gone(k);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(al.available(act, address(floor)), 0, "stays lowered");
    }

    function test_M8_lowerSlippageCancelsItsRaise() public {
        uint8 k = al.SET_SLIPPAGE();
        vm.prank(governor);
        al.propose(abi.encode(k, uint16(500)));
        uint16 low = al.maxSlippageBps() / 2;
        vm.prank(governor);
        al.lowerSlippage(low);
        _gone(k);
        assertEq(al.maxSlippageBps(), low);
    }

    function test_M8_clearFreezerCancelsAPendingFreezer() public {
        uint8 k = al.SET_FREEZER();
        vm.prank(governor);
        al.propose(abi.encode(k, makeAddr("leaked")));
        vm.prank(governor);
        al.clearFreezer();
        _gone(k);
        assertEq(al.freezer(), address(0));
    }

    /// A batch carrying the same field goes whole (the Safe re-proposes the rest); one that does not stays.
    function test_M8_batchCarryingTheFieldIsCancelled() public {
        address bad = makeAddr("badKeeper");
        uint8 b = al.BATCH();
        uint8 ks = al.SET_SLIPPAGE();
        uint8 kk = al.ADD_KEEPER();
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(ks, uint16(100));
        items[1] = abi.encode(kk, bad);
        vm.prank(governor);
        al.propose(abi.encode(b, items));
        vm.prank(governor);
        al.removeKeeper(keeper); // not in the batch
        (, uint256 eta) = al.pendingOf(b);
        assertGt(eta, 0, "not touched");
        vm.prank(governor);
        al.removeKeeper(bad);
        _gone(b);
        assertEq(al.locked(), 0, "every lock released");
    }

    /// Second re-check: address(0) read as the any-field marker, so the freezer could kill any keeper proposal by naming none.
    function test_R2_removeZeroKeeperCancelsNothing() public {
        uint8 b = al.BATCH();
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(al.ADD_KEEPER(), makeAddr("newKeeper"));
        items[1] = abi.encode(al.SET_SLIPPAGE(), uint16(100));
        vm.prank(governor);
        al.propose(abi.encode(b, items));
        vm.prank(freezer);
        al.removeKeeper(address(0));
        (, uint256 eta) = al.pendingOf(b);
        assertGt(eta, 0, "still pending");
    }
}
