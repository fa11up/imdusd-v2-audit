// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {
    SwarmPricePolicy,
    SwarmNhiPolicy,
    SwarmQuestions,
    SwarmPriceFeed,
    SwarmSeatFeed,
    SwarmSeatMedianPolicy,
    SwarmSeatSpotPolicy,
    SwarmSeatMedianFeed,
    SwarmSeatSpotFeed
} from "../../src/feeds/SwarmFeeds.sol";

/// @dev The production question binding with a test signer (the plane's key is not ours).
contract TestPriceFeed is SwarmPricePolicy {
    constructor(address attester_, uint256 maxAge_) SwarmFeed(attester_, address(0), 1, 3, maxAge_, 2000) {}
}

contract TestNhiFeed is SwarmNhiPolicy {
    constructor(address attester_) SwarmFeed(attester_, address(0), 1, 3, 1 days, 2000) {}
}

contract TestSeatMedianFeed is SwarmSeatMedianPolicy {
    constructor(address attester_) SwarmFeed(attester_, address(0), 1, 3, 26 hours, 3000) {}
}

contract TestSeatSpotFeed is SwarmSeatSpotPolicy {
    constructor(address attester_) SwarmFeed(attester_, address(0), 1, 3, 26 hours, 5000) {}
}

/// @notice The v2 port of v1's SwarmFeed: v1's audited rules (bound question, absolute panel counts, never a ratio,
/// epoch bound) plus window freshness on a chain the data is not about.
contract SwarmFeedTest is Test {
    uint256 constant KEY = 0xA11CE;
    address attester;
    uint256 nonce;

    function setUp() public {
        attester = vm.addr(KEY);
        vm.chainId(4663);
        vm.roll(26_000_000); // on 4663, block.number reports Ethereum's head
        vm.warp(1_800_000_000);
    }

    function _att(SwarmFeed f, uint64 toBlock, uint256 value) internal returns (SwarmFeed.OracleAttestation memory a) {
        a.requestId = bytes32(++nonce);
        a.chainId = 1;
        a.answerType = 3;
        a.answer = abi.encode(value);
        a.fromBlock = toBlock - 600;
        a.toBlock = toBlock;
        a.questionHash = f.expectedQuestionHash(a.fromBlock, a.toBlock);
        a.panelSize = 100;
        a.quorum = 67;
        a.agreed = 67;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _digest(SwarmFeed f, SwarmFeed.OracleAttestation memory a) internal view returns (bytes32) {
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    f.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), h));
    }

    function _sign(SwarmFeed f, SwarmFeed.OracleAttestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(f, a));
        return abi.encodePacked(r, s, v);
    }

    function _submit(SwarmFeed f, SwarmFeed.OracleAttestation memory a) internal {
        f.submitAttestation(a, _sign(f, a, KEY));
    }

    // ------------------------------------------------------------ the question is the live v1 one

    /// @dev The real attestation v1 relayed (v1 record attestation-e2c85027): window 26120928..26121526,
    /// questionHash 0xc87a…c16e. Same prefix, same hash.
    function test_priceQuestionHashMatchesARealSignedAttestation() public {
        SwarmPriceFeed f = new SwarmPriceFeed(1 hours, 2000);
        assertEq(f.expectedQuestionHash(26120928, 26121526), 0xc87aa8a9fa49ca4885e3c3048e9159cd00578e7ad37188b1fce70199c510c16e);
    }

    /// @dev The same real attestation's SIGNATURE recovers to the plane's attester through this port's domain + typehash,
    /// rebuilt at its consumer (Sepolia, 0x5bbf…0462). (Its 60-member panel is below the 100 floor, so it is not submitted.)
    function test_realSignatureRecoversThroughThePortsDomain() public {
        vm.chainId(11155111);
        address at = 0x5bbFA44200AcE481388B0B69355F7Bd1FeAb0462;
        deployCodeTo("SwarmFeed.t.sol:TestPriceFeed", abi.encode(SwarmQuestions.ATTESTER, uint256(1 hours)), at);
        SwarmFeed f = SwarmFeed(at);
        SwarmFeed.OracleAttestation memory a;
        a.requestId = 0xe2c85027f00e4b988d7c713694509b6e00000000000000000000000000000000;
        a.chainId = 1;
        a.questionHash = 0xc87aa8a9fa49ca4885e3c3048e9159cd00578e7ad37188b1fce70199c510c16e;
        a.answerType = 3;
        a.answer = abi.encode(uint256(0x0d3ff87714bef1));
        a.figure = 3729511079526129;
        a.fromBlock = 26120928;
        a.toBlock = 26121526;
        a.blockHash = 0x661f90063244eaa60ab43a4b65a46dd1a58b2a6e03526f0f4c80c1ca04988429;
        a.panelJobId = 0x85d6177a7f9b4b938c1a76fc35f733b500000000000000000000000000000000;
        a.panelSize = 60;
        a.quorum = 20;
        a.agreed = 20;
        a.issuedAt = 1791147640;
        a.expiresAt = 1791234040;
        bytes memory sig =
            hex"8303bd1ea1bc22a4f4b32ac95dedb591d0facdc07e23fdbbe2ef3da4194bf8cf7d94b98d49ffe924b326b6980811fdb403a8ee7ca766ff9bd24cbfe8d8b85da21c";
        (bytes32 r, bytes32 s) = (bytes32(_slice(sig, 0)), bytes32(_slice(sig, 32)));
        assertEq(ecrecover(_digest(f, a), uint8(sig[64]), r, s), SwarmQuestions.ATTESTER);
    }

    function _slice(bytes memory b, uint256 o) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(add(b, 32), o))
        }
    }

    // ------------------------------------------------------------ v1's rules, unchanged

    function test_acceptsAndReadsTheSignedAnswer() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        assertEq(f.blockClockChainId(), 1, "on 4663 block.number is Ethereum's");
        _submit(f, _att(f, 25_999_990, 3e15));
        (uint256 v, uint64 at) = f.latestValue();
        assertEq(v, 3e15);
        assertEq(at, vm.getBlockTimestamp());
        assertFalse(f.isStale());
        assertEq(f.acceptedAt(), vm.getBlockTimestamp());
    }

    /// Audit wave 1, panel 6: a held attestation reports its relay time apart from its signature (the seat clock opens there).
    function test_acceptedAtIsTheRelayTimeNotTheSignature() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        SwarmFeed.OracleAttestation memory a = _att(f, 25_999_990, 3e15);
        uint64 signedAt = a.issuedAt;
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _submit(f, a);
        (, uint64 at) = f.latestValue();
        assertEq(at, signedAt, "latestValue keeps the signature time");
        assertEq(f.acceptedAt(), signedAt + 30 minutes, "acceptedAt is when it was relayed");
    }

    function test_absoluteFloorsNeverARatio() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        SwarmFeed.OracleAttestation memory a = _att(f, 25_999_990, 3e15);
        a.agreed = 66; // 66 of 100: below the absolute 67
        bytes memory sig = _sign(f, a, KEY);
        vm.expectRevert(SwarmFeed.NotEnoughAgreement.selector);
        f.submitAttestation(a, sig);
        a = _att(f, 25_999_990, 3e15);
        a.panelSize = 99;
        a.agreed = 99; // unanimous, but the panel is thinner than 100
        sig = _sign(f, a, KEY);
        vm.expectRevert(SwarmFeed.PanelTooSmall.selector);
        f.submitAttestation(a, sig);
        TestNhiFeed n = new TestNhiFeed(attester);
        a = _att(n, 25_999_990, 0.98e18);
        a.agreed = 51; // the NHI floor
        _submit(n, a);
    }

    function test_boundQuestionSignerReplayAndAnswer() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        SwarmFeed.OracleAttestation memory a = _att(f, 25_999_990, 3e15);
        a.questionHash = keccak256("another question");
        bytes memory sig = _sign(f, a, KEY);
        vm.expectRevert();
        f.submitAttestation(a, sig);
        a = _att(f, 25_999_990, 3e15);
        sig = _sign(f, a, 0xB0B);
        vm.expectRevert(SwarmFeed.InvalidSignature.selector);
        f.submitAttestation(a, sig);
        a.figure = 4e15; // a nonzero figure must equal the answer
        sig = _sign(f, a, KEY);
        vm.expectRevert(SwarmFeed.AnswerMismatch.selector);
        f.submitAttestation(a, sig);
        a.figure = 0;
        sig = _sign(f, a, KEY);
        f.submitAttestation(a, sig);
        vm.expectRevert(SwarmFeed.ReplayedAttestation.selector);
        f.submitAttestation(a, sig);
    }

    function test_epochBoundStillHolds() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        _submit(f, _att(f, 25_999_990, 3e15));
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.roll(26_000_025);
        SwarmFeed.OracleAttestation memory a = _att(f, 26_000_020, 3.7e15); // +23% inside the epoch
        bytes memory sig = _sign(f, a, KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        f.submitAttestation(a, sig);
    }

    // ------------------------------------------------------------ stale allowance cap

    /// @notice F2 (medium): after a silence the allowance is 2x the cap and never wider. It used to grow an eighth of the
    /// cap per further hour: 60% after the 10-hour plane outage of 2026-10-23, 100% after 26 hours, and whoever relayed
    /// first re-anchored the feed by that much. FAILED before the fix (the +45% value was accepted; the 26-hour allowance read 100%).
    function test_staleAllowanceCapsAtTwiceTheCap() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        _submit(f, _att(f, 25_999_990, 3e15));
        // Ten hours of silence.
        vm.warp(vm.getBlockTimestamp() + 10 hours);
        vm.roll(26_003_000);
        (,, uint256 allowance) = f.epoch();
        assertEq(allowance, 2 * f.maxDeviationBps(), "2x the cap after any silence, not 60%");
        assertFalse(f.accepts(3e15 * 141 / 100));
        SwarmFeed.OracleAttestation memory a = _att(f, 26_002_995, 3e15 * 145 / 100); // +45%: inside the OLD 60%
        bytes memory sig = _sign(f, a, KEY);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        f.submitAttestation(a, sig);
        // +39% is within 2x the cap: accepted, and it anchors the epoch.
        _submit(f, _att(f, 26_002_996, 3e15 * 139 / 100));
        (uint256 v,) = f.latestValue();
        assertEq(v, 3e15 * 139 / 100);
        // A day of silence later: still 2x the cap (it used to be 100%: any value).
        vm.warp(vm.getBlockTimestamp() + 26 hours);
        vm.roll(26_003_000 + 7_800);
        (,, allowance) = f.epoch();
        assertEq(allowance, 2 * f.maxDeviationBps());
        assertFalse(f.accepts(2 * v), "a 2x value is refused however long the silence");
        assertTrue(f.accepts(v * 139 / 100), "a value inside 2x the cap is not");
    }

    /// @notice F6 (low): two attestations signed in the same second can only be relayed in WINDOW order: the later
    /// window first makes the earlier one `WindowNotAdvancing`, so the order is deterministic (it was before the fix too:
    /// recorded as the rule rather than changed, because SeatFeed relies on an equal-time replacement being admitted).
    function test_equalIssuedAtOrderIsTheWindowOrder() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        _submit(f, _att(f, 25_999_990, 3e15));
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.roll(26_000_025);
        SwarmFeed.OracleAttestation memory older = _att(f, 26_000_010, 3.1e15);
        SwarmFeed.OracleAttestation memory newer = _att(f, 26_000_020, 3.2e15); // the same issuedAt, a later window
        assertEq(older.issuedAt, newer.issuedAt);
        _submit(f, newer);
        bytes memory sig = _sign(f, older, KEY);
        vm.expectRevert(abi.encodeWithSelector(SwarmFeed.WindowNotAdvancing.selector, uint64(26_000_010), uint64(26_000_020)));
        f.submitAttestation(older, sig);
        (uint256 v,) = f.latestValue();
        assertEq(v, 3.2e15, "the later window stands");
        // In window order both land and the later window still ends on top.
        TestPriceFeed g = new TestPriceFeed(attester, 1 hours);
        _submit(g, _att(g, 25_999_990, 3e15));
        _submit(g, _att(g, 26_000_010, 3.1e15));
        _submit(g, _att(g, 26_000_020, 3.2e15));
        (v,) = g.latestValue();
        assertEq(v, 3.2e15);
    }

    // ------------------------------------------------------------ freshness on a remote chain (the port's addition)

    function test_blockClockWithSequencerSlack() public {
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        SwarmFeed.OracleAttestation memory a = _att(f, 26_000_301, 3e15);
        bytes memory sig = _sign(f, a, KEY);
        vm.expectRevert(abi.encodeWithSelector(SwarmFeed.WindowInFuture.selector, uint64(26_000_301), uint256(26_000_000)));
        f.submitAttestation(a, sig);
        a = _att(f, 25_999_699, 3e15); // 301 blocks old: more than a lifetime (300 x 12 s)
        sig = _sign(f, a, KEY);
        vm.expectRevert(abi.encodeWithSelector(SwarmFeed.WindowTooOld.selector, uint64(25_999_699), uint256(26_000_000)));
        f.submitAttestation(a, sig);
        _submit(f, _att(f, 26_000_300, 3e15)); // the sequencer's L1 number lags the real head: accepted
    }

    function test_mainnetKeepsV1RuleExactly() public {
        vm.chainId(1);
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        SwarmFeed.OracleAttestation memory a = _att(f, 26_000_001, 3e15);
        bytes memory sig = _sign(f, a, KEY);
        vm.expectRevert(abi.encodeWithSelector(SwarmFeed.WindowInFuture.selector, uint64(26_000_001), uint256(26_000_000)));
        f.submitAttestation(a, sig);
        _submit(f, _att(f, 26_000_000, 3e15));
        assertEq(f.clockAt(), 0, "no time clock where the data is local");
    }

    /// @dev A chain with no block clock (block.number is its own): only the time clock judges the window.
    function test_timeClockRefusesAnOldWindowSignedFresh() public {
        vm.chainId(8453);
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        assertEq(f.blockClockChainId(), 8453);
        vm.roll(1); // this chain's own numbers say nothing about Ethereum's
        _submit(f, _att(f, 26_000_000, 3e15)); // the first value sets the clock (the deployment's to check, as v1)
        assertEq(f.clockBlock(), 26_000_000);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        // two hours later a buyer has the window from 1h50m ago signed now: refused
        SwarmFeed.OracleAttestation memory a = _att(f, 26_000_050, 3e15);
        bytes memory sig = _sign(f, a, KEY);
        uint256 projected = f.projectedHead(uint64(vm.getBlockTimestamp()));
        assertEq(projected, 26_000_000 + 581, "600 blocks in 2h, less the 1/32 drift allowance (rounded down)");
        vm.expectRevert(abi.encodeWithSelector(SwarmFeed.WindowBehindClock.selector, uint64(26_000_050), projected));
        f.submitAttestation(a, sig);
        // an honest window at the head, even with a few missed slots, is accepted
        _submit(f, _att(f, 26_000_590, 3e15));
    }

    /// @dev A run of laggy-but-allowed windows cannot walk the clock into the past: it advances along the slow projection.
    function test_timeClockCannotBeWalkedBack() public {
        vm.chainId(8453);
        TestPriceFeed f = new TestPriceFeed(attester, 1 hours);
        _submit(f, _att(f, 26_000_000, 3e15));
        uint64 to = 26_000_000;
        bool refused;
        for (uint256 i; i < 40; ++i) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            to += 1; // advances, but barely: each window older relative to the head than the last
            SwarmFeed.OracleAttestation memory a = _att(f, to, 3e15);
            bytes memory sig = _sign(f, a, KEY);
            try f.submitAttestation(a, sig) {}
            catch {
                refused = true;
                assertGt(i, 10, "allowed while within one lifetime of the projected head");
                assertLt(i, 14, "refused once more than a lifetime behind");
                break;
            }
        }
        assertTrue(refused);
    }

    // ------------------------------------------------------------ the seat legs (beta seats, 2026-10-26)

    /// @dev The two hashes are the plane's own oracleQuestionHash of the frozen payloads
    /// over the window of the live test attestation 55b17093 (26223897..26274136): the pinned
    /// prefix + that window + "}}" is the very document the attester hashes.
    function test_seatQuestionsMatchThePlane() public {
        SwarmSeatMedianFeed m = new SwarmSeatMedianFeed(26 hours, 3000);
        SwarmSeatSpotFeed s = new SwarmSeatSpotFeed(26 hours, 5000);
        assertEq(m.expectedQuestionHash(26223897, 26274136), 0x9a2a1d854239023e28f96c68638808d83fc4b31c8323b1d059e2fcdb92033f85);
        assertEq(s.expectedQuestionHash(26223897, 26274136), 0xd4f124132f999070c20f5770cff09cbdad1bec6bcf7cf703375780d86ea9b72b);
        assertEq(m.attester(), SwarmQuestions.ATTESTER);
        assertEq(m.minAgreed(), 51);
        assertEq(s.minAgreed(), 51);
    }

    function _seatAtt(SwarmFeed f, uint64 toBlock, uint64 span, uint256 value, uint256 figure)
        internal
        returns (SwarmFeed.OracleAttestation memory a)
    {
        a = _att(f, toBlock, value);
        a.fromBlock = toBlock - span;
        a.questionHash = f.expectedQuestionHash(a.fromBlock, a.toBlock);
        a.quorum = 51;
        a.agreed = 51;
        a.figure = figure;
    }

    /// The seat legs keep the figure (distinct seats sold) beside the price; a price feed still refuses a figure that
    /// is not its answer.
    function test_seatFeedKeepsTheCount() public {
        TestSeatMedianFeed m = new TestSeatMedianFeed(attester);
        SwarmFeed.OracleAttestation memory a = _seatAtt(m, 25_999_990, 50_239, 1e18, 42);
        _submit(m, a);
        (uint256 v,) = m.latestValue();
        assertEq(v, 1e18);
        assertEq(SwarmSeatFeed(address(m)).latestFigure(), 42);
        TestSeatSpotFeed s = new TestSeatSpotFeed(attester);
        a = _seatAtt(s, 25_999_990, 7_200, 1.27e18, 4);
        _submit(s, a);
        assertEq(SwarmSeatFeed(address(s)).latestFigure(), 4);
        // The price feed keeps v1's rule.
        TestPriceFeed p = new TestPriceFeed(attester, 1 hours);
        a = _att(p, 25_999_990, 3e15);
        a.figure = 42;
        bytes memory sig = _sign(p, a, KEY);
        vm.expectRevert(SwarmFeed.AnswerMismatch.selector);
        p.submitAttestation(a, sig);
    }

    function test_seatFeedSpanAndPanelFloors() public {
        TestSeatMedianFeed m = new TestSeatMedianFeed(attester);
        SwarmFeed.OracleAttestation memory a = _seatAtt(m, 25_999_990, 7_200, 1e18, 42); // a day is not a week
        bytes memory sig = _sign(m, a, KEY);
        vm.expectRevert(abi.encodeWithSelector(SwarmFeed.WindowSpanOutOfRange.selector, uint64(7_200)));
        m.submitAttestation(a, sig);
        a = _seatAtt(m, 25_999_990, 50_239, 1e18, 42);
        a.panelSize = 25; // the live test request's panel: thinner than the floor
        a.agreed = 12;
        sig = _sign(m, a, KEY);
        vm.expectRevert(SwarmFeed.PanelTooSmall.selector);
        m.submitAttestation(a, sig);
        a.panelSize = 100;
        a.agreed = 50; // one short of a strict majority
        sig = _sign(m, a, KEY);
        vm.expectRevert(SwarmFeed.NotEnoughAgreement.selector);
        m.submitAttestation(a, sig);
        a.agreed = 51;
        sig = _sign(m, a, KEY);
        m.submitAttestation(a, sig);
        assertEq(SwarmSeatFeed(address(m)).latestFigure(), 42);
    }
}
