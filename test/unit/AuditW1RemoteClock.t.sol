// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmFeed} from "src/feeds/SwarmFeed.sol";
import {SwarmPricePolicy} from "src/feeds/SwarmFeeds.sol";

/// @dev The production question binding with a test signer.
contract W1ClockFeed is SwarmPricePolicy {
    constructor(address attester_) SwarmFeed(attester_, address(0), 1, 3, 1 hours, 2_000) {}
}

/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 3; the judge's proof): on a consumer chain other than the
/// data chain, a window ending past the most blocks Ethereum can have made since the clock is refused.
contract AuditW1RemoteClockTest is Test {
    uint256 constant KEY = 0xA11CE;
    address attester;
    uint256 nonce;

    function setUp() public {
        attester = vm.addr(KEY);
        vm.chainId(8453);
        vm.roll(1);
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
                    f.ATTESTATION_TYPEHASH(),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", f.DOMAIN_SEPARATOR(), h));
    }

    function _submit(SwarmFeed f, SwarmFeed.OracleAttestation memory a) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, _digest(f, a));
        f.submitAttestation(a, abi.encodePacked(r, s, v));
    }

    /// @dev FAILS on the audited commit: the future window is accepted (no revert). Passes once the time
    /// clock also bounds `toBlock` from above (e.g. `toBlock <= projectedHead(issuedAt) + PARENT_SLACK`).
    function test_futureWindowIsRefused() public {
        W1ClockFeed f = new W1ClockFeed(attester);
        _submit(f, _att(f, 26_000_000, 3e15));
        assertEq(f.clockBlock(), 26_000_000);

        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        SwarmFeed.OracleAttestation memory future = _att(f, 1_000_000_000_000, 3e15);
        vm.expectPartialRevert(SwarmFeed.WindowInFuture.selector);
        this.submitAs(f, future);
    }

    function submitAs(SwarmFeed f, SwarmFeed.OracleAttestation memory a) external {
        _submit(f, a);
    }
}