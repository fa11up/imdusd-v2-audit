// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {System} from "../../utils/System.sol";
import {MockERC20, MockFeed} from "../../utils/Mocks.sol";
import {ParametersBase} from "../../../src/ParametersBase.sol";
import {ParametersRules} from "../../../src/ParametersRules.sol";
import {GovernedByKind} from "../../../src/GovernedByKind.sol";
import {LedgerBase} from "../../../src/LedgerBase.sol";
import {LedgerSettlement} from "../../../src/LedgerSettlement.sol";
import {Redeemer} from "../../../src/Redeemer.sol";
import {IFeed} from "../../../src/interfaces/IFeed.sol";
import {Adjust} from "../../../src/interfaces/IPositions.sol";

/// @notice A collateral token with a sender hook (ERC777 tokensToSend-style): calls the sender before moving funds.
contract HookToken is ERC20 {
    constructor() ERC20("HOOK", "HOOK") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function transferFrom(address from, address to, uint256 a) public override returns (bool) {
        if (from.code.length != 0) IHookReceiver(from).tokensToSend();
        return super.transferFrom(from, to, a);
    }
}

interface IHookReceiver {
    function tokensToSend() external;
}

interface ILedgerLike {
    function addFor(uint256 id, uint256 amount, bool viaAsset) external;
}

/// @notice Adds 1 wei of collateral to a victim's position and, inside the token's sender hook (i.e. inside the Ledger's
/// lock), redeems that same position through the Redeemer: LedgerSettlement.redeemPosition takes no lock.
contract Griefer is IHookReceiver {
    ILedgerLike ledger;
    Redeemer redeemer;
    bytes32 ilk;
    uint256 amount;
    bool armed;

    constructor(ILedgerLike l, Redeemer r, bytes32 i, IERC20 hook, IERC20 usd) {
        (ledger, redeemer, ilk) = (l, r, i);
        hook.approve(address(l), type(uint256).max);
        usd.approve(address(r), type(uint256).max);
    }

    function attack(uint256 victim, uint256 redeemAmount) external {
        amount = redeemAmount;
        armed = true;
        ledger.addFor(victim, 1, false);
    }

    function tokensToSend() external {
        if (!armed) return;
        armed = false;
        redeemer.redeem(ilk, amount, 0.05e18, 1, 0);
    }
}

interface ILiquidatorLike {
    function liquidate(uint256 id) external returns (uint256, uint256, uint256);
}

/// @notice As Griefer, but liquidates the victim inside the hook: the victim's debt comes back after the liquidation paid it.
contract LiqGriefer is IHookReceiver {
    ILedgerLike ledger;
    ILiquidatorLike liq;
    uint256 victim;
    bool armed;

    constructor(ILedgerLike l, ILiquidatorLike q, IERC20 hook) {
        (ledger, liq) = (l, q);
        hook.approve(address(l), type(uint256).max);
    }

    function attack(uint256 v) external {
        victim = v;
        armed = true;
        ledger.addFor(v, 1, false);
    }

    function tokensToSend() external {
        if (!armed) return;
        armed = false;
        liq.liquidate(victim);
    }

    function liquidateAgain(uint256 v) external {
        liq.liquidate(v);
    }
}

contract PanelSplitsRegressionTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant HK = "HOOK";
    bytes32 constant HK2 = "HOOK2"; // same, not redeemable
    HookToken hook2;
    MockERC20 weth;
    HookToken hook;
    MockFeed ethFeed;
    MockFeed hookFeed;
    address victim = makeAddr("victim");
    address whale = makeAddr("whale");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        hook = new HookToken();
        ethFeed = new MockFeed(2000e18);
        hookFeed = new MockFeed(1e18);
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 100_000_000e18));
        _addIlk(HK, address(hook), hookFeed, hookFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 100_000_000e18));
        hook2 = new HookToken();
        _addIlk(HK2, address(hook2), hookFeed, hookFeed, IFeed(address(0)), address(0), address(0), false, _risk(1.4e18, 100_000_000e18));
        params.seal();
    }

    // ------------------------------------------------------------ wiring of the two modules

    function test_settlementImmutablesEqualLedgers() public view {
        LedgerSettlement s = LedgerSettlement(ledger.settlement());
        assertEq(s.ledger(), address(ledger));
        assertEq(address(s.token()), address(ledger.token()));
        assertEq(address(s.params()), address(ledger.params()));
        assertEq(address(s.pricer()), address(ledger.pricer()));
        assertEq(s.treasury(), ledger.treasury());
        assertEq(s.wirer(), ledger.wirer());
        assertEq(address(s.pulse()), address(ledger.pulse()));
        assertEq(address(s.sorted()), address(ledger.sorted()));
        assertEq(address(s.nft()), address(ledger.nft()));
        assertEq(address(ledger.sorted()).code.length > 0, true);
    }

    function test_rulesImmutables() public view {
        ParametersRules r = params.rules();
        assertEq(r.governor(), params.governor());
        assertEq(r.wirer(), address(1)); // never read on a delegated path (grep: wirer only in Parameters' genesis setters)
    }

    function test_directCallsRevert() public {
        LedgerSettlement s = LedgerSettlement(ledger.settlement());
        vm.expectRevert(LedgerSettlement.DirectCall.selector);
        s.redeemPosition(1, 1, 1, 0, address(this));
        vm.expectRevert(LedgerSettlement.DirectCall.selector);
        s.liquidatePosition(1, 1, address(this), address(this), false);
        vm.expectRevert(LedgerSettlement.DirectCall.selector);
        s.writeOff(1);
        ParametersRules r = params.rules();
        vm.expectRevert(ParametersRules.NotDelegated.selector);
        r.validateKind(abi.encode(uint8(3), uint256(1)));
        vm.expectRevert(ParametersRules.NotDelegated.selector);
        r.applyKind(abi.encode(uint8(3), uint256(1)));
    }

    /// The governor can drive the module's OWN inherited propose/apply (on the module's storage): nothing reaches Parameters.
    function test_rulesOwnGovernanceIsIsolated() public {
        ParametersRules r = params.rules();
        vm.prank(governor);
        r.propose(abi.encode(uint8(3), uint256(777))); // SET_MIGRATOR_LINE
        vm.warp(block.timestamp + 48 hours);
        r.applyPending(3);
        assertEq(r.migratorLine(), 777);
        assertEq(params.migratorLine(), 0);
        assertEq(params.pendingKinds(), 0);
    }

    function test_revertBubblesAndReturnData() public {
        vm.expectRevert(LedgerBase.Unauthorized.selector);
        ledger.redeemPosition(1, 1, 1, 0, address(this));
        vm.expectRevert(LedgerBase.Unauthorized.selector);
        ledger.liquidatePosition(1, 1, address(this), address(this), false);
        vm.expectRevert(LedgerBase.UnknownPosition.selector);
        ledger.writeOff(1);
        // value is refused by the Ledger's non-payable dispatcher
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(ledger).call{value: 1}(abi.encodeCall(ledger.writeOff, (1)));
        assertFalse(ok);
        // Parameters: a validate failure bubbles the module's error unchanged
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(19), uint64(1e18))); // SET_UNBACKED_BRAKE above MAX
        vm.prank(governor);
        vm.expectRevert(ParametersBase.UnknownKind.selector);
        params.propose(abi.encode(uint8(99)));
    }

    /// Return data of the redeem path reaches the Redeemer intact (redeemed == debt change).
    function test_redeemReturnData() public {
        _open(victim, ETH, 100e18, 50_000e18, 0.02e18);
        _open(whale, ETH, 1_000e18, 500_000e18, 0.05e18);
        uint256 before = ledger.debtOf(_id(ETH, victim));
        vm.prank(whale);
        (uint256 red, uint256 out) = redeemer.redeem(ETH, 10_000e18, 0.05e18, 1, 0);
        assertEq(red, 10_000e18);
        assertEq(before - ledger.debtOf(_id(ETH, victim)), red);
        assertGt(out, 0);
        assertEq(weth.balanceOf(whale), 1_000_000e18 - 1_000e18 + out);
    }

    /// The settlement module's writeOff takes the Ledger's transient lock (shared slot via delegatecall); redeem/liquidate do not.
    /// LOW: through a collateral token that calls its sender (ERC777-style), `addFor` on a VICTIM's position re-enters
    /// Redeemer -> Ledger.redeemPosition on the same position; `_adjust` then writes its stale local debt back, so the victim
    /// keeps the full debt while having given up the redeemed collateral, and the type's recorded debt falls below Σ positions.
    function test_S1_reentrantRedeemReverts() public {
        hook.mint(victim, 1_000_000e18);
        vm.prank(victim);
        hook.approve(address(ledger), type(uint256).max);
        _open(victim, HK, 200_000e18, 100_000e18, 0.02e18);
        // attacker gets imdUSD elsewhere (ETH position)
        _open(whale, ETH, 1_000e18, 500_000e18, 0.05e18);
        // a second borrower in the type, at a higher rate (the victim is first in the redemption order)
        address other = makeAddr("other");
        hook.mint(other, 1_000_000e18);
        vm.prank(other);
        hook.approve(address(ledger), type(uint256).max);
        _open(other, HK, 300_000e18, 150_000e18, 0.1e18);
        Griefer g = new Griefer(ILedgerLike(address(ledger)), redeemer, HK, IERC20(address(hook)), IERC20(address(usd)));
        hook.mint(address(g), 1);
        vm.prank(whale);
        usd.transfer(address(g), 50_000e18);

        uint256 id = _id(HK, victim);
        uint256 debtBefore = ledger.debtOf(id);
        uint256 collBefore = ledger.position(id).collateral;
        (uint128 ilkDebtBefore,,,,) = ledger.ilkState(HK);

        vm.expectRevert(); // fixed: the re-entry hits the Ledger lock
        g.attack(id, 50_000e18);
        return;

        uint256 debtAfter = ledger.debtOf(id);
        uint256 collAfter = ledger.position(id).collateral;
        (uint128 ilkDebtAfter,,,,) = ledger.ilkState(HK);
        emit log_named_decimal_uint("victim debt before", debtBefore, 18);
        emit log_named_decimal_uint("victim debt after ", debtAfter, 18);
        emit log_named_decimal_uint("victim coll before", collBefore, 18);
        emit log_named_decimal_uint("victim coll after ", collAfter, 18);
        emit log_named_decimal_uint("ilk debt before   ", ilkDebtBefore, 18);
        emit log_named_decimal_uint("ilk debt after    ", ilkDebtAfter, 18);
        assertEq(debtAfter, debtBefore, "victim debt restored by _adjust's stale write");
        assertLt(collAfter + 49_000e18, collBefore, "victim lost ~50k of collateral to the redemption");
        uint256 sumPositions = debtAfter + ledger.debtOf(_id(HK, other));
        emit log_named_decimal_uint("sum of positions  ", sumPositions, 18);
        assertApproxEqAbs(sumPositions - uint256(ilkDebtAfter), 50_000e18, 1e18, "type debt 50k below the sum of its positions");
        // The other borrower repays in full first; the victim's full repayment then underflows s.debt.
        vm.startPrank(whale);
        usd.transfer(other, 160_000e18);
        vm.stopPrank();
        vm.startPrank(other);
        ledger.adjust(_id(HK, other), Adjust(0, -int256(ledger.debtOf(_id(HK, other))), 0, 0, 0, false, 0, address(0)));
        vm.stopPrank();
        // The victim cannot fully repay any more: s.debt underflows.
        (uint128 ilkDebtLeft,,,,) = ledger.ilkState(HK);
        emit log_named_decimal_uint("ilk debt left     ", ilkDebtLeft, 18);
        emit log_named_decimal_uint("victim still owes ", ledger.debtOf(id), 18);
        vm.prank(whale);
        usd.transfer(victim, 100_000e18);
        int256 owed = int256(ledger.debtOf(id));
        vm.startPrank(victim);
        vm.expectRevert(); // panic 0x11: s.debt -= amount
        ledger.adjust(id, Adjust(0, -owed, 0, 0, 0, false, 0, address(0)));
        vm.stopPrank();
    }

    /// Same hole through the Liquidator (on a NON-redeemable type: on a redeemable one `_relist` reverts NotListed): after the hooked liquidation the victim's full debt is written back (at rate 0) on a
    /// position with almost no collateral; liquidating it again books the PHANTOM debt as bad debt, which trips the
    /// unbacked brake (1% of supply) and stops all new borrowing on every type.
    function test_S1_reentrantLiquidationReverts() public {
        address other = makeAddr("other");
        hook2.mint(victim, 1_000_000e18);
        hook2.mint(other, 1_000_000e18);
        vm.prank(victim);
        hook2.approve(address(ledger), type(uint256).max);
        vm.prank(other);
        hook2.approve(address(ledger), type(uint256).max);
        _open(victim, HK2, 150_000e18, 100_000e18, 0.02e18);
        _open(other, HK2, 1_000_000e18, 150_000e18, 0.1e18);
        _open(whale, ETH, 1_000e18, 500_000e18, 0.05e18);
        LiqGriefer g = new LiqGriefer(ILedgerLike(address(ledger)), ILiquidatorLike(address(liquidator)), IERC20(address(hook2)));
        hook2.mint(address(g), 1);
        vm.prank(whale);
        usd.transfer(address(g), 200_000e18);
        // the victim falls under mat (1.4): 150k units at $0.9 = 135k < 140k
        hookFeed.set(0.9e18);
        ethFeed.set(2000e18);
        uint256 id = _id(HK2, victim);
        uint256 debtBefore = ledger.debtOf(id);

        vm.expectRevert(); // fixed: the re-entry hits the Ledger lock
        g.attack(id);
        return;
        uint256 debtAfter = ledger.debtOf(id);
        uint256 collAfter = ledger.position(id).collateral;
        emit log_named_decimal_uint("victim debt before    ", debtBefore, 18);
        emit log_named_decimal_uint("victim debt after liq ", debtAfter, 18);
        emit log_named_decimal_uint("victim coll after liq ", collAfter, 18);
        emit log_named_uint("victim rate after     ", ledger.position(id).rate);
        assertEq(debtAfter, debtBefore, "debt written back after the liquidation repaid it");

        g.liquidateAgain(id);
        emit log_named_decimal_uint("totalBadDebt          ", ledger.totalBadDebt(), 18);
        emit log_named_decimal_uint("unbacked              ", ledger.unbacked(), 18);
        assertGt(ledger.totalBadDebt(), 70_000e18);
        // the brake now refuses any new debt, on any type
        uint256 wid = _id(ETH, whale);
        vm.prank(whale);
        vm.expectPartialRevert(LedgerBase.Braked.selector);
        ledger.adjust(wid, Adjust(0, 1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    function _id(bytes32 ilk, address u) internal view returns (uint256) {
        return ledger.positionId(u, ilk, 0);
    }

    function _open(address u, bytes32 ilk, uint256 coll, uint256 debt, uint64 rate) internal {
        if (ilk == ETH) {
            weth.mint(u, 1_000_000e18);
            vm.prank(u);
            weth.approve(address(ledger), type(uint256).max);
        }
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        vm.prank(u);
        ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }
}
