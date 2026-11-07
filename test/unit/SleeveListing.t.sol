// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {GovernedByKind} from "../../src/GovernedByKind.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {ILedgerCover, IBackstopOracle} from "../../src/backstop/IBackstop.sol";
import {PricerOracle} from "../../src/backstop/PricerOracle.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Join} from "../../src/Join.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";

/// @notice A type listed after launch can still get a standing bid. PricerOracle maps NEW tokens only, and after
/// its seal only through Parameters' timelocked ADD_SLEEVE_ILK; uncovering is instant by the governor.
contract SleeveListingTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant WBTC = "WBTC"; // registered at genesis, NOT covered at genesis
    bytes32 constant SIMD = "SIMD";
    bytes32 constant LATE = "LATE"; // an edge-kind type, covered later

    MockERC20 weth;
    MockERC20 wbtc;
    MockERC20 simd;
    MockERC20 late;
    PricerOracle oracle;
    Backstop blue;
    Backstop edge;

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        wbtc = new MockERC20("WBTC", 8);
        simd = new MockERC20("sIMD", 18);
        late = new MockERC20("LATE", 18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        MockFeed f = new MockFeed(2000e18);
        _addIlk(ETH, address(weth), f, f, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1_000_000e18));
        _addIlk(WBTC, address(wbtc), f, f, IFeed(address(0)), address(0), address(0), true, _risk(1.5e18, 1_000_000e18));
        ParametersBase.Risk memory ir = _risk(1.7e18, 1_000_000e18);
        ir.chop = 0.2e18;
        _addIlk(SIMD, address(simd), f, f, IFeed(address(0)), address(0), address(0), true, ir);
        _addIlk(LATE, address(late), f, f, IFeed(address(0)), address(0), address(0), true, ir);

        oracle = new PricerOracle(pricer, address(params));
        oracle.setIlk(address(weth), ETH);
        oracle.setIlk(address(simd), SIMD);
        oracle.seal();
        blue = new Backstop(IERC20(address(usd)), ILedgerCover(address(ledger)), IBackstopOracle(address(oracle)), false, "blue", "bB");
        edge = new Backstop(IERC20(address(usd)), ILedgerCover(address(ledger)), IBackstopOracle(address(oracle)), true, "edge", "bE");
        blue.wire(address(liquidator), address(params), address(0));
        edge.wire(address(liquidator), address(params), address(0));
        blue.addIlk(ETH, address(weth), 0, 1e30, 0);
        edge.addIlk(SIMD, address(simd), 20_000e18, 1e30, 0);
        blue.seal();
        edge.seal();
        params.setGenesisBackstops(address(blue), address(edge), 0.2e18);
        params.setGenesisEdgeIlk(SIMD);
        params.seal();
    }

    function _list(bytes32 ilk, bool isEdge, uint128 genesisLine) internal {
        bytes memory p = abi.encode(params.ADD_SLEEVE_ILK(), ilk, isEdge, genesisLine, uint128(2e8), uint128(uint256(2e8) / 1 days));
        vm.prank(governor);
        params.propose(p);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending(params.ADD_SLEEVE_ILK());
    }

    function test_oracleMapsNewTokensOnlyAndOnlyThroughParametersAfterSeal() public {
        vm.expectRevert(PricerOracle.Unauthorized.selector);
        oracle.setIlk(address(wbtc), WBTC); // the deployer has no power after the seal
        vm.prank(address(params));
        oracle.setIlk(address(wbtc), WBTC);
        assertEq(oracle.ilkOf(address(wbtc)), WBTC);
        vm.prank(address(params));
        vm.expectRevert(PricerOracle.Exists.selector);
        oracle.setIlk(address(wbtc), LATE); // never repointed
        vm.prank(address(params));
        vm.expectRevert(PricerOracle.Exists.selector);
        oracle.setIlk(address(weth), WBTC);
    }

    function test_addSleeveIlkCoversALaterType() public {
        (address listed,,,) = blue.ilks(WBTC);
        assertEq(listed, address(0), "not covered at genesis");
        _list(WBTC, false, 0);
        (address t,, uint128 gl, bool on) = blue.ilks(WBTC);
        assertTrue(t == address(wbtc) && on, "listed in blue");
        assertEq(gl, 0, "blue has no bootstrap");
        assertEq(oracle.ilkOf(address(wbtc)), WBTC, "oracle maps the token");
        assertFalse(params.edgeIlk(WBTC), "blue type is not edge");
        assertGt(blue.bidRoom(WBTC) + 1, 0);
    }

    function test_addSleeveIlkEdgeFlagsTheType() public {
        _list(LATE, true, 5_000e18);
        (address t,, uint128 gl, bool on) = edge.ilks(LATE);
        assertTrue(t == address(late) && on);
        assertEq(gl, 5_000e18, "bootstrap allowance");
        assertTrue(params.edgeIlk(LATE), "edge type: first loss, premium, summed capacity");
        assertEq(params.edgeIlkCount(), 2);
    }

    function test_addSleeveIlkValidation() public {
        uint8 k = params.ADD_SLEEVE_ILK(); // read first: an expectRevert must hit propose itself
        vm.startPrank(governor);
        vm.expectRevert(ParametersBase.UnknownIlk.selector);
        params.propose(abi.encode(k, bytes32("NOPE"), false, uint128(0), uint128(1), uint128(0)));
        vm.expectRevert(ParametersBase.BadConfig.selector); // ETH is already in blue
        params.propose(abi.encode(k, ETH, false, uint128(0), uint128(1), uint128(0)));
        vm.expectRevert(ParametersBase.BadConfig.selector); // SIMD sits in edge: never in two sleeves
        params.propose(abi.encode(k, SIMD, false, uint128(0), uint128(1), uint128(0)));
        vm.stopPrank();
    }

    function test_disableSleeveIlkIsInstantAndGovernorOnly() public {
        vm.expectRevert(GovernedByKind.NotGovernor.selector);
        params.disableSleeveIlk(ETH, false);
        vm.prank(governor);
        params.disableSleeveIlk(ETH, false);
        (,,, bool on) = blue.ilks(ETH);
        assertFalse(on, "no standing bid on ETH");
        assertEq(blue.bidRoom(ETH), 0);
    }

    /// Disabling an edge type used to be final (no re-listing; its borrowing frozen for good).
    /// The same timelocked ADD_SLEEVE_ILK now lists it again.
    function test_disabledSleeveIlkCanBeRelisted() public {
        vm.prank(governor);
        params.disableSleeveIlk(SIMD, true);
        assertEq(edge.edgeCapacity(SIMD, 0), 0, "disabled: no edge capacity");
        _list(SIMD, true, 7_000e18);
        (address t,, uint128 gl, bool on) = edge.ilks(SIMD);
        assertTrue(t == address(simd) && on, "re-listed");
        assertEq(gl, 7_000e18, "fresh bootstrap");
        assertEq(edge.edgeCapacity(SIMD, 0), 7_000e18);
        assertEq(params.edgeIlkCount(), 1, "not flagged twice");
        assertEq(edge.ilkList(0), SIMD);
        vm.expectRevert();
        edge.ilkList(1); // not listed twice
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.BadConfig.selector); // live again: not re-listable
        params.propose(abi.encode(k, SIMD, true, uint128(0), uint128(1), uint128(0)));
    }

    // ---------------------------------------------------------------- listing checked at propose

    /// (a) The blue sleeve holds at most MAX_TOKENS tokens (mainnet lists six at genesis). A listing of a NEW token
    /// in a full sleeve used to pass propose and revert TooManyTokens at apply, holding the slot; now it is refused at
    /// propose. A type whose token the sleeve already holds still lists.
    function test_panelG3_fullSleeveRefusedAtPropose() public {
        for (uint256 i; i < 5; ++i) {
            MockERC20 t = new MockERC20("FILL", 18);
            vm.prank(address(params));
            blue.addIlk(bytes32(uint256(0x100 + i)), address(t), 0, 1e30, 0);
        }
        assertEq(blue.tokenCount(), blue.MAX_TOKENS(), "blue is full");
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, WBTC, false, uint128(0), uint128(1), uint128(0)));
    }

    /// (b) An edge listing of a type that already carries debt adds it to every edge type's SUM bound. Above the
    /// edge sleeve's capacity that froze sIMD borrowing at apply; now it is refused at propose. Within capacity it lists.
    function test_panelG3_edgeListingOverCapacityRefused() public {
        address alice = makeAddr("alice");
        late.mint(alice, 100e18);
        vm.startPrank(alice);
        late.approve(address(ledger), type(uint256).max);
        ledger.open(LATE, 0, Adjust(int256(10e18), int256(5_000e18), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, LATE, true, uint128(1_000e18), uint128(2e8), uint128(0))); // capacity 1,000 < 5,000 debt
        _list(LATE, true, 10_000e18); // within the 10,000 bootstrap and SIMD's ~20,000: lists
        assertTrue(params.edgeIlk(LATE));
    }

    // ---------------------------------------------------------------- re-check: listing and re-listing

    function _borrowOn(bytes32 ilk, MockERC20 token, string memory who, uint256 debt) private {
        MockFeed(address(params.config(ilk).median)).set(2000e18); // fresh after any timelock's warp
        address a = makeAddr(who);
        token.mint(a, 100e18);
        vm.startPrank(a);
        token.approve(address(ledger), type(uint256).max);
        ledger.open(ilk, 0, Adjust(int256(10e18), int256(debt), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
    }

    /// With debt on the type: a disabled edge type re-lists. Its own debt counts once and its own capacity of 0
    /// (it is disabled) does not refuse it.
    function test_RD_relistDisabledEdgeTypeWithDebt() public {
        _borrowOn(SIMD, simd, "simdBorrower", 5_000e18);
        vm.prank(governor);
        params.disableSleeveIlk(SIMD, true);
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector); // 5,000 debt over a 4,000 line: still bounded
        params.propose(abi.encode(k, SIMD, true, uint128(4_000e18), uint128(2e8), uint128(0)));
        _list(SIMD, true, 6_000e18); // fits only if its debt is counted once (5,000; twice would be 10,000)
        (,,, bool on) = edge.ilks(SIMD);
        assertTrue(on, "re-listed");
        assertEq(params.edgeIlkCount(), 1);
        _borrowOn(SIMD, simd, "simdBorrower2", 500e18); // the Ledger's own sum bound agrees: it can borrow again
    }

    /// A disabled edge type no longer blocks listing another edge type with debt: its capacity of 0 is no bound on anyone.
    function test_RD_disabledEdgeTypeDoesNotBlockOtherListing() public {
        _borrowOn(SIMD, simd, "simdBorrower", 5_000e18);
        _borrowOn(LATE, late, "lateBorrower", 1_000e18);
        vm.prank(governor);
        params.disableSleeveIlk(SIMD, true);
        _list(LATE, true, 7_000e18);
        assertTrue(params.edgeIlk(LATE));
        _borrowOn(LATE, late, "lateBorrower2", 500e18);
    }

    /// But a disabled type's debt still counts: the Ledger's SUM bound (`_checkEdge`) reads every edge type, so a listing
    /// that fits only by ignoring it would stop borrowing on the new type at once.
    function test_RD_disabledEdgeTypeDebtStillCounts() public {
        _borrowOn(SIMD, simd, "simdBorrower", 5_000e18);
        _borrowOn(LATE, late, "lateBorrower", 1_000e18);
        vm.prank(governor);
        params.disableSleeveIlk(SIMD, true);
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, LATE, true, uint128(2_000e18), uint128(2e8), uint128(0))); // 6,000 sum over a 2,000 line
    }

    // ---------------------------------------------------------------- re-check: a reverting feed and the instant cap

    /// The recheck's PoC turned round. The emergency lever must work exactly when a feed misbehaves. Unreadable, the 1/100
    /// floor does not apply (no live low to compare with).
    function test_RD_lowerCapOnRevertingFeed() public {
        ParametersBase.Config memory c = params.config(ETH);
        vm.mockCallRevert(address(c.median), abi.encodeWithSelector(IFeed.latestValue.selector), "feed down");
        vm.prank(governor);
        params.lowerCap(ETH, 1e18); // far under 1/100 of the last price
        assertEq(params.cap(ETH), 1e18);
    }

    function test_RD_lowerCapOnFeedWhoseStaleReadReverts() public {
        ParametersBase.Config memory c = params.config(ETH);
        vm.mockCallRevert(address(c.median), abi.encodeWithSelector(IFeed.isStale.selector), "feed down");
        vm.prank(governor);
        params.lowerCap(ETH, 1e18);
        assertEq(params.cap(ETH), 1e18);
    }

    /// Only the spot leg down: the median still reads, so the unit-error floor still applies.
    function test_RD_lowerCapSpotDownKeepsTheFloor() public {
        MockFeed spot = new MockFeed(2000e18);
        bytes32 two = "TWOLEGS";
        _addTwoLegType(two, spot);
        (uint256 m,) = params.config(two).median.latestValue();
        vm.mockCallRevert(address(spot), abi.encodeWithSelector(IFeed.latestValue.selector), "spot down");
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.lowerCap(two, m / 100 - 1);
        vm.prank(governor);
        params.lowerCap(two, m / 100);
        assertEq(params.cap(two), m / 100);
    }

    function _addTwoLegType(bytes32 ilk, MockFeed spot) private {
        MockERC20 t = new MockERC20("TWO", 18);
        bytes memory add = abi.encode(
            params.ADD_ILK(),
            ilk,
            _twoLegConfig(t, spot),
            _risk(1.5e18, 1_000_000e18)
        );
        vm.prank(governor);
        params.propose(add);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending(params.ADD_ILK());
        spot.set(2000e18);
        MockFeed(address(params.config(ilk).median)).set(2000e18);
    }

    function _twoLegConfig(MockERC20 t, MockFeed spot) private returns (ParametersBase.Config memory) {
        Join j = new Join(address(t), address(this));
        j.wire(address(ledger));
        return ParametersBase.Config({
            token: address(t),
            join: address(j),
            median: IFeed(address(new MockFeed(2000e18))),
            spot: IFeed(address(spot)),
            nhi: IFeed(address(0)),
            yieldRate: address(0),
            pegAggregator: address(0),
            liveSpot: IFeed(address(0)),
            redeemable: true,
            auction: false
        });
    }

    /// SET_CAP past 2x needs a readable low; with the feed down a raise stays within 2x, and validates rather than reverts.
    function test_RD_setCapOnRevertingFeed() public {
        vm.prank(governor);
        params.lowerCap(ETH, 1_000e18);
        ParametersBase.Config memory c = params.config(ETH);
        vm.mockCallRevert(address(c.median), abi.encodeWithSelector(IFeed.latestValue.selector), "feed down");
        uint8 k = params.SET_CAP();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(abi.encode(k, ETH, uint256(2_001e18)));
        vm.prank(governor);
        params.propose(abi.encode(k, ETH, uint256(2_000e18)));
    }

    /// Second re-check: the instant disable cancels a pending re-list of that type, or anyone's applyPending turns the bid on.
    function test_R2_disableCancelsPendingRelist() public {
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.startPrank(governor);
        params.disableSleeveIlk(SIMD, true);
        params.propose(abi.encode(k, SIMD, true, uint128(0), uint128(1e27), uint128(1e22)));
        params.disableSleeveIlk(SIMD, true); // the incident
        vm.stopPrank();
        (, uint256 eta) = params.pendingOf(k);
        assertEq(eta, 0, "cancelled");
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(GovernedByKind.NothingPending.selector);
        params.applyPending(k);
    }

    function test_R2_disableLeavesAnotherTypesListing() public {
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.startPrank(governor);
        params.propose(abi.encode(k, WBTC, false, uint128(0), uint128(1e27), uint128(1e22)));
        params.disableSleeveIlk(ETH, false);
        vm.stopPrank();
        (, uint256 eta) = params.pendingOf(k);
        assertGt(eta, 0, "another type's listing stays");
    }

    /// Second re-check: the listing's room reads netVested, as edgeCapacity does. Booked bad debt stands behind nothing.
    function test_R2_edgeListingRoomNetsBookedBadDebt() public {
        address fundr = makeAddr("funder");
        weth.mint(fundr, 100e18);
        vm.startPrank(fundr);
        weth.approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(int256(10e18), int256(3_000e18), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        usd.approve(address(edge), type(uint256).max);
        edge.deposit(3_000e18, fundr);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        edge.realize(fundr);
        _borrowOn(LATE, late, "lateBorrower", 1_000e18);
        vm.mockCall(
            address(ledger),
            abi.encodeWithSignature("ilkState(bytes32)", SIMD),
            abi.encode(uint128(0), uint128(0), uint256(0), uint64(0), uint128(2_900e18))
        );
        uint8 k = params.ADD_SLEEVE_ILK();
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector); // vested 3,000 would give 9,000 of room; net of the loss ~300
        params.propose(abi.encode(k, LATE, true, uint128(500e18), uint128(2e8), uint128(0)));
    }
}
