// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoChains} from "../utils/TwoChains.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Governed} from "../../src/Governed.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {MessagingFee, Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {SendParam, OFTReceipt} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice The OFT path and the chain line on two offline chains built by the real deploy script.
contract BridgeTest is TwoChains {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _setUpChains();
        weth.mint(alice, 1000e18);
        other.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        weth.approve(address(rh.ledger), type(uint256).max);
        weth.approve(address(home.ledger), type(uint256).max);
        other.approve(address(rh.ledger), type(uint256).max);
        vm.stopPrank();
        vm.deal(alice, 10 ether);
    }

    function _borrow(Ledger l, bytes32 ilk, uint256 coll, uint256 debt) internal {
        vm.prank(alice);
        l.open(ilk, 0, Adjust(int256(coll), int256(debt), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function _param(uint32 dst, address to, uint256 amount) internal pure returns (SendParam memory) {
        return SendParam(dst, bytes32(uint256(uint160(to))), amount, 0, "", "", "");
    }

    function _send(ImdBridge b, uint32 dst, address to, uint256 amount) internal returns (uint256 sent) {
        SendParam memory p = _param(dst, to, amount);
        MessagingFee memory fee = b.quoteSend(p, false);
        vm.prank(alice);
        (, OFTReceipt memory r) = b.send{value: fee.nativeFee}(p, fee, alice);
        sent = r.amountSentLD;
    }

    // ------------------------------------------------------------ authority and wiring

    function test_noOwnerAndOnlyTheTimelockMakesItAMinter() public {
        (bool ok,) = address(rh.bridge).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner()");
        assertEq(rh.bridge.governor(), safe);
        assertEq(rh.usd.bridge(), address(0), "deployed, not yet a minter");
        _open();
        assertEq(rh.usd.bridge(), address(rh.bridge));
        assertEq(rh.bridge.peers(HOME_EID), _peer(home.bridge));
        // the minter is set once: a second SET_BRIDGE is refused at propose (audit wave 1), and ImdUSD itself refuses one
        vm.prank(safe);
        vm.expectRevert(ParametersBase.BadConfig.selector);
        rh.params.propose(abi.encode(uint8(4), address(rh.bridge)));
        vm.prank(address(rh.params));
        vm.expectRevert(ImdUSD.AlreadySet.selector);
        rh.usd.setBridge(address(rh.bridge));
    }

    function test_pathBoundsAndBatch() public {
        vm.startPrank(safe);
        vm.expectRevert(ImdBridge.OutOfBounds.selector);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), 10_000_001e18, 1));
        vm.expectRevert(ImdBridge.OutOfBounds.selector);
        rh.bridge.propose(abi.encode(uint8(1), HOME_EID, _peer(home.bridge), 1e18, uint256(30 minutes), 1e18, uint256(1 days), bytes("")));
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.bridge.propose(_path(RH_EID, _peer(home.bridge), 1e18, 1e18)); // own eid
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.bridge.propose(_path(HOME_EID, bytes32(0), 1e18, 1e18));
        bytes[] memory nested = new bytes[](1);
        nested[0] = abi.encode(uint8(6), new bytes[](0));
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.bridge.propose(abi.encode(uint8(6), nested));
        // a batch: the path and the DVN config in one 48h window
        bytes[] memory items = new bytes[](2);
        items[0] = _path(HOME_EID, _peer(home.bridge), OUT_LIMIT, IN_LIMIT);
        items[1] = abi.encode(uint8(2), address(rhEp), new SetConfigParam[](0));
        rh.bridge.propose(abi.encode(uint8(6), items));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, vm.getBlockTimestamp() + 48 hours));
        rh.bridge.applyPending();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rh.bridge.applyPending();
        assertEq(rh.bridge.peers(HOME_EID), _peer(home.bridge));
        assertEq(rhEp.configCalls(address(rh.bridge)), 1, "DVN config only through the timelock, by the OApp itself");
        assertEq(rh.bridge.availableOut(HOME_EID), OUT_LIMIT);
    }

    // ------------------------------------------------------------ round trip + supply

    function test_roundTripKeepsEverySupplyEquation() public {
        _open();
        _borrow(rh.ledger, ETH, 10e18, 5_000e18);
        _assertChainSupply(rh);
        uint256 sent = _send(rh.bridge, HOME_EID, bob, 3_000e18 + 123); // dust below 1e-6 stays home
        assertEq(sent, 3_000e18);
        assertEq(rh.usd.balanceOf(alice), 2_000e18, "only whole 1e-6 units are burned");
        _assertChainSupply(rh);
        _assertChainSupply(home);
        _assertGlobalSupply(); // 3,000 in flight
        assertEq(_inFlight(rhEp), 3_000e18);
        assertTrue(rhEp.deliver(0));
        assertEq(home.usd.balanceOf(bob), 3_000e18);
        _assertChainSupply(home);
        _assertGlobalSupply();
        // and back
        vm.prank(bob);
        home.usd.transfer(alice, 3_000e18);
        _send(home.bridge, RH_EID, alice, 3_000e18);
        assertTrue(homeEp.deliver(0));
        assertEq(rh.usd.balanceOf(alice), 5_000e18);
        _assertChainSupply(rh);
        _assertChainSupply(home);
        _assertGlobalSupply();
        assertEq(home.usd.totalSupply(), 0);
        // repay on rh with the returned imdUSD (+ the upfront fee's worth, F1, from the Treasury that received it)
        uint256 owed = rh.ledger.debtOf(_pid(ETH, alice));
        vm.prank(address(rh.treasury));
        rh.usd.transfer(alice, owed - 5_000e18);
        vm.prank(alice);
        rh.ledger.open(ETH, 0, Adjust(0, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        _assertChainSupply(rh);
    }

    function test_outboundLimitAndDecay() public {
        _open();
        _borrow(rh.ledger, ETH, 100e18, 25_000e18);
        _send(rh.bridge, HOME_EID, bob, 8_000e18);
        SendParam memory p = _param(HOME_EID, bob, 3_000e18);
        MessagingFee memory fee = rh.bridge.quoteSend(p, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.RateLimited.selector, HOME_EID, 3_000e18, 2_000e18));
        rh.bridge.send{value: fee.nativeFee}(p, fee, alice);
        vm.warp(vm.getBlockTimestamp() + 12 hours); // half the window: 5,000 decays
        assertEq(rh.bridge.availableOut(HOME_EID), 7_000e18);
        _send(rh.bridge, HOME_EID, bob, 7_000e18);
        assertEq(rh.bridge.availableOut(HOME_EID), 0);
    }

    function test_inboundLimitLeavesMessageInFlightUntilRoom() public {
        _open();
        // lower rh's inbound limit from home to 1,000/day to exercise it (home's outbound stays 50k)
        vm.prank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, 1_000e18));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rh.bridge.applyPending();
        deal(address(home.usd), alice, 2_000e18, true); // test-only supply on home (no supply equation asserted here)
        _send(home.bridge, RH_EID, alice, 800e18);
        _send(home.bridge, RH_EID, alice, 800e18);
        assertTrue(homeEp.deliver(0));
        assertFalse(homeEp.deliver(1), "over rh's inbound limit: refused, kept in flight");
        assertEq(_inFlight(homeEp), 800e18);
        vm.warp(vm.getBlockTimestamp() + 12 hours); // 200 + 500 room: still short
        assertFalse(homeEp.deliver(1));
        vm.warp(vm.getBlockTimestamp() + 6 hours); // 200 + 750
        assertTrue(homeEp.deliver(1), "retried once the window has room");
        assertEq(rh.usd.balanceOf(alice), 1_600e18);
        assertEq(_inFlight(homeEp), 0);
    }

    /// @dev A message larger than the receiving side's whole inbound limit can never land until the Safe raises the limit:
    /// that is why each side's OUTBOUND limit mirrors the other side's INBOUND (RobinhoodConfig.robinhoodPathOnMainnet).
    function test_mirroredLimitsRefuseAnUndeliverableSend() public {
        _open();
        deal(address(home.usd), alice, 60_000e18, true);
        SendParam memory p = _param(RH_EID, alice, 50_000e18 + 1e18);
        MessagingFee memory fee = home.bridge.quoteSend(p, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.RateLimited.selector, RH_EID, 50_001e18, 50_000e18));
        home.bridge.send{value: fee.nativeFee}(p, fee, alice);
    }

    function test_pauseIsFastUnpauseIsSlow() public {
        _open();
        _borrow(rh.ledger, ETH, 10e18, 5_000e18);
        vm.prank(alice);
        vm.expectRevert(ImdBridge.Unauthorized.selector);
        rh.bridge.pause(HOME_EID);
        vm.prank(guardian);
        rh.bridge.pause(HOME_EID);
        SendParam memory p = _param(HOME_EID, bob, 1_000e18);
        MessagingFee memory fee = rh.bridge.quoteSend(p, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathPaused.selector, HOME_EID));
        rh.bridge.send{value: fee.nativeFee}(p, fee, alice);
        // inbound waits too
        deal(address(home.usd), alice, 1_000e18, true);
        _send(home.bridge, RH_EID, alice, 1_000e18);
        assertFalse(homeEp.deliver(0));
        vm.prank(safe);
        rh.bridge.propose(abi.encode(uint8(5), HOME_EID));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rh.bridge.applyPending();
        assertTrue(homeEp.deliver(0));
        assertEq(rh.usd.balanceOf(alice), 6_000e18);
    }

    function test_onlyEndpointAndPeer() public {
        _open();
        Origin memory o = Origin(HOME_EID, _peer(home.bridge), 1);
        bytes memory m = abi.encodePacked(bytes32(uint256(uint160(alice))), uint64(1e6));
        vm.expectRevert(ImdBridge.OnlyEndpoint.selector);
        rh.bridge.lzReceive(o, bytes32(0), m, address(0), "");
        o.sender = bytes32(uint256(uint160(alice)));
        vm.prank(address(rhEp));
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.OnlyPeer.selector, HOME_EID, o.sender));
        rh.bridge.lzReceive(o, bytes32(0), m, address(0), "");
        assertFalse(rh.bridge.allowInitializePath(o));
    }

    function test_composeAndLzTokenRefused() public {
        _open();
        _borrow(rh.ledger, ETH, 10e18, 5_000e18);
        SendParam memory p = _param(HOME_EID, bob, 1_000e18);
        p.composeMsg = hex"01";
        vm.expectRevert(ImdBridge.ComposeUnsupported.selector);
        rh.bridge.quoteSend(p, false);
        vm.expectRevert(ImdBridge.LzTokenUnsupported.selector);
        rh.bridge.quoteSend(_param(HOME_EID, bob, 1e18), true);
    }

    function test_beforeSetBridgeNothingMints() public {
        // a path opened without the minter: a delivery cannot mint, so it stays in flight
        vm.startPrank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, IN_LIMIT));
        home.bridge.propose(_path(RH_EID, _peer(rh.bridge), IN_LIMIT, OUT_LIMIT));
        home.params.propose(abi.encode(uint8(4), address(home.bridge)));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rh.bridge.applyPending();
        home.bridge.applyPending();
        home.params.applyPending();
        deal(address(home.usd), alice, 1_000e18, true);
        _send(home.bridge, RH_EID, alice, 1_000e18);
        assertFalse(homeEp.deliver(0), "rh token refuses a mint from a non-minter");
    }

    // ------------------------------------------------------------ chain line

    function test_chainLineCapsTheSumOfTypes() public {
        assertTrue(rh.params.chainCapped());
        assertEq(rh.params.chainLine(), CHAIN_LINE);
        assertFalse(home.params.chainCapped(), "mainnet-shaped: uncapped");
        _borrow(rh.ledger, ETH, 100e18, 20_000e18);
        vm.prank(alice);
        vm.expectRevert(LedgerBase.ChainLineExceeded.selector);
        rh.ledger.open(OTHER, 0, Adjust(100_000e18, 10_001e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        _borrow(rh.ledger, OTHER, 100_000e18, 9_900e18); // + both upfront fees stays under the 30k chain line
        // a type line alone would have allowed it on the uncapped chain
        _borrow(home.ledger, ETH, 100e18, 30_000e18);
        // repaying is never blocked; the room comes back
        vm.prank(alice);
        rh.ledger.open(ETH, 0, Adjust(0, -5_000e18, 0, 0, 0, false, type(uint256).max, address(0)));
        _borrow(rh.ledger, OTHER, 0, 4_000e18);
    }

    function test_chainLineGovernance() public {
        vm.startPrank(safe);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        rh.params.propose(abi.encode(uint8(11), uint256(50_000_001e18)));
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        home.params.propose(abi.encode(uint8(11), uint256(1e18))); // never capped: cannot be capped later either
        rh.params.propose(abi.encode(uint8(11), uint256(60_000e18)));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        rh.params.applyPending();
        assertEq(rh.params.chainLine(), 60_000e18);
        vm.prank(deployer);
        vm.expectRevert(ParametersBase.Sealed.selector);
        rh.params.setGenesisChainLine(1);
    }

    // ------------------------------------------------------------ per-destination fee

    function _setFee(ImdBridge b, uint32 eid, uint256 bps) internal {
        vm.prank(safe);
        b.propose(abi.encode(uint8(7), eid, bps));
        _warp(48 hours);
        b.applyPending();
    }

    function test_feeStartsAtZeroBoundedAndTimelocked() public {
        assertEq(rh.bridge.feeBps(HOME_EID), 0);
        assertEq(rh.bridge.treasury(), address(rh.treasury));
        vm.startPrank(safe);
        vm.expectRevert(ImdBridge.OutOfBounds.selector);
        rh.bridge.propose(abi.encode(uint8(7), HOME_EID, uint256(26)));
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.bridge.propose(abi.encode(uint8(7), RH_EID, uint256(10))); // own eid
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        rh.bridge.propose(abi.encode(uint8(7), HOME_EID, uint256(10)));
        vm.prank(safe);
        rh.bridge.propose(abi.encode(uint8(7), HOME_EID, uint256(25)));
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, vm.getBlockTimestamp() + 48 hours));
        rh.bridge.applyPending();
        _warp(48 hours);
        rh.bridge.applyPending();
        assertEq(rh.bridge.feeBps(HOME_EID), 25);
        assertEq(rh.bridge.feeBps(uint32(30184)), 0, "per destination");
    }

    function test_feeMintedToTreasuryAndSupplyHolds() public {
        _open();
        _setFee(rh.bridge, HOME_EID, 25);
        _borrow(rh.ledger, ETH, 10e18, 5_000e18);
        uint256 tre0 = rh.usd.balanceOf(address(rh.treasury)); // the borrow's upfront fee
        SendParam memory p = _param(HOME_EID, bob, 3_000e18 + 123);
        OFTReceipt memory q = rh.bridge.quoteOFT(p);
        assertEq(q.amountSentLD, 3_000e18);
        assertEq(q.amountReceivedLD, 2_992.5e18);
        // minAmountLD bounds what is DELIVERED
        p.minAmountLD = 3_000e18;
        MessagingFee memory fee = rh.bridge.quoteSend(p, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.SlippageExceeded.selector, 2_992.5e18, 3_000e18));
        rh.bridge.send{value: fee.nativeFee}(p, fee, alice);
        p.minAmountLD = 2_992.5e18;
        vm.prank(alice);
        (, OFTReceipt memory r) = rh.bridge.send{value: fee.nativeFee}(p, fee, alice);
        assertEq(r.amountSentLD, 3_000e18);
        assertEq(r.amountReceivedLD, 2_992.5e18);
        assertEq(rh.usd.balanceOf(alice), 2_000e18, "burned the whole amount");
        assertEq(rh.usd.balanceOf(address(rh.treasury)) - tre0, 7.5e18, "fee minted to the Treasury");
        assertEq(rh.bridge.fees(), 7.5e18);
        assertEq(rh.bridge.sent(), 2_992.5e18, "sent counts only what is delivered");
        assertEq(rh.bridge.availableOut(HOME_EID), OUT_LIMIT - 2_992.5e18, "the limit counts what leaves the chain");
        _assertChainSupply(rh);
        _assertGlobalSupply();
        assertTrue(rhEp.deliver(0));
        assertEq(home.usd.balanceOf(bob), 2_992.5e18);
        _assertChainSupply(home);
        _assertGlobalSupply();
        // the other direction has no fee until home's Safe sets one
        vm.prank(bob);
        home.usd.transfer(alice, 1_000e18);
        assertEq(_send(home.bridge, RH_EID, alice, 1_000e18), 1_000e18);
        assertTrue(homeEp.deliver(0));
        assertEq(rh.usd.balanceOf(alice), 3_000e18);
        _assertChainSupply(rh);
        _assertChainSupply(home);
        _assertGlobalSupply();
    }

    /// @dev The fee takes the dust its own rounding leaves, so burned == delivered + fee and delivered is whole 1e-6 units.
    function testFuzz_feeSplitIsExact(uint256 amount, uint256 bps) public {
        _open();
        bps = bound(bps, 0, 25);
        amount = bound(amount, 2e12, 4_000e18); // >= 2 shared units: 1 unit less any fee delivers 0 (refused, )
        if (bps != 0) _setFee(rh.bridge, HOME_EID, bps);
        _borrow(rh.ledger, ETH, 10e18, 5_000e18);
        uint256 before = rh.usd.balanceOf(alice);
        uint256 tre0 = rh.usd.balanceOf(address(rh.treasury)); // the borrow's upfront fee
        SendParam memory p = _param(HOME_EID, bob, amount);
        MessagingFee memory fee = rh.bridge.quoteSend(p, false);
        vm.prank(alice);
        (, OFTReceipt memory r) = rh.bridge.send{value: fee.nativeFee}(p, fee, alice);
        assertEq(r.amountSentLD, amount / 1e12 * 1e12);
        assertEq(r.amountReceivedLD % 1e12, 0);
        assertEq(before - rh.usd.balanceOf(alice), r.amountSentLD);
        assertEq(rh.usd.balanceOf(address(rh.treasury)) - tre0, r.amountSentLD - r.amountReceivedLD);
        assertLe(r.amountSentLD - r.amountReceivedLD, r.amountSentLD * bps / 10_000 + 1e12);
        _assertChainSupply(rh);
        _assertGlobalSupply();
    }
}
