// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoChains} from "../utils/TwoChains.sol";
import {MockLzEndpoint, MockMessageLib} from "../utils/MockLzEndpoint.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Ledger} from "../../src/Ledger.sol";
import {MessagingFee} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {SendParam} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {DeployMainnetBridge} from "../../script/DeployMainnetBridge.s.sol";
import {DeployRobinhood} from "../../script/DeployRobinhood.s.sol";

/// @notice Regression tests for the bridge findings of an earlier internal review (F1-F4).
contract BridgeReviewTest is TwoChains {
    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address sendLib;
    address receiveLib;
    address movedLib; // LayerZero's next default
    address dvnA = address(0x1000);
    address dvnB = address(0x2000);
    address dvnC = address(0x3000);

    function setUp() public {
        _setUpChains();
        sendLib = address(new MockMessageLib());
        receiveLib = address(new MockMessageLib());
        movedLib = address(new MockMessageLib());
        // LayerZero's defaults today = the libraries we pin
        rhEp.setDefaultLibraries(HOME_EID, sendLib, receiveLib);
        homeEp.setDefaultLibraries(RH_EID, sendLib, receiveLib);
        weth.mint(alice, 1000e18);
        vm.startPrank(alice);
        weth.approve(address(rh.ledger), type(uint256).max);
        vm.stopPrank();
        vm.deal(alice, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    /// @dev Three required DVNs (MIN_REQUIRED_DVNS = 3): `a`, `b` and dvnC (0x3000, above both, so the
    /// list stays ascending whenever a < b < 0x3000).
    function _dvns(address a, address b) internal pure returns (address[] memory d) {
        d = new address[](3);
        (d[0], d[1], d[2]) = (a, b, address(0x3000));
    }

    function _uln(uint64 conf, uint8 count, address[] memory req) internal pure returns (bytes memory) {
        return abi.encode(UlnConfig(conf, count, 0, 0, req, new address[](0)));
    }

    function _cfg(address lib, uint32 eid, uint32 configType, bytes memory config) internal pure returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(eid, configType, config);
        return abi.encode(uint8(2), lib, p);
    }

    function _pinSend(uint32 eid, address lib) internal pure returns (bytes memory) {
        return abi.encode(uint8(3), eid, lib);
    }

    function _pinReceive(uint32 eid, address lib) internal pure returns (bytes memory) {
        return abi.encode(uint8(4), eid, lib, uint256(0));
    }

    function _batch(bytes memory a, bytes memory b, bytes memory c) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](3);
        (items[0], items[1], items[2]) = (a, b, c);
        return abi.encode(uint8(6), items);
    }

    function _govern(ImdBridge b, bytes memory payload) internal {
        vm.prank(safe);
        b.propose(payload);
        _warp(48 hours);
        b.applyPending();
    }

    /// @dev rh's launch BATCH on the mock: pins + a valid receive config (from home = Ethereum's eid: 15 confirmations).
    function _pinAndConfigure() internal {
        _govern(
            rh.bridge,
            _batch(
                _pinSend(HOME_EID, sendLib),
                _pinReceive(HOME_EID, receiveLib),
                _cfg(receiveLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB)))
            )
        );
    }

    // ------------------------------------------------------------ F1: pinned libraries

    function test_reviewF1_defaultLibraryMoveNoLongerChangesTheEffectiveConfig() public {
        _open();
        _pinAndConfigure();
        bytes memory ours = rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID);
        assertGt(ours.length, 0, "our DVN config verifies inbound packets");
        assertEq(rh.bridge.receiveLibrary(HOME_EID), receiveLib);
        assertEq(rh.bridge.sendLibrary(HOME_EID), sendLib);
        // LayerZero moves its default library (no transaction of ours)
        rhEp.setDefaultLibraries(HOME_EID, movedLib, movedLib);
        (address lib, bool isDefault) = rhEp.getReceiveLibrary(address(rh.bridge), HOME_EID);
        assertEq(lib, receiveLib, "still on the pinned library");
        assertFalse(isDefault);
        assertEq(rhEp.getSendLibrary(address(rh.bridge), HOME_EID), sendLib);
        assertEq(keccak256(rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID)), keccak256(ours), "config unchanged");
    }

    function test_reviewF1_unpinnedOAppFollowsTheDefaultMove() public {
        // the mechanism the pin closes: config set on today's default, not pinned, is lost on a default move
        _open();
        rhEp.setDefaultLibraries(HOME_EID, sendLib, receiveLib);
        vm.prank(address(rh.bridge));
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB)));
        rhEp.setConfig(address(rh.bridge), receiveLib, p);
        assertGt(rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID).length, 0);
        rhEp.setDefaultLibraries(HOME_EID, movedLib, movedLib);
        assertEq(rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID).length, 0, "the library's defaults verify now");
    }

    function test_reviewF1_setConfigRefusesAnUnpinnedLibrary() public {
        bytes memory cfg = _cfg(receiveLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB)));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.UnpinnedLibrary.selector, HOME_EID, receiveLib));
        rh.bridge.propose(cfg);
        // pinned in the same BATCH: accepted (any position in the batch)
        vm.prank(safe);
        rh.bridge.propose(_batch(cfg, _pinReceive(HOME_EID, receiveLib), _pinSend(HOME_EID, sendLib)));
        vm.prank(safe);
        rh.bridge.cancel();
        // pinned for another eid only: refused
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.UnpinnedLibrary.selector, HOME_EID, receiveLib));
        rh.bridge.propose(_batch(_pinReceive(40_161, receiveLib), _pinSend(HOME_EID, sendLib), cfg));
        // a library LayerZero moved to (not ours): refused even after we pinned the old one
        _pinAndConfigure();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.UnpinnedLibrary.selector, HOME_EID, movedLib));
        rh.bridge.propose(_cfg(movedLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))));
        // a migration = re-pin + config in one BATCH
        _govern(
            rh.bridge,
            _batch(
                _pinReceive(HOME_EID, movedLib),
                _cfg(movedLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))),
                _pinSend(HOME_EID, sendLib)
            )
        );
        assertEq(rh.bridge.receiveLibrary(HOME_EID), movedLib);
    }

    function test_reviewF1_launchBatchesPinBothLibraries() public pure {
        // the shipped launch BATCHes carry both pins ahead of the config (checked by decoding, offline)
        _assertPins(
            RobinhoodConfigProbe.batch4663(), 30101, 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7, 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043
        );
        _assertPins(
            RobinhoodConfigProbe.batchMainnet(),
            30416,
            0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1,
            0xc02Ab410f0734EFa3F14628780e6e695156024C2
        );
    }

    // ------------------------------------------------------------ F2: DVN floors

    /// @dev Propose a receive config from home (Ethereum: floor 15) on pinned libraries; expect `reason`.
    function _refused(bytes memory uln, uint8 reason) internal {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, reason));
        rh.bridge.propose(_batch(_pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib), _cfg(receiveLib, HOME_EID, 2, uln)));
    }

    function test_reviewF2_refusesOneRequiredDvn() public {
        address[] memory one = new address[](1);
        one[0] = dvnA;
        _refused(_uln(15, 1, one), 3);
    }

    function test_reviewF2_refusesZeroRequiredDvnsMeaningDefaults() public {
        _refused(_uln(15, 0, new address[](0)), 3);
    }

    function test_reviewF2_refusesNilRequiredDvns() public {
        _refused(_uln(15, 255, new address[](0)), 3);
    }

    function test_reviewF2_refusesDvnListNotMatchingCount() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (dvnA, dvnB);
        _refused(_uln(15, 3, two), 4);
    }

    function test_reviewF2_refusesTwoRequiredDvns() public {
        // The floor is 3, so the old launch pair alone (e.g. LayerZero Labs + one other) is refused
        address[] memory two = new address[](2);
        (two[0], two[1]) = (dvnA, dvnB);
        _refused(_uln(15, 2, two), 3);
    }

    function test_reviewF2_floorIsThree() public view {
        assertEq(rh.bridge.MIN_REQUIRED_DVNS(), 3);
    }

    function test_reviewF2_refusesZeroDuplicateOrUnsortedDvns() public {
        _refused(_uln(15, 3, _dvns(address(0), dvnB)), 5);
        _refused(_uln(15, 3, _dvns(dvnA, dvnA)), 5); // one DVN counted twice
        _refused(_uln(15, 3, _dvns(dvnB, dvnA)), 5);
    }

    function test_reviewF2_refusesConfirmationsBelowTheSourceFloor() public {
        _refused(_uln(14, 3, _dvns(dvnA, dvnB)), 6); // from Ethereum: 15
        _refused(_uln(0, 3, _dvns(dvnA, dvnB)), 6); // 0 = the library default
        _refused(_uln(type(uint64).max, 3, _dvns(dvnA, dvnB)), 6); // NIL = no confirmations
        // home's SEND config: the source is Ethereum (15 passes); rh's SEND config: the source is 4663 (20 needed)
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, uint8(6)));
        rh.bridge.propose(
            _batch(_pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib), _cfg(sendLib, HOME_EID, 2, _uln(19, 3, _dvns(dvnA, dvnB))))
        );
        vm.prank(safe);
        rh.bridge.propose(
            _batch(_pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib), _cfg(sendLib, HOME_EID, 2, _uln(20, 3, _dvns(dvnA, dvnB))))
        );
        vm.prank(safe);
        home.bridge.propose(
            _batch(_pinSend(RH_EID, sendLib), _pinReceive(RH_EID, receiveLib), _cfg(sendLib, RH_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))))
        );
        // home RECEIVING from 4663: 20
        vm.prank(safe);
        home.bridge.cancel();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, uint8(6)));
        home.bridge.propose(
            _batch(_pinSend(RH_EID, sendLib), _pinReceive(RH_EID, receiveLib), _cfg(receiveLib, RH_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))))
        );
    }

    function test_reviewF2_refusesBadOptionalSet() public {
        address[] memory opt = new address[](1);
        opt[0] = dvnC;
        _refused(abi.encode(UlnConfig(15, 3, 1, 2, _dvns(dvnA, dvnB), opt)), 7); // threshold > count
        _refused(abi.encode(UlnConfig(15, 3, 2, 1, _dvns(dvnA, dvnB), opt)), 7); // count != length
        _refused(abi.encode(UlnConfig(15, 3, 1, 0, _dvns(dvnA, dvnB), opt)), 7); // threshold 0 with optionals
    }

    function test_reviewF2_refusesUnknownTypeExecutorOnReceiveAndZeroExecutor() public {
        _refusedRaw(_cfg(receiveLib, HOME_EID, 3, ""), 1);
        _refusedRaw(_cfg(receiveLib, HOME_EID, 1, abi.encode(uint32(10_000), address(0x4000))), 1); // executor on a receive lib
        _refusedRaw(_cfg(sendLib, HOME_EID, 1, abi.encode(uint32(10_000), address(0))), 2);
    }

    function _refusedRaw(bytes memory cfg, uint8 reason) internal {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, reason));
        rh.bridge.propose(_batch(_pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib), cfg));
    }

    function test_reviewF2_shippedConfigsPassTheFloors() public {
        // the launch configs' shape (3 sorted DVNs, executor on send, 15 from Ethereum / 20 from 4663) is accepted
        address[] memory set = _dvns(dvnA, dvnB);
        SetConfigParam[] memory sp = new SetConfigParam[](2);
        sp[0] = SetConfigParam(HOME_EID, 1, abi.encode(uint32(10_000), address(0x4000)));
        sp[1] = SetConfigParam(HOME_EID, 2, _uln(20, 3, set));
        _govern(
            rh.bridge,
            _batch(_pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib), abi.encode(uint8(2), sendLib, sp))
        );
        _govern(rh.bridge, _cfg(receiveLib, HOME_EID, 2, _uln(15, 3, set)));
        assertEq(rhEp.configCalls(address(rh.bridge)), 2);
    }

    // ------------------------------------------------------------ F3: void a verified forged payload

    address attacker = makeAddr("attacker");

    /// @dev A forged "home -> rh, `amount` to attacker" packet verified by a compromised DVN set; returns its index on homeEp.
    function _forged(uint256 amount) internal returns (uint256 i, uint64 n, bytes32 sender) {
        sender = _peer(home.bridge);
        bytes memory message = abi.encodePacked(bytes32(uint256(uint160(attacker))), uint64(amount / 1e12));
        i = homeEp.forge(RH_EID, _peer(rh.bridge), sender, message);
        n = homeEp.nonce();
    }

    function test_reviewF3_kelpSequenceGuardianNilifiesAndThePathReopens() public {
        _open();
        (uint256 i, uint64 n, bytes32 sender) = _forged(60_000e18);
        assertFalse(homeEp.deliver(i), "RateLimited: 60k > 50k inbound, stays verified at the endpoint");
        // guardian: pause + nilify, both instant
        vm.startPrank(guardian);
        rh.bridge.pause(HOME_EID);
        rh.bridge.nilify(HOME_EID, sender, n, keccak256("payload"));
        vm.stopPrank();
        assertEq(rhEp.voided(address(rh.bridge), HOME_EID, sender, n), 2);
        // the Safe reopens (48h): the forged packet is dead even with the full window free
        _govern(rh.bridge, abi.encode(uint8(5), HOME_EID));
        _warp(2 days);
        assertFalse(homeEp.deliver(i), "nilified: never executes");
        assertEq(rh.usd.balanceOf(attacker), 0);
        // honest traffic flows again on the same peer
        deal(address(home.usd), alice, 100e18, true);
        _sendFrom(alice, 100e18);
        assertTrue(homeEp.deliver(homeEp.packetCount() - 1));
        assertEq(rh.usd.balanceOf(alice), 100e18);
    }

    function test_reviewF3_withoutVoidingTheForgedPacketMintsAfterReopening() public {
        // the finding as it stood: pause + reopen does nothing for an already-verified packet
        _open();
        (uint256 i,,) = _forged(40_000e18);
        vm.prank(guardian);
        rh.bridge.pause(HOME_EID);
        assertFalse(homeEp.deliver(i));
        _govern(rh.bridge, abi.encode(uint8(5), HOME_EID));
        assertTrue(homeEp.deliver(i), "verified payload still executable");
        assertEq(rh.usd.balanceOf(attacker), 40_000e18);
    }

    function test_reviewF3_timelockedBurnAndSkipOnlyOnAPausedPath() public {
        _open();
        (uint256 i, uint64 n, bytes32 sender) = _forged(60_000e18);
        bytes memory burnIt = abi.encode(uint8(10), HOME_EID, sender, n, keccak256("payload"));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathOpen.selector, HOME_EID));
        rh.bridge.propose(burnIt);
        vm.prank(guardian);
        rh.bridge.pause(HOME_EID);
        _govern(rh.bridge, burnIt);
        assertEq(rhEp.voided(address(rh.bridge), HOME_EID, sender, n), 3);
        rhEp.reverify(address(rh.bridge), HOME_EID, sender, n);
        assertFalse(homeEp.deliver(i), "burned: not re-verifiable");
        // skip a nonce that was never verified
        _govern(rh.bridge, abi.encode(uint8(8), HOME_EID, sender, uint64(n + 1)));
        assertEq(rhEp.voided(address(rh.bridge), HOME_EID, sender, n + 1), 1);
        // a void naming this chain's own eid is refused
        vm.prank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.bridge.propose(abi.encode(uint8(9), RH_EID, sender, n, bytes32(0)));
    }

    function test_reviewF3_nilifyIsGuardianOrGovernorOnlyAndReverifiable() public {
        _open();
        (uint256 i, uint64 n, bytes32 sender) = _forged(1_000e18);
        vm.prank(attacker);
        vm.expectRevert(ImdBridge.Unauthorized.selector);
        rh.bridge.nilify(HOME_EID, sender, n, bytes32(0));
        vm.prank(safe);
        rh.bridge.nilify(HOME_EID, sender, n, bytes32(0));
        assertFalse(homeEp.deliver(i));
        // a nilified honest message is delayed, not lost: the DVNs re-verify it
        rhEp.reverify(address(rh.bridge), HOME_EID, sender, n);
        assertTrue(homeEp.deliver(i));
    }

    // ------------------------------------------------------------ F4: guardian from env, zero refused off a fork

    function test_reviewF4_deployScriptsRefuseAZeroGuardianOnARealChain() public {
        DeployMainnetBridge m = new DeployMainnetBridge();
        DeployRobinhood r = new DeployRobinhood();
        vm.setEnv("GUARDIAN", vm.toString(address(0)));
        vm.setEnv("FORK", "0");
        vm.chainId(1);
        vm.expectRevert(DeployMainnetBridge.NoGuardian.selector);
        m.guardianFromEnv();
        vm.chainId(4663);
        vm.expectRevert(DeployRobinhood.NoGuardian.selector);
        r.guardianFromEnv();
        // a rehearsal on a local fork (FORK=1) may leave it zero, with a warning
        vm.setEnv("FORK", "1");
        assertEq(r.guardianFromEnv(), address(0));
        // the operator's guardian address, from the environment
        address g = makeAddr("keeper guardian");
        vm.setEnv("GUARDIAN", vm.toString(g));
        vm.setEnv("FORK", "0");
        assertEq(m.guardianFromEnv(), g);
        assertEq(r.guardianFromEnv(), g);
        vm.setEnv("GUARDIAN", vm.toString(address(0))); // nothing else reads these; leave them inert
    }

    // ------------------------------------------------------------ F6: native fee exact

    /// @dev Funds alice BEFORE any expectRevert (deal's own calls would consume it), then sends.
    function _fund(uint256 amount) internal {
        deal(address(home.usd), alice, amount, true);
    }

    function _sendValue(uint256 value, uint256 declared, uint256 amount) internal {
        SendParam memory p = SendParam(RH_EID, bytes32(uint256(uint160(alice))), amount, 0, "", "", "");
        vm.prank(alice);
        home.bridge.send{value: value}(p, MessagingFee(declared, 0), alice);
    }

    function test_reviewF6_overpaymentRefusedNotStranded() public {
        _open();
        uint256 fee = homeEp.FEE();
        _fund(100e18);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotEnoughNative.selector, fee * 3));
        _sendValue(fee * 3, fee, 100e18);
        _sendValue(fee, fee, 100e18);
        assertEq(address(home.bridge).balance, 0, "nothing left behind");
    }

    function test_reviewF6_strandedBalanceCannotFundTheNextSender() public {
        _open();
        uint256 fee = homeEp.FEE();
        vm.deal(address(home.bridge), 1 ether); // e.g. an executor's native drop on lzReceive
        // declaring more than sent used to be paid from the bridge's balance and refunded to the caller
        _fund(100e18);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotEnoughNative.selector, 0));
        _sendValue(0, fee, 100e18);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotEnoughNative.selector, fee));
        _sendValue(fee, 1 ether, 100e18);
        assertEq(address(home.bridge).balance, 1 ether);
    }

    // ------------------------------------------------------------ F7: limit lowering + zero amounts

    function _inbound(ImdBridge b, uint32 eid) internal view returns (uint256 limit, uint256 inFlight) {
        (uint128 l,, uint128 f,) = b.inbound(eid);
        (limit, inFlight) = (l, f);
    }

    /// @dev Fill rh's inbound window from home (50k) with honest traffic.
    function _fillInbound() internal {
        deal(address(home.usd), alice, 50_000e18, true);
        _sendFrom(alice, 50_000e18);
        assertTrue(homeEp.deliver(homeEp.packetCount() - 1));
        assertEq(rh.bridge.availableIn(HOME_EID), 0);
    }

    function test_reviewF7_loweringALimitScalesWhatIsInFlight() public {
        _open();
        _fillInbound();
        // the Safe lowers rh's inbound 50k -> 1k a day (48h; _govern warps 48h first, so re-fill right before applying)
        vm.prank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, 1_000e18));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _fillInbound();
        rh.bridge.applyPending();
        (uint256 limit, uint256 inFlight) = _inbound(rh.bridge, HOME_EID);
        assertEq(limit, 1_000e18);
        assertEq(inFlight, 1_000e18, "full window stays full, scaled: 50k/50k -> 1k/1k");
        assertEq(rh.bridge.availableIn(HOME_EID), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(rh.bridge.availableIn(HOME_EID), 1_000e18, "one window at the new rate, not 50 days");
    }

    function test_reviewF7_halfUsedWindowStaysHalfUsedAfterALowering() public {
        _open();
        vm.prank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, 10_000e18));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        deal(address(home.usd), alice, 25_000e18, true);
        _sendFrom(alice, 25_000e18);
        assertTrue(homeEp.deliver(homeEp.packetCount() - 1));
        rh.bridge.applyPending();
        (, uint256 inFlight) = _inbound(rh.bridge, HOME_EID);
        assertEq(inFlight, 5_000e18);
        assertEq(rh.bridge.availableIn(HOME_EID), 5_000e18);
    }

    function test_reviewF7_raisingKeepsTheAbsoluteAmount() public {
        _open();
        vm.prank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, 100_000e18));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        deal(address(home.usd), alice, 10_000e18, true);
        _sendFrom(alice, 10_000e18);
        assertTrue(homeEp.deliver(homeEp.packetCount() - 1));
        rh.bridge.applyPending();
        (, uint256 inFlight) = _inbound(rh.bridge, HOME_EID);
        assertEq(inFlight, 10_000e18, "a raise is not scaled");
        assertEq(rh.bridge.availableIn(HOME_EID), 90_000e18);
    }

    function test_reviewF7_zeroAmountMessageDoesNotSnapTheWindow() public {
        _open();
        _fillInbound();
        (, uint256 before) = _inbound(rh.bridge, HOME_EID);
        // a zero-amount packet from the real peer (one LZ fee): delivered, mints nothing, moves no window
        bytes memory zero = abi.encodePacked(bytes32(uint256(uint160(attacker))), uint64(0));
        uint256 i = homeEp.forge(RH_EID, _peer(rh.bridge), _peer(home.bridge), zero);
        assertTrue(homeEp.deliver(i));
        (, uint256 after_) = _inbound(rh.bridge, HOME_EID);
        assertEq(after_, before);
        assertEq(rh.bridge.availableIn(HOME_EID), 0);
    }

    function test_reviewF7_zeroAmountSendRefused() public {
        _open();
        deal(address(home.usd), alice, 1e18, true);
        SendParam memory p = SendParam(RH_EID, bytes32(uint256(uint160(alice))), 1e11, 0, "", "", ""); // dust only
        uint256 fee = homeEp.FEE();
        vm.prank(alice);
        vm.expectRevert(ImdBridge.ZeroAmount.selector);
        home.bridge.send{value: fee}(p, MessagingFee(fee, 0), alice);
    }

    function _sendFrom(address from, uint256 amount) internal {
        SendParam memory p = SendParam(RH_EID, bytes32(uint256(uint160(from))), amount, 0, "", "", "");
        uint256 fee = homeEp.FEE();
        vm.prank(from);
        home.bridge.send{value: fee}(p, MessagingFee(fee, 0), from);
    }

    function _assertPins(bytes memory batch, uint32 eid, address s, address r) internal pure {
        (, bytes[] memory items) = abi.decode(batch, (uint8, bytes[]));
        assertEq(items.length, 5);
        (uint8 k1, uint32 e1, address l1) = abi.decode(items[1], (uint8, uint32, address));
        (uint8 k2, uint32 e2, address l2, uint256 grace) = abi.decode(items[2], (uint8, uint32, address, uint256));
        assertEq(k1, 3);
        assertEq(e1, eid);
        assertEq(l1, s);
        assertEq(k2, 4);
        assertEq(e2, eid);
        assertEq(l2, r);
        assertEq(grace, 0);
    }
}

import {RobinhoodConfig} from "../../script/DeployConfig.sol";

library RobinhoodConfigProbe {
    function batch4663() internal pure returns (bytes memory) {
        return RobinhoodConfig.launchBatch4663(RobinhoodConfig.mainnetPath(bytes32(uint256(1)), ""));
    }

    function batchMainnet() internal pure returns (bytes memory) {
        return RobinhoodConfig.launchBatchMainnet(RobinhoodConfig.robinhoodPathOnMainnet(bytes32(uint256(1)), ""));
    }
}
