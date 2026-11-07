// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {Join} from "../../src/Join.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Governed} from "../../src/Governed.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice A live pool price as LivePoolPrice reports it: never stale unless unreadable.
contract LiveMock is IFeed {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, value == 0 ? 0 : uint64(block.timestamp));
    }

    function isStale() external view returns (bool) {
        return value == 0;
    }

    function maxAge() external pure returns (uint256) {
        return type(uint64).max;
    }
}

/// @notice the live payout leg, per-type fees and base rates, the rolling window cap.
contract RedemptionTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant STABLE = "USDX";
    bytes32 constant SIMD = "SIMD";
    uint256 constant CAP = 20_000e18;

    MockERC20 weth;
    MockERC20 usdx;
    MockERC20 simd;
    MockFeed ethFeed;
    MockFeed usdxFeed;
    MockFeed simdMedian;
    MockFeed simdSpot;
    MockFeed nhi;
    LiveMock live;

    address alice = makeAddr("alice"); // sIMD borrower (lowest rate)
    address bob = makeAddr("bob"); // second sIMD borrower
    address whale = makeAddr("whale"); // holds imdUSD from ETH and stable positions
    address dave = makeAddr("dave"); // redeemer

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        usdx = new MockERC20("USDX", 18);
        simd = new MockERC20("sIMD", 18);
        ethFeed = new MockFeed(2000e18);
        usdxFeed = new MockFeed(1e18);
        simdMedian = new MockFeed(5e18);
        simdSpot = new MockFeed(5e18);
        nhi = new MockFeed(0.98e18);
        live = new LiveMock();
        live.set(5e18);

        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        ParametersBase.Risk memory er = _risk(1.4e18, 100_000_000e18);
        er.redeemDivisor = 4;
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, er);
        ParametersBase.Risk memory sr = _risk(1.05e18, 100_000_000e18);
        sr.chop = 0.03e18;
        sr.rateFloor = 0.005e18;
        sr.redeemFloor = 0.001e18;
        sr.redeemDivisor = 8;
        _addIlk(STABLE, address(usdx), usdxFeed, usdxFeed, IFeed(address(0)), address(0), address(0), true, sr);
        ParametersBase.Risk memory ir = _risk(1.7e18, 100_000_000e18);
        ir.chop = 0.2e18;
        ir.skew = 0.1e18;
        ir.redeemCap = uint128(CAP);
        _addIlk(SIMD, address(simd), simdMedian, simdSpot, nhi, address(0), address(0), IFeed(address(live)), true, ir);
        params.seal();

        address[4] memory us = [alice, bob, whale, dave];
        for (uint256 i; i < 4; ++i) {
            weth.mint(us[i], 1_000_000e18);
            usdx.mint(us[i], 100_000_000e18);
            simd.mint(us[i], 10_000_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usdx.approve(address(ledger), type(uint256).max);
            simd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
        // sIMD book: 2 x 100k debt on $1.5M of collateral each (redeemable, healthy).
        _open(alice, SIMD, 300_000e18, 100_000e18, 0.04e18);
        _open(bob, SIMD, 300_000e18, 100_000e18, 0.05e18);
        // The rest of supply: ETH and stablecoin positions, whose imdUSD the redeemer buys.
        _open(whale, ETH, 1_000e18, 500_000e18, 0.05e18);
        _open(whale, STABLE, 1_000_000e18, 500_000e18, 0.05e18);
        vm.prank(whale);
        usd.transfer(dave, 400_000e18);
    }

    function _open(address u, bytes32 ilk, uint256 coll, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        vm.prank(u);
        ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _redeem(bytes32 ilk, uint256 amount) internal returns (uint256 redeemed, uint256 out) {
        vm.prank(dave);
        return redeemer.redeem(ilk, amount, 0.05e18, 10, 0);
    }

    // ------------------------------------------------------------ the live leg

    /// @notice THE RALLY-STRIPPING REGRESSION. The market (live pool) is 3% above both attested legs. A
    /// redemption must not hand out more than $1 of collateral, valued at the market, per imdUSD. Paying at
    /// max(median, spot), as the pre-09 Redeemer did, pays ~$1.0249 per imdUSD here and fails this test.
    function test_rallyIsNotPaidToTheRedeemer() public {
        live.set(5.15e18);
        uint256 fee = redeemer.feeFor(SIMD, 10_000e18);
        (uint256 redeemed, uint256 out) = _redeem(SIMD, 10_000e18);
        assertEq(redeemed, 10_000e18);
        uint256 marketValue = Math.mulDiv(out, live.value(), 1e18);
        assertLe(marketValue, redeemed, "redeemer took more than $1 of collateral per imdUSD at the market");
        // And exactly the fee below par: paid at the live price.
        assertApproxEqRel(marketValue, redeemed * (1e18 - fee) / 1e18, 1e12);
    }

    /// @notice The live leg can only LOWER what a redeemer receives (raise the payout price).
    function testFuzz_liveLegOnlyLowersPayout(uint256 livePrice) public {
        livePrice = bound(livePrice, 1e15, 50e18);
        live.set(livePrice);
        uint256 fee = redeemer.feeFor(SIMD, 1_000e18);
        (, uint256 out) = _redeem(SIMD, 1_000e18);
        uint256 atHigh = Math.mulDiv(Math.mulDiv(1_000e18, 1e18, 5e18), 1e18 - fee, 1e18);
        assertLe(out, atHigh, "live leg raised the payout");
        uint256 expected = Math.mulDiv(Math.mulDiv(1_000e18, 1e18, Math.max(5e18, livePrice)), 1e18 - fee, 1e18);
        assertEq(out, expected);
    }

    /// @notice A live leg that cannot be read closes redemption on that type (fail closed); others continue.
    function test_unreadableLiveLegStopsOnlyThatType() public {
        live.set(0);
        vm.prank(dave);
        vm.expectRevert(Redeemer.NotPriced.selector);
        redeemer.redeem(SIMD, 1_000e18, 0.05e18, 10, 0);
        (uint256 r,) = _redeem(ETH, 1_000e18);
        assertEq(r, 1_000e18);
    }

    // ------------------------------------------------------------ the window cap

    function test_windowCapFillsThenRefuses() public {
        (uint256 a,) = _redeem(SIMD, 15_000e18);
        assertEq(a, 15_000e18);
        // Over-size request: filled up to what the window has left.
        (uint256 b,) = _redeem(SIMD, 10_000e18);
        assertEq(b, 5_000e18);
        assertEq(redeemer.windowLeft(SIMD), 0);
        vm.prank(dave);
        vm.expectRevert(Redeemer.WindowFull.selector);
        redeemer.redeem(SIMD, 1e18, 0.05e18, 10, 0);
        // Chainlink types are uncapped meanwhile.
        assertEq(redeemer.windowLeft(ETH), type(uint256).max);
        (uint256 c,) = _redeem(ETH, 30_000e18);
        assertEq(c, 30_000e18);
    }

    /// @notice Edges: the window is never shorter than 2h (still full at +2h), and frees once the first
    /// bucket leaves the counted span (at most 2h10m).
    function test_windowRollsAtItsEdges() public {
        _redeem(SIMD, CAP);
        uint256 t0 = vm.getBlockTimestamp();
        _keepFresh(t0 + 2 hours);
        assertEq(redeemer.windowLeft(SIMD), 0, "freed before 2h");
        uint256 freeAt = (t0 / 10 minutes + 13) * 10 minutes;
        assertLe(freeAt - t0, 2 hours + 10 minutes);
        _keepFresh(freeAt - 1);
        assertEq(redeemer.windowLeft(SIMD), 0);
        _keepFresh(freeAt);
        assertEq(redeemer.windowLeft(SIMD), CAP);
        (uint256 r,) = _redeem(SIMD, CAP);
        assertEq(r, CAP);
    }

    /// @notice Whatever the timing of a series of redemptions, no 2h interval admits more than the cap.
    function testFuzz_noTwoHourIntervalExceedsTheCap(uint256 seed) public {
        uint256[] memory ts = new uint256[](12);
        uint256[] memory amt = new uint256[](12);
        uint256 n;
        for (uint256 i; i < 12; ++i) {
            uint256 step = uint256(keccak256(abi.encode(seed, i, "t"))) % 50 minutes;
            uint256 want = 1e18 + uint256(keccak256(abi.encode(seed, i, "a"))) % 12_000e18;
            _keepFresh(vm.getBlockTimestamp() + step);
            if (redeemer.windowLeft(SIMD) == 0) continue;
            (uint256 r,) = _redeem(SIMD, want);
            ts[n] = vm.getBlockTimestamp();
            amt[n] = r;
            ++n;
        }
        assertGt(n, 0);
        for (uint256 i; i < n; ++i) {
            uint256 sum;
            for (uint256 j; j < n; ++j) {
                if (ts[j] <= ts[i] && ts[i] - ts[j] <= 2 hours) sum += amt[j];
            }
            assertLe(sum, CAP, "a 2h interval admitted more than the cap");
        }
    }

    // ------------------------------------------------------------ per-type fees

    function test_baseRatesAreIndependentPerType() public {
        _keepFresh(vm.getBlockTimestamp() + 60 days); // past the launch decay: every base rate back to ~0
        uint256 ethBefore = redeemer.feeFor(ETH, 1_000e18);
        uint256 stableBefore = redeemer.feeFor(STABLE, 1_000e18);
        _redeem(SIMD, CAP);
        assertGt(redeemer.decayedBaseRate(SIMD), 0);
        assertEq(redeemer.decayedBaseRate(ETH), 0);
        assertEq(redeemer.decayedBaseRate(STABLE), 0);
        // Other types' fees moved only through the smaller supply, never through sIMD's base rate.
        uint256 supply = usd.totalSupply();
        assertEq(redeemer.feeFor(ETH, 1_000e18), 0.005e18 + uint256(1_000e18) * 1e18 / supply / 4);
        assertEq(redeemer.feeFor(STABLE, 1_000e18), 0.001e18 + uint256(1_000e18) * 1e18 / supply / 8);
        assertGe(redeemer.feeFor(ETH, 1_000e18), ethBefore);
        assertGe(redeemer.feeFor(STABLE, 1_000e18), stableBefore);
        assertGt(redeemer.feeFor(SIMD, 1_000e18), redeemer.feeFor(ETH, 1_000e18));
    }

    function test_stableFeeFloorIsTenBasisPoints() public {
        _keepFresh(vm.getBlockTimestamp() + 60 days); // past the launch decay
        uint256 f = redeemer.feeFor(STABLE, 1e18);
        assertEq(f, 0.001e18 + uint256(1e18) * 1e18 / usd.totalSupply() / 8);
        assertLt(f, 0.0011e18);
    }

    function test_feeNeverExceedsTheCap() public {
        assertEq(redeemer.feeFor(SIMD, usd.totalSupply()), 0.05e18);
        assertEq(redeemer.feeFor(STABLE, usd.totalSupply()), 0.05e18);
        (uint256 r,) = _redeem(ETH, 300_000e18);
        assertEq(r, 300_000e18);
        assertLe(redeemer.decayedBaseRate(ETH), 0.05e18);
        assertEq(redeemer.feeFor(ETH, 300_000e18), 0.05e18);
    }

    function test_redemptionBoundsAreEnforced() public {
        ParametersBase.Risk memory r = params.risk(SIMD);
        vm.startPrank(governor);
        r.redeemFloor = 0.0009e18;
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(1), SIMD, r));
        r.redeemFloor = 0.051e18;
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(1), SIMD, r));
        r.redeemFloor = 0.005e18;
        r.redeemDivisor = 0;
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(1), SIMD, r));
        r.redeemDivisor = 17;
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(1), SIMD, r));
        // A type with a live (manipulable) leg can never be uncapped.
        r.redeemDivisor = 2;
        r.redeemCap = 0;
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(uint8(1), SIMD, r));
        // A Chainlink type may be.
        ParametersBase.Risk memory e = params.risk(ETH);
        e.redeemCap = 0;
        params.propose(abi.encode(uint8(1), ETH, e));
        vm.stopPrank();
    }

    function test_capChangeGoesThroughTheTimelock() public {
        ParametersBase.Risk memory r = params.risk(SIMD);
        r.redeemCap = 5_000e18;
        vm.prank(governor);
        params.propose(abi.encode(uint8(1), SIMD, r));
        vm.expectRevert();
        params.applyPending();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        _keepFresh(vm.getBlockTimestamp());
        (uint256 got,) = _redeem(SIMD, 8_000e18);
        assertEq(got, 5_000e18);
    }

    // ------------------------------------------------------------ D4: minCollateralOut

    function test_minCollateralOutBoundsTheFill() public {
        uint256 snap = vm.snapshotState();
        (, uint256 out) = _redeem(ETH, 1_000e18);
        assertGt(out, 0);
        vm.revertToState(snap);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(Redeemer.CollateralTooLow.selector, out));
        redeemer.redeem(ETH, 1_000e18, 0.05e18, 10, out + 1);
        vm.prank(dave);
        (, uint256 got) = redeemer.redeem(ETH, 1_000e18, 0.05e18, 10, out);
        assertEq(got, out);
    }

    // ------------------------------------------------------------ C9: launch at the cap

    function test_baseRateStartsAtCapAndDecaysFromLaunch() public {
        uint256 cap = redeemer.FEE_CAP();
        uint256 launch = params.listedAt(ETH);
        assertEq(launch, params.sealedAt(), "a genesis type goes live at the seal");
        assertEq(redeemer.decayedBaseRate(ETH), cap, "0h: at the cap");
        assertEq(redeemer.decayedBaseRate(STABLE), cap);
        assertEq(redeemer.decayedBaseRate(SIMD), cap);
        assertEq(redeemer.feeFor(ETH, 1e18), cap, "the fee is capped at launch");
        _keepFresh(launch + 12 hours);
        assertApproxEqRel(redeemer.decayedBaseRate(ETH), cap / 2, 0.001e18, "12h: one half-life");
        _keepFresh(launch + 40 hours);
        // 5% x 2^(-40/12) = 0.496%
        assertApproxEqRel(redeemer.decayedBaseRate(ETH), 0.00496e18, 0.002e18, "40h: ~0.5%");
        uint256 f = redeemer.feeFor(STABLE, 1e18);
        assertApproxEqRel(f, 0.001e18 + 0.00496e18, 0.002e18, "floor + decayed base");
        // A redemption starts from the decayed launch rate, not from zero.
        uint256 before = redeemer.decayedBaseRate(ETH);
        _redeem(ETH, 1_000e18);
        assertGe(redeemer.decayedBaseRate(ETH), before);
        (, uint64 at) = redeemer.rates(ETH);
        assertEq(at, block.timestamp);
    }

    function test_typeAddedLaterStartsAtCap() public {
        _keepFresh(vm.getBlockTimestamp() + 10 days);
        ParametersBase.Config memory c = params.config(ETH);
        Join j = new Join(c.token, address(this));
        j.wire(address(ledger));
        c.join = address(j);
        bytes32 NEW = "ETH-2";
        bytes memory add = abi.encode(params.ADD_ILK(), NEW, c, params.risk(ETH));
        vm.prank(governor);
        params.propose(add);
        _keepFresh(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        assertEq(params.listedAt(NEW), block.timestamp, "a later type goes live when added");
        assertEq(redeemer.decayedBaseRate(NEW), redeemer.FEE_CAP());
        assertLt(redeemer.decayedBaseRate(ETH), 1e12, "the genesis type has long decayed (12 days: ~3e-9)");
        _keepFresh(vm.getBlockTimestamp() + 12 hours);
        assertApproxEqRel(redeemer.decayedBaseRate(NEW), redeemer.FEE_CAP() / 2, 0.001e18);
    }

    function _keepFresh(uint256 t) internal {
        vm.warp(t);
        ethFeed.set(ethFeed.value());
        usdxFeed.set(usdxFeed.value());
        simdMedian.set(simdMedian.value());
        simdSpot.set(simdSpot.value());
        nhi.set(nhi.value());
    }
}
