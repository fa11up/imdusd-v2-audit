// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";
import {SwarmImdDepthFeed} from "../../src/feeds/SwarmFeeds.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";

contract MockDepth {
    uint256 public depth;
    address public manager = address(1);

    /// @dev Each mock stands for its own pool (ImdDepth lists one sampler per pool).
    function poolId() external view returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }

    function set(uint256 d) external {
        depth = d;
    }
}

contract RevertingDepth {
    address public manager = address(1);

    function poolId() external view returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }

    function depth() external pure returns (uint256) {
        revert("broken");
    }
}

/// @notice The k-rule's IMD depth is MEASURED (Σ samplers, 7-day low, min'd with the swarm leg), the posted
/// figure is only a lower-only cap, and the rule binds live through risk(depthIlk).line.
contract DepthMeasuredTest is System {
    bytes32 constant SIMD = "SIMD";
    bytes32 constant ETH = "ETH";

    ImdDepth depthOracle;
    MockDepth s1;
    MockDepth s2;
    MockFeed price;
    MockERC20 simd;
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        price = new MockFeed(5e18);
        price.setMaxAge(365 days);
        simd = new MockERC20("sIMD", 18);
        ParametersBase.Risk memory r = _risk(1.7e18, 0);
        r.chop = 0.2e18;
        r.redeemCap = 20_000e18;
        _addIlk(SIMD, address(simd), price, price, IFeed(address(0)), address(0), address(0), true, r);
        _addIlk(ETH, address(new MockERC20("WETH", 18)), price, price, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1e24));
        depthOracle = new ImdDepth(address(params));
        s1 = new MockDepth();
        s2 = new MockDepth();
        address[] memory list = new address[](2);
        (list[0], list[1]) = (address(s1), address(s2));
        params.setGenesisImdDepth(address(depthOracle), list);
        params.setGenesisDepthRule(SIMD, 0.8e18, 0, 0, 0); // no posted cap: depth is measured only
        params.seal();
        simd.mint(bob, 1_000_000e18);
        vm.prank(bob);
        simd.approve(address(ledger), type(uint256).max);
    }

    /// @dev `n` days of hourly-ish pokes at the samplers' current readings (one poke a day is enough for a low).
    function _days(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            depthOracle.poke();
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        depthOracle.poke();
        price.set(price.value());
    }

    /// @dev Propose, then wait 48h while the keeper keeps poking (a silent day would read as zero depth).
    function _gov(bytes memory payload) internal {
        vm.prank(governor);
        params.propose(payload);
        _days(2);
    }

    function _lineTo(uint128 line) internal view returns (bytes memory) {
        ParametersBase.Risk memory r = params.storedRisk(SIMD);
        r.line = line;
        return abi.encode(params.SET_RISK(), SIMD, r);
    }

    function test_depthIsTheSumOfSamplers() public {
        s1.set(50_000e18);
        s2.set(30_100e18);
        assertEq(depthOracle.sampled(), 80_100e18);
        _days(7);
        assertEq(depthOracle.depth(), 80_100e18);
        assertEq(params.depthIMD(), 80_100e18);
        (,, uint256 room) = params.depthRule();
        assertEq(room, 64_080e18);
    }

    function test_freshDeploymentReadsZeroUntilAWeekOfLows() public {
        s1.set(80_100e18);
        assertEq(params.depthIMD(), 0, "no past lows yet");
        _days(5);
        assertEq(params.depthIMD(), 0, "five past days is not a week");
        _days(1);
        assertEq(params.depthIMD(), 80_100e18);
    }

    function test_aSilentDayReadsZeroAndTheLowIsTheWeeksMinimum() public {
        s1.set(80_100e18);
        _days(7);
        s1.set(40_000e18);
        _days(1); // one thin day
        s1.set(90_000e18);
        _days(1);
        assertEq(params.depthIMD(), 40_000e18, "the thin day's low holds for a week");
        vm.warp(vm.getBlockTimestamp() + 2 days); // no pokes for two days
        assertEq(params.depthIMD(), 0, "a past day with no low fails closed");
    }

    function test_postedCapOnlyLowersInstantRaiseTimelocked() public {
        s1.set(80_100e18);
        _days(7);
        vm.prank(governor);
        params.postLowerDepth(60_000e18);
        assertEq(params.depthIMD(), 60_000e18);
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.postLowerDepth(70_000e18); // not lower
        vm.expectRevert();
        params.postLowerDepth(1); // not the governor
        // Clearing (or raising) the cap waits 48h.
        _gov(abi.encode(params.SET_DEPTH(), uint256(0)));
        params.applyPending(params.SET_DEPTH());
        assertEq(params.depthIMD(), 80_100e18);
    }

    function test_ruleBindsLiveNoNewDebtAtZeroDepthButRepayWorks() public {
        s1.set(80_100e18);
        _days(7);
        _gov(_lineTo(36_733e18)); // 36,733 x 1.2 + 20k <= 64,080
        params.applyPending(params.SET_RISK());
        assertEq(params.risk(SIMD).line, 36_733e18);
        vm.prank(bob);
        uint256 id = ledger.open(SIMD, 0, Adjust(10_000e18, 10_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        // Depth falls: the live line follows at once.
        s1.set(50_000e18);
        assertEq(uint256(params.risk(SIMD).line), uint256(40_000e18 - 20_000e18) * 1e18 / 1.2e18);
        assertEq(params.storedRisk(SIMD).line, 36_733e18, "the stored line is untouched");
        // Samples stop: depth 0, line 0, no new debt.
        s1.set(0);
        assertEq(params.depthIMD(), 0);
        assertEq(params.risk(SIMD).line, 0);
        vm.prank(bob);
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        ledger.adjust(id, Adjust(0, 1e18, 0, 0, 0, false, type(uint256).max, address(0)));
        // Repaying still works.
        vm.prank(bob);
        ledger.adjust(id, Adjust(0, -1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        assertLt(ledger.debtOf(id), 10_100e18);
    }

    function test_samplerListingTimelockedRemovalInstant() public {
        MockDepth s3 = new MockDepth();
        s3.set(1e18);
        bytes memory add = abi.encode(params.ADD_DEPTH_SAMPLER(), address(s3));
        uint8 kind = params.ADD_DEPTH_SAMPLER();
        vm.prank(governor);
        params.propose(add);
        vm.expectRevert();
        params.applyPending(kind); // not before 48h
        _days(2);
        params.applyPending(kind);
        assertEq(depthOracle.samplers().length, 3);
        vm.expectRevert();
        params.removeDepthSampler(address(s3)); // not the governor
        vm.prank(governor);
        params.removeDepthSampler(address(s3));
        assertEq(depthOracle.samplers().length, 2);
        vm.expectRevert(ImdDepth.Unauthorized.selector);
        depthOracle.addSampler(address(s3)); // only Parameters lists
    }

    function test_attestedLegIsMinnedInAndFailsClosed() public {
        s1.set(80_100e18);
        _days(7);
        MockFeed leg = new MockFeed(20e18); // 20 ETH (wei)
        MockFeed ethUsd = new MockFeed(2_000e18);
        leg.setMaxAge(365 days);
        ethUsd.setMaxAge(365 days);
        _gov(abi.encode(params.SET_DEPTH_LEG(), address(leg), address(ethUsd)));
        params.applyPending(params.SET_DEPTH_LEG());
        assertEq(depthOracle.attested(), 40_000e18);
        assertEq(params.depthIMD(), 40_000e18, "min(sampled 80,100, attested 40,000)");
        leg.set(100e18); // attested 200k: the sampler binds
        assertEq(params.depthIMD(), 80_100e18);
        leg.setStale(true);
        assertEq(params.depthIMD(), 0, "a configured leg that goes stale fails closed");
    }

    function test_aRevertingSamplerCountsZeroAndNothingReverts() public {
        s1.set(80_100e18);
        RevertingDepth bad = new RevertingDepth();
        bytes memory add = abi.encode(params.ADD_DEPTH_SAMPLER(), address(bad));
        _gov(add);
        params.applyPending(params.ADD_DEPTH_SAMPLER());
        _days(7);
        assertEq(depthOracle.sampled(), 80_100e18);
        assertEq(params.depthIMD(), 80_100e18);
        params.risk(SIMD); // never reverts
    }

    /// The swarm leg's question is the plane's own document
    /// (questionDocument + canonical JSON from plane branch recipe/univ4-depth): same hash for the same window.
    function test_swarmLegQuestionMatchesThePlane() public {
        SwarmImdDepthFeed f = new SwarmImdDepthFeed(1 days, 9_000);
        assertEq(f.expectedQuestionHash(26300000, 26307200), 0xbec8d448de58ddbb07c00e11747dfbe4a7487fb43fd80bfd083e52ac5986dc13);
    }

    // ------------------------------------------------------------ the depth read is only for the line

    /// Gas audit: the depth rule is read only where `line` is compared. Everything else reads the stored risk, so a
    /// repay, a deposit or a quote on the depth-gated type pays for no ImdDepth read, and a charged setRate still binds.
    function _openForDepthChecks() internal returns (uint256 id) {
        s1.set(80_100e18);
        _days(7);
        _gov(_lineTo(36_733e18));
        params.applyPending(params.SET_RISK());
        vm.prank(bob);
        id = ledger.open(SIMD, 0, Adjust(10_000e18, 10_000e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function test_gas_repayReadsNoDepth() public {
        uint256 id = _openForDepthChecks();
        vm.expectCall(address(depthOracle), abi.encodeWithSignature("depth()"), 0);
        vm.prank(bob);
        ledger.adjust(id, Adjust(0, -1_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    function test_gas_depositReadsNoDepth() public {
        uint256 id = _openForDepthChecks();
        vm.expectCall(address(depthOracle), abi.encodeWithSignature("depth()"), 0);
        vm.prank(bob);
        ledger.adjust(id, Adjust(1e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    function test_gas_quoteReadsNoDepth() public {
        _openForDepthChecks();
        vm.expectCall(address(depthOracle), abi.encodeWithSignature("depth()"), 0);
        pricer.quote(SIMD);
    }

    function test_gas_chargedRateChangeStillBindsTheLiveLine() public {
        uint256 id = _openForDepthChecks();
        s1.set(0);
        assertEq(params.risk(SIMD).line, 0);
        vm.prank(bob);
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        ledger.setRate(id, 0.06e18, 0, 0); // inside the cooldown: the premium is new debt
    }
}
