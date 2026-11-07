// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PegPositionsTest} from "./PegPositions.t.sol";
import {PegPositionZap} from "../../src/earn/PegPositionZap.sol";

/// @notice Regression from the 2026-11 internal review: the zap's unwind pulled `debt - imdGot` from the owner with no
/// bound. Failed before the fix (no `maxImdIn`).
abstract contract PanelPegBase is PegPositionsTest {
    function test_PEG02_unwindShortfallBounded() public {
        uint256 id = _open(10_000e6);
        vm.prank(alice);
        nft.approveOperator(id, address(zap), 32);
        _fund(alice, 30_000e18, 0);
        vm.prank(alice);
        usd.approve(address(zap), type(uint256).max);

        // A push above the band just before the unwind: with a bound of 1% of the debt the owner is protected.
        _moveTo(150);
        uint256 debt = ledger.debtOf(id);
        uint256 i0 = usd.balanceOf(alice);
        vm.prank(alice);
        vm.expectPartialRevert(PegPositionZap.ShortfallTooHigh.selector);
        zap.unwind(id, 0, debt / 100);
        assertEq(usd.balanceOf(alice), i0, "nothing pulled");

        // Back at the opening price the shortfall is the upfront fee + interest: a small bound passes.
        _moveTo(0);
        vm.prank(alice);
        zap.unwind(id, 0, debt / 100);
        uint256 paid = i0 - usd.balanceOf(alice);
        assertLe(paid, debt / 100, "pulled at most maxImdIn");
        assertEq(ledger.position(id).collateral, 0);
        _assertZapEmpty();
    }
}

contract PanelPegStable0Test is PanelPegBase {
    function _quoteAddr() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }
}

contract PanelPegStable1Test is PanelPegBase {
    function _quoteAddr() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001);
    }
}
