// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../../utils/StockSystem.sol";
import {ParametersBase} from "../../../src/ParametersBase.sol";
import {_pid} from "../../utils/Pid.sol";
import {Adjust} from "../../../src/interfaces/IPositions.sol";

/// @notice The Ledger settles an auction with the position's BOUND chop, but StockJoin.take recomputes the
/// penalty with the type's NEWEST chop (`params.risk(ilk).chop`, StockJoin.sol:119). While a SET_RISK that lowers chop and
/// raises mat is in its 7-day grace, the two differ: StockJoin's `bonus` is below the cuts the Ledger already paid out,
/// `units = seized - bonus` exceeds what is left of the position, and `redeem(units)` takes the difference out of OTHER
/// borrowers' vault shares held in the same Join. The taker pays USDG for them and it is credited to the liquidated
/// borrower. The Join ends short: the last borrower cannot withdraw.
contract PanelStockChopRegressionTest is StockSystem {
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

    function test_M3_stockAuctionUsesBoundChop() public {
        _open(alice, 100e18, 6_000e18); // $10,000 at 150% (mat 150%, chop 10%)
        _open(bob, 100e18, 0); // a second depositor in the same Join (no debt, so free to leave at any time)

        // Governance: chop 10% -> 2%, mat 150% -> 160% (not "kinder": binds after RISK_GRACE; positions stay on v0).
        ParametersBase.Risk memory r = params.storedRisk(STK);
        r.chop = 0.02e18;
        r.mat = 1.6e18;
        bytes memory payload = abi.encode(params.SET_RISK(), STK, r);
        vm.prank(governor);
        params.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours); // Wednesday 14:00 UTC, in session
        _price(100e8);
        params.applyPending();
        (, uint256 boundChop) = params.liqRisk(STK, 0);
        assertEq(boundChop, 0.1e18, "positions still pay the old 10% chop");
        assertEq(params.risk(STK).chop, 0.02e18, "newest chop 2%");

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _price(80e8); // alice unhealthy at her bound 150%
        vm.prank(marker);
        liquidator.liquidate(_pid(STK, alice));

        uint256 bobColl = ledger.position(_pid(STK, bob)).collateral;
        vm.prank(taker);
        sjoin.take(_pid(STK, alice), 80e18);

        uint256 held = vault.balanceOf(address(sjoin));
        assertGe(held, bobColl, "fixed: the Join still holds bob's collateral");
        // Bob, with no debt, takes his collateral back.
        vm.prank(bob);
        ledger.open(STK, 0, Adjust(-int256(bobColl), 0, 0, 0, 0, false, 0, address(0)));
        assertEq(ledger.position(_pid(STK, bob)).collateral, 0);
    }
}
