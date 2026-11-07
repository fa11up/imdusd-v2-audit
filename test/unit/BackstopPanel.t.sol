// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {IBackstopSeller} from "../../src/backstop/IBackstop.sol";
import {BackstopBase, BUSD} from "./Backstop.t.sol";

/// @dev A seller that pays the sale and, in the same callback, calls the permissionless `sync()` (a route/pool hook,
/// or a Ledger accrual that mints the edge premium and syncs).
contract SyncingSeller is IBackstopSeller {
    BUSD public usd;
    uint256 public price;

    constructor(BUSD u) {
        usd = u;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function sell(Backstop bs, address token, uint256 amount) external returns (uint256) {
        return bs.sell(token, amount, 0, "");
    }

    function onBackstopSell(address, uint256 amount, bytes calldata) external {
        usd.mint(msg.sender, Math.mulDiv(amount, price, 1e18));
        Backstop(msg.sender).sync();
    }
}

/// @dev A collateral token with an issuer blocklist and pause (cbBTC / WBTC have these).
contract BlockToken is ERC20 {
    mapping(address => bool) public blocked;
    bool public paused;

    constructor() ERC20("cbBTC", "cbBTC") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!paused, "paused");
        require(!blocked[from] && !blocked[to], "blocked");
        super._update(from, to, v);
    }
}

/// @dev The Liquidator harness with a BlockToken as collateral.
contract BlockLiq {
    function liquidate(Backstop bs, bytes32 ilk, BUSD usd, BlockToken coll, uint256 repaid, uint256 seized) external {
        bs.openBid(ilk);
        usd.burn(address(bs), repaid);
        coll.mint(address(bs), seized);
        bs.closeBid(ilk, repaid);
    }
}

/// Regression tests for the 2026-11 internal review's backstop findings. Each test is the review's PoC with its
/// assertion turned around: it failed before the fix and passes on it.
contract BackstopPanelTest is BackstopBase {
    address carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        usd.mint(carol, 1_000_000e18);
        vm.startPrank(carol);
        usd.approve(address(blue), type(uint256).max);
        usd.approve(address(edgeS), type(uint256).max);
        vm.stopPrank();
    }

    function _valueOf(Backstop b, address u) internal view returns (uint256) {
        return Math.mulDiv(b.vested(), b.balanceOf(u), b.totalSupply());
    }

    /// @dev What Treasury.coverBadDebt does after the sleeve's part (StandingBid and PanelRecheck run the real one): burns
    /// imdUSD against whatever is still booked.
    function _treasuryPaysRest() internal {
        (,,,, uint128 left) = ledger.ilkState(SIMD);
        address t = makeAddr("treasury");
        usd.mint(t, left);
        vm.prank(t);
        ledger.cover(SIMD, left);
    }

    // ------------------------------------------------------------------ recapitalising a wiped sleeve

    /// The verifier's forced path: bob's bucket has matured, bad debt over the room is booked; anyone runs coverBadDebt
    /// then realize(bob) in ONE transaction, so the bucket converts at the post-wipe price exactly. Before the fix bob
    /// was left 250 imdUSD of 1M and the floor swallowed the rest for good.
    function test_H2_coverThenConvertSameTxKeepsTheRecap() public {
        _join(edgeS, alice, 1_000_000e18);
        usd.mint(address(edgeS), 1_000e18); // a premium stream in flight
        edgeS.sync();
        _deposit(edgeS, bob, 1_000_000e18);
        skip(2 days);
        ledger.setBad(SIMD, 5_000_000e18); // booked, not yet covered
        edgeS.coverBadDebt(SIMD);
        assertEq(edgeS.vested(), 1e18, "cover leaves exactly the 1 imdUSD residue");
        _treasuryPaysRest(); // Treasury.coverBadDebt: the sleeve first, then itself
        edgeS.realize(bob);
        assertGt(_valueOf(edgeS, bob), 999_999e18, "bob keeps his recap");
        assertGt(edgeS.bidRoom(SIMD), 999_999e18, "the recap is bid room");
        assertLt(_valueOf(edgeS, alice), 1.01e18, "alice keeps the residue's worth");
        skip(7 days); // the stream vests: both share it pro rata
        (uint256 out,) = _exit(edgeS, bob);
        assertGt(out, 999_999e18);
    }

    /// The reviewer's F2: a 1M recap after a wipe used to truncate to 2.5e38 shares and pay back ~250.
    function test_H2_recapAfterWipeIsWholeAndBidsAgain() public {
        _join(edgeS, alice, 1_000_000e18);
        ledger.setBad(SIMD, 2_000_000e18);
        edgeS.coverBadDebt(SIMD);
        _treasuryPaysRest();
        assertLe(edgeS.edgeCapacity(SIMD, 0), 30_000e18, "wiped: only the bootstrap stands behind lines");
        _deposit(edgeS, bob, 1_000_000e18);
        skip(2 days);
        uint256 supplyBefore = edgeS.totalSupply();
        edgeS.realize(bob);
        uint256 minted = edgeS.totalSupply() - supplyBefore;
        (, uint256 bucketShares,,) = edgeS.buckets((block.timestamp - 2 days) / 1 days);
        assertEq(bucketShares, minted, "no truncation");
        assertEq(edgeS.balanceOf(bob), minted, "bob holds every share his bucket became");
        assertGt(edgeS.bidRoom(SIMD), 999_999e18);
        assertApproxEqRel(edgeS.edgeCapacity(SIMD, 0), 3_000_000e18, 1e12);
        (uint256 out,) = _exit(edgeS, bob);
        assertGt(out, 999_999e18);
    }

    /// The reviewer's F2b: a small recap no longer becomes floor.
    function test_H2_smallRecapIsRoom() public {
        _join(edgeS, alice, 1_000_000e18);
        ledger.setBad(SIMD, 2_000_000e18);
        edgeS.coverBadDebt(SIMD);
        _treasuryPaysRest();
        _join(edgeS, bob, 100e18);
        assertApproxEqAbs(edgeS.bidRoom(SIMD), 100e18, 1e9);
    }

    /// A second full wipe after a recap still leaves the next recap whole (the floor never grows with the supply).
    function test_H2_twoWipesStillRecapitalise() public {
        _join(edgeS, alice, 1_000_000e18);
        ledger.setBad(SIMD, 2_000_000e18);
        edgeS.coverBadDebt(SIMD);
        _treasuryPaysRest();
        _join(edgeS, bob, 1_000_000e18);
        ledger.setBad(SIMD, 2_000_000e18);
        edgeS.coverBadDebt(SIMD);
        _treasuryPaysRest();
        _join(edgeS, carol, 1_000_000e18);
        assertGt(_valueOf(edgeS, carol), 999_999e18);
        assertGt(edgeS.bidRoom(SIMD), 999_999e18);
    }

    // ------------------------------------------------------------------ first loss is not escapable

    /// The reviewer's F1: a request matured 30 days ago used to be a standing instant exit. It now expires after the
    /// 2-day claim window and must be re-queued (7 more days).
    function test_M2_maturedRequestExpires() public {
        _join(edgeS, alice, 10_000e18);
        uint256 sa = edgeS.balanceOf(alice);
        vm.prank(alice);
        edgeS.requestWithdraw(sa);
        skip(30 days);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("Expired()")));
        edgeS.withdraw(alice);
        vm.prank(alice);
        edgeS.requestWithdraw(0); // re-queue as it stands
        skip(7 days);
        vm.prank(alice);
        (uint256 out,) = edgeS.withdraw(alice);
        assertApproxEqAbs(out, 10_000e18, 1e6);
    }

    /// F1 inside the claim window: alice exits after the loss is booked but before anyone covers it. She now takes her
    /// half of it (was: 10,000 out, bob 1e-8).
    function test_M2_exitBeforeCoverTakesItsShare() public {
        _join(edgeS, alice, 10_000e18);
        _join(edgeS, bob, 10_000e18);
        uint256 sa = edgeS.balanceOf(alice);
        uint256 sb = edgeS.balanceOf(bob);
        vm.prank(alice);
        edgeS.requestWithdraw(sa);
        vm.prank(bob);
        edgeS.requestWithdraw(sb);
        skip(7 days);
        ledger.setBad(SIMD, 10_000e18);
        assertApproxEqAbs(edgeS.bidRoom(SIMD), 10_000e18 - 1e18, 2, "booked loss is not bid room");
        assertApproxEqAbs(edgeS.edgeCapacity(SIMD, 0), 30_000e18, 3e18, "nor capacity");
        vm.prank(alice);
        (uint256 aOut,) = edgeS.withdraw(alice);
        edgeS.coverBadDebt(SIMD);
        vm.prank(bob);
        (uint256 bOut,) = edgeS.withdraw(bob);
        assertApproxEqAbs(aOut, 5_000e18, 1e18);
        assertApproxEqAbs(bOut, 5_000e18, 1e18);
    }

    /// The reviewer's F1b: a bucket that matures while a loss within the sleeve's room is booked converts net of it, so
    /// realize-then-cover in one tx no longer makes the newcomer pay half of an old loss.
    function test_M2_conversionNetsBookedBadDebt() public {
        _join(edgeS, alice, 10_000e18);
        _deposit(edgeS, carol, 10_000e18);
        skip(1 days);
        ledger.setBad(SIMD, 6_000e18);
        skip(1 days);
        edgeS.realize(carol);
        assertGt(edgeS.balanceOf(carol), 0, "a loss the sleeve can take: converts");
        edgeS.coverBadDebt(SIMD);
        assertEq(ledger.bad(SIMD), 0);
        assertApproxEqAbs(_valueOf(edgeS, carol), 10_000e18, 1e18);
        assertApproxEqAbs(_valueOf(edgeS, alice), 4_000e18, 1e18);
    }

    /// The forced exact-floor path with no Treasury in it: the loss is exactly the room, cover then realize in one tx.
    function test_H2_lossExactlyTheRoomConverts() public {
        _join(edgeS, alice, 10_000e18);
        _deposit(edgeS, bob, 5_000e18);
        skip(2 days);
        ledger.setBad(SIMD, uint128(edgeS.vested() - edgeS.floor()));
        edgeS.realize(bob); // before the cover
        assertGt(edgeS.balanceOf(bob), 0, "the room covers it all: nothing to wait for");
        edgeS.coverBadDebt(SIMD);
        assertEq(ledger.bad(SIMD), 0);
        assertApproxEqAbs(_valueOf(edgeS, bob), 5_000e18, 1e18);
    }

    /// The recheck's PoC turned round. Bob deposits before a loss bigger than the sleeve's room; the Treasury cannot pay the
    /// rest. His bucket WAITS (his deposit used to be burned against the old loss by anyone's realize + cover), takes no
    /// part in anything, and can be cancelled in full. It converts once the booked loss is gone.
    function test_RD_recapEatenByResidualBadDebt() public {
        _join(edgeS, alice, 1_000e18);
        _deposit(edgeS, bob, 5_000e18);
        skip(1 days);
        ledger.setBad(SIMD, 10_000e18);
        edgeS.coverBadDebt(SIMD); // 9,001 stays booked
        assertEq(edgeS.vested(), 1e18);
        skip(1 days);
        edgeS.realize(bob);
        assertEq(edgeS.balanceOf(bob), 0, "waits while the loss exceeds the room");
        assertEq(edgeS.staged(), 5_000e18);
        assertEq(edgeS.coverBadDebt(SIMD), 0, "no cover can reach the waiting money");
        assertEq(edgeS.staged(), 5_000e18);
        // Capacity and bidding stay shut during the wait.
        assertEq(edgeS.bidRoom(SIMD), 0);
        assertEq(edgeS.bidRoomNow(SIMD), 0, "a waiting bucket is not bid room");
        assertLe(edgeS.edgeCapacity(SIMD, 0), edgeS.bootstrap(SIMD) + 3e18, "only the bootstrap or the residue stands behind lines");
        // Once the rest is paid the bucket converts whole.
        _treasuryPaysRest();
        assertApproxEqAbs(edgeS.bidRoomNow(SIMD), 5_000e18, 1);
        edgeS.realize(bob);
        assertGt(_valueOf(edgeS, bob), 4_999e18, "bob keeps his deposit");
        assertLt(_valueOf(edgeS, alice), 1.01e18);
    }

    function test_RD_waitingBucketCancelsInFull() public {
        _join(edgeS, alice, 1_000e18);
        _deposit(edgeS, bob, 5_000e18);
        ledger.setBad(SIMD, 10_000e18);
        edgeS.coverBadDebt(SIMD);
        skip(2 days);
        edgeS.realize(bob);
        uint256 b0 = usd.balanceOf(bob);
        vm.prank(bob);
        edgeS.cancelDeposit(5_000e18);
        assertEq(usd.balanceOf(bob) - b0, 5_000e18, "all of it, after maturity");
        assertEq(edgeS.staged(), 0);
    }

    /// The other re-check's V3: bob deposited 1,000,000 into an open hole and could withdraw 0.99. He now holds no shares,
    /// can leave with all of it, and the hole stays the Treasury's.
    function test_V3_recapIntoAnOpenHole() public {
        _join(edgeS, alice, 1_000_000e18);
        ledger.setBad(SIMD, 2_000_000e18);
        edgeS.coverBadDebt(SIMD);
        _join(edgeS, bob, 1_000_000e18);
        assertEq(edgeS.balanceOf(bob), 0, "no shares in a hole");
        assertEq(edgeS.bidRoom(SIMD), 0);
        uint256 bad0 = ledger.bad(SIMD);
        edgeS.coverBadDebt(SIMD);
        assertEq(ledger.bad(SIMD), bad0, "the deposit pays none of the hole");
        uint256 b0 = usd.balanceOf(bob);
        vm.prank(bob);
        edgeS.cancelDeposit(1_000_000e18);
        assertEq(usd.balanceOf(bob) - b0, 1_000_000e18);
    }

    /// A disabled type's losses are the Treasury's: they are not netted.
    function test_M2_disabledTypeNotNetted() public {
        _join(edgeS, alice, 10_000e18);
        ledger.setBad(SIMD, 4_000e18);
        (uint256 v,) = edgeS.nav();
        assertApproxEqAbs(v, 6_000e18, 1);
        edgeS.disableIlk(SIMD);
        (v,) = edgeS.nav();
        assertEq(v, edgeS.vested());
    }

    // ------------------------------------------------------------------ a token that cannot be sent

    function _cbSleeve() internal returns (Backstop b, BlockToken cb) {
        cb = new BlockToken();
        b = new Backstop(IERC20(address(usd)), ledger, oracle, false, "b", "b");
        BlockLiq bl = new BlockLiq();
        b.wire(address(bl), address(this), address(0));
        b.addIlk(ETH, address(weth), 0, 1e30, 1e20);
        b.addIlk("CBBTC", address(cb), 0, 1e30, 1e20);
        b.seal();
        oracle.set(address(cb), 100_000e28, 100_100e28); // per 1e18 raw (8 decimals)
        vm.prank(alice);
        usd.approve(address(b), type(uint256).max);
        vm.prank(bob);
        usd.approve(address(b), type(uint256).max);
        _join(b, alice, 100_000e18);
        _join(b, bob, 100_000e18);
        bl.liquidate(b, "CBBTC", usd, cb, 10_000e18, 0.11e8); // the sleeve buys 0.11 cbBTC
    }

    /// The reviewer's F3: the sleeve is blocklisted by cbBTC's issuer. Alice's exit used to revert, imdUSD included.
    function test_M3_blockedTokenNeverBlocksTheRest() public {
        (Backstop b, BlockToken cb) = _cbSleeve();
        uint256 sa = b.balanceOf(alice);
        vm.prank(alice);
        b.requestWithdraw(sa);
        skip(7 days);
        cb.setBlocked(address(b), true);
        vm.prank(alice);
        (uint256 out, uint256[] memory collOut) = b.withdraw(alice);
        assertApproxEqAbs(out, 95_000e18, 1e18, "imdUSD part paid");
        assertApproxEqAbs(collOut[1], 0.055e8, 1); // DEAD's offset shares keep a unit
        assertEq(cb.balanceOf(alice), 0);
        assertApproxEqAbs(b.unsent(alice, address(cb)), 0.055e8, 1, "credited"); // DEAD's offset shares keep a unit
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        b.claim(address(cb), alice); // still blocked: the claim waits
        cb.setBlocked(address(b), false);
        vm.prank(alice);
        b.claim(address(cb), alice);
        assertApproxEqAbs(cb.balanceOf(alice), 0.055e8, 1); // DEAD's offset shares keep a unit
        assertEq(b.unsent(alice, address(cb)), 0);
        // bob's pro rata share is untouched by alice's unsent credit
        (, uint256[] memory bOut) = _exit(b, bob);
        assertApproxEqAbs(bOut[1], 0.055e8, 1); // DEAD's offset shares keep a unit
    }

    /// A paused token and a blocklisted receiver behave the same.
    function test_M3_pausedTokenAndBlockedReceiver() public {
        (Backstop b, BlockToken cb) = _cbSleeve();
        uint256 sa = b.balanceOf(alice);
        vm.prank(alice);
        b.requestWithdraw(sa);
        skip(7 days);
        cb.setBlocked(alice, true);
        vm.prank(alice);
        (uint256 out,) = b.withdraw(alice);
        assertGt(out, 94_000e18);
        assertApproxEqAbs(b.unsent(alice, address(cb)), 0.055e8, 1); // DEAD's offset shares keep a unit
        vm.prank(alice);
        b.claim(address(cb), carol); // to an address the issuer does not block
        assertApproxEqAbs(cb.balanceOf(carol), 0.055e8, 1); // DEAD's offset shares keep a unit
    }

    // ------------------------------------------------------------------ unpriced held collateral

    /// Retiring through Parameters' timelock is test_M4_retiredTokenUnblocksConversions in PanelRecheck.t.sol.

    /// Unpriced dust (under 10 imdUSD at its last good price) never stops conversions, with no governance at all.
    function test_M4_unpricedDustDoesNotStopConversions() public {
        _join(blue, alice, 10_000e18);
        _bid(blue, ETH, weth, 2e18, 0.0011e18); // the sleeve holds 0.0011 WETH (~2.2 imdUSD)
        oracle.setBad(address(weth), true);
        _join(blue, carol, 500_000e18);
        assertGt(blue.balanceOf(carol), 0);
        assertEq(blue.staged(), 0);
    }

    // ------------------------------------------------------------------ sync() inside a sale

    /// The reviewer's F5: a sync() inside the sale callback used to count the proceeds twice (tracked 11,200 vs a
    /// balance of 10,100) and the last holder could not leave.
    function test_L1_syncInsideSaleCountsOnce() public {
        SyncingSeller ss = new SyncingSeller(usd);
        Backstop b = new Backstop(IERC20(address(usd)), ledger, oracle, false, "b", "b");
        b.wire(address(liq), address(this), address(ss));
        b.addIlk(ETH, address(weth), 0, 100e18, 1e18);
        b.seal();
        vm.prank(alice);
        usd.approve(address(b), type(uint256).max);
        _join(b, alice, 10_000e18);
        _bid(b, ETH, weth, 1_000e18, 0.55e18);
        ss.setPrice(2000e18);
        ss.sell(b, address(weth), 0.55e18); // pays 1,100 imdUSD
        assertEq(b.tracked(), usd.balanceOf(address(b)), "counted once");
        (uint256 out,) = _exit(b, alice);
        assertApproxEqAbs(out, 10_100e18, 1e6);
    }
}
