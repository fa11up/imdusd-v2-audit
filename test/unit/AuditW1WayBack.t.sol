// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "src/feeds/SwarmFeeds.sol";

/// @dev A price leaf with the production PRICE question, a test attester, 1h lifetime, 20% cap (BetaConfig values).
contract W1WayBackLeaf is SwarmPricePolicy {
    constructor(address att) SwarmFeed(att, address(0), 1, 3, 1 hours, 2000) {}
}

/// SwarmFeed._returnAnchor ("the way back") accepts a value within the cap of the EXPIRED epoch's level even when
/// that value is 50% away from the last accepted value, with no silence at all. The README trust model says a value
/// "moves at most a fixed cap per epoch, widened at most 2x after an hour of staleness"; here a fresh feed moves
/// +50% in one accepted attestation (0.8A -> 1.2A). Fails on this commit (the value is accepted); passes once the
/// way back only admits values between the last accepted value and the expired epoch's level.
/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 3; the permissions specialist's proof, adapted: its
/// signature is now made before expectRevert, which the original pointed at the signing call). The way back is bounded by
/// 2x the cap from the last accepted value too. The second test pins the lock-out a tighter bound caused (pre-publish
/// review of the wave-2 snapshot): only values between the last one and the level refused an honest fall past the level.
contract AuditW1WayBackTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 nonce;
    W1WayBackLeaf f;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_000_000);
        vm.warp(1_800_000_000);
        f = new W1WayBackLeaf(vm.addr(KEY));
    }

    function _att(uint256 value) internal returns (SwarmFeed.OracleAttestation memory a) {
        uint64 toBlock = uint64(block.number);
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
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(SwarmFeed.OracleAttestation memory a) internal view returns (bytes memory) {
        bytes32 h = keccak256(
            bytes.concat(
                abi.encode(
                    f.ATTESTATION_TYPEHASH(), a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), h)));
        return abi.encodePacked(r, s, v);
    }

    function _advance(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12);
    }

    function test_wayBackRefusesAFiftyPercentStepPastTheLevel() public {
        uint256 A = 4e15; // wei of ETH per 1e18 IMD, the order of the live feed
        // t0: the first value anchors epoch 1 at A with the 20% cap.
        SwarmFeed.OracleAttestation memory first = _att(A);
        f.submitAttestation(first, _sign(first));
        // t0 + 59 min: the market fell 20%; an honest attestation of 0.8A is accepted (within the cap of the anchor).
        _advance(59 minutes);
        SwarmFeed.OracleAttestation memory lo = _att(A * 80 / 100);
        f.submitAttestation(lo, _sign(lo));
        (uint256 v,) = f.latestValue();
        assertEq(v, A * 80 / 100);
        assertFalse(f.isStale(), "the feed is fresh: no silence has been earned");

        // t0 + 60 min: epoch 1 has just expired. The cap from the last value (0.8A, fresh) admits at most 0.96A.
        _advance(1 minutes);
        (uint256 anchor, , uint256 allowanceBps) = f.epoch();
        assertEq(anchor, A * 80 / 100, "the next epoch anchors on the last value");
        assertEq(allowanceBps, 2000, "with the plain cap: the feed is fresh");

        // Yet 1.2A, +50% from the last accepted value, is accepted through the way back (within the cap of A).
        SwarmFeed.OracleAttestation memory hi = _att(A * 120 / 100);
        bytes memory sig = _sign(hi);
        vm.expectRevert(SwarmFeed.ExcessDeviation.selector);
        f.submitAttestation(hi, sig);
    }

    /// A push to 1.2A in the last minute of an epoch anchored at A, then the market at 0.95A: the way back must take the
    /// honest value at once (5% from the level, 21% from the pushed last value, inside 2x the cap), not two hours later.
    function test_honestFallPastTheLevelAfterAPushIsNotLockedOut() public {
        uint256 A = 4e15;
        SwarmFeed.OracleAttestation memory first = _att(A);
        f.submitAttestation(first, _sign(first));
        _advance(59 minutes);
        SwarmFeed.OracleAttestation memory pushed = _att(A * 120 / 100);
        f.submitAttestation(pushed, _sign(pushed));
        _advance(2 minutes);
        SwarmFeed.OracleAttestation memory honest = _att(A * 95 / 100);
        f.submitAttestation(honest, _sign(honest));
        (uint256 v,) = f.latestValue();
        assertEq(v, A * 95 / 100, "accepted at t0 + 61 min");
    }
}
