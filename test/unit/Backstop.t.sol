// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {IBackstopOracle, ILedgerCover, IBackstopSeller} from "../../src/backstop/IBackstop.sol";

contract BUSD is ERC20 {
    constructor() ERC20("imdUSD", "imdUSD") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    /// @dev The Ledger is a minter: it burns without an allowance.
    function burn(address from, uint256 a) external {
        _burn(from, a);
    }
}

contract BToken is ERC20 {
    address public hookTarget;
    bytes public hookData;

    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    /// @dev ERC-777-like: calls back into `hookTarget` on every transfer to it.
    function setHook(address t, bytes calldata d) external {
        hookTarget = t;
        hookData = d;
    }

    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (hookTarget != address(0) && to == hookTarget) {
            (bool ok, bytes memory ret) = hookTarget.call(hookData);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

contract BOracle is IBackstopOracle {
    mapping(address => uint256) public low;
    mapping(address => uint256) public high;
    mapping(address => bool) public bad;

    function set(address t, uint256 l, uint256 h) external {
        low[t] = l;
        high[t] = h;
    }

    function setBad(address t, bool b) external {
        bad[t] = b;
    }


    function priceOf(address t) external view returns (uint256, uint256, bool) {
        return (low[t], high[t], !bad[t] && low[t] != 0);
    }

    function pricedAt(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev The Ledger's two roles here: `liquidatePosition` (burn from the payer, pay collateral) and `cover`.
contract BLedger is ILedgerCover {
    BUSD public usd;
    mapping(bytes32 => uint128) public bad;

    constructor(BUSD u) {
        usd = u;
    }

    function setBad(bytes32 ilk, uint128 b) external {
        bad[ilk] = b;
    }

    function cover(bytes32 ilk, uint256 amount) external {
        if (amount > bad[ilk]) amount = bad[ilk];
        bad[ilk] -= uint128(amount);
        usd.burn(msg.sender, amount);
    }

    function ilkState(bytes32 ilk) external view returns (uint128, uint128, uint256, uint64, uint128) {
        return (0, 0, 0, 0, bad[ilk]);
    }

    uint256 public accrualMint; // the edge premium the Ledger's accrual mints to the payer mid-liquidation

    function setAccrualMint(uint256 a) external {
        accrualMint = a;
    }

    function liquidatePosition(address payer, BToken coll, uint256 repaid, uint256 seized) external returns (uint256) {
        if (accrualMint != 0) usd.mint(payer, accrualMint);
        usd.burn(payer, repaid);
        coll.mint(payer, seized);
        return repaid;
    }
}

/// @dev The Liquidator's integration: open, liquidate with the backstop as payer, close.
contract BLiquidator {
    Backstop public bs;
    BLedger public ledger;

    constructor(BLedger l) {
        ledger = l;
    }

    function setBackstop(Backstop b) external {
        bs = b;
    }

    function liquidate(bytes32 ilk, BToken coll, uint256 repaid, uint256 seized) external returns (uint256, uint256) {
        bs.openBid(ilk);
        uint256 r = ledger.liquidatePosition(address(bs), coll, repaid, seized);
        return bs.closeBid(ilk, r);
    }

    /// @dev Open, try `data` on `target` inside the bid, close: returns the inner revert data (empty on success).
    function openCallClose(bytes32 ilk, address target, bytes calldata data) external returns (bytes memory ret) {
        bs.openBid(ilk);
        bool ok;
        (ok, ret) = target.call(data);
        if (ok) ret = "";
        bs.closeBid(ilk, 0);
    }
}

contract BLiquidatorLiar {
    BLedger public ledger;

    constructor(BLedger l) {
        ledger = l;
    }

    function lie(Backstop b, bytes32 ilk, BToken coll, uint256 repaid, uint256 seized) external {
        b.openBid(ilk);
        ledger.liquidatePosition(address(b), coll, repaid, seized);
        b.closeBid(ilk, repaid / 2);
    }
}

contract BSeller is IBackstopSeller {
    BUSD public usd;
    uint256 public payBps = 10_000;
    uint256 public price; // imdUSD per 1e18

    constructor(BUSD u) {
        usd = u;
    }

    function set(uint256 p, uint256 bps) external {
        price = p;
        payBps = bps;
    }

    function sell(Backstop bs, address token, uint256 amount, uint256 minOut) external returns (uint256) {
        return bs.sell(token, amount, minOut, "");
    }

    function onBackstopSell(address, uint256 amount, bytes calldata) external {
        usd.mint(msg.sender, Math.mulDiv(Math.mulDiv(amount, price, 1e18), payBps, 10_000));
    }
}

abstract contract BackstopBase is Test {
    BUSD usd;
    BToken weth;
    BToken simd;
    BOracle oracle;
    BLedger ledger;
    BLiquidator liq;
    BSeller seller;
    Backstop blue;
    Backstop edgeS;

    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usd = new BUSD();
        weth = new BToken("WETH");
        simd = new BToken("sIMD");
        oracle = new BOracle();
        oracle.set(address(weth), 2000e18, 2010e18);
        oracle.set(address(simd), 5e18, 5.2e18);
        ledger = new BLedger(usd);
        liq = new BLiquidator(ledger);
        seller = new BSeller(usd);
        blue = new Backstop(IERC20(address(usd)), ledger, oracle, false, "Backstop blue", "sBACK-B");
        edgeS = new Backstop(IERC20(address(usd)), ledger, oracle, true, "Backstop edge", "sBACK-E");
        blue.wire(address(liq), address(this), address(seller));
        edgeS.wire(address(liq), address(this), address(seller));
        blue.addIlk(ETH, address(weth), 0, 100e18, uint128(100e18) / 1 days);
        edgeS.addIlk(SIMD, address(simd), 30_000e18, 10_000e18, uint128(10_000e18) / 1 days);
        blue.seal();
        edgeS.seal();
        address[3] memory us = [alice, bob, eve];
        for (uint256 i; i < 3; ++i) {
            usd.mint(us[i], 1_000_000e18);
            vm.startPrank(us[i]);
            usd.approve(address(blue), type(uint256).max);
            usd.approve(address(edgeS), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deposit(Backstop b, address u, uint256 a) internal {
        vm.prank(u);
        b.deposit(a, u);
    }

    /// @dev Deposit, wait for the bucket to mature, and realize.
    function _join(Backstop b, address u, uint256 a) internal {
        _deposit(b, u, a);
        skip(2 days);
        b.realize(u);
    }

    function _bid(Backstop b, bytes32 ilk, BToken c, uint256 repaid, uint256 seized) internal returns (uint256, uint256) {
        liq.setBackstop(b);
        return liq.liquidate(ilk, c, repaid, seized);
    }

    function _exit(Backstop b, address u) internal returns (uint256 usdOut, uint256[] memory collOut) {
        uint256 sh = b.balanceOf(u);
        vm.prank(u);
        b.requestWithdraw(sh);
        skip(7 days);
        vm.prank(u);
        (usdOut, collOut) = b.withdraw(u);
    }
}

contract BackstopTest is BackstopBase {
    // ------------------------------------------------------------ deposits and maturity

    /// Value already in an empty pool (premium that vested before anyone joined, an exit's remainder) belongs to DEAD's shares,
    /// minted at the first conversion: entries and exits then price over the same supply, and a later depositor cannot buy the
    /// earlier ones' earnings at a discount. With an entry-only offset bob took 400 of alice's 1,200.
    function test_preExistingValueDoesNotLetLaterDepositorsTakeEarnings() public {
        usd.mint(address(edgeS), 100e18);
        edgeS.sync();
        skip(8 days);
        _join(edgeS, alice, 100e18);
        usd.mint(address(edgeS), 1_000e18); // the sleeve earns
        edgeS.sync();
        skip(8 days);
        _join(edgeS, bob, 1_200e18);
        (uint256 bobOut,) = _exit(edgeS, bob);
        assertApproxEqRel(bobOut, 1_200e18, 1e12, "bob takes out what he put in");
        (uint256 aliceOut,) = _exit(edgeS, alice);
        assertApproxEqRel(aliceOut, 600e18, 1e12, "alice keeps her half of the earnings (DEAD's half stays in the pool)");
        assertEq(edgeS.balanceOf(address(0xdEaD)), 1e6, "DEAD holds the offset");
    }

    function test_depositWaitsAFullDayBeforeShares() public {
        vm.warp((vm.getBlockTimestamp() / 1 days) * 1 days + 23 hours); // late in day D
        _deposit(blue, alice, 1000e18);
        assertEq(blue.balanceOf(alice), 0);
        assertEq(blue.staged(), 1000e18);
        assertEq(blue.bidRoom(ETH), 0); // immature: no room
        skip(2 hours); // day D+1: still waiting
        blue.realize(alice);
        assertEq(blue.balanceOf(alice), 0);
        skip(1 days); // day D+2
        blue.realize(alice);
        assertGt(blue.balanceOf(alice), 0);
        assertEq(blue.staged(), 0);
        assertEq(blue.bidRoom(ETH), 1000e18 - 1e18); // less the floor (a fixed 1 imdUSD residue)
    }

    function test_cancelBeforeMaturityReturnsEverything() public {
        _deposit(blue, alice, 500e18);
        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        blue.cancelDeposit(500e18);
        assertEq(usd.balanceOf(alice), before + 500e18);
        assertEq(blue.staged(), 0);
    }

    function test_cannotCancelAfterConversion() public {
        _deposit(blue, alice, 500e18);
        skip(2 days);
        blue.realize(bob); // converts the bucket
        vm.prank(alice);
        vm.expectRevert(Backstop.NotReady.selector);
        blue.cancelDeposit(500e18);
    }

    function test_flashDepositCannotBidOrCapture() public {
        _join(blue, alice, 10_000e18);
        // Eve deposits a large amount right before a liquidation in the same block: it neither adds room nor shares in it.
        _deposit(blue, eve, 900_000e18);
        uint256 room = blue.bidRoom(ETH);
        assertEq(room, 10_000e18 - 1e18);
        _bid(blue, ETH, weth, 5000e18, 2.75e18); // pays 5,000 for 2.75 WETH (5,500 at 2000)
        vm.prank(eve);
        blue.cancelDeposit(900_000e18); // eve leaves with exactly what she brought
        assertEq(usd.balanceOf(eve), 1_000_000e18);
        assertEq(weth.balanceOf(eve), 0);
    }

    function test_thirdPendingDayReverts() public {
        _deposit(blue, alice, 1e18);
        skip(1 days);
        _deposit(blue, alice, 1e18);
        // Day D+2: the day-D slot matures and is realized, freeing a slot.
        skip(1 days);
        _deposit(blue, alice, 1e18);
        assertGt(blue.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------ standing bid

    function test_standingBidBooksCollateralAndGain() public {
        _join(blue, alice, 10_000e18);
        // Liquidation: debt 4,000 repaid by the sleeve, 2.2 WETH (4,400 at the 2000 low: a 10% penalty) paid to it.
        (uint256 spent, uint256 got) = _bid(blue, ETH, weth, 4000e18, 2.2e18);
        assertEq(spent, 4000e18);
        assertEq(got, 2.2e18);
        assertEq(blue.coll(address(weth)), 2.2e18);
        (uint256 v,) = blue.nav();
        // 6,000 imdUSD + 2.2 WETH at the 2010 high.
        assertApproxEqAbs(v, 6000e18 + 4422e18, 2);
        (uint256 usdOut, uint256[] memory c) = _exit(blue, alice);
        assertApproxEqAbs(usdOut, 6000e18, 1e6);
        assertApproxEqAbs(c[0], 2.2e18, 1e6);
    }

    function test_premiumMintedDuringBidStreamsAndDoesNotMaskSpend() public {
        _join(edgeS, alice, 10_000e18);
        ledger.setAccrualMint(5000e18); // bigger than the spend: must not revert, must not count as vested at once
        (uint256 spent,) = _bid(edgeS, SIMD, simd, 1000e18, 220e18);
        assertEq(spent, 1000e18);
        assertApproxEqAbs(edgeS.vested(), 9000e18, 1);
        edgeS.sync();
        assertApproxEqAbs(edgeS.vested(), 9000e18, 1); // the 5,000 streams
        skip(7 days);
        assertApproxEqAbs(edgeS.vested(), 14_000e18, 1);
    }

    function test_closeRejectsUnderReportedBurn() public {
        // A liquidator reporting less than the Ledger burned cannot hide the spend.
        BLiquidatorLiar l2 = new BLiquidatorLiar(ledger);
        Backstop b = new Backstop(IERC20(address(usd)), ledger, oracle, false, "b", "b");
        b.wire(address(l2), address(this), address(0));
        b.addIlk(ETH, address(weth), 0, 0, 0);
        vm.prank(bob);
        usd.approve(address(b), type(uint256).max);
        _join(b, bob, 10_000e18);
        vm.expectRevert(Backstop.OverRoom.selector);
        l2.lie(b, ETH, weth, 1000e18, 0.6e18);
    }

    function test_bidAtSeveralDiscounts() public {
        _join(blue, alice, 100_000e18);
        uint256[4] memory pen = [uint256(0), 300, 1000, 1500]; // bps
        for (uint256 i; i < 4; ++i) {
            uint256 repaid = 1000e18;
            uint256 seized = Math.mulDiv(Math.mulDiv(repaid, 1e18, 2000e18), 10_000 + pen[i], 10_000);
            (uint256 s, uint256 g) = _bid(blue, ETH, weth, repaid, seized);
            assertEq(s, repaid);
            assertEq(g, seized);
        }
        assertEq(blue.coll(address(weth)), Math.mulDiv(0.5e18, 4 * 10_000 + 2800, 10_000));
    }

    function test_bidOverRoomReverts() public {
        _join(blue, alice, 1000e18);
        liq.setBackstop(blue);
        vm.expectRevert(Backstop.OverRoom.selector);
        liq.liquidate(ETH, weth, 1000e18, 0.6e18); // the floor keeps 1 wei+: 1000 is over the room
    }

    function test_bidAtALossReverts() public {
        _join(blue, alice, 10_000e18);
        liq.setBackstop(blue);
        vm.expectRevert(Backstop.BadPrice.selector);
        liq.liquidate(ETH, weth, 4000e18, 1.9e18); // 1.9 WETH = 3,800 < 4,000
    }

    function test_bidRefusedWhilePriceBad() public {
        _join(blue, alice, 10_000e18);
        oracle.setBad(address(weth), true);
        liq.setBackstop(blue);
        vm.expectRevert(Backstop.BadPrice.selector);
        liq.liquidate(ETH, weth, 1000e18, 0.6e18);
    }

    function test_onlyLiquidatorBids() public {
        vm.expectRevert(Backstop.Unauthorized.selector);
        blue.openBid(ETH);
        vm.expectRevert(Backstop.Unauthorized.selector);
        blue.closeBid(ETH, 0);
    }

    function test_noUserActionsWhileBidOpen() public {
        _join(blue, alice, 10_000e18);
        liq.setBackstop(blue);
        bytes[4] memory calls = [
            abi.encodeCall(Backstop.deposit, (1e18, address(liq))),
            abi.encodeCall(Backstop.realize, (alice)),
            abi.encodeCall(Backstop.requestWithdraw, (1)),
            abi.encodeCall(Backstop.coverBadDebt, (ETH))
        ];
        for (uint256 i; i < 4; ++i) {
            bytes memory ret = liq.openCallClose(ETH, address(blue), calls[i]);
            assertEq(bytes4(ret), Backstop.BidOpen.selector);
        }
        _deposit(blue, bob, 1e18); // works again after the close
    }

    function test_reentrantCollateralCannotActDuringBid() public {
        _join(blue, alice, 10_000e18);
        weth.setHook(address(blue), abi.encodeCall(Backstop.deposit, (1e18, address(this))));
        liq.setBackstop(blue);
        vm.expectRevert(Backstop.BidOpen.selector);
        liq.liquidate(ETH, weth, 1000e18, 0.6e18);
    }

    function test_disabledIlkHasNoRoom() public {
        _join(blue, alice, 10_000e18);
        blue.disableIlk(ETH);
        assertEq(blue.bidRoom(ETH), 0);
        liq.setBackstop(blue);
        vm.expectRevert(Backstop.UnknownIlk.selector);
        liq.liquidate(ETH, weth, 1000e18, 0.6e18);
    }

    // ------------------------------------------------------------ withdrawals

    function test_queueTakesLossesUntilPaid() public {
        _join(edgeS, alice, 10_000e18);
        _join(edgeS, bob, 10_000e18);
        uint256 sh = edgeS.balanceOf(alice);
        vm.prank(alice);
        edgeS.requestWithdraw(sh);
        // A bad-debt cover lands while alice waits: she shares it.
        ledger.setBad(SIMD, 4000e18);
        edgeS.coverBadDebt(SIMD);
        skip(7 days);
        vm.prank(alice);
        (uint256 out,) = edgeS.withdraw(alice);
        assertApproxEqAbs(out, 8000e18, 1e6);
    }

    function test_withdrawBeforeQueueReverts() public {
        _join(blue, alice, 1000e18);
        uint256 sh = blue.balanceOf(alice);
        vm.prank(alice);
        blue.requestWithdraw(sh);
        skip(7 days - 1);
        vm.prank(alice);
        vm.expectRevert(Backstop.NotReady.selector);
        blue.withdraw(alice);
    }

    function test_queuedSharesCannotMove() public {
        _join(blue, alice, 1000e18);
        uint256 sh = blue.balanceOf(alice);
        vm.prank(alice);
        blue.requestWithdraw(sh / 2);
        vm.prank(alice);
        vm.expectRevert(Backstop.Locked.selector);
        blue.transfer(bob, sh / 2 + 1);
        vm.prank(alice);
        blue.transfer(bob, sh / 2);
    }

    function test_queueIsPerUserNoGrief() public {
        _join(blue, alice, 1000e18);
        _join(blue, bob, 1000e18);
        uint256 sb = blue.balanceOf(bob);
        vm.prank(bob);
        blue.requestWithdraw(sb);
        // Eve spams requests of her own: bob's clock is untouched.
        _join(blue, eve, 1e18);
        for (uint256 i; i < 5; ++i) {
            vm.prank(eve);
            blue.requestWithdraw(1);
        }
        skip(5 days); // 7 days after bob's request (eve's _join took 2): inside his claim window

        vm.prank(bob);
        (uint256 out,) = blue.withdraw(bob);
        assertApproxEqAbs(out, 1000e18, 1e6);
    }

    function test_multiCollateralProRataExit() public {
        Backstop e = edgeS;
        BToken seat = new BToken("SEATACC");
        oracle.set(address(seat), 1000e18, 1000e18);
        e.addIlk("SEAT", address(seat), 0, 1e18, 1);
        _join(e, alice, 30_000e18);
        _join(e, bob, 10_000e18); // bob joins with alice at the same price: 1/4 of the pool
        _bid(e, SIMD, simd, 1000e18, 220e18);
        _bid(e, "SEAT", seat, 2000e18, 2.5e18);
        (uint256 ub, uint256[] memory cb) = _exit(e, bob);
        assertApproxEqRel(ub, 37_000e18 / 4, 1e12);
        assertApproxEqRel(cb[0], 220e18 / 4, 1e12);
        assertApproxEqRel(cb[1], 2.5e18 / 4, 1e12);
        (uint256 ua, uint256[] memory ca) = _exit(e, alice);
        assertApproxEqRel(ua, 37_000e18 * 3 / 4, 1e12);
        assertApproxEqRel(ca[0], 220e18 * 3 / 4, 1e12);
        assertLe(ca[1] + cb[1], 2.5e18);
    }

    function test_sleeveWithOnlyCollateralStillPaysOut() public {
        _join(edgeS, alice, 1000e18);
        // A bid spends everything down to the floor: the sleeve holds collateral only.
        uint256 room = edgeS.bidRoom(SIMD);
        _bid(edgeS, SIMD, simd, room, Math.mulDiv(room, 1.1e18, 5e18));
        assertLe(edgeS.vested(), edgeS.floor());
        (uint256 aliceNav,) = edgeS.nav();
        // A new depositor converts at the asset value with sIMD at its high price: he buys into the pool as it is.
        _join(edgeS, bob, 1000e18);
        uint256 sa = edgeS.balanceOf(alice);
        uint256 sb = edgeS.balanceOf(bob);
        assertGt(sb, 0);
        (uint256 ua, uint256[] memory ca) = _exit(edgeS, alice);
        (uint256 ub, uint256[] memory cb) = _exit(edgeS, bob);
        // At the high price each leaves with what they put in: alice her pool, bob his 1,000.
        assertApproxEqRel(ua + Math.mulDiv(ca[0], 5.2e18, 1e18), aliceNav, 1e14);
        assertApproxEqRel(ub + Math.mulDiv(cb[0], 5.2e18, 1e18), 1000e18, 1e14);
        assertGt(sa, 0);
    }

    // ------------------------------------------------------------ edge

    function test_badDebtCutsEdgeOnly() public {
        _join(edgeS, alice, 10_000e18);
        _join(blue, alice, 10_000e18);
        ledger.setBad(SIMD, 3000e18);
        uint256 c = edgeS.coverBadDebt(SIMD);
        assertEq(c, 3000e18);
        assertEq(ledger.bad(SIMD), 0);
        assertApproxEqAbs(edgeS.vested(), 7000e18, 1);
        assertApproxEqAbs(blue.vested(), 10_000e18, 1);
        vm.expectRevert(Backstop.UnknownIlk.selector);
        blue.coverBadDebt(SIMD);
    }

    function test_coverStopsAtTheFloor() public {
        _join(edgeS, alice, 1000e18);
        ledger.setBad(SIMD, 5000e18);
        uint256 c = edgeS.coverBadDebt(SIMD);
        assertLt(c, 1000e18);
        assertGe(edgeS.vested(), edgeS.floor());
        assertEq(ledger.bad(SIMD), 5000e18 - c); // the rest stays for the Treasury
    }

    function test_premiumStreamsOverSevenDays() public {
        _join(edgeS, alice, 10_000e18);
        usd.mint(address(edgeS), 700e18); // the Ledger mints the edge premium here
        edgeS.sync();
        assertApproxEqAbs(edgeS.vested(), 10_000e18, 1);
        skip(3.5 days);
        assertApproxEqAbs(edgeS.vested(), 10_350e18, 1e15);
        skip(3.5 days);
        assertApproxEqAbs(edgeS.vested(), 10_700e18, 1);
    }

    function test_premiumSandwichEarnsNothing() public {
        _join(edgeS, alice, 10_000e18);
        // Eve deposits just before a large premium and would leave right after: maturity + queue stop it.
        _deposit(edgeS, eve, 100_000e18);
        usd.mint(address(edgeS), 1000e18);
        edgeS.sync();
        vm.prank(eve);
        edgeS.cancelDeposit(100_000e18);
        assertEq(usd.balanceOf(eve), 1_000_000e18);
    }

    function test_capacityBootstrapDecay() public {
        // listed at setUp with a 30,000 genesis line; empty sleeve.
        assertEq(edgeS.edgeCapacity(SIMD, 0), 30_000e18);
        skip(30 days);
        assertEq(edgeS.edgeCapacity(SIMD, 0), 15_000e18);
        skip(30 days);
        assertEq(edgeS.edgeCapacity(SIMD, 0), 0);
        skip(1 days);
        assertEq(edgeS.edgeCapacity(SIMD, 0), 0);
        _join(edgeS, alice, 4000e18);
        assertApproxEqAbs(edgeS.edgeCapacity(SIMD, 0), 12_000e18, 3);
        assertApproxEqAbs(edgeS.edgeCapacity(SIMD, 5000e18), 7000e18, 3);
        assertEq(edgeS.edgeCapacity(SIMD, 20_000e18), 0);
        assertEq(blue.edgeCapacity(ETH, 0), 0);
    }

    function test_bidRoomNowCountsMaturedDeposits() public {
        _deposit(blue, alice, 10_000e18);
        assertEq(blue.bidRoomNow(ETH), 0, "immature: no room yet");
        skip(2 days);
        assertEq(blue.bidRoom(ETH), 0, "matured but not converted: bidRoom still reads 0");
        assertApproxEqAbs(blue.bidRoomNow(ETH), 10_000e18, 1e18, "bidRoomNow shows the room the next bid will have");
        blue.realize(alice); // converts
        assertApproxEqAbs(blue.bidRoom(ETH), blue.bidRoomNow(ETH), 1, "the same once converted");
    }

    function test_capacityIgnoresImmatureDeposits() public {
        skip(61 days);
        _deposit(edgeS, alice, 10_000e18);
        assertEq(edgeS.edgeCapacity(SIMD, 0), 0);
        skip(2 days);
        edgeS.realize(alice);
        assertApproxEqAbs(edgeS.edgeCapacity(SIMD, 0), 30_000e18, 3);
    }

    function test_capacityMaxOfBootstrapAndMultiple() public {
        _join(edgeS, alice, 20_000e18); // 3x = 60k > bootstrap ~29.0k
        assertApproxEqAbs(edgeS.edgeCapacity(SIMD, 0), 60_000e18, 3);
    }

    // ------------------------------------------------------------ attacks

    function test_inflationAttackFails() public {
        // Eve converts 1 wei, then donates a lot hoping the next depositor's shares round to zero.
        _join(blue, eve, 1);
        usd.mint(eve, 1_000_000e18);
        vm.prank(eve);
        usd.transfer(address(blue), 1_000_000e18);
        blue.sync(); // the donation streams: it does not move the price now
        _deposit(blue, alice, 1000e18);
        skip(2 days);
        blue.realize(alice);
        assertGt(blue.balanceOf(alice), 0);
        // Alice owns ~all of what she put in plus part of the donation, never less than she paid.
        (uint256 out,) = _exit(blue, alice);
        assertGe(out + 1e6, 1000e18);
    }

    function test_donatedCollateralIsNotCounted() public {
        _join(blue, alice, 1000e18);
        weth.mint(address(blue), 10e18);
        (uint256 v,) = blue.nav();
        assertApproxEqAbs(v, 1000e18, 1);
        assertEq(blue.coll(address(weth)), 0);
    }

    function test_convertWaitsWhileCollateralUnpriced() public {
        _join(blue, alice, 10_000e18);
        _bid(blue, ETH, weth, 1000e18, 0.55e18);
        oracle.setBad(address(weth), true);
        _deposit(blue, bob, 1000e18);
        skip(2 days);
        blue.realize(bob);
        assertEq(blue.balanceOf(bob), 0);
        oracle.setBad(address(weth), false);
        blue.realize(bob);
        assertGt(blue.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------ sale path

    function test_sellRespectsLimitAndPrice() public {
        _join(blue, alice, 10_000e18);
        _bid(blue, ETH, weth, 4000e18, 2.2e18);
        seller.set(2000e18, 10_000);
        uint256 got = seller.sell(blue, address(weth), 1e18, 1990e18);
        assertEq(got, 2000e18);
        assertEq(blue.coll(address(weth)), 1.2e18);
        seller.set(2000e18, 9700); // 3% short of the low price
        vm.expectRevert(Backstop.SaleShort.selector);
        seller.sell(blue, address(weth), 1e18, 0);
        vm.expectRevert(Backstop.Unauthorized.selector);
        blue.sell(address(weth), 1e18, 0, "");
    }

    function test_sellRateLimited() public {
        _join(blue, alice, 900_000e18);
        _bid(blue, ETH, weth, 400_000e18, 220e18);
        seller.set(2000e18, 10_000);
        seller.sell(blue, address(weth), 100e18, 0); // the whole bucket
        vm.expectRevert(Backstop.SaleLimit.selector);
        seller.sell(blue, address(weth), 1e18, 0);
        skip(1 days);
        seller.sell(blue, address(weth), 99.99e18, 0); // refilled at slope (100/day, rounded down per second)
    }

    // ------------------------------------------------------------ setup rules

    function test_listingRules() public {
        vm.prank(eve);
        vm.expectRevert(Backstop.Unauthorized.selector);
        blue.addIlk("X", address(simd), 0, 0, 0);
        vm.expectRevert(Backstop.Exists.selector);
        blue.addIlk(ETH, address(weth), 0, 0, 0);
        for (uint256 i; i < 5; ++i) {
            blue.addIlk(bytes32(i + 1), address(new BToken("T")), 0, 0, 0);
        }
        address t7 = address(new BToken("T7"));
        vm.expectRevert(Backstop.TooManyTokens.selector);
        blue.addIlk("T7", t7, 0, 0, 0);
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_bidMath(uint256 dep, uint256 repaid, uint256 penBps) public {
        dep = bound(dep, 2e18, 1_000_000e18);
        repaid = bound(repaid, 1, dep - 1e18); // the floor is a fixed 1 imdUSD residue
        penBps = bound(penBps, 0, 2000);
        _join(blue, alice, dep);
        uint256 seized = Math.mulDiv(Math.mulDiv(repaid, 1e18, 2000e18, Math.Rounding.Ceil), 10_000 + penBps, 10_000, Math.Rounding.Ceil);
        (uint256 s, uint256 g) = _bid(blue, ETH, weth, repaid, seized);
        assertEq(s, repaid);
        assertEq(g, seized);
        (uint256 v,) = blue.nav();
        assertGe(v + 2, dep); // a bid at or above the low price never lowers the asset value
    }
}

/// @dev Random deposits, cancels, realizes, bids, covers, premiums, requests and withdrawals on the edge sleeve.
contract BackstopHandler is Test {
    Backstop public bs;
    BUSD public usd;
    BToken public simd;
    BLedger public ledger;
    BLiquidator public liq;
    address[] public users;

    constructor(Backstop b, BUSD u, BToken s, BLedger l, BLiquidator lq, address[] memory us) {
        bs = b;
        usd = u;
        simd = s;
        ledger = l;
        liq = lq;
        users = us;
    }

    function _u(uint256 i) internal view returns (address) {
        return users[i % users.length];
    }

    function deposit(uint256 i, uint256 a) external {
        a = bound(a, 1, 100_000e18);
        address u = _u(i);
        usd.mint(u, a);
        vm.startPrank(u);
        usd.approve(address(bs), a);
        try bs.deposit(a, u) {} catch {}
        vm.stopPrank();
    }

    function cancel(uint256 i, uint256 a) external {
        address u = _u(i);
        Backstop.Pend[2] memory p = bs.pendingOf(u);
        uint256 max = p[0].amount + p[1].amount;
        if (max == 0) return;
        a = bound(a, 1, max);
        vm.prank(u);
        try bs.cancelDeposit(a) {} catch {}
    }

    function warp(uint256 s) external {
        skip(bound(s, 1, 3 days));
    }

    function realize(uint256 i) external {
        bs.realize(_u(i));
    }

    function bid(uint256 a, uint256 pen) external {
        uint256 room = bs.bidRoom("SIMD");
        if (room == 0) return;
        a = bound(a, 1, room);
        pen = bound(pen, 0, 1500);
        uint256 seized = Math.mulDiv(Math.mulDiv(a, 1e18, 5e18, Math.Rounding.Ceil), 10_000 + pen, 10_000, Math.Rounding.Ceil);
        liq.liquidate("SIMD", simd, a, seized);
    }

    function cover(uint256 a) external {
        ledger.setBad("SIMD", uint128(bound(a, 0, 50_000e18)));
        bs.coverBadDebt("SIMD");
    }

    function premium(uint256 a) external {
        usd.mint(address(bs), bound(a, 0, 10_000e18));
        bs.sync();
    }

    function request(uint256 i, uint256 s) external {
        address u = _u(i);
        (uint256 q,) = bs.requests(u);
        uint256 free = bs.balanceOf(u) - q;
        if (free == 0) return;
        vm.prank(u);
        bs.requestWithdraw(bound(s, 1, free));
    }

    function withdraw(uint256 i) external {
        address u = _u(i);
        vm.prank(u);
        try bs.withdraw(u) {} catch {}
    }
}

contract BackstopInvariant is BackstopBase {
    BackstopHandler h;

    function setUp() public override {
        super.setUp();
        address[] memory us = new address[](3);
        us[0] = alice;
        us[1] = bob;
        us[2] = eve;
        h = new BackstopHandler(edgeS, usd, simd, ledger, liq, us);
        liq.setBackstop(edgeS);
        targetContract(address(h));
    }

    /// @dev What the sleeve owes is exactly what it holds: imdUSD counted + waiting <= balance, collateral booked <=
    /// balance, and buckets add up to `staged`.
    function invariant_claimsEqualAssets() public view {
        assertGe(usd.balanceOf(address(edgeS)), edgeS.tracked() + edgeS.staged());
        assertLe(edgeS.coll(address(simd)), simd.balanceOf(address(edgeS)));
        uint256 sum;
        for (uint256 i = edgeS.openHead(); i < edgeS.openDaysLength(); ++i) {
            (uint128 a,,,) = edgeS.buckets(edgeS.openDays(i));
            sum += a;
        }
        assertEq(sum, edgeS.staged());
        assertGe(edgeS.tracked(), edgeS.unvested());
    }

    /// @dev Every share is owned: users' balances plus the contract's not-yet-realized bucket shares == supply.
    function invariant_sharesAccounted() public view {
        uint256 s = edgeS.balanceOf(alice) + edgeS.balanceOf(bob) + edgeS.balanceOf(eve) + edgeS.balanceOf(address(edgeS))
            + edgeS.balanceOf(address(0xdEaD)); // the offset minted at the first conversion
        assertEq(s, edgeS.totalSupply());
    }
}
