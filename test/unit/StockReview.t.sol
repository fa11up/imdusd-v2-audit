// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockSystem} from "../utils/StockSystem.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Regression tests for an earlier internal review's bridge-robinhood-stocks F5 (with core-ledger C3): sticky-zero
/// `writeOff`, seized shares to the Treasury, and a StockVault that cannot be captured while hollow.
contract StockReviewTest is StockSystem {
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    function setUp() public {
        _deployStocks(100_000e18, 50_000e18);
    }

    function test_reviewF5_burnThenReissueInsideTheDelayWritesNothingOff() public {
        _open(alice, 100e18, 6_000e18);
        stock.adminBurn(address(vault), 100e18); // a migration: burn ...
        ledger.writeOff(_pid(STK, alice)); // a watcher calls at once: only arms
        assertEq(ledger.position(_pid(STK, alice)).collateral, 100e24, "nothing written off");
        assertEq(_bad(), 0);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(LedgerBase.WriteOffTooSoon.selector, vm.getBlockTimestamp() + 30 minutes));
        ledger.writeOff(_pid(STK, alice));
        stock.mint(address(vault), 100e18); // ... then reissue to the same holder
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        ledger.writeOff(_pid(STK, alice)); // sees value again: clears the record instead of writing off
        assertEq(ledger.worthlessSince(STK), 0);
        assertEq(ledger.position(_pid(STK, alice)).collateral, 100e24);
        assertEq(_bad(), 0);
        vm.expectRevert(LedgerBase.NotWorthless.selector);
        ledger.writeOff(_pid(STK, alice));
    }

    function test_reviewF5_withoutTheStickyZeroTheFirstReadingWouldHaveWrittenOff() public {
        // what the finding described: on main one call in the burn block wrote the position off; now it only arms
        _open(alice, 100e18, 6_000e18);
        stock.adminBurn(address(vault), 100e18);
        ledger.writeOff(_pid(STK, alice));
        assertGt(ledger.debtOf(_pid(STK, alice)), 0);
        assertEq(ledger.worthlessSince(STK), vm.getBlockTimestamp());
    }

    function test_reviewF5_staleRecordReArmsInsteadOfWritingOff() public {
        _open(alice, 100e18, 6_000e18);
        stock.adminBurn(address(vault), 100e18);
        ledger.writeOff(_pid(STK, alice));
        vm.warp(vm.getBlockTimestamp() + ledger.WRITEOFF_WINDOW() + 1);
        ledger.writeOff(_pid(STK, alice)); // older than the window: re-armed now
        assertEq(ledger.worthlessSince(STK), vm.getBlockTimestamp());
        assertGt(ledger.debtOf(_pid(STK, alice)), 0);
        vm.warp(vm.getBlockTimestamp() + ledger.WRITEOFF_DELAY());
        ledger.writeOff(_pid(STK, alice));
        assertEq(ledger.debtOf(_pid(STK, alice)), 0);
    }

    function test_reviewF5_adminBurnThenReissueAfterAWriteOffRecoversToTheTreasury() public {
        _open(alice, 100e18, 6_000e18);
        stock.adminBurn(address(vault), 100e18);
        ledger.writeOff(_pid(STK, alice));
        vm.warp(vm.getBlockTimestamp() + ledger.WRITEOFF_DELAY());
        ledger.writeOff(_pid(STK, alice));
        assertEq(vault.balanceOf(address(sjoin)), 0, "nothing stranded in the join");
        assertEq(vault.balanceOf(address(treasury)), 100e24);
        // the hollow vault refuses a dust deposit that would have captured the reissue
        assertEq(vault.maxDeposit(mallory), 0);
        stock.mint(mallory, 1);
        vm.startPrank(mallory);
        stock.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, mallory, 1, 0));
        vault.deposit(1, mallory);
        vm.stopPrank();
        // the issuer reissues: the Treasury's shares hold it all (governable by the Safe), deposits reopen
        stock.mint(address(vault), 100e18);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(address(treasury))), 100e18, 1);
        assertGt(vault.maxDeposit(mallory), 0);
    }

    function test_reviewF5_vaultSharesCarrySixMoreDecimalsAndValuesAreUnchanged() public {
        assertEq(vault.decimals(), stock.decimals() + 6);
        _open(alice, 100e18, 5_000e18);
        assertEq(ledger.position(_pid(STK, alice)).collateral, 100e24);
        (uint256 v,) = price.latestValue();
        assertApproxEqRel(v, 100e12, 1e9, "per 1e18 shares = 1e-6 of a $100 token");
        (bool ok,) = ledger.healthy(_pid(STK, alice));
        assertTrue(ok, "$10,000 against $5,000: the value is the same as before the offset");
    }

    function _bad() internal view returns (uint128 bad) {
        (,,,, bad) = ledger.ilkState(STK);
    }
}
