// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployRobinhood} from "../../script/DeployRobinhood.s.sol";
import {DeployChain} from "../../script/DeployChain.s.sol";
import {DeployTypes, RobinhoodConfig, BetaConfig} from "../../script/DeployConfig.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {ImdBridge, IMintableBurnable as IMintableBurnableMin} from "../../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2 as ILayerZeroEndpointV2Min} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {MessagingFee, Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SendParam} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @dev Stands in for the 4663 governance Safe, which does not exist yet: a contract (the script refuses an EOA) whose
/// address the tests prank as.
contract SafeStandIn {}

/// @notice Robinhood Chain fork rehearsal. Skipped unless ROBINHOOD_RPC_URL is set:
///   ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/fork/Robinhood.t.sol
/// REAL: the 4663 chain state (WETH, USDG, Steakhouse USDG vault, IMD OFT, Chainlink ETH/USD + USDG/USD, LayerZero
/// EndpointV2 + its default send library and fees), the whole deploy script with RobinhoodConfig. MOCKED: the three swarm
/// feeds' readings (no plane attestation can be signed in a test; `vm.mockCall` on latestValue/isStale), the Safe (a
/// stand-in contract), and price moves (Chainlink answers mocked where a test needs a crash).
abstract contract RobinhoodFork is Test {
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address liq = makeAddr("liquidator");
    address safe;
    Deploy.Deployed d;
    bool live;

    function _forkRobinhood() internal returns (uint256 id) {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return 0;
        }
        id = vm.createSelectFork(rpc);
        live = true;
    }

    function _deployRobinhood() internal {
        safe = address(new SafeStandIn());
        DeployTypes.Config memory c = RobinhoodConfig.get();
        c.governor = safe;
        Deploy script = new DeployChain();
        d = script.deployAs(c, deployer);
    }

    /// @dev The IMD median, spot and NHI as the swarm would attest them (values from mainnet's live v1 feeds, 2026-10-21).
    function _mockSwarm(uint256 imdEth, uint256 nhi) internal {
        _mockFeed(address(d.feeds[RobinhoodConfig.F_IMD_ETH]), imdEth);
        _mockFeed(address(d.feeds[RobinhoodConfig.F_IMD_ETH_SPOT]), imdEth);
        _mockFeed(address(d.feeds[RobinhoodConfig.F_NHI]), nhi);
    }

    function _mockFeed(address f, uint256 v) internal {
        vm.mockCall(f, abi.encodeWithSelector(IFeed.latestValue.selector), abi.encode(v, uint64(vm.getBlockTimestamp())));
        vm.mockCall(f, abi.encodeWithSelector(IFeed.isStale.selector), abi.encode(false));
    }

    function _mockEthPrice(uint256 usd8) internal {
        vm.mockCall(
            RobinhoodConfig.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(usd8), vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
    }

    function _approve(address token) internal {
        vm.prank(alice);
        IERC20(token).approve(address(d.ledger), type(uint256).max);
    }

    function _adjust(bytes32 ilk, int256 coll, int256 debt, bool viaAsset) internal {
        vm.prank(alice);
        d.ledger.open(ilk, 0, Adjust(coll, debt, 0.05e18, 0, 0, viaAsset, type(uint256).max, address(0)));
    }

    /// @dev Repay all of alice's debt on `ilk` (the amount + the upfront fee, F1, whose imdUSD the Treasury received) and
    /// take `coll` back.
    function _repayAll(bytes32 ilk, int256 coll, bool viaAsset) internal {
        uint256 owed = d.ledger.debtOf(_pid(ilk, alice));
        uint256 bal = d.usd.balanceOf(alice);
        if (owed > bal) {
            vm.prank(address(d.treasury));
            d.usd.transfer(alice, owed - bal);
        }
        _adjust(ilk, coll, -int256(owed), viaAsset);
    }

    /// @dev The most `room` admits once the borrow's upfront fee at a 5% average is added: whole imdUSD.
    function _net(uint256 room) internal pure returns (uint256) {
        return room * 365 days / (365 days + 0.05e18 * 7 days / 1e18) / 1e18 * 1e18;
    }

    function _supplyHolds() internal {
        bytes32[3] memory ilks = [bytes32("ETH"), "S-USDG", "IMD"];
        uint256 sum = d.ledger.reserveBacked() + d.migrator.outstanding();
        if (address(d.hook) != address(0)) sum += d.hook.outstanding(); // the peg keeper's term
        for (uint256 i; i < 3; ++i) {
            d.ledger.accrue(ilks[i]);
            (uint128 debt,,,, uint128 bad) = d.ledger.ilkState(ilks[i]);
            sum += uint256(debt) + bad;
        }
        assertEq(int256(d.usd.totalSupply()), int256(sum) + d.bridge.netMinted(), "4663 supply equation");
    }

    /// @dev The Safe's launch acts: SET_BRIDGE on Parameters (48h), then the path to `eid` on the bridge (48h).
    function _openBridge(uint32 eid, bytes32 peer, uint256 outLimit, uint256 inLimit) internal {
        vm.prank(safe);
        d.params.propose(abi.encode(uint8(4), address(d.bridge)));
        _keepAlive(48 hours);
        d.params.applyPending();
        // one BATCH: the path, both library pins, and this OApp's own executor + DVN config on them (the
        // endpoint's default for a new OApp is a dead DVN)
        bytes memory batch = RobinhoodConfig.launchBatch4663(
            abi.encode(uint8(1), eid, peer, outLimit, uint256(1 days), inLimit, uint256(1 days), bytes(""))
        );
        vm.prank(safe);
        d.bridge.propose(batch);
        _keepAlive(48 hours);
        d.bridge.applyPending();
    }

    /// @dev Warp with the keeper poking the Pulse every 10 minutes, and Chainlink kept fresh.
    function _keepAlive(uint256 dt) internal {
        uint256 end = vm.getBlockTimestamp() + dt;
        while (vm.getBlockTimestamp() < end) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes > end ? end : vm.getBlockTimestamp() + 10 minutes);
            if (address(d.pulse) != address(0)) d.pulse.poke();
        }
        _freshChainlink();
    }

    function _freshChainlink() internal {
        (, int256 eth,,,) = _round(RobinhoodConfig.CL_ETH_USD);
        _mockEthPrice(uint256(eth));
        (, int256 usdg,,,) = _round(RobinhoodConfig.CL_USDG_USD);
        vm.mockCall(
            RobinhoodConfig.CL_USDG_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), usdg, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
    }

    function _round(address agg) internal view returns (uint80, int256, uint256, uint256, uint80) {
        (bool ok, bytes memory data) = agg.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok, "chainlink");
        return abi.decode(data, (uint80, int256, uint256, uint256, uint80));
    }
}

contract RobinhoodForkTest is RobinhoodFork {
    bytes32 constant ETH = "ETH";
    bytes32 constant SUSDG = "S-USDG";
    bytes32 constant IMD = "IMD";
    // mainnet v1 IMD/ETH spot and NHI as read 2026-10-21 (order of magnitude is what matters here)
    uint256 constant IMD_ETH = 2.4e15;
    uint256 constant NHI = 0.98e18;

    function setUp() public {
        _forkRobinhood();
        if (!live) return;
        _deployRobinhood();
        _freshChainlink();
        deal(RobinhoodConfig.WETH, alice, 100e18);
        deal(RobinhoodConfig.USDG, alice, 100_000e6);
        deal(RobinhoodConfig.IMD, alice, 10_000e18);
        _approve(RobinhoodConfig.WETH);
        _approve(RobinhoodConfig.USDG);
        _approve(RobinhoodConfig.STEAKHOUSE_USDG);
        _approve(RobinhoodConfig.IMD);
    }

    // ------------------------------------------------------------ the deployment

    function test_scriptRefusesTheMissingSafe() public {
        DeployRobinhood entry = new DeployRobinhood();
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.GovernorNotAContract.selector, address(0)));
        entry.run();
    }

    function test_deployedAsConfiguredAndPowerless() public {
        assertEq(block.chainid, 4663);
        assertEq(d.params.governor(), safe);
        assertEq(d.treasury.governor(), safe);
        assertEq(d.bridge.governor(), safe);
        assertEq(address(d.bridge.endpoint()), RobinhoodConfig.LZ_ENDPOINT);
        assertEq(d.params.ilkCount(), 3 + RobinhoodConfig.stocks().types.length, "ETH, S-USDG, IMD + the 3b stock types");
        assertTrue(d.params.chainCapped());
        assertEq(d.params.chainLine(), RobinhoodConfig.CHAIN_LINE);
        assertEq(address(d.ledger.pulse()), address(d.pulse));
        assertEq(address(d.liquidator.pulse()), address(d.pulse));
        assertEq(d.pulse.gap(), 15 minutes);
        assertEq(d.pulse.grace(), 1 hours);
        assertEq(d.params.migratorLine(), 0, "no v1 on 4663");
        assertEq(d.usd.bridge(), address(0), "minter only after the Safe's SET_BRIDGE");
        assertEq(d.usd.keeper(), address(d.hook), "the peg hook is the keeper minter, cap 0");
        assertEq(d.params.keeperCap(), 0);
        address[5] memory contracts =
            [address(d.params), address(d.treasury), address(d.ledger), address(d.bridge), address(d.pulse)];
        for (uint256 i; i < 5; ++i) {
            (bool ok,) = contracts[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "no owner()");
        }
        vm.prank(deployer);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.setGenesisChainLine(1);
        // the real feeds
        (uint256 eth,) = d.feeds[RobinhoodConfig.F_ETH].latestValue();
        assertGt(eth, 500e18);
        assertLt(eth, 20_000e18);
        (uint256 share,) = d.feeds[RobinhoodConfig.F_SUSDG].latestValue();
        assertGt(share, 1e18, "steakUSDG > $1 per share");
        assertLt(share, 1.1e18);
        assertTrue(d.feeds[RobinhoodConfig.F_IMD_USD].isStale(), "swarm feeds inert until their first attestation");
        assertEq(SwarmFeed(address(d.feeds[RobinhoodConfig.F_IMD_ETH])).blockClockChainId(), 1);
    }

    // ------------------------------------------------------------ round trip on every pair

    function test_roundTripEth() public {
        _adjust(ETH, 10e18, 10_000e18, false);
        assertEq(d.usd.balanceOf(alice), 10_000e18);
        _supplyHolds();
        _repayAll(ETH, -10e18, false);
        assertEq(IERC20(RobinhoodConfig.WETH).balanceOf(alice), 100e18);
        _supplyHolds();
    }

    function test_roundTripSUsdgStakedOnDeposit() public {
        IERC20 vault = IERC20(RobinhoodConfig.STEAKHOUSE_USDG);
        uint256 before = vault.balanceOf(address(d.joins[1]));
        _adjust(SUSDG, 50_000e6, 10_000e18, true); // raw USDG in, staked into the real Steakhouse vault for alice
        uint256 shares = d.ledger.position(_pid(SUSDG, alice)).collateral;
        assertEq(vault.balanceOf(address(d.joins[1])) - before, shares);
        assertGt(shares, 49_000e18, "18-decimal shares for 6-decimal USDG");
        _keepAlive(7 days); // the vault's yield is harvested against the debt on the next touch
        vm.prank(alice);
        d.ledger.open(SUSDG, 0, Adjust(0, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        uint256 debt = d.ledger.debtOf(_pid(SUSDG, alice));
        deal(address(d.usd), alice, d.usd.balanceOf(alice) + 100e18, true); // any net interest is paid from outside
        _adjust(SUSDG, -int256(uint256(d.ledger.position(_pid(SUSDG, alice)).collateral)), -int256(debt), true);
        assertGe(IERC20(RobinhoodConfig.USDG).balanceOf(alice), 99_900e6, "USDG back, less the yield harvested to the debt");
        assertLe(IERC20(RobinhoodConfig.USDG).balanceOf(alice), 100_100e6, "at most the unharvested dust of the yield");
    }

    function test_roundTripImdFromMainnetAttestations() public {
        vm.expectRevert(LedgerBase.NotPriced.selector);
        _adjust(IMD, 1_000e18, 1_000e18, false);
        _mockSwarm(IMD_ETH, NHI);
        _adjust(IMD, 5_000e18, 1_000e18, false); // ~ $29k of IMD at 2.4e15 ETH x ~$2,440
        assertEq(d.usd.balanceOf(alice), 1_000e18);
        assertFalse(d.params.config(IMD).redeemable, "no live pool leg on 4663: not redeemable");
        assertEq(d.pricer.quote(IMD).mat, 1.7e18, "NHI-linked: 170% at NHI 0.98");
        assertEq(d.pricer.quote(IMD).lull, 6 hours, "and v1's 6h grace between mark and bite");
        _repayAll(IMD, -5_000e18, false);
        assertEq(IERC20(RobinhoodConfig.IMD).balanceOf(alice), 10_000e18);
        _supplyHolds();
    }

    // ------------------------------------------------------------ caps and limits

    function test_chainLineAcrossTypes() public {
        _mockSwarm(IMD_ETH, NHI);
        _adjust(ETH, 50e18, int256(_net(20_000e18)), false); // each type up to its line, upfront fee included
        _adjust(IMD, 5_000e18, int256(_net(3_000e18)), false);
        // What the 30k chain line has left, net of the borrow's own fee.
        uint256 used;
        bytes32[3] memory ks = [ETH, SUSDG, IMD];
        for (uint256 i; i < 3; ++i) {
            (uint128 dt,,,, uint128 bad) = d.ledger.ilkState(ks[i]);
            used += uint256(dt) + bad;
        }
        uint256 b = _net(RobinhoodConfig.CHAIN_LINE - used);
        vm.expectRevert(LedgerBase.ChainLineExceeded.selector);
        _adjust(SUSDG, 50_000e6, int256(b + 1e18), true);
        _adjust(SUSDG, 50_000e6, int256(b), true);
        _supplyHolds();
    }

    function test_outboundLimitOnTheRealEndpoint() public {
        bytes32 peer = bytes32(uint256(uint160(makeAddr("mainnet bridge"))));
        _openBridge(RobinhoodConfig.MAINNET_EID, peer, RobinhoodConfig.OUT_LIMIT, RobinhoodConfig.IN_LIMIT);
        _adjust(ETH, 50e18, 19_900e18, false); // under the 20k ETH line once its upfront fee is added
        vm.deal(alice, 1 ether);
        SendParam memory p = SendParam(RobinhoodConfig.MAINNET_EID, bytes32(uint256(uint160(alice))), 10_000e18, 0, _opts(), "", "");
        MessagingFee memory fee = d.bridge.quoteSend(p, false); // the real EndpointV2 + default send library quote
        assertGt(fee.nativeFee, 0);
        vm.prank(alice);
        d.bridge.send{value: fee.nativeFee}(p, fee, alice);
        assertEq(d.bridge.sent(), 10_000e18);
        _supplyHolds();
        p.amountLD = 1e18;
        fee = d.bridge.quoteSend(p, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.RateLimited.selector, RobinhoodConfig.MAINNET_EID, 1e18, 0));
        d.bridge.send{value: fee.nativeFee}(p, fee, alice);
    }

    /// @dev Type-3 options: lzReceive gas 200k (the executor needs it; OptionsBuilder.addExecutorLzReceiveOption).
    function _opts() internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(200_000));
    }

    // ------------------------------------------------------------ the sequencer grace

    function test_sequencerGapLiquidationWaitsOutTheGrace() public {
        _adjust(ETH, 10e18, 15_000e18, false);
        // the sequencer is down for 2 hours; ETH falls 30% meanwhile and the first block after carries the new price
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (, int256 eth,,,) = _round(RobinhoodConfig.CL_ETH_USD);
        _mockEthPrice(uint256(eth) * 70 / 100);
        (bool ok,) = d.ledger.healthy(_pid(ETH, alice));
        assertFalse(ok);
        deal(address(d.usd), liq, 30_000e18);
        vm.prank(liq);
        (uint256 repaid,,) = d.liquidator.liquidate(_pid(ETH, alice));
        assertEq(repaid, 0, "held: grace started by this very liquidation");
        assertEq(d.pulse.graceUntil(), vm.getBlockTimestamp() + 1 hours);
        _keepAlive(30 minutes); // the keeper pokes every 10 minutes (Chainlink re-stamped at the crashed price)
        vm.prank(liq);
        (repaid,,) = d.liquidator.bite(_pid(ETH, alice));
        assertEq(repaid, 0, "still in grace");
        _keepAlive(30 minutes);
        vm.prank(liq);
        (repaid,,) = d.liquidator.bite(_pid(ETH, alice));
        assertGt(repaid, 0, "seized once the grace has run");
        _supplyHolds();
    }
}

/// @notice imdUSD 4663 -> Ethereum -> 4663 across two forks (needs ROBINHOOD_RPC_URL and MAINNET_RPC_URL).
/// REAL on both sides: our deployments (RobinhoodConfig on 4663, BetaConfig + an ImdBridge on mainnet), each chain's
/// EndpointV2 `quote`/`send` with its default send library, DVN/executor fee and the PacketSent it emits; the packet's
/// guid, nonce and OFT message are read from that event. MOCKED: verification and delivery (DVNs + executor): the
/// destination's real endpoint address is pranked calling `lzReceive` with the source packet's own bytes.
contract RobinhoodMainnetLzTest is RobinhoodFork {
    address constant MAINNET_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant MAINNET_SAFE = 0xbeFd108085613662356aa26A2466Ad3426DA9C32;
    bytes32 constant PACKET_SENT = keccak256("PacketSent(bytes,bytes,address)");

    uint256 rhFork;
    uint256 ethFork;
    Deploy.Deployed m;

    function setUp() public {
        rhFork = _forkRobinhood();
        string memory mrpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (!live || bytes(mrpc).length == 0) {
            vm.skip(true);
            return;
        }
        _deployRobinhood();
        _freshChainlink();
        ethFork = vm.createSelectFork(mrpc);
        vm.pauseGasMetering();
        Deploy script = new Deploy();
        m = script.deployAs(_beta(), deployer);
        m.bridge = new ImdBridge(
            ILayerZeroEndpointV2Min(MAINNET_ENDPOINT), IMintableBurnableMin(address(m.usd)), MAINNET_SAFE, address(0),
            address(m.treasury)
        );
        vm.resumeGasMetering();
        // mainnet's Safe: SET_BRIDGE, then the path to 4663 (mirror limits)
        vm.prank(MAINNET_SAFE);
        m.params.propose(abi.encode(uint8(4), address(m.bridge)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        m.params.applyPending();
        bytes memory batch =
            RobinhoodConfig.launchBatchMainnet(RobinhoodConfig.robinhoodPathOnMainnet(_b32(address(d.bridge)), ""));
        vm.prank(MAINNET_SAFE);
        m.bridge.propose(batch);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        m.bridge.applyPending();
        // 4663's Safe
        vm.selectFork(rhFork);
        _openBridge(RobinhoodConfig.MAINNET_EID, _b32(address(m.bridge)), RobinhoodConfig.OUT_LIMIT, RobinhoodConfig.IN_LIMIT);
        deal(RobinhoodConfig.WETH, alice, 100e18);
        _approve(RobinhoodConfig.WETH);
        vm.deal(alice, 1 ether);
    }

    function _beta() internal pure returns (DeployTypes.Config memory c) {
        c = BetaConfig.get();
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _sendAndCapture(ImdBridge b, uint32 dst, uint256 amount)
        internal
        returns (uint64 nonce, bytes32 guid, bytes memory message)
    {
        SendParam memory p = SendParam(dst, _b32(alice), amount, amount, _lzOpts(), "", "");
        MessagingFee memory fee = b.quoteSend(p, false);
        vm.recordLogs();
        vm.prank(alice);
        b.send{value: fee.nativeFee}(p, fee, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory payload;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PACKET_SENT) (payload,,) = abi.decode(logs[i].data, (bytes, bytes, address));
        }
        require(payload.length > 113, "no PacketSent");
        // PacketV1Codec: version(1) nonce(8) srcEid(4) sender(32) dstEid(4) receiver(32) | guid(32) | message
        assembly {
            nonce := shr(192, mload(add(payload, 33)))
            guid := mload(add(payload, 113))
        }
        message = new bytes(payload.length - 113);
        for (uint256 i; i < message.length; ++i) message[i] = payload[113 + i];
    }

    function _lzOpts() internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(200_000));
    }

    function test_roundTripBetweenRobinhoodAndEthereum() public {
        _adjust("ETH", 10e18, 5_000e18, false);
        (uint64 n1, bytes32 g1, bytes memory msg1) = _sendAndCapture(d.bridge, RobinhoodConfig.MAINNET_EID, 2_000e18);
        assertEq(d.usd.balanceOf(alice), 3_000e18);
        _supplyHolds(); // 4663: supply == debt (5,000 + its upfront fee) + received 0 - sent 2,000
        uint256 rhSupply = d.usd.totalSupply();
        uint256 rhDebt = d.ledger.debtOf(_pid("ETH", alice));

        vm.selectFork(ethFork);
        uint256 before = m.usd.totalSupply();
        vm.prank(MAINNET_ENDPOINT);
        m.bridge.lzReceive(Origin(RobinhoodConfig.EID, _b32(address(d.bridge)), n1), g1, msg1, address(0), "");
        assertEq(m.usd.balanceOf(alice), 2_000e18);
        assertEq(m.usd.totalSupply(), before + 2_000e18);
        assertEq(m.usd.totalSupply() + rhSupply, rhDebt, "across chains: supply == 4663's debt");
        // and back, through mainnet's real endpoint
        vm.deal(alice, 1 ether);
        (uint64 n2, bytes32 g2, bytes memory msg2) = _sendAndCapture(m.bridge, RobinhoodConfig.EID, 2_000e18);
        assertEq(m.usd.totalSupply(), before);

        vm.selectFork(rhFork);
        vm.prank(RobinhoodConfig.LZ_ENDPOINT);
        d.bridge.lzReceive(Origin(RobinhoodConfig.MAINNET_EID, _b32(address(m.bridge)), n2), g2, msg2, address(0), "");
        assertEq(d.usd.balanceOf(alice), 5_000e18);
        _supplyHolds();
        _repayAll("ETH", -10e18, false);
        assertEq(d.usd.totalSupply(), 0);
    }
}
