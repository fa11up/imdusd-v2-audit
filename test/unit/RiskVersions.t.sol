// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {System} from "../utils/System.sol";
import {SeatSystem} from "../utils/SeatSystem.sol";
import {MockERC20, MockFeed, MockSeatFeed} from "../utils/Mocks.sol";
import {MockSeatNFT, MockAgentAdapter} from "../utils/SeatMocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {GovernedByKind} from "../../src/GovernedByKind.sol";
import {Ledger, Adjust} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {_pid} from "../utils/Pid.sol";
import {Pricer} from "../../src/Pricer.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";

/// @notice Versioned liquidation risk. A position stays on the mat/chop it last took risk under until a
/// newer version binds (at once if kinder, after RISK_GRACE if stricter).
contract RiskVersionsTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";

    MockERC20 weth;
    MockERC20 simd;
    MockFeed ethMedian;
    MockFeed ethSpot;
    MockFeed simdFeed;
    MockFeed nhi;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dave = makeAddr("dave");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        simd = new MockERC20("sIMD", 18);
        ethMedian = new MockFeed(2000e18);
        ethSpot = new MockFeed(2000e18);
        simdFeed = new MockFeed(5e18);
        nhi = new MockFeed(0.98e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethMedian, ethSpot, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1_000_000e18));
        ParametersBase.Risk memory ir = _risk(1.7e18, 1_000_000e18);
        ir.chop = 0.2e18;
        _addIlk(SIMD, address(simd), simdFeed, simdFeed, nhi, address(0), address(0), true, ir);
        params.seal();
        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, dave][i];
            weth.mint(u, 1000e18);
            simd.mint(u, 100_000e18);
            vm.startPrank(u);
            weth.approve(address(ledger), type(uint256).max);
            simd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _refresh() internal {
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
        simdFeed.set(simdFeed.value());
        nhi.set(nhi.value());
    }

    mapping(uint256 => bool) internal _opened;

    function _adjust(address u, bytes32 ilk, int256 coll, int256 debt, uint64 rate) internal {
        Adjust memory a = Adjust(coll, debt, rate, 0, 0, false, type(uint256).max, address(0));
        uint256 id = _pid(ilk, u);
        bool exists = _opened[id]; // no extra external call: a caller's vm.expectRevert must hit the action itself
        vm.prank(u);
        if (exists) ledger.adjust(id, a);
        else ledger.open(ilk, 0, a);
        _opened[id] = ledger.ilkOf(id) != bytes32(0); // read after the action, so an expected revert is not counted
    }

    function _propose(bytes memory payload) internal {
        vm.prank(governor);
        params.propose(payload);
    }

    function _ethTo(uint256 p) internal {
        ethMedian.set(p);
        ethSpot.set(p);
    }

    function _setRisk(bytes32 ilk, ParametersBase.Risk memory r) internal {
        _propose(abi.encode(params.SET_RISK(), ilk, r));
        _skip(48 hours);
        params.applyPending();
        _refresh();
    }

    function _ethRisk(uint64 mat, uint64 chop) internal view returns (ParametersBase.Risk memory r) {
        r = params.storedRisk(ETH);
        r.mat = mat;
        r.chop = chop;
    }

    function _version(bytes32 ilk, address u) internal view returns (uint256) {
        return ledger.position(_pid(ilk, u)).version;
    }

    // ================================================================ stricter: grandfathered for RISK_GRACE

    function test_stricterMatDoesNotAmbushOpenPositions() public {
        // 10 ETH at $2,000 = $20,000 against ~13,500: ~148%, healthy at 140%.
        _adjust(alice, ETH, 10e18, 13_500e18, 0.05e18);
        assertEq(params.riskVersion(ETH), 0);
        assertEq(_version(ETH, alice), 0);
        _setRisk(ETH, _ethRisk(1.6e18, 0.1e18));
        assertEq(params.riskVersion(ETH), 1, "a mat change makes a version");
        // Alice is still on v0: healthy at 140% though v1 says 160%.
        (bool ok,) = ledger.healthy(_pid(ETH, alice));
        assertTrue(ok, "grandfathered");
        (uint256 m,) = params.liqRisk(ETH, 0);
        assertEq(m, 1.4e18);
        // A newcomer is measured at the newest version.
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(bob, ETH, 10e18, 13_500e18, 0.05e18);
        // Alice taking on more risk rebinds her to v1, where she is unhealthy: refused.
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, 0, 100e18, 0.05e18);
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        _adjust(alice, ETH, -0.1e18, 0, 0.05e18);
        // Adding collateral is not risk: she keeps v0.
        _adjust(alice, ETH, 0.1e18, 0, 0.05e18);
        assertEq(_version(ETH, alice), 0);
        // After the grace, v1 binds everyone.
        _skip(params.RISK_GRACE());
        _refresh();
        (m,) = params.liqRisk(ETH, 0);
        assertEq(m, 1.6e18, "v1 binds after the grace");
        (ok,) = ledger.healthy(_pid(ETH, alice));
        assertFalse(ok, "now under 160%");
    }

    function test_takingRiskRebindsWhenHealthyThere() public {
        _adjust(alice, ETH, 10e18, 5_000e18, 0.05e18);
        _setRisk(ETH, _ethRisk(1.6e18, 0.1e18));
        _adjust(alice, ETH, 0, 1_000e18, 0.05e18); // 333%: fine at 160%
        assertEq(_version(ETH, alice), 1, "rebound to the newest version");
    }

    // ================================================================ kinder: binds at once

    function test_kinderChangeBindsAtOnce() public {
        _adjust(alice, ETH, 10e18, 13_500e18, 0.05e18); // ~148%
        _ethTo(1_870e18); // ~138.5%: unhealthy at 140%
        (bool ok,) = ledger.healthy(_pid(ETH, alice));
        assertFalse(ok);
        _setRisk(ETH, _ethRisk(1.3e18, 0.1e18));
        _ethTo(1_870e18);
        (ok,) = ledger.healthy(_pid(ETH, alice));
        assertTrue(ok, "a lower mat helps at once, with no action by the borrower");
        assertEq(_version(ETH, alice), 0, "no transaction was needed");
    }

    // ================================================================ liquidation: the bound version's penalty

    function test_liquidationUsesTheBoundChop() public {
        _adjust(alice, ETH, 10e18, 10_000e18, 0.02e18);
        _adjust(dave, ETH, 200e18, 50_000e18, 0.05e18); // the liquidator's imdUSD
        uint256 base = vm.snapshotState();
        _ethTo(1_300e18); // 130% < 140%
        vm.prank(dave);
        (uint256 r0, uint256 s0,) = liquidator.liquidate(_pid(ETH, alice));
        vm.revertToState(base);
        // A higher penalty (and the same mat): stricter, so it waits; alice's liquidation still uses chop 10%.
        _setRisk(ETH, _ethRisk(1.4e18, 0.2e18));
        _ethTo(1_300e18);
        vm.prank(dave);
        (uint256 r1, uint256 s1,) = liquidator.liquidate(_pid(ETH, alice));
        assertApproxEqRel(r1, r0, 0.001e18, "same debt repaid (only interest over the wait differs)");
        assertApproxEqRel(s1, s0, 0.001e18, "seized with the bound 10% penalty, not 20%");
        assertGt(s0, 0);
    }

    // ================================================================ NHI types: mat live, chop versioned

    function test_nhiTypeKeepsLiveMatAndVersionsChop() public {
        (uint256 m, uint256 c) = params.liqRisk(SIMD, 0);
        assertEq(m, 0, "NHI type: the caller uses the live NHI mat");
        assertEq(c, 0.2e18);
        _adjust(alice, SIMD, 10_000e18, 25_000e18, 0.05e18); // $50,000: 200%, healthy at NHI 0.98 (170%)
        (bool ok,) = ledger.healthy(_pid(SIMD, alice));
        assertTrue(ok);
        nhi.set(0.6e18); // NHI <= 0.60: mat 200%, at once (a market signal, not a governance change)
        (ok,) = ledger.healthy(_pid(SIMD, alice));
        assertFalse(ok, "NHI mat binds live, as in v1");
        ParametersBase.Risk memory r = params.storedRisk(SIMD);
        r.chop = 0.25e18;
        nhi.set(0.98e18);
        _setRisk(SIMD, r);
        (, c) = params.liqRisk(SIMD, 0);
        assertEq(c, 0.2e18, "a higher chop waits for the grace");
        _skip(params.RISK_GRACE());
        (, c) = params.liqRisk(SIMD, 0);
        assertEq(c, 0.25e18);
    }

    // ================================================================ what makes a version

    function test_onlyMatOrChopMakeAVersion() public {
        ParametersBase.Risk memory r = params.storedRisk(ETH);
        r.line = 500_000e18;
        _setRisk(ETH, r);
        assertEq(params.riskVersion(ETH), 0, "a line change is not a liquidation-risk version");
        r.mat = 1.5e18;
        _setRisk(ETH, r);
        assertEq(params.riskVersion(ETH), 1);
        vm.prank(governor);
        params.lowerLine(ETH, 100_000e18);
        assertEq(params.riskVersion(ETH), 1, "instant lowers of new-debt limits make no version");
    }

    /// A stale version id (a position bound before a later version) never reads past the list.
    function test_liqRiskAcrossManyVersions() public {
        _setRisk(ETH, _ethRisk(1.5e18, 0.1e18)); // v1 stricter: binds at +7d
        _setRisk(ETH, _ethRisk(1.45e18, 0.1e18)); // v2 kinder than v1 but stricter than v0: waits too
        (uint256 m,) = params.liqRisk(ETH, 0);
        assertEq(m, 1.4e18, "v0 positions keep v0 until the softened raise binds");
        (m,) = params.liqRisk(ETH, 99);
        assertEq(m, 1.45e18, "an out-of-range id reads the newest");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (m,) = params.liqRisk(ETH, 0);
        assertEq(m, 1.45e18, "then the newest bound version wins (v1 never binds on its own)");
        _setRisk(ETH, _ethRisk(1.42e18, 0.1e18)); // kinder than the version in force and nothing pending: binds now
        (m,) = params.liqRisk(ETH, 0);
        assertEq(m, 1.42e18);
    }
}
