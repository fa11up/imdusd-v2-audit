// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";

/// @notice D1: line x (1 + chop) + redeemCap <= k x depthIMD for the sIMD type. Raises through the
/// timelock, checked at apply; lowering line, k or depth instant by the governor. Plus the BATCH kind the day-7 Safe act uses.
contract DepthRuleTest is System {
    bytes32 constant SIMD = "SIMD";
    bytes32 constant ETH = "ETH";

    function setUp() public {
        vm.warp(1_800_000_000);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        MockFeed f = new MockFeed(5e18);
        ParametersBase.Risk memory r = _risk(1.7e18, 0); // sIMD opens at line 0
        r.chop = 0.2e18;
        r.redeemCap = 20_000e18;
        _addIlk(SIMD, address(new MockERC20("sIMD", 18)), f, f, IFeed(address(0)), address(0), address(0), true, r);
        _addIlk(ETH, address(new MockERC20("WETH", 18)), f, f, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1e24));
        params.setGenesisDepthRule(SIMD, 0.8e18, 80_100e18, 0, 0); // room = 64,080
        params.seal();
    }

    function _gov(bytes memory payload) internal {
        vm.prank(governor);
        params.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
    }

    function _lineTo(uint128 line) internal view returns (bytes memory) {
        ParametersBase.Risk memory r = params.storedRisk(SIMD);
        r.line = line;
        return abi.encode(params.SET_RISK(), SIMD, r);
    }

    function test_raiseRefusedWhenRuleFailsAcceptedWhenItHolds() public {
        // 50k x 1.2 + 20k = 80k > 64,080: refused at apply.
        _gov(_lineTo(50_000e18));
        vm.expectRevert(abi.encodeWithSelector(ParametersBase.DepthRuleFails.selector, 80_000e18, 64_080e18));
        params.applyPending();
        assertEq(params.storedRisk(SIMD).line, 0);
        // 36,733 x 1.2 + 20k = 64,079.6 <= 64,080: applies.
        vm.prank(governor);
        params.cancel();
        _gov(_lineTo(36_733e18));
        params.applyPending();
        assertEq(params.storedRisk(SIMD).line, 36_733e18);
        (bool holds, uint256 need, uint256 room) = params.depthRule();
        assertTrue(holds);
        assertLe(need, room);
        // Raising chop or redeemCap is a raise too.
        ParametersBase.Risk memory r = params.storedRisk(SIMD);
        r.redeemCap = 21_000e18;
        _gov(abi.encode(params.SET_RISK(), SIMD, r));
        vm.expectRevert();
        params.applyPending();
        // Other types are not gated.
        ParametersBase.Risk memory e = params.storedRisk(ETH);
        e.line = 1e27;
        vm.prank(governor);
        params.cancel();
        _gov(abi.encode(params.SET_RISK(), ETH, e));
        params.applyPending();
    }

    function test_kBoundedAtOne() public {
        assertEq(params.MAX_DEPTH_K(), 1e18);
        bytes memory over = abi.encode(params.SET_DEPTH_K(), uint64(1e18 + 1));
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(over);
        // Raising k through the timelock to 1 makes room for a bigger line.
        _gov(abi.encode(params.SET_DEPTH_K(), uint64(1e18)));
        params.applyPending();
        assertEq(params.depthK(), 1e18);
        _gov(_lineTo(50_000e18)); // 80k <= 80.1k
        params.applyPending();
        // At genesis too.
        Parameters p = new Parameters(governor, address(this));
        vm.expectRevert(ParametersBase.UnknownIlk.selector);
        p.setGenesisDepthRule(SIMD, 0.8e18, 1, 0, 0);
    }

    function test_instantLoweringByGovernorOnly() public {
        _gov(_lineTo(30_000e18));
        params.applyPending();
        vm.expectRevert(Governed.NotGovernor.selector);
        params.lowerDepthLine(10_000e18);
        vm.startPrank(governor);
        params.lowerDepthLine(10_000e18); // no timelock
        assertEq(params.storedRisk(SIMD).line, 10_000e18);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerDepthLine(10_000e18); // not a lowering
        params.lowerDepthK(0.5e18);
        assertEq(params.depthK(), 0.5e18);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerDepthK(0.6e18);
        vm.stopPrank();
    }

    function test_depthPostUpTimelockedDownInstantAndBreaksRaises() public {
        // Up: only through SET_DEPTH (48h).
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.postLowerDepth(90_000e18);
        _gov(abi.encode(params.SET_DEPTH(), uint256(100_000e18)));
        assertEq(params.depthIMD(), 80_100e18, "not before the timelock");
        params.applyPending();
        assertEq(params.depthIMD(), 100_000e18);
        _gov(_lineTo(40_000e18)); // 68k <= 80k
        params.applyPending();
        // Down: instant; the rule breaks (68k > 0.8 x 50k): an event, nothing forced.
        vm.expectEmit(address(params));
        emit ParametersBase.DepthRuleBroken(68_000e18, 40_000e18);
        vm.prank(governor);
        params.postLowerDepth(50_000e18);
        assertEq(params.depthIMD(), 50_000e18);
        assertEq(params.storedRisk(SIMD).line, 40_000e18, "positions and the line are untouched");
        (bool holds,,) = params.depthRule();
        assertFalse(holds);
        // ...and no raise applies until it holds again, even a tiny one.
        _gov(_lineTo(40_001e18));
        vm.expectRevert();
        params.applyPending();
        // Lowering through the timelock still applies while broken.
        vm.prank(governor);
        params.cancel();
        _gov(_lineTo(15_000e18));
        params.applyPending();
        (holds,,) = params.depthRule();
        assertTrue(holds, "38k <= 40k");
    }

    /// E2: other chains' IMD lines count against the rule; raised through the timelock, lowered instantly.
    function test_otherChainImdLinesCount() public {
        _gov(_lineTo(36_000e18)); // 63.2k <= 64,080
        params.applyPending();
        // Robinhood's 3k IMD line at 20% chop adds 3.6k: 66.8k > 64,080 -> refused at apply.
        bytes memory up = abi.encode(params.SET_OTHER_IMD(), uint256(3_000e18), uint64(0.2e18));
        _gov(up);
        vm.expectRevert(abi.encodeWithSelector(ParametersBase.DepthRuleFails.selector, 66_800e18, 64_080e18));
        params.applyPending();
        vm.prank(governor);
        params.cancel();
        // Make room first (instant lowering of the sIMD line), then the other-chain line applies.
        vm.prank(governor);
        params.lowerDepthLine(33_000e18); // 59.6k
        _gov(up);
        params.applyPending();
        assertEq(params.otherImdLines(), 3_000e18);
        (bool holds, uint256 need,) = params.depthRule();
        assertTrue(holds);
        assertEq(need, 63_200e18); // 39.6k + 20k + 3.6k
        // ...and it now limits sIMD raises.
        _gov(_lineTo(34_000e18)); // 64.4k
        vm.expectRevert();
        params.applyPending();
        vm.prank(governor);
        params.cancel();
        // Lowering is instant, governor only.
        vm.expectRevert(Governed.NotGovernor.selector);
        params.lowerOtherImdLines(0);
        vm.prank(governor);
        params.lowerOtherImdLines(1_000e18);
        assertEq(params.otherImdLines(), 1_000e18);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerOtherImdLines(2_000e18);
    }

    function test_batchAppliesInOrderAndChecksAtApply() public {
        // The day-7 act: post depth, open the sIMD line, raise the keeper cap: one proposal.
        bytes[] memory items = new bytes[](3);
        items[0] = abi.encode(params.SET_DEPTH(), uint256(95_000e18)); // room 76k
        items[1] = _lineTo(46_000e18); // 75.2k: holds only after the depth post
        items[2] = abi.encode(params.SET_KEEPER_CAP(), uint256(50_000e18));
        _gov(abi.encode(params.BATCH(), items));
        params.applyPending();
        assertEq(params.depthIMD(), 95_000e18);
        assertEq(params.storedRisk(SIMD).line, 46_000e18);
        assertEq(params.keeperCap(), 50_000e18);
        // A batch whose line does not fit reverts whole.
        items[0] = abi.encode(params.SET_DEPTH(), uint256(95_000e18));
        items[1] = _lineTo(50_000e18);
        items[2] = abi.encode(params.SET_KEEPER_CAP(), uint256(60_000e18));
        _gov(abi.encode(params.BATCH(), items));
        vm.expectRevert();
        params.applyPending();
        assertEq(params.keeperCap(), 50_000e18);
        // No nesting, no empty batch, items validated at propose.
        vm.prank(governor);
        params.cancel();
        uint8 B = params.BATCH();
        bytes[] memory nested = new bytes[](1);
        nested[0] = abi.encode(B, items);
        bytes[] memory bad = new bytes[](1);
        bad[0] = abi.encode(params.SET_DEPTH_K(), uint64(2e18));
        vm.startPrank(governor);
        vm.expectRevert(ParametersBase.UnknownKind.selector);
        params.propose(abi.encode(B, nested));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(B, new bytes[](0)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(B, bad));
        vm.stopPrank();
    }
}
