// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployChain} from "../../script/DeployChain.s.sol";
import {DeployTypes} from "../../script/DeployConfig.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {MockERC20, MockFeed} from "./Mocks.sol";
import {MockLzEndpoint} from "./MockLzEndpoint.sol";

/// @notice Two v2 deployments in one EVM, each built by the REAL `script/Deploy.s.sol`: "home" (mainnet-shaped: no Pulse, no
/// chain line) and "rh" (Robinhood-shaped: Pulse 15 min / 1 h, chain line 30k), an ETH type on each (mock feeds), and an
/// ImdBridge on each over a MockLzEndpoint pair. `_open()` makes each bridge its token's minter (SET_BRIDGE, 48h) and opens
/// the path both ways (SET_PATH with RobinhoodConfig-sized limits, 48h), as the two Safes would.
abstract contract TwoChains is Test {
    bytes32 constant ETH = "ETH";
    bytes32 constant OTHER = "OTHER";
    uint32 constant HOME_EID = 30101;
    uint32 constant RH_EID = 30416;
    uint256 constant CHAIN_LINE = 30_000e18;
    uint256 constant OUT_LIMIT = 10_000e18; // rh -> home per day
    uint256 constant IN_LIMIT = 50_000e18; // home -> rh per day

    address safe = makeAddr("safe");
    address guardian = makeAddr("guardian");
    address deployer = makeAddr("deployer");

    MockERC20 weth;
    MockERC20 other;
    MockFeed ethFeed;
    MockFeed otherFeed;
    MockLzEndpoint homeEp;
    MockLzEndpoint rhEp;
    Deploy.Deployed home;
    Deploy.Deployed rh;

    function _setUpChains() internal {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        other = new MockERC20("OTHER", 18);
        ethFeed = new MockFeed(2000e18);
        otherFeed = new MockFeed(1e18);
        homeEp = new MockLzEndpoint(HOME_EID);
        rhEp = new MockLzEndpoint(RH_EID);
        homeEp.link(rhEp);
        rhEp.link(homeEp);
        Deploy script = new DeployChain();
        home = script.deployAs(_config(false, address(homeEp)), deployer);
        rh = script.deployAs(_config(true, address(rhEp)), deployer);
    }

    function _config(bool robinhood, address endpoint) internal view returns (DeployTypes.Config memory c) {
        c.governor = safe;
        c.flashCap = 1_000_000e18;
        c.migratorClosed = true; // v1 = 0: the migrator is inert
        c.savingsShare = 0.35e18;
        c.feeds = new DeployTypes.FeedNode[](2);
        c.feeds[0].kind = DeployTypes.EXISTING;
        c.feeds[0].source = address(ethFeed);
        c.feeds[1].kind = DeployTypes.EXISTING;
        c.feeds[1].source = address(otherFeed);
        uint8 none = DeployTypes.NONE;
        c.ilks = new DeployTypes.IlkSpec[](2);
        c.ilks[0] = DeployTypes.IlkSpec(ETH, address(weth), 0, 0, none, none, address(0), none, true, _risk(1.4e18, 1_000_000e18));
        c.ilks[1] = DeployTypes.IlkSpec(OTHER, address(other), 1, 1, none, none, address(0), none, true, _risk(1.5e18, 1_000_000e18));
        if (robinhood) {
            c.chain = DeployTypes.ChainSpec({
                chainId: 0, pulse: true, pulseGap: 15 minutes, pulseGrace: 1 hours, capped: true, chainLine: CHAIN_LINE
            });
        }
        c.bridge = DeployTypes.BridgeSpec({enabled: true, endpoint: endpoint, guardian: guardian});
    }

    function _risk(uint64 mat, uint128 line) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: mat,
            chop: 0.1e18,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: 0.01e18,
            yieldFee: 0,
            skew: 0.05e18,
            pegFloor: 0,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 4,
            redeemCap: 0
        });
    }

    function _peer(ImdBridge b) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address(b))));
    }

    /// @dev The Safes' launch acts on both chains (two 48h windows: Parameters, then each bridge).
    function _open() internal {
        vm.startPrank(safe);
        home.params.propose(abi.encode(uint8(4), address(home.bridge)));
        rh.params.propose(abi.encode(uint8(4), address(rh.bridge)));
        vm.stopPrank();
        _warp(48 hours);
        home.params.applyPending();
        rh.params.applyPending();
        vm.startPrank(safe);
        home.bridge.propose(_path(RH_EID, _peer(rh.bridge), IN_LIMIT, OUT_LIMIT));
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, IN_LIMIT));
        vm.stopPrank();
        _warp(48 hours);
        home.bridge.applyPending();
        rh.bridge.applyPending();
    }

    function _path(uint32 eid, bytes32 peer, uint256 outLimit, uint256 inLimit) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), eid, peer, outLimit, uint256(1 days), inLimit, uint256(1 days), bytes(""));
    }

    /// @dev Warp and keep the mock prices and the rh Pulse alive (a keeper pokes more often than the gap).
    function _warp(uint256 dt) internal {
        uint256 step = 10 minutes;
        uint256 end = vm.getBlockTimestamp() + dt;
        while (vm.getBlockTimestamp() < end) {
            uint256 t = vm.getBlockTimestamp() + step > end ? end : vm.getBlockTimestamp() + step;
            vm.warp(t);
            rh.pulse.poke();
        }
        ethFeed.set(ethFeed.value());
        otherFeed.set(otherFeed.value());
    }

    /// @dev Per-chain supply equation (Σ debt + Σ bad debt + reserve-backed + migrated + bridge received − sent).
    function _ledgerTerms(Deploy.Deployed memory d) internal returns (uint256 sum) {
        bytes32[2] memory ilks = [ETH, OTHER];
        for (uint256 i; i < 2; ++i) {
            d.ledger.accrue(ilks[i]);
            (uint128 debt,,,, uint128 bad) = d.ledger.ilkState(ilks[i]);
            sum += uint256(debt) + bad;
        }
        sum += d.ledger.reserveBacked() + d.migrator.outstanding();
    }

    function _assertChainSupply(Deploy.Deployed memory d) internal {
        int256 rhs = int256(_ledgerTerms(d)) + d.bridge.netMinted(); // accrues first: interest is minted on accrual
        int256 lhs = int256(d.usd.totalSupply());
        assertEq(lhs, rhs, "supply == debt + bad + reserve + migrated + received - sent");
    }

    /// @dev Σ supply + in flight == Σ ledger terms across both chains.
    function _assertGlobalSupply() internal {
        uint256 terms = _ledgerTerms(home) + _ledgerTerms(rh); // accrues first
        uint256 inFlight = _inFlight(homeEp) + _inFlight(rhEp);
        assertEq(home.usd.totalSupply() + rh.usd.totalSupply() + inFlight, terms, "global supply");
    }

    function _inFlight(MockLzEndpoint ep) internal view returns (uint256 sum) {
        uint256 n = ep.packetCount();
        for (uint256 i; i < n; ++i) {
            if (!ep.isDelivered(i)) sum += ep.amountOf(i);
        }
    }
}
