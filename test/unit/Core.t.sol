// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed, MockAggregator, MockVault} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Governed} from "../../src/Governed.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {Join} from "../../src/Join.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

contract FlashTaker is IERC3156FlashBorrower {
    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        IERC20(token).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev Owns a position and drops its rate through a flash mint in one transaction: repay to zero, reopen lower
/// (finding A1: before the fix this skipped setRate's 7-day premium).
contract RateDropper is IERC3156FlashBorrower {
    Ledger immutable ledger;
    ImdUSD immutable usd;
    bytes32 immutable ilk;
    uint64 reopenRate;

    constructor(Ledger ledger_, ImdUSD usd_, bytes32 ilk_) {
        (ledger, usd, ilk) = (ledger_, usd_, ilk_);
    }

    function open(IERC20 coll, uint256 c, uint256 d, uint64 rate) external {
        coll.approve(address(ledger), c);
        ledger.open(ilk, 0, Adjust(int256(c), int256(d), rate, 0, 0, false, type(uint256).max, address(0)));
    }

    function cycle(uint64 rate) external {
        reopenRate = rate;
        usd.flashLoan(this, address(usd), ledger.debtOf(_pid(ilk, address(this))), "");
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        ledger.open(ilk, 0, Adjust(0, -int256(amount), 0, 0, 0, false, type(uint256).max, address(0))); // repay to zero
        ledger.open(ilk, 0, Adjust(0, int256(amount), reopenRate, 0, 0, false, type(uint256).max, address(0))); // reopen
        IERC20(token).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

contract CoreTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant SUSDC = "S-USDC";
    bytes32 constant SIMD = "SIMD";

    MockERC20 weth;
    MockERC20 usdc;
    MockERC20 simd;
    MockERC20 v1;
    MockVault vault;
    MockFeed ethMedian;
    MockFeed ethSpot;
    MockFeed usdcFeed;
    MockFeed simdFeed;
    MockFeed nhi;
    MockAggregator usdcPeg;
    RateFeed vaultRate;
    Join ethJoin;
    Join vaultJoin;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        usdc = new MockERC20("USDC", 6);
        simd = new MockERC20("sIMD", 18);
        v1 = new MockERC20("imdUSDv1", 18);
        vault = new MockVault(IERC20(address(usdc)));
        ethMedian = new MockFeed(2000e18);
        ethSpot = new MockFeed(2000e18);
        usdcFeed = new MockFeed(1e30); // $1 per 1e6 raw = 1e30 per 1e18 raw
        simdFeed = new MockFeed(5e18);
        nhi = new MockFeed(0.98e18);
        usdcPeg = new MockAggregator(8, 1e8);
        // Seed the vault so its rate is defined, then build the rate feed (cap: 1% a day).
        usdc.mint(address(this), 1e6);
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6, address(0xbeef));
        vaultRate = new RateFeed(
            address(vault), bytes4(keccak256("convertToAssets(uint256)")), true, usdcFeed, uint256(0.01e18) / 1 days
        );

        _deploySystem(IERC20(address(v1)));
        ethJoin = _addIlk(ETH, address(weth), ethMedian, ethSpot, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1_000_000e18));
        ParametersBase.Risk memory sr = _risk(1.08e18, 1_000_000e18);
        sr.chop = 0.05e18;
        sr.yieldFee = 0.1e18;
        sr.pegFloor = 0.98e18;
        sr.rateFloor = 0.005e18;
        vaultJoin = _addIlk(SUSDC, address(vault), IFeed(address(vaultRate)), IFeed(address(vaultRate)), IFeed(address(0)), address(vaultRate), address(usdcPeg), true, sr);
        ParametersBase.Risk memory ir = _risk(1.7e18, 1_000_000e18);
        ir.chop = 0.2e18;
        _addIlk(SIMD, address(simd), simdFeed, simdFeed, nhi, address(0), address(0), true, ir);
        params.setGenesisMigratorLine(1_000_000e18);
        params.seal();

        for (uint256 i; i < 4; ++i) {
            address u = [alice, bob, carol, dave][i];
            weth.mint(u, 1000e18);
            usdc.mint(u, 1_000_000e6);
            simd.mint(u, 100_000e18);
            vm.startPrank(u);
            weth.approve(address(ledger), type(uint256).max);
            usdc.approve(address(ledger), type(uint256).max);
            vault.approve(address(ledger), type(uint256).max);
            simd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    /// @dev The upfront fee a borrow would pay now.
    function _uf(bytes32 ilk, uint256 amount, uint64 rate) internal view returns (uint256) {
        return ledger.upfrontFeeFor(ilk, amount, rate);
    }

    function _open(address u, bytes32 ilk, uint256 coll, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        vm.prank(u);
        ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _refresh() internal {
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
        usdcFeed.set(usdcFeed.value());
        simdFeed.set(simdFeed.value());
        nhi.set(nhi.value());
        usdcPeg.set(usdcPeg.answer());
    }

    function _assertSupply() internal {
        bytes32[3] memory ilks = [ETH, SUSDC, SIMD];
        uint256 sum = ledger.reserveBacked() + migrator.outstanding() + _keeperOutstanding();
        for (uint256 i; i < 3; ++i) {
            ledger.accrue(ilks[i]);
            (uint128 d,,,, uint128 bad) = ledger.ilkState(ilks[i]);
            sum += uint256(d) + bad;
        }
        // + bridged in − bridged out (zero while no bridge minter is set)
        assertEq(int256(usd.totalSupply()), int256(sum) + _bridgeNet(), "supply == debt + bad debt + reserve-backed + migrated + bridge net");
    }

    // ------------------------------------------------------------ borrowing

    function test_borrowAndRepay() public {
        uint256 fee = _uf(ETH, 10_000e18, 0.05e18);
        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        assertEq(usd.balanceOf(alice), 10_000e18);
        assertEq(weth.balanceOf(address(ethJoin)), 10e18);
        assertEq(ledger.debtOf(_pid(ETH, alice)), 10_000e18 + fee, "F1: the upfront fee is owed too");
        vm.prank(address(treasury));
        usd.transfer(alice, fee); // she buys the fee's imdUSD back (here: from the Treasury, which received it)
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(-10e18, -int256(10_000e18 + fee), 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(ledger.debtOf(_pid(ETH, alice)), 0);
        assertEq(weth.balanceOf(alice), 1000e18);
        assertEq(sorted.size(ETH), 0);
        assertEq(ledger.position(_pid(ETH, alice)).rate, 0.05e18, "the rate is kept across a repayment to zero (A1)");
        _assertSupply();
    }

    function test_unhealthyBorrowReverts() public {
        // 10 ETH at $2000 = $20,000; at 140% the most is 14,285.7
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(10e18, 14_300e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        _open(alice, ETH, 10e18, 14_265e18, 0.05e18); // + its upfront fee (~13.7) stays under the 14,285.7 maximum
    }

    function test_ceilingDustAndRateFloor() public {
        vm.prank(alice);
        vm.expectRevert(LedgerBase.DustDebt.selector);
        ledger.open(ETH, 0, Adjust(10e18, 50e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.prank(alice);
        vm.expectRevert(LedgerBase.RateOutOfRange.selector);
        ledger.open(ETH, 0, Adjust(10e18, 500e18, 0.001e18, 0, 0, false, type(uint256).max, address(0)));
        vm.prank(alice);
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        ledger.open(ETH, 0, Adjust(1000e18, 1_000_001e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    // ------------------------------------------------------------ interest

    function test_interestMintsToTreasury() public {
        uint256 fa = _uf(ETH, 10_000e18, 0.05e18);
        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        uint256 fb = _uf(ETH, 5_000e18, 0.10e18);
        _open(bob, ETH, 10e18, 5_000e18, 0.10e18);
        vm.warp(block.timestamp + 365 days);
        _refresh();
        // A year of interest on the debt incl. the upfront fees.
        uint256 da = (10_000e18 + fa) * 105 / 100;
        uint256 db = (5_000e18 + fb) * 110 / 100;
        assertApproxEqAbs(ledger.debtOf(_pid(ETH, alice)), da, 1);
        assertApproxEqAbs(ledger.debtOf(_pid(ETH, bob)), db, 1);
        ledger.accrue(ETH);
        assertApproxEqAbs(usd.balanceOf(address(treasury)), da + db - 15_000e18, 2, "fees + a year of interest");
        _assertSupply();
        // Alice repays in full: the type's recorded debt is never below the sum of its positions.
        uint256 owed = ledger.debtOf(_pid(ETH, alice));
        deal(address(usd), alice, owed, true);
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(0, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        (uint128 d,,,,) = ledger.ilkState(ETH);
        assertGe(d, ledger.debtOf(_pid(ETH, bob)));
    }

    function test_rateCooldownPremium() public {
        _open(alice, ETH, 10e18, 10_000e18, 0.10e18);
        uint256 d0 = ledger.debtOf(_pid(ETH, alice)); // 10,000 + its upfront fee
        // Raising inside the cooldown is charged too: 7 days at the old 10% on the debt.
        vm.prank(alice);
        ledger.setRate(_pid(ETH, alice), 0.12e18, 0, 0);
        uint256 d1 = d0 + _premium(d0, 0.10e18);
        assertEq(ledger.debtOf(_pid(ETH, alice)), d1);
        // Lowering inside the cooldown costs 7 days at the old rate on the debt: d1 * 12% * 7/365.
        vm.prank(alice);
        ledger.setRate(_pid(ETH, alice), 0.02e18, 0, 0);
        assertApproxEqAbs(ledger.debtOf(_pid(ETH, alice)), d1 + d1 * 12 * 7 / 36500, 1);
        // After the cooldown, lowering is free again.
        vm.warp(block.timestamp + 8 days);
        _refresh();
        uint256 before = ledger.debtOf(_pid(ETH, alice));
        vm.prank(alice);
        ledger.setRate(_pid(ETH, alice), 0.01e18, 0, 0);
        assertEq(ledger.debtOf(_pid(ETH, alice)), before);
        _assertSupply();
    }

    /// A premium left by a charged change lapses with its cooldown. A same-rate call restarts the clock, and must not bring it back.
    function test_lapsedPremiumStaysLapsedAcrossASameRateCall() public {
        _open(alice, ETH, 10e18, 5_000e18, 0.10e18);
        uint256 id = _pid(ETH, alice);
        vm.prank(alice);
        ledger.setRate(id, 0.12e18, 0, 0); // charged: leaves premiumRate 10%
        assertEq(ledger.position(id).premiumRate, 0.10e18);
        vm.warp(block.timestamp + 8 days);
        _refresh();
        vm.prank(alice);
        ledger.setRate(id, 0.12e18, 0, 0);
        assertEq(ledger.position(id).premiumRate, 0, "lapsed, and stays lapsed");
        uint256 before = ledger.debtOf(id);
        uint256 fee = ledger.upfrontFeeFor(ETH, 1_000e18, 0.12e18);
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(ledger.debtOf(id), before + 1_000e18 + fee, "the borrow pays its upfront fee and no premium");
    }

    /// Inside the cooldown a same-rate call keeps the premium: nothing has lapsed.
    function test_sameRateCallInsideTheCooldownKeepsThePremium() public {
        _open(alice, ETH, 10e18, 5_000e18, 0.10e18);
        uint256 id = _pid(ETH, alice);
        vm.startPrank(alice);
        ledger.setRate(id, 0.12e18, 0, 0);
        ledger.setRate(id, 0.12e18, 0, 0);
        vm.stopPrank();
        assertEq(ledger.position(id).premiumRate, 0.10e18);
    }

    /// The last borrower's harvest takes the type's debt to its residue before its own record moves `weighted`: the fee on
    /// a borrow in the same call must still read the rate, not divide by the residue.
    function test_borrowInTheCallThatHarvestsTheDebtAway() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 300e18, 0.02e18, 0, 0, true, type(uint256).max, address(0)));
        uint256 id = _pid(SUSDC, alice);
        vault.accrue(500e6 + 50); // ~$450 net of the fee: more than the debt
        vm.warp(block.timestamp + 6 days);
        _refresh();
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, 1_000e18, 0.02e18, 0, 0, false, _premium(1_000e18, 0.02e18), address(0)));
        // The average reads recorded debt over debt with accrual: marginally below the rate (see `_upfrontFee`).
        assertApproxEqRel(ledger.debtOf(id), 1_000e18 + _premium(1_000e18, 0.02e18), 1e12, "the old debt harvested; the fee at the type's rate");
        _assertSupply();
    }

    // ------------------------------------------------------------ A1: repay to zero and reopen

    function _dropper(uint64 rate) internal returns (RateDropper x) {
        x = new RateDropper(ledger, usd, ETH);
        weth.mint(address(x), 10e18);
        x.open(IERC20(address(weth)), 10e18, 10_000e18, rate);
    }

    function _premium(uint256 debt, uint256 oldRate) internal pure returns (uint256) {
        return (debt * oldRate * 7 days + 365 days * 1e18 - 1) / (365 days * 1e18);
    }

    function test_flashRepayAndReopenLowerPaysPremium() public {
        RateDropper x = _dropper(0.10e18);
        uint256 d0 = ledger.debtOf(_pid(ETH, address(x))); // 10,000 + its opening fee
        uint256 t0 = usd.balanceOf(address(treasury));
        x.cycle(0.01e18); // one transaction: flash mint, repay to 0, reopen at 1%
        uint256 premium = _premium(d0, 0.10e18);
        assertGt(premium, 19e18); // ~19.2 imdUSD: 7 days of 10% on the debt
        // + the upfront fee: the type is empty mid-transaction, so at the reopening rate (1%).
        uint256 upfront = _premium(d0, 0.01e18);
        assertApproxEqAbs(ledger.debtOf(_pid(ETH, address(x))), d0 + premium + upfront, 2, "setRate's premium + the upfront fee");
        assertEq(ledger.position(_pid(ETH, address(x))).rate, 0.01e18);
        assertEq(ledger.position(_pid(ETH, address(x))).lastRateChange, block.timestamp);
        assertApproxEqAbs(usd.balanceOf(address(treasury)) - t0, premium + upfront, 2, "minted as interest");
        assertEq(sorted.rateOf(ETH, _pid(ETH, address(x))), 0.01e18);
        _assertSupply();
    }

    function test_flashRepayAndReopenLowerAfterCooldownIsFree() public {
        RateDropper x = _dropper(0.10e18);
        vm.warp(block.timestamp + 7 days);
        _refresh();
        uint256 before = ledger.debtOf(_pid(ETH, address(x)));
        x.cycle(0.01e18);
        // No premium once the cooldown has passed; only the upfront fee at the reopening rate, the type being
        // empty mid-transaction. (Before review C1 this read 0: the type's rounding residue made the average 0.)
        assertEq(ledger.debtOf(_pid(ETH, address(x))), before + _premium(before, 0.01e18), "no premium once the cooldown has passed");
        assertEq(ledger.position(_pid(ETH, address(x))).rate, 0.01e18);
        assertEq(ledger.position(_pid(ETH, address(x))).premiumRate, 0, "a free change leaves no memory");
        _assertSupply();
    }

    function test_flashRepayAndReopenHigherIsFreeAndRestartsCooldown() public {
        RateDropper x = _dropper(0.05e18);
        vm.warp(block.timestamp + 8 days);
        _refresh();
        uint256 before = ledger.debtOf(_pid(ETH, address(x)));
        x.cycle(0.20e18); // raising after the cooldown is free of the premium: only the upfront fee at 20%
        uint256 d1 = before + _premium(before, 0.20e18);
        assertEq(ledger.debtOf(_pid(ETH, address(x))), d1);
        assertEq(ledger.position(_pid(ETH, address(x))).rate, 0.20e18);
        // ...and restarts the cooldown, as setRate does: dropping straight back pays 7 days at 20% on the debt
        // (plus the upfront fee at the new 5%, the type being empty mid-transaction).
        x.cycle(0.05e18);
        assertEq(ledger.debtOf(_pid(ETH, address(x))), d1 + _premium(d1, 0.20e18) + _premium(d1, 0.05e18));
        _assertSupply();
    }

    function test_newPositionOpensAtAnyRateFree() public {
        // "Free" of the A1 premium: only the upfront fee applies.
        uint256 fb = _uf(ETH, 1_000e18, 0.01e18);
        _open(bob, ETH, 10e18, 1_000e18, 0.01e18); // the floor
        uint256 fc = _uf(ETH, 1_000e18, 1e18);
        _open(carol, ETH, 10e18, 1_000e18, 1e18); // MAX_RATE
        assertEq(ledger.debtOf(_pid(ETH, bob)), 1_000e18 + fb);
        assertEq(ledger.debtOf(_pid(ETH, carol)), 1_000e18 + fc);
        assertEq(ledger.position(_pid(ETH, bob)).lastRateChange, block.timestamp);
        _assertSupply();
    }

    // ------------------------------------------------------------ F1: the upfront borrow fee

    function _avgRate(bytes32 ilk) internal view returns (uint256) {
        (uint128 d,, uint256 w,,) = ledger.ilkState(ilk);
        return d == 0 ? 0 : w / d;
    }

    function test_openingPaysAverageRateUpfront() public {
        // Empty type: the opener's own rate. 10,000 x 10% x 7/365 = 19.18.
        uint256 fee0 = ledger.upfrontFeeFor(ETH, 10_000e18, 0.10e18);
        assertEq(fee0, _premium(10_000e18, 0.10e18));
        uint256 t0 = usd.balanceOf(address(treasury));
        _open(bob, ETH, 10e18, 10_000e18, 0.10e18);
        assertEq(ledger.debtOf(_pid(ETH, bob)), 10_000e18 + fee0, "fee added to the debt");
        assertEq(usd.balanceOf(bob), 10_000e18, "the borrower receives the amount");
        assertEq(usd.balanceOf(address(treasury)) - t0, fee0, "minted as interest");
        // A low-rate opener pays the TYPE's average (~10%), not its own 1%.
        uint256 avg = _avgRate(ETH);
        assertApproxEqRel(avg, 0.10e18, 0.001e18);
        uint256 fee1 = ledger.upfrontFeeFor(ETH, 5_000e18, 0.01e18);
        assertEq(fee1, (5_000e18 * avg * 7 days + 365 days * 1e18 - 1) / (365 days * 1e18));
        _open(carol, ETH, 10e18, 5_000e18, 0.01e18);
        assertEq(ledger.debtOf(_pid(ETH, carol)), 5_000e18 + fee1);
        assertGt(fee1, _premium(5_000e18, 0.01e18) * 5, "well above 7 days at its own rate");
        // Adding debt pays it too.
        uint256 fee2 = ledger.upfrontFeeFor(ETH, 1_000e18, 0);
        vm.prank(bob);
        ledger.open(ETH, 0, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(ledger.debtOf(_pid(ETH, bob)), 11_000e18 + fee0 + fee2);
        _assertSupply();
    }

    function test_freshAddressRoundTripPaysTheFee() public {
        // The A1 residual: Alice (10%) repays, moves her collateral to a fresh address, reborrows at 1%.
        _open(bob, ETH, 100e18, 100_000e18, 0.10e18); // the market sits at 10%
        _open(alice, ETH, 10e18, 10_000e18, 0.10e18);
        uint256 owed = ledger.debtOf(_pid(ETH, alice));
        deal(address(usd), alice, owed, true);
        vm.startPrank(alice);
        ledger.open(ETH, 0, Adjust(-10e18, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        weth.transfer(dave, 10e18);
        vm.stopPrank();
        uint256 avg = _avgRate(ETH);
        _open(dave, ETH, 10e18, 10_000e18, 0.01e18);
        uint256 cost = ledger.debtOf(_pid(ETH, dave)) - 10_000e18;
        assertGe(cost, 10_000e18 * avg * 7 days / (365 days * 1e18), "costs >= 7 days at the average rate");
        assertApproxEqRel(cost, _premium(10_000e18, 0.10e18), 0.001e18, "~ the premium she dodged (avg = her old rate here)");
    }

    function test_maxUpfrontFeeReverts() public {
        uint256 fee = ledger.upfrontFeeFor(ETH, 10_000e18, 0.05e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LedgerBase.UpfrontFeeTooHigh.selector, fee));
        ledger.open(ETH, 0, Adjust(10e18, 10_000e18, 0.05e18, 0, 0, false, fee - 1, address(0)));
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(10e18, 10_000e18, 0.05e18, 0, 0, false, fee, address(0)));
        assertEq(ledger.debtOf(_pid(ETH, alice)), 10_000e18 + fee);
        // Repaying and depositing never pay it, whatever the bound.
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(1e18, -1_000e18, 0, 0, 0, false, 0, address(0)));
    }

    function test_migratorPaysNoUpfrontFee() public {
        // The Migrator is a 1:1 conversion outside the Ledger: no debt, so no fee (exempt by construction).
        _open(bob, ETH, 10e18, 10_000e18, 0.10e18);
        uint256 t0 = usd.balanceOf(address(treasury));
        v1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        v1.approve(address(migrator), type(uint256).max);
        migrator.toV2(1_000e18);
        vm.stopPrank();
        assertEq(usd.balanceOf(alice), 1_000e18);
        assertEq(usd.balanceOf(address(treasury)), t0);
        _assertSupply();
    }

    // ------------------------------------------------------------ A2: equal rates, newest first

    function test_equalRatesRedeemNewestFirst() public {
        address erin = makeAddr("erin");
        weth.mint(erin, 10e18);
        vm.prank(erin);
        weth.approve(address(ledger), type(uint256).max);

        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        _open(bob, ETH, 10e18, 10_000e18, 0.05e18);
        _open(carol, ETH, 10e18, 10_000e18, 0.05e18);
        assertEq(sorted.first(ETH), _pid(ETH, carol), "newest at the rate is first");
        assertEq(sorted.next(ETH, _pid(ETH, carol)), _pid(ETH, bob));
        assertEq(sorted.next(ETH, _pid(ETH, bob)), _pid(ETH, alice));
        assertEq(sorted.last(ETH), _pid(ETH, alice));

        // A raise to an existing rate lands at the FRONT of that run.
        _open(dave, ETH, 10e18, 10_000e18, 0.03e18);
        (uint256 p, uint256 n) = sorted.findInsertPosition(ETH, 0.05e18);
        vm.prank(dave);
        ledger.setRate(_pid(ETH, dave), 0.05e18, p, n);
        assertEq(sorted.first(ETH), _pid(ETH, dave));
        assertEq(sorted.next(ETH, _pid(ETH, dave)), _pid(ETH, carol));

        // An old-order hint (after the run) is not accepted as valid: the list walks to the front of the run.
        vm.prank(erin);
        ledger.open(ETH, 0, Adjust(10e18, 1_000e18, 0.05e18, _pid(ETH, alice), 0, false, type(uint256).max, address(0)));
        assertEq(sorted.first(ETH), _pid(ETH, erin));
        assertEq(sorted.next(ETH, _pid(ETH, erin)), _pid(ETH, dave));
        assertEq(sorted.size(ETH), 5);

        vm.prank(alice);
        usd.transfer(bob, 3_000e18);
        uint256 fee = redeemer.feeFor(ETH, 3_000e18);
        uint256 e = ledger.debtOf(_pid(ETH, erin));
        uint256 dv = ledger.debtOf(_pid(ETH, dave));
        uint256 c0 = ledger.debtOf(_pid(ETH, carol));
        uint256 a0 = ledger.debtOf(_pid(ETH, alice));
        vm.prank(bob);
        redeemer.redeem(ETH, 3_000e18, fee, 10, 0);
        // Newest first: Erin (1,000 + fee) is closed, the rest comes from Dave (the next newest at 5%).
        assertEq(ledger.debtOf(_pid(ETH, erin)), 0);
        assertEq(ledger.debtOf(_pid(ETH, dave)), dv - (3_000e18 - e));
        assertEq(ledger.debtOf(_pid(ETH, carol)), c0, "older positions at the rate untouched");
        assertEq(ledger.debtOf(_pid(ETH, alice)), a0, "the oldest is redeemed last");
        _assertSupply();
    }

    // ------------------------------------------------------------ A3: a feed that reverts

    function test_revertingFeedStillAllowsRepayAndDeposit() public {
        uint256 fee = _uf(ETH, 10_000e18, 0.05e18);
        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        vm.mockCallRevert(address(ethMedian), abi.encodeWithSelector(IFeed.latestValue.selector), "feed down");
        vm.expectRevert();
        pricer.quote(ETH);

        vm.startPrank(alice);
        ledger.open(ETH, 0, Adjust(0, -1_000e18, 0, 0, 0, false, type(uint256).max, address(0))); // pure repay
        ledger.open(ETH, 0, Adjust(1e18, 0, 0, 0, 0, false, type(uint256).max, address(0))); // pure deposit
        ledger.open(ETH, 0, Adjust(1e18, -1_000e18, 0, 0, 0, false, type(uint256).max, address(0))); // both
        // Anything that needs a price still refuses.
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(ETH, 0, Adjust(0, 100e18, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(ETH, 0, Adjust(-1e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.setRate(_pid(ETH, alice), 0.03e18, 0, 0); // a drop inside the cooldown needs the health check
        vm.stopPrank();

        vm.prank(alice);
        usd.transfer(bob, 500e18);
        vm.prank(bob);
        ledger.repayFor(_pid(ETH, alice), 500e18);
        assertEq(ledger.debtOf(_pid(ETH, alice)), 7_500e18 + fee);
        assertEq(ledger.position(_pid(ETH, alice)).collateral, 12e18);

        // Liquidation and redemption need the price and still refuse.
        vm.expectRevert();
        liquidator.liquidate(_pid(ETH, alice));
        vm.clearMockedCalls();
        _assertSupply();
    }

    // ------------------------------------------------------------ redemption

    function test_redemptionHitsLowestRateFirst() public {
        uint256 fa = _uf(ETH, 10_000e18, 0.02e18);
        _open(alice, ETH, 10e18, 10_000e18, 0.02e18);
        _open(bob, ETH, 10e18, 10_000e18, 0.05e18);
        _open(carol, ETH, 10e18, 10_000e18, 0.03e18);
        assertEq(sorted.first(ETH), _pid(ETH, alice));
        assertEq(sorted.next(ETH, _pid(ETH, alice)), _pid(ETH, carol));
        assertEq(sorted.next(ETH, _pid(ETH, carol)), _pid(ETH, bob));

        vm.prank(bob);
        usd.transfer(dave, 6_000e18);
        uint256 fee = redeemer.feeFor(ETH, 6_000e18);
        assertEq(fee, 0.05e18); // 0.5% floor + 6000/30000/2 = 10.5%, capped at 5%
        vm.prank(dave);
        (uint256 redeemed, uint256 out) = redeemer.redeem(ETH, 6_000e18, fee, 10, 0);
        assertEq(redeemed, 6_000e18);
        // $6,000 of ETH at $2000 less 5% = 2.85 ETH, all from Alice; her position gives up the whole $6,000 (3 ETH)
        // and the fee's 0.15 ETH goes to the Treasury (left in the position it made self-redemption free).
        assertEq(out, 2.85e18);
        assertEq(weth.balanceOf(dave), 1000e18 + 2.85e18);
        assertEq(weth.balanceOf(address(treasury)), 0.15e18, "the fee's collateral is the Treasury's");
        assertEq(ledger.debtOf(_pid(ETH, alice)), 4_000e18 + fa);
        assertEq(ledger.position(_pid(ETH, alice)).collateral, 10e18 - 3e18);
        assertGt(ledger.debtOf(_pid(ETH, carol)), 10_000e18, "untouched: its amount + its upfront fee");
        assertLt(ledger.debtOf(_pid(ETH, carol)), 10_010e18);
        _assertSupply();
    }

    function test_redemptionLeavesDustOrCloses() public {
        _open(alice, ETH, 10e18, 1_000e18, 0.02e18);
        _open(bob, ETH, 10e18, 5_000e18, 0.05e18);
        uint256 a = ledger.debtOf(_pid(ETH, alice));
        uint256 b = ledger.debtOf(_pid(ETH, bob));
        vm.prank(bob);
        usd.transfer(dave, a + 50e18);
        vm.prank(dave);
        (uint256 redeemed,) = redeemer.redeem(ETH, a + 50e18, 0.05e18, 10, 0);
        // Alice closed entirely, Bob takes the remaining 50 — but 50 would leave him above dust: ok.
        assertEq(redeemed, a + 50e18);
        assertEq(ledger.debtOf(_pid(ETH, alice)), 0);
        assertFalse(sorted.contains(ETH, _pid(ETH, alice)));
        assertEq(ledger.debtOf(_pid(ETH, bob)), b - 50e18);
    }

    function test_redemptionSkipsUnderwater() public {
        _open(alice, ETH, 1e18, 1_395e18, 0.02e18); // CR ~143% incl. the upfront fee
        _open(bob, ETH, 100e18, 10_000e18, 0.05e18);
        ethMedian.set(1000e18);
        ethSpot.set(1000e18); // Alice now at 71%: worth less than her debt, so skipped
        vm.prank(bob);
        usd.transfer(dave, 500e18);
        uint256 a = ledger.debtOf(_pid(ETH, alice));
        uint256 b = ledger.debtOf(_pid(ETH, bob));
        vm.prank(dave);
        redeemer.redeem(ETH, 500e18, 0.05e18, 10, 0);
        assertEq(ledger.debtOf(_pid(ETH, alice)), a, "skipped");
        assertEq(ledger.debtOf(_pid(ETH, bob)), b - 500e18);
    }

    // ------------------------------------------------------------ liquidation

    function test_liquidationSplitsPenalty() public {
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        uint256 debt = ledger.debtOf(_pid(ETH, alice)); // 14,000 + its upfront fee
        _open(dave, ETH, 100e18, 20_000e18, 0.05e18);
        ethMedian.set(1800e18);
        ethSpot.set(1800e18);
        vm.prank(dave);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(_pid(ETH, alice));
        assertEq(repaid, debt);
        assertEq(bad, 0);
        // debt/1,800 * 1.1 ETH seized; bonus 10% of it: Treasury 50%, marker 10% (both Dave here)
        assertApproxEqAbs(seized, debt * 1.1e18 / 1800e18, 1);
        uint256 bonus = seized - debt * 1e18 / 1800e18;
        assertApproxEqAbs(weth.balanceOf(address(treasury)), bonus / 2, 2);
        assertEq(ledger.position(_pid(ETH, alice)).collateral, 10e18 - seized);
        assertEq(ledger.debtOf(_pid(ETH, alice)), 0);
        assertFalse(sorted.contains(ETH, _pid(ETH, alice)));
        assertEq(ledger.position(_pid(ETH, alice)).rate, 0, "a liquidated position forgets its rate (A1)");
        _assertSupply();
    }

    function test_liquidationBadDebtThenCover() public {
        uint256 fee = _uf(ETH, 14_000e18, 0.05e18);
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(dave, ETH, 200e18, 50_000e18, 0.05e18);
        ethMedian.set(1200e18);
        ethSpot.set(1200e18);
        vm.prank(dave);
        (uint256 repaid, uint256 seized, uint256 bad) = liquidator.liquidate(_pid(ETH, alice));
        assertEq(seized, 10e18);
        // Solvency before penalty: the $12,000 the collateral is worth repays debt first; no bonus, no cut.
        assertEq(repaid, 12_000e18);
        assertEq(repaid + bad, 14_000e18 + fee, "the whole debt incl. the upfront fee");
        assertEq(weth.balanceOf(address(treasury)), 0, "no Treasury cut out of a position that booked bad debt");
        _assertSupply();
        vm.prank(dave);
        ledger.cover(ETH, bad);
        (,,,, uint128 left) = ledger.ilkState(ETH);
        assertEq(left, 0);
        _assertSupply();
    }

    /// A caller picks the gas limit. A cover starved on purpose must not leave the liquidation standing with the loss uncovered: a depositor could leave between the two.
    function test_starvedCoverCannotLeaveTheLossUncovered() public {
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(dave, ETH, 200e18, 50_000e18, 0.05e18);
        vm.prank(dave);
        usd.transfer(address(treasury), 10_000e18);
        ethMedian.set(1200e18);
        ethSpot.set(1200e18);
        uint256 id = _pid(ETH, alice);
        uint256 landed;
        for (uint256 g = 200_000; g < 2_500_000; g += 5_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(dave);
            try liquidator.liquidate{gas: g}(id) {
                ++landed;
                (,,,, uint128 bad) = ledger.ilkState(ETH);
                assertEq(bad, 0, "liquidated with the bad debt uncovered");
            } catch {}
            vm.revertToState(snap);
        }
        assertGt(landed, 0, "it does land with enough gas");
    }

    function test_liquidationWithoutBadDebtNeedsNoCoverGas() public {
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(dave, ETH, 200e18, 50_000e18, 0.05e18);
        ethMedian.set(1900e18);
        ethSpot.set(1900e18);
        vm.prank(dave);
        (,, uint256 bad) = liquidator.liquidate{gas: 1_000_000}(_pid(ETH, alice));
        assertEq(bad, 0);
    }

    function test_healthyCannotBeLiquidated() public {
        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        vm.expectRevert(Liquidator.Healthy.selector);
        liquidator.liquidate(_pid(ETH, alice));
    }

    function test_nhiGraceBeforeBite() public {
        // sIMD at $5, NHI 0.98 -> mat 170%, grace 6h
        _open(alice, SIMD, 1_000e18, 2_900e18, 0.05e18);
        _open(dave, ETH, 100e18, 50_000e18, 0.05e18);
        simdFeed.set(4e18);
        vm.prank(dave);
        liquidator.bark(_pid(SIMD, alice));
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(Liquidator.InGrace.selector, block.timestamp + 6 hours));
        liquidator.bite(_pid(SIMD, alice));
        vm.warp(block.timestamp + 6 hours);
        _refresh();
        vm.prank(dave);
        liquidator.bite(_pid(SIMD, alice));
        assertEq(ledger.debtOf(_pid(SIMD, alice)), 0);
    }

    /// @dev Beta: Parameters.maxLull caps the NHI grace. 0 = sIMD is bitten in the same call as the mark;
    /// the timelock restores the 6h schedule without a redeploy, and nothing above 6h is accepted.
    function test_maxLullCapsTheNhiGrace() public {
        assertEq(params.maxLull(), 6 hours, "default = v1 schedule");
        uint8 kind = params.SET_MAX_LULL(); // read before vm.prank: a getter call would consume the prank
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(kind, uint64(6 hours + 1)));
        vm.prank(governor);
        params.propose(abi.encode(kind, uint64(0)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _refresh();
        params.applyPending();
        assertEq(params.maxLull(), 0);
        assertEq(pricer.quote(SIMD).lull, 0, "no grace at NHI 0.98");

        _open(alice, SIMD, 1_000e18, 2_900e18, 0.05e18);
        _open(dave, ETH, 100e18, 50_000e18, 0.05e18);
        simdFeed.set(4e18);
        vm.prank(dave);
        liquidator.liquidate(_pid(SIMD, alice)); // mark + bite in one call
        assertEq(ledger.debtOf(_pid(SIMD, alice)), 0);

        vm.prank(governor);
        params.propose(abi.encode(kind, uint64(6 hours)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _refresh();
        params.applyPending();
        assertEq(pricer.quote(SIMD).lull, 6 hours, "grace restored by the timelock");
        nhi.set(0.725e18); // halfway down the schedule: 3h, under the cap
        assertEq(pricer.quote(SIMD).lull, 3 hours);

        vm.expectRevert(ParametersBase.Sealed.selector); // the genesis setter, after seal
        params.setGenesisMaxLull(0);
    }

    function test_genesisMaxLull() public {
        Parameters p = new Parameters(governor, address(this));
        vm.prank(alice);
        vm.expectRevert(ParametersBase.Unauthorized.selector);
        p.setGenesisMaxLull(0);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        p.setGenesisMaxLull(6 hours + 1);
        p.setGenesisMaxLull(0);
        assertEq(p.maxLull(), 0);
    }

    function test_staleNhiStopsEverything() public {
        _open(alice, SIMD, 1_000e18, 2_000e18, 0.05e18);
        nhi.setStale(true);
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(SIMD, 0, Adjust(0, 100e18, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.expectRevert(Liquidator.NotPriced.selector);
        liquidator.bark(_pid(SIMD, alice));
        // Repaying is always allowed.
        vm.prank(alice);
        ledger.open(SIMD, 0, Adjust(0, -100e18, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    // ------------------------------------------------------------ pricing

    function test_skewBlocksBorrowingLiquidatesOnMedian() public {
        _open(alice, ETH, 10e18, 14_000e18, 0.05e18);
        _open(dave, ETH, 100e18, 20_000e18, 0.05e18);
        // Spot drops 10% (> 5% skew), median holds: borrowing stops...
        ethSpot.set(1800e18);
        vm.prank(dave);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(ETH, 0, Adjust(0, 1e18, 0, 0, 0, false, type(uint256).max, address(0)));
        // ...and Alice is measured on the median ($2000, 142.8%), so she cannot be liquidated by the spot.
        vm.expectRevert(Liquidator.Healthy.selector);
        liquidator.liquidate(_pid(ETH, alice));
    }

    function test_depegBlocksBorrowing() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 5_000e18, 0.02e18, 0, 0, true, type(uint256).max, address(0)));
        usdcPeg.set(0.97e8);
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(SUSDC, 0, Adjust(0, 10e18, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    // ------------------------------------------------------------ yield

    function test_stakeOnDepositAndWithdrawAsset() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 5_000e18, 0.02e18, 0, 0, true, type(uint256).max, address(0)));
        // 10,000 USDC staked for her: the join holds vault shares, not USDC.
        assertEq(usdc.balanceOf(address(vaultJoin)), 0);
        assertEq(vault.balanceOf(address(vaultJoin)), ledger.position(_pid(SUSDC, alice)).collateral);
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(-1_000e6, 0, 0, 0, 0, true, type(uint256).max, address(0)));
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6 + 1_000e6);
    }

    function test_yieldRepaysDebtWithFee() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 5_000e18, 0.02e18, 0, 0, true, type(uint256).max, address(0)));
        uint256 shares = ledger.position(_pid(SUSDC, alice)).collateral;
        // +5% yield, over 6 days (inside the 1%/day cap).
        vault.accrue(500e6 + 50);
        vm.warp(block.timestamp + 6 days);
        _refresh();
        uint256[] memory owners = new uint256[](1);
        owners[0] = _pid(SUSDC, alice);
        uint256 debtBefore = ledger.debtOf(_pid(SUSDC, alice));
        ledger.harvest(SUSDC, owners);
        uint256 debtAfter = ledger.debtOf(_pid(SUSDC, alice));
        // ~$500 of yield, 10% fee: ~$450 off the debt.
        assertApproxEqRel(debtBefore - debtAfter, 450e18, 0.001e18);
        assertApproxEqRel(ledger.reserveBacked(), 450e18, 0.001e18);
        // The Treasury holds the yield shares; Alice's collateral is still worth ~$10,000.
        uint256 taken = shares - ledger.position(_pid(SUSDC, alice)).collateral;
        assertEq(vault.balanceOf(address(treasury)), taken);
        assertApproxEqRel(vault.convertToAssets(ledger.position(_pid(SUSDC, alice)).collateral), 10_000e6, 0.001e18);
        _assertSupply();
        // The Treasury retires reserve-backed supply with imdUSD it holds (interest it earned).
        vm.prank(dave);
        ledger.open(ETH, 0, Adjust(10e18, 1_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.prank(dave);
        usd.transfer(address(treasury), 100e18);
        uint256 reserveBefore = ledger.reserveBacked();
        treasury.retireReserve(100e18);
        assertEq(ledger.reserveBacked(), reserveBefore - 100e18);
        _assertSupply();
    }

    function test_donationIsCapped() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 5_000e18, 0.02e18, 0, 0, true, type(uint256).max, address(0)));
        // A 50% donation lands; one day later the feed admits at most ~1%.
        vault.accrue(5_000e6);
        vm.warp(block.timestamp + 1 days);
        _refresh();
        (uint256 live,) = vaultRate.liveRate();
        assertGt(live, 1.4e18);
        assertApproxEqRel(vaultRate.rate(), 1.01e18, 0.001e18);
        uint256[] memory owners = new uint256[](1);
        owners[0] = _pid(SUSDC, alice);
        uint256 before = ledger.debtOf(_pid(SUSDC, alice));
        ledger.harvest(SUSDC, owners);
        assertLt(before - ledger.debtOf(_pid(SUSDC, alice)), 95e18); // ~1% of $10k less fee, not $4,500
    }

    function test_lossIsNotHarvested() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 5_000e18, 0.02e18, 0, 0, true, type(uint256).max, address(0)));
        vault.lose(1_000e6);
        vm.warp(block.timestamp + 1 days);
        _refresh();
        uint256[] memory owners = new uint256[](1);
        owners[0] = _pid(SUSDC, alice);
        uint256 before = ledger.debtOf(_pid(SUSDC, alice));
        ledger.harvest(SUSDC, owners);
        assertEq(ledger.debtOf(_pid(SUSDC, alice)), before);
        // Recovering back to the old mark charges nothing either.
        vault.accrue(1_000e6);
        vm.warp(block.timestamp + 1 days);
        _refresh();
        ledger.harvest(SUSDC, owners);
        assertApproxEqAbs(ledger.debtOf(_pid(SUSDC, alice)), before, 1e15);
    }

    function test_zeroDebtKeepsItsYield() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 0, 0, 0, 0, true, type(uint256).max, address(0)));
        vault.accrue(500e6);
        vm.warp(block.timestamp + 6 days);
        _refresh();
        // Borrowing now must not harvest the yield earned while she owed nothing.
        uint256 fee = _uf(SUSDC, 1_000e18, 0.02e18);
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(0, 1_000e18, 0.02e18, 0, 0, false, type(uint256).max, address(0)));
        assertEq(ledger.debtOf(_pid(SUSDC, alice)), 1_000e18 + fee);
        assertEq(vault.balanceOf(address(treasury)), 0);
    }

    // ------------------------------------------------------------ migrator, token

    function test_migrator() public {
        v1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        v1.approve(address(migrator), type(uint256).max);
        migrator.toV2(1_000e18);
        assertEq(usd.balanceOf(alice), 1_000e18);
        migrator.toV1(400e18);
        vm.stopPrank();
        assertEq(v1.balanceOf(alice), 400e18);
        assertEq(migrator.outstanding(), 600e18);
        _assertSupply();
    }

    function test_eip3009Transfer() public {
        (address signer, uint256 key) = makeAddrAndKey("payer");
        deal(address(usd), signer, 100e18, true);
        bytes32 nonce = keccak256("x402-1");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usd.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        usd.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), signer, bob, 25e18, 0, block.timestamp + 1 hours, nonce
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.prank(carol); // any relayer (an x402 facilitator) may submit it
        usd.transferWithAuthorization(signer, bob, 25e18, 0, block.timestamp + 1 hours, nonce, v, r, s);
        assertEq(usd.balanceOf(bob), 25e18);
        vm.expectRevert(ImdUSD.AuthorizationAlreadyUsed.selector);
        usd.transferWithAuthorization(signer, bob, 25e18, 0, block.timestamp + 1 hours, nonce, v, r, s);
    }

    function test_flashMintIsFree() public {
        FlashTaker taker = new FlashTaker();
        usd.flashLoan(taker, address(usd), 1_000_000e18, "");
        assertEq(usd.totalSupply(), 0);
        assertEq(usd.flashFee(address(usd), 1e18), 0);
    }

    function test_onlyMintersMint() public {
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        usd.mint(alice, 1);
        vm.expectRevert(ImdUSD.AlreadySet.selector);
        usd.wire(address(ledger), address(migrator), address(params));
    }

    // ------------------------------------------------------------ governance

    function test_governanceBoundsAndTimelock() public {
        ParametersBase.Risk memory r = params.risk(ETH);
        r.chop = 0.3e18;
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(1), ETH, r));

        r.chop = 0.12e18;
        r.mat = 1.5e18;
        vm.prank(governor);
        params.propose(abi.encode(uint8(1), ETH, r));
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, block.timestamp + 48 hours));
        params.applyPending();
        vm.warp(block.timestamp + 48 hours);
        params.applyPending(); // anyone
        assertEq(params.risk(ETH).mat, 1.5e18);

        vm.expectRevert(Governed.NotGovernor.selector);
        params.propose(abi.encode(uint8(1), ETH, r));
        ParametersBase.Config memory c = params.config(ETH);
        vm.expectRevert(ParametersBase.Sealed.selector); // the deployer, after seal
        params.addGenesisIlk(bytes32("X"), c, r);
        vm.prank(alice);
        vm.expectRevert(ParametersBase.Unauthorized.selector);
        params.addGenesisIlk(bytes32("X"), c, r);
    }

    // ------------------------------------------------------------ regressions

    /// Yield that pays a debt off entirely must take the position out of the redemption order, and
    /// borrowing again must put it back (found by the invariant suite: it stayed listed with no debt).
    function test_yieldPaysOffDebtThenBorrowAgain() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 100e18, 0.02e18, 0, 0, true, type(uint256).max, address(0)));
        assertTrue(sorted.contains(SUSDC, _pid(SUSDC, alice)));
        vault.accrue(500e6);
        vm.warp(block.timestamp + 6 days);
        _refresh();
        // Any touch harvests: a deposit pays the 100 debt off from ~$450 of net yield.
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(1e6, 0, 0, 0, 0, true, type(uint256).max, address(0)));
        assertEq(ledger.debtOf(_pid(SUSDC, alice)), 0);
        assertFalse(sorted.contains(SUSDC, _pid(SUSDC, alice)));
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(0, 500e18, 0.03e18, 0, 0, false, type(uint256).max, address(0)));
        assertTrue(sorted.contains(SUSDC, _pid(SUSDC, alice)));
        assertEq(sorted.rateOf(SUSDC, _pid(SUSDC, alice)), 0.03e18);
        _assertSupply();
    }

    /// A redemption that skips a position must still record that position's harvest. Alice (lowest rate)
    /// is harvested down to a dust-sized debt, so the redemption skips her and takes Bob instead; before
    /// the fix her harvest moved the type's debt but not her recorded debt.
    function test_skippedRedemptionStillRecordsHarvest() public {
        vm.prank(alice);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 102e18, 0.02e18, 0, 0, true, type(uint256).max, address(0))); // dust is 100
        vm.prank(bob);
        ledger.open(SUSDC, 0, Adjust(10_000e6, 5_000e18, 0.05e18, 0, 0, true, type(uint256).max, address(0)));
        vault.accrue(10e6); // ~$5 of yield each before fee: Alice's debt falls to ~97.5, under dust
        vm.warp(block.timestamp + 1 days);
        _refresh();
        vm.prank(bob);
        usd.transfer(carol, 50e18);
        vm.prank(carol);
        (uint256 redeemed,) = redeemer.redeem(SUSDC, 50e18, 0.05e18, 5, 0);
        assertEq(redeemed, 50e18);
        assertLt(ledger.debtOf(_pid(SUSDC, alice)), 100e18); // her harvest landed in her recorded debt
        (uint128 d,,,,) = ledger.ilkState(SUSDC);
        assertGe(d, ledger.debtOf(_pid(SUSDC, alice)) + ledger.debtOf(_pid(SUSDC, bob)));
        _assertSupply();
    }

    // ------------------------------------------------------------ gas audit: a quote only where something reads it

    function test_gas_depositOnAPlainTypeQuotesNothing() public {
        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        vm.expectCall(address(pricer), abi.encodeWithSelector(Pricer.quote.selector, ETH), 0);
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(1e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    function test_gas_repayOnAPlainTypeQuotesNothing() public {
        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        vm.expectCall(address(pricer), abi.encodeWithSelector(Pricer.quote.selector, ETH), 0);
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(0, -1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    function test_gas_withdrawStillNeedsAPrice() public {
        _open(alice, ETH, 10e18, 10_000e18, 0.05e18);
        vm.warp(vm.getBlockTimestamp() + 30 days); // every feed stale
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(ETH, 0, Adjust(-1e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    /// One feed in both slots reads once and prices as two identical legs; stale, it prices nothing.
    function test_gas_oneFeedInBothSlots() public {
        Pricer.Quote memory q = pricer.quote(SUSDC);
        assertTrue(q.priced && q.agree);
        assertEq(q.low, q.high);
        assertEq(q.payout, q.high);
        (uint256 m,) = vaultRate.latestValue();
        assertEq(q.low, m);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertFalse(pricer.quote(SUSDC).priced);
    }
}
