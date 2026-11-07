// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Governed} from "../../src/Governed.sol";
import {SavingsVault} from "../../src/SavingsVault.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";

import {Shield} from "../utils/Shield.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";
/// @notice sImdUSD: the savers' share of interest, streamed over 7 days.
contract SavingsTest is System {
    bytes32 constant ETH = "ETH";

    MockERC20 weth;
    MockFeed ethFeed;
    SavingsVault savings;

    address alice = makeAddr("alice"); // borrower whose interest pays savers
    address bob = makeAddr("bob"); // saver
    address eve = makeAddr("eve"); // attacker

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        ethFeed = new MockFeed(2000e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        savings = new SavingsVault(IERC20(address(usd)));
        params.setGenesisSavings(address(savings), 0.5e18);
        params.seal();

        address[3] memory us = [alice, bob, eve];
        for (uint256 i; i < 3; ++i) {
            weth.mint(us[i], 10_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usd.approve(address(savings), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    /// Borrow real imdUSD so the supply equation keeps holding (no `deal`).
    function _borrow(address u, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ETH, rate);
        vm.prank(u);
        ledger.open(ETH, 0, Adjust(int256(debt * 2 / 2000), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _save(address u, uint256 amount) internal returns (uint256 shares) {
        vm.prank(u);
        shares = savings.deposit(amount, u);
    }

    function _wait(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        ethFeed.set(ethFeed.value());
    }

    function _assertSupply() internal {
        ledger.accrue(ETH);
        (uint128 d,,,, uint128 bad) = ledger.ilkState(ETH);
        assertEq(usd.totalSupply(), uint256(d) + bad + ledger.reserveBacked() + migrator.outstanding(), "supply equation");
    }

    // ------------------------------------------------------------ split

    /// @dev A year of interest on ETH, measured from now (so the opening upfront fees, F1, are excluded), and how it split.
    function _yearSplit() internal returns (uint256 interest, uint256 toSavers, uint256 toTreasury, uint256 supply) {
        uint256 s0 = usd.balanceOf(address(savings));
        uint256 t0 = usd.balanceOf(address(treasury));
        (uint128 d0,,,,) = ledger.ilkState(ETH);
        _wait(365 days);
        supply = usd.totalSupply(); // what the Ledger divides by at the accrual
        ledger.accrue(ETH);
        (uint128 d1,,,,) = ledger.ilkState(ETH);
        interest = uint256(d1) - d0;
        toSavers = usd.balanceOf(address(savings)) - s0;
        toTreasury = usd.balanceOf(address(treasury)) - t0;
        assertApproxEqAbs(toSavers + toTreasury, interest, 2, "the split sums to the interest");
    }

    function test_halfOfInterestToSavers() public {
        // Savers hold 60% of supply: uptake is above the 50% share, so the share paid is capped at 50%.
        _borrow(bob, 60_000e18, 0.05e18);
        _save(bob, 60_000e18);
        _borrow(alice, 40_000e18, 0.10e18);
        (uint256 interest, uint256 toS, uint256 toT,) = _yearSplit();
        // Interest over the year: ~40,000 x 10% + 60,000 x 5% = 7,000 (+ interest on the upfront fees); half each side.
        assertApproxEqRel(interest, 7_000e18, 0.005e18);
        assertApproxEqAbs(toS, interest / 2, 2);
        assertApproxEqAbs(toT, interest - interest / 2, 2);
        _assertSupply();
    }

    /// C6: a tiny vault gets the 5% floor, not the governed 50%.
    function test_tinyVaultGetsTheFloor() public {
        _borrow(bob, 1_000e18, 0.05e18);
        _save(bob, 1_000e18);
        _borrow(alice, 100_000e18, 0.10e18);
        (uint256 interest, uint256 toS,,) = _yearSplit();
        // Uptake ~1,000 / 101,000 < 5%: 5% of the interest to savers, the rest to the Treasury.
        assertApproxEqRel(interest, 10_050e18, 0.005e18);
        assertApproxEqAbs(toS, interest * 5 / 100, 2);
        _assertSupply();
    }

    /// C6: between the floor and the cap the share paid equals savings / supply.
    function test_shareScalesWithUptake() public {
        _borrow(bob, 20_000e18, 0.05e18);
        _save(bob, 20_000e18);
        _borrow(alice, 80_000e18, 0.10e18);
        (uint256 interest, uint256 toS,, uint256 supply) = _yearSplit();
        // Uptake 20,000 / ~100,000 = ~20% (the upfront fees add a little supply).
        uint256 eff = uint256(20_000e18) * 1e18 / supply;
        assertApproxEqRel(eff, 0.2e18, 0.005e18);
        assertApproxEqAbs(toS, interest * eff / 1e18, 2);
        _assertSupply();
    }

    function test_noSaversAllToTreasury() public {
        _borrow(alice, 100_000e18, 0.10e18);
        (uint256 interest,, uint256 toT,) = _yearSplit();
        assertEq(usd.balanceOf(address(savings)), 0);
        assertEq(toT, interest);
        assertApproxEqRel(interest, 10_000e18, 0.005e18);
    }

    function test_rateCooldownPremiumIsSplitToo() public {
        _borrow(bob, 60_000e18, 0.05e18);
        _save(bob, 60_000e18); // uptake 60%: the share paid is the full 50%
        _wait(1); // a deposit counts as uptake from the next block
        _borrow(alice, 40_000e18, 0.10e18);
        uint256 d = ledger.debtOf(_pid(ETH, alice)); // 40,000 + its upfront fee
        uint256 s0 = usd.balanceOf(address(savings));
        uint256 t0 = usd.balanceOf(address(treasury));
        vm.prank(alice);
        ledger.setRate(_pid(ETH, alice), 0.02e18, 0, 0);
        // Premium = debt x 10% x 7/365 (~76.7); half to savers.
        uint256 premium = (d * 0.10e18 * 7 days + 365 days * 1e18 - 1) / (365 days * 1e18);
        assertApproxEqAbs(usd.balanceOf(address(savings)) - s0, premium / 2, 2);
        assertApproxEqAbs(usd.balanceOf(address(treasury)) - t0, premium - premium / 2, 2);
        _assertSupply();
    }

    // ------------------------------------------------------------ smoothing

    function test_interestVestsLinearlyOverSevenDays() public {
        _borrow(bob, 1_000e18, 0.05e18);
        _save(bob, 1_000e18);
        _borrow(alice, 100_000e18, 0.10e18);
        _wait(365 days);
        ledger.accrue(ETH);
        uint256 arrived = usd.balanceOf(address(savings)) - 1_000e18;
        // Nothing counts at once.
        assertApproxEqAbs(savings.totalAssets(), 1_000e18, 1);
        savings.sync();
        assertApproxEqAbs(savings.totalAssets(), 1_000e18, 1, "sync does not move the price");
        _wait(3.5 days);
        assertApproxEqAbs(savings.totalAssets(), 1_000e18 + arrived / 2, 1e12);
        _wait(3.5 days);
        assertApproxEqAbs(savings.totalAssets(), 1_000e18 + arrived, 1);
        assertApproxEqAbs(savings.maxWithdraw(bob), 1_000e18 + arrived, 1e6);
    }

    function test_newArrivalBlendsIntoTheRunningStream() public {
        _borrow(bob, 2_100e18, 0.05e18);
        _save(bob, 1_000e18);
        vm.prank(bob);
        usd.transfer(address(savings), 700e18); // first arrival: 700 over 7 days
        savings.sync();
        assertEq(savings.streamEnd(), block.timestamp + 7 days);
        _wait(3.5 days); // 350 vested, 350 left with 3.5 days to go
        vm.prank(bob);
        usd.transfer(address(savings), 350e18); // second: 350 over 7 days
        savings.sync();
        // Value-weighted end: (350 x 3.5d + 350 x 7d) / 700 = 5.25 days from now.
        assertApproxEqAbs(savings.streamEnd(), block.timestamp + 5.25 days, 1);
        assertApproxEqAbs(savings.totalAssets(), 1_350e18, 1e12);
        _wait(5.25 days);
        assertApproxEqAbs(savings.totalAssets(), 2_050e18, 1);
    }

    /// Deposit just before a large accrual, withdraw just after: the attacker earns only what vests while
    /// they are in, which over one block is nothing.
    function test_sandwichAroundAccrualEarnsNothing() public {
        _borrow(bob, 1_000e18, 0.05e18);
        _save(bob, 1_000e18);
        _borrow(alice, 1_000_000e18, 0.10e18);
        _borrow(eve, 2_000_000e18, 0.01e18);
        _wait(365 days);
        // Front-run the accrual with 2M (2,000x Bob's stake).
        uint256 shares = _save(eve, 2_000_000e18);
        ledger.accrue(ETH); // ~51,000 to savers
        uint256 arrived = usd.balanceOf(address(savings)) - 1_000e18 - 2_000_000e18;
        vm.warp(block.timestamp + 12);
        ethFeed.set(ethFeed.value());
        vm.prank(eve);
        uint256 out = savings.redeem(shares, eve, eve);
        // In 12 s, 12/604800 of the stream vests; eve's share of that is all she can get.
        uint256 vestedIn12s = arrived * 12 / 7 days;
        assertLe(out, 2_000_000e18 + vestedIn12s + 1, "attacker took more than one block's vesting");
        assertLt(out - 2_000_000e18, arrived / 10_000, "less than 0.01% of the accrual");
        // Bob keeps the rest once the stream ends.
        _wait(7 days);
        assertGt(savings.maxWithdraw(bob), 1_000e18 + arrived * 99 / 100);
        _assertSupply();
    }

    /// The classic first-depositor attack: 1 wei of shares, then a donation to inflate the price so the
    /// victim's deposit rounds to zero shares. The donation only streams, and virtual shares absorb it.
    function test_donationCannotInflateSharePrice() public {
        _borrow(eve, 20_000e18, 0.05e18);
        _borrow(bob, 1_000e18, 0.05e18);
        vm.prank(eve);
        savings.deposit(1, eve);
        vm.prank(eve);
        usd.transfer(address(savings), 10_000e18);
        uint256 shares = _save(bob, 1_000e18);
        assertGt(shares, 0);
        assertApproxEqAbs(savings.previewRedeem(shares), 1_000e18, 1, "victim's deposit is whole at once");
        // Even after the donation fully vests, the victim keeps at least their deposit, and the
        // attacker recovers almost none of the 10,000 they gave away.
        _wait(8 days);
        assertGe(savings.previewRedeem(shares), 1_000e18);
        assertLt(savings.previewRedeem(savings.balanceOf(eve)), 1e18);
    }

    function test_donationBeforeAnyDepositDoesNotBreakFirstDeposit() public {
        _borrow(eve, 20_000e18, 0.05e18);
        _borrow(bob, 1_000e18, 0.05e18);
        vm.prank(eve);
        usd.transfer(address(savings), 10_000e18);
        _wait(8 days);
        uint256 shares = _save(bob, 1_000e18);
        assertGe(savings.previewRedeem(shares), 1_000e18 - 1);
    }

    // ------------------------------------------------------------ governance

    function _setShare(uint64 share) internal {
        vm.prank(governor);
        params.propose(abi.encode(uint8(5), share));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
    }

    function test_savingsShareBoundsAndTimelock() public {
        assertEq(params.MAX_SAVINGS_SHARE(), 0.5e18);
        // Bound 50%: the genesis value is 50%, so a raise is out of bounds.
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(5), uint64(0.51e18)));
        // At most 10 points per change: 50% -> 39% refused, 50% -> 40% accepted (through the 48h timelock).
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(5), uint64(0.39e18)));
        vm.prank(governor);
        params.propose(abi.encode(uint8(5), uint64(0.4e18)));
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, block.timestamp + 48 hours));
        params.applyPending();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        assertEq(params.savingsShare(), 0.4e18);
        // Upward too: 40% -> 50.01% refused (step and bound), back to 50% accepted.
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(5), uint64(0.5001e18)));
        _setShare(0.5e18);
        assertEq(params.savingsShare(), 0.5e18);

        // Zero switches the savings rate off, reached 10 points at a time: everything to the Treasury again.
        _setShare(0.4e18);
        _setShare(0.3e18);
        _setShare(0.2e18);
        _setShare(0.1e18);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(5), uint64(0.21e18))); // +11 points from 10%
        _setShare(0);
        assertEq(params.savingsShare(), 0);
        ethFeed.set(ethFeed.value());
        _borrow(bob, 1_000e18, 0.05e18);
        _save(bob, 1_000e18);
        _borrow(alice, 100_000e18, 0.10e18);
        _wait(365 days);
        ledger.accrue(ETH);
        assertEq(usd.balanceOf(address(savings)), 1_000e18);

        // The vault itself is fixed at genesis.
        vm.expectRevert(ParametersBase.Sealed.selector);
        params.setGenesisSavings(address(savings), 0.5e18);
        vm.expectRevert(Governed.NotGovernor.selector);
        params.propose(abi.encode(uint8(5), uint64(0.1e18)));
    }

    function test_genesisSavingsChecks() public {
        Parameters p = new Parameters(governor, address(this));
        // Not wired to a token yet.
        vm.expectRevert(ParametersBase.BadConfig.selector);
        p.setGenesisSavings(address(savings), 0.5e18);
        p.wire(address(ledger), address(usd));
        vm.prank(alice);
        vm.expectRevert(ParametersBase.Unauthorized.selector);
        p.setGenesisSavings(address(savings), 0.5e18);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        p.setGenesisSavings(address(savings), 0.51e18); // bound 50%
        // A vault over a different asset.
        SavingsVault wrong = new SavingsVault(IERC20(address(weth)));
        vm.expectRevert(ParametersBase.BadConfig.selector);
        p.setGenesisSavings(address(wrong), 0.5e18);
        p.setGenesisSavings(address(savings), 0.5e18); // 0 -> 50%: the genesis start value is exempt from the 10-point step
        (address v, uint256 s) = p.savingsSplit();
        assertEq(v, address(savings));
        assertEq(s, 0.5e18);
    }

    // ------------------------------------------------------------ shares can be shielded

    /// sImdUSD minted in a transaction can be pulled by a shielded pool, paid out and redeemed in the same block.
    function test_sharesShieldInTheBlockTheyAreMinted() public {
        _borrow(bob, 10_000e18, 0.05e18);
        uint256 shares = _save(bob, 10_000e18);
        Shield pool = new Shield();
        vm.startPrank(bob);
        savings.approve(address(pool), shares);
        pool.shield(IERC20(address(savings)), shares);
        vm.stopPrank();
        pool.unshield(IERC20(address(savings)), eve, shares);
        vm.prank(eve);
        uint256 out = savings.redeem(shares, eve, eve);
        assertApproxEqAbs(out, 10_000e18, 1);
    }
}
