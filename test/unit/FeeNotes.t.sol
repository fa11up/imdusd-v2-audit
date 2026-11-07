// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {Treasury, ICoverable} from "../../src/Treasury.sol";
import {FeeNotes, ITreasuryNotes} from "../../src/peg/FeeNotes.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Fee notes: series only through the timelock, exact pricing, the revenue cap and its 90-day
/// meter, non-transferability, redemption at maturity that fails closed on a short Treasury.
contract FeeNotesTest is System {
    bytes32 constant ETH = "ETH";

    MockERC20 weth;
    MockERC20 usdc;
    MockFeed ethFeed;
    FeeNotes notes;

    address alice = makeAddr("alice"); // borrower whose interest is the revenue
    address bob = makeAddr("bob"); // note buyer
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        usdc = new MockERC20("USDC", 6);
        ethFeed = new MockFeed(2000e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        notes = new FeeNotes(IERC20(address(usd)), IERC20(address(usdc)), ITreasuryNotes(address(treasury)), address(params));
        treasury.wireNotes(address(notes));
        params.setGenesisNotes(address(notes));
        params.seal();

        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            weth.mint(us[i], 10_000e18);
            usdc.mint(us[i], 10_000_000e6);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usdc.approve(address(notes), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _borrow(address u, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ETH, rate);
        vm.prank(u);
        ledger.open(ETH, 0, Adjust(int256(debt * 2 / 2000), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _wait(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        ethFeed.set(ethFeed.value());
    }

    /// Open a series the only way there is: the governor proposes, 48h pass, anyone applies.
    function _open(uint64 tenor, uint32 d, uint128 cap) internal returns (uint256 id) {
        bytes memory payload = abi.encode(params.OPEN_NOTE_SERIES(), tenor, d, cap);
        vm.prank(governor);
        params.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        ethFeed.set(ethFeed.value());
        params.applyPending();
        id = notes.count();
    }

    /// The upfront fee (7 days of 10% on 100k, ~191.8) + 30 days of 10% on the debt: ~1,015 imdUSD in the meter.
    function _earnRevenue() internal returns (uint256 revenue) {
        uint256 fee = ledger.upfrontFeeFor(ETH, 100_000e18, 0.10e18);
        _borrow(alice, 100_000e18, 0.10e18);
        _wait(30 days);
        ledger.accrue(ETH);
        revenue = treasury.trailingRevenue();
        assertApproxEqAbs(revenue, fee + (100_000e18 + fee) * 30 / 3650, 2);
        assertEq(usd.balanceOf(address(treasury)), revenue, "meter == imdUSD received");
    }

    function _assertSupply() internal {
        ledger.accrue(ETH);
        (uint128 d,,,, uint128 bad) = ledger.ilkState(ETH);
        assertEq(
            usd.totalSupply(), uint256(d) + bad + ledger.reserveBacked() + migrator.outstanding() + _keeperOutstanding(), "supply equation"
        );
    }

    // ------------------------------------------------------------ series only via the timelock

    function test_seriesOnlyThroughTheTimelock() public {
        // Nobody opens directly: not a stranger, not the governor, not the wirer.
        vm.expectRevert(FeeNotes.Unauthorized.selector);
        notes.open(30 days, 500, 1_000e18);
        vm.prank(governor);
        vm.expectRevert(FeeNotes.Unauthorized.selector);
        notes.open(30 days, 500, 1_000e18);
        // Only the governor proposes.
        bytes memory p = abi.encode(params.OPEN_NOTE_SERIES(), uint64(30 days), uint32(500), uint128(1_000e18));
        vm.expectRevert(Governed.NotGovernor.selector);
        params.propose(p);
        vm.prank(governor);
        params.propose(p);
        assertEq(notes.count(), 0, "nothing opened yet");
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, vm.getBlockTimestamp() + 1));
        params.applyPending();
        vm.warp(vm.getBlockTimestamp() + 1);
        params.applyPending();
        assertEq(notes.count(), 1);
        FeeNotes.Series memory s = notes.series(1);
        assertEq(s.saleEnd, vm.getBlockTimestamp() + 7 days);
        assertEq(s.maturity, vm.getBlockTimestamp() + 7 days + 30 days);
        assertEq(s.discountBps, 500);
        assertEq(s.cap, 1_000e18);
        assertEq(s.sold, 0);
        // The genesis setter is spent.
        vm.expectRevert(ParametersBase.Sealed.selector);
        params.setGenesisNotes(address(notes));
        vm.expectRevert(Treasury.AlreadyWired.selector);
        treasury.wireNotes(address(notes));
    }

    function test_seriesBounds() public {
        uint8 k = params.OPEN_NOTE_SERIES();
        vm.startPrank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, uint64(45 days), uint32(500), uint128(1_000e18)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, uint64(30 days), uint32(0), uint128(1_000e18)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, uint64(30 days), uint32(1001), uint128(1_000e18)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, uint64(30 days), uint32(500), uint128(0)));
        // Every allowed tenor and the largest discount pass validation.
        params.propose(abi.encode(k, uint64(90 days), uint32(1000), uint128(1)));
        params.cancel();
        params.propose(abi.encode(k, uint64(180 days), uint32(1), uint128(type(uint128).max)));
        params.cancel();
        vm.stopPrank();
    }

    function test_genesisNotesChecks() public {
        // A fresh Parameters refuses a notes contract bound to another Parameters / token.
        Parameters other = new Parameters(governor, address(this));
        vm.expectRevert(ParametersBase.BadConfig.selector);
        other.setGenesisNotes(address(notes)); // token not wired yet
        MockERC20 tok = new MockERC20("x", 18);
        other.wire(address(ledger), address(tok));
        vm.expectRevert(ParametersBase.BadConfig.selector);
        other.setGenesisNotes(address(notes)); // notes.token() != tok
        vm.expectRevert(ParametersBase.BadConfig.selector);
        other.setGenesisNotes(alice); // no code
        // Wrong decimals order or zero addresses are refused at construction.
        vm.expectRevert(FeeNotes.OddDecimals.selector);
        new FeeNotes(IERC20(address(usdc)), IERC20(address(usd)), ITreasuryNotes(address(treasury)), address(params));
        vm.expectRevert(FeeNotes.ZeroAddress.selector);
        new FeeNotes(IERC20(address(usd)), IERC20(address(usdc)), ITreasuryNotes(address(0)), address(params));
    }

    // ------------------------------------------------------------ price

    function test_priceFormulaExact() public {
        _earnRevenue();
        uint256 id = _open(30 days, 500, 1_000e18);
        // 1,000 imdUSD at 5% off = 950 USDC exactly.
        assertEq(notes.priceOf(id, 1_000e18), 950e6);
        // A face that does not divide evenly rounds the USDC up.
        assertEq(notes.priceOf(id, 1e18 + 1), 950_001);
        uint256 tBefore = usdc.balanceOf(address(treasury));
        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = notes.buy(id, 1_000e18);
        assertEq(paid, 950e6);
        assertEq(usdc.balanceOf(address(treasury)) - tBefore, 950e6, "USDC to the Treasury");
        assertEq(bBefore - usdc.balanceOf(bob), 950e6);
        assertEq(notes.balanceOf(bob, id), 1_000e18, "face held as the 1155");
        assertEq(notes.outstanding(), 1_000e18);
        assertEq(notes.series(id).sold, 1_000e18);
    }

    function testFuzz_priceFormula(uint256 face, uint32 d) public {
        face = bound(face, 1, 1e30);
        d = uint32(bound(d, 1, 1000));
        _earnRevenue();
        uint256 id = _open(90 days, d, type(uint128).max);
        assertEq(notes.priceOf(id, face), Math.mulDiv(face, 10_000 - d, 10_000 * 1e12, Math.Rounding.Ceil));
    }

    // ------------------------------------------------------------ the revenue cap

    function test_capEnforcedAgainstTheMeter() public {
        uint256 revenue = _earnRevenue();
        uint256 id = _open(30 days, 300, 100_000e18);
        assertEq(notes.capacity(), 2 * revenue, "2x trailing revenue");
        // Exactly the cap sells; one wei more does not.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.CapExceeded.selector, 2 * revenue));
        notes.buy(id, 2 * revenue + 1);
        vm.prank(bob);
        notes.buy(id, 2 * revenue);
        assertEq(notes.capacity(), 0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.CapExceeded.selector, 0));
        notes.buy(id, 1);
        // More revenue reopens room, within the sale window.
        _wait(3 days);
        ledger.accrue(ETH);
        uint256 more = treasury.trailingRevenue() - revenue;
        assertGt(more, 0);
        assertEq(notes.capacity(), 2 * more);
        vm.prank(carol);
        notes.buy(id, 2 * more);
        assertEq(notes.outstanding(), 2 * revenue + 2 * more);
    }

    function test_seriesCapAndSaleWindow() public {
        _earnRevenue();
        uint256 id = _open(30 days, 300, 500e18);
        vm.prank(bob);
        notes.buy(id, 400e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.SeriesFull.selector, 100e18));
        notes.buy(id, 101e18);
        vm.prank(bob);
        notes.buy(id, 100e18);
        // A second series sells independently of the first's size cap, under the same revenue cap.
        uint256 id2 = _open(90 days, 300, 500e18);
        vm.prank(carol);
        notes.buy(id2, 100e18);
        // The first series' window closes 7 days after it opened; the second is still selling.
        vm.warp(notes.series(id).saleEnd);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.SaleClosed.selector, notes.series(id).saleEnd));
        notes.buy(id, 1);
        vm.prank(carol);
        notes.buy(id2, 1e18);
        vm.expectRevert(FeeNotes.UnknownSeries.selector);
        notes.buy(99, 1);
        vm.expectRevert(FeeNotes.ZeroAmount.selector);
        notes.buy(id2, 0);
    }

    // ------------------------------------------------------------ the meter

    /// forge-config: default.fuzz.runs = 128
    /// @dev A Treasury fed directly (this contract as its "ledger"): after every write and after every silent
    /// warp, the meter equals the sum over the last 90 days of a reference log.
    function testFuzz_meterRollsOver90Days(uint32[24] memory gaps, uint96[24] memory amounts, uint32 silent) public {
        Treasury t = new Treasury(governor, IERC20(address(usd)), address(this));
        t.wire(ICoverable(address(this)));
        uint256[24] memory days_;
        for (uint256 i; i < 24; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(uint256(gaps[i]), 0, 40 days));
            t.noteRevenue(bytes32("ETH"), amounts[i]);
            days_[i] = vm.getBlockTimestamp() / 1 days;
            assertEq(t.trailingRevenue(), _reference(days_, amounts, i + 1), "after write");
        }
        // Days pass with no write: the view rolls on its own.
        vm.warp(vm.getBlockTimestamp() + bound(uint256(silent), 0, 200 days));
        assertEq(t.trailingRevenue(), _reference(days_, amounts, 24), "after silent warp");
        // And a write afterwards clears exactly what expired.
        t.noteRevenue(bytes32("ETH"), 1);
        assertEq(t.trailingRevenue(), _reference(days_, amounts, 24) + 1, "after late write");
        assertEq(t.meterTotal(), t.trailingRevenue());
    }

    function _reference(uint256[24] memory days_, uint96[24] memory amounts, uint256 n) internal view returns (uint256 sum) {
        uint256 today = vm.getBlockTimestamp() / 1 days;
        for (uint256 i; i < n; ++i) {
            if (days_[i] + 90 > today) sum += amounts[i];
        }
    }

    function test_meterCountsOnlyImdUsdReceivedAsInterest() public {
        // No savings vault here: every interest mint lands in the Treasury and is metered in full.
        _borrow(alice, 100_000e18, 0.10e18);
        _wait(10 days);
        ledger.accrue(ETH);
        assertEq(treasury.trailingRevenue(), usd.balanceOf(address(treasury)));
        // A transfer into the Treasury is not revenue.
        vm.prank(alice);
        usd.transfer(address(treasury), 1_000e18);
        assertEq(treasury.trailingRevenue() + 1_000e18, usd.balanceOf(address(treasury)));
        // Only the Ledger may report.
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.noteRevenue(bytes32("ETH"), 1);
        vm.prank(governor);
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.noteRevenue(bytes32("ETH"), 1);
    }

    // ------------------------------------------------------------ non-transferable

    function test_nonTransferable() public {
        _earnRevenue();
        uint256 id = _open(30 days, 500, 1_000e18);
        vm.prank(bob);
        notes.buy(id, 100e18);
        vm.startPrank(bob);
        vm.expectRevert(FeeNotes.NonTransferable.selector);
        notes.safeTransferFrom(bob, carol, id, 1, "");
        uint256[] memory ids = new uint256[](1);
        uint256[] memory vs = new uint256[](1);
        ids[0] = id;
        vs[0] = 1;
        vm.expectRevert(FeeNotes.NonTransferable.selector);
        notes.safeBatchTransferFrom(bob, carol, ids, vs, "");
        vm.expectRevert(FeeNotes.NonTransferable.selector);
        notes.setApprovalForAll(carol, true);
        vm.stopPrank();
        assertEq(notes.balanceOf(bob, id), 100e18);
        assertEq(notes.balanceOf(carol, id), 0);
    }

    // ------------------------------------------------------------ redemption

    function test_redeemAtMaturityRefusedBefore() public {
        _earnRevenue();
        uint256 id = _open(30 days, 500, 1_000e18);
        vm.prank(bob);
        notes.buy(id, 500e18);
        uint64 maturity = notes.series(id).maturity;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.NotMatured.selector, maturity));
        notes.redeem(id, 500e18);
        vm.warp(maturity - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.NotMatured.selector, maturity));
        notes.redeem(id, 500e18);
        vm.warp(maturity);
        uint256 supply = usd.totalSupply();
        uint256 tBefore = usd.balanceOf(address(treasury));
        vm.prank(bob);
        notes.redeem(id, 500e18);
        assertEq(usd.balanceOf(bob), 500e18, "paid in full");
        assertEq(tBefore - usd.balanceOf(address(treasury)), 500e18, "from the Treasury's balance");
        assertEq(usd.totalSupply(), supply, "no mint");
        assertEq(notes.balanceOf(bob, id), 0);
        assertEq(notes.outstanding(), 0);
        // Nothing left to redeem.
        vm.prank(bob);
        vm.expectRevert();
        notes.redeem(id, 1);
        _assertSupply();
    }

    function test_partialRedemption() public {
        _earnRevenue();
        uint256 id = _open(30 days, 500, 1_000e18);
        vm.prank(bob);
        notes.buy(id, 500e18);
        vm.warp(notes.series(id).maturity);
        vm.prank(bob);
        notes.redeem(id, 200e18);
        assertEq(notes.balanceOf(bob, id), 300e18);
        assertEq(notes.outstanding(), 300e18);
        assertEq(usd.balanceOf(bob), 200e18);
    }

    function test_redeemFailsClosedWhenTreasuryShortAndSucceedsOnceFunded() public {
        uint256 revenue = _earnRevenue();
        uint256 id = _open(30 days, 500, 10_000e18);
        vm.prank(bob);
        notes.buy(id, 2 * revenue); // the whole cap: more face than the Treasury holds today
        vm.warp(notes.series(id).maturity);
        // Nobody has touched the type since, so the Treasury still holds only `revenue`: short.
        uint256 bal = usd.balanceOf(address(treasury));
        assertLt(bal, 2 * revenue);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FeeNotes.TreasuryShort.selector, bal));
        notes.redeem(id, 2 * revenue);
        assertEq(notes.balanceOf(bob, id), 2 * revenue, "the claim waits, nothing burned");
        assertEq(notes.outstanding(), 2 * revenue);
        // A partial redemption within the balance still works.
        vm.prank(bob);
        notes.redeem(id, bal / 2);
        // Funded (here: interest accrued since; the Safe could also unwind LP into imdUSD), the rest pays.
        ledger.accrue(ETH);
        assertGe(usd.balanceOf(address(treasury)), 2 * revenue - bal / 2);
        vm.prank(bob);
        notes.redeem(id, 2 * revenue - bal / 2);
        assertEq(usd.balanceOf(bob), 2 * revenue);
        assertEq(notes.outstanding(), 0);
        _assertSupply();
    }

    function test_treasuryPaysNotesOnlyForTheNotesContract() public {
        _earnRevenue();
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.payNote(bob, 1);
        vm.prank(governor);
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.payNote(bob, 1);
    }

    // ------------------------------------------------------------ the supply equation

    function test_supplyEquationUntouchedByNotes() public {
        _earnRevenue();
        _assertSupply();
        uint256 id = _open(30 days, 500, 1_000e18);
        uint256 supply = usd.totalSupply();
        vm.prank(bob);
        notes.buy(id, 1_000e18);
        assertEq(usd.totalSupply(), supply, "a sale mints nothing");
        _assertSupply();
        vm.warp(notes.series(id).maturity);
        _assertSupply();
        supply = usd.totalSupply();
        vm.prank(bob);
        notes.redeem(id, 1_000e18);
        assertEq(usd.totalSupply(), supply, "a redemption is a transfer, not a mint");
        _assertSupply();
    }
}
