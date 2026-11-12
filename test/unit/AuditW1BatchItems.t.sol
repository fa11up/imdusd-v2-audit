// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract W1GovStub {}

contract W1GovStubJoin {
    address public token;
    address public ledger;

    constructor(address t, address l) {
        (token, ledger) = (t, l);
    }
}

/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 4; the auditors' proof, adapted): a BATCH item shorter
/// than two words (a SET_MIGRATOR_LINE / SET_DEPTH payload `propose` did not decode) made `Parameters._touches` revert,
/// so every instant per-type lower the batch locked reverted for EVERY type. `propose` now decodes both kinds (a
/// malformed one is refused there) and `_touches` skips an item too short to name a type.
contract AuditW1BatchItemsTest is Test {
    Parameters params;
    address gov = makeAddr("gov");
    bytes32 constant ETH = "ETH";
    bytes32 constant WBTC = "WBTC";

    function setUp() public {
        params = new Parameters(gov, address(this));
        address ledger = address(new W1GovStub());
        params.wire(ledger, address(new W1GovStub()));
        _add(ETH, ledger);
        _add(WBTC, ledger);
        params.seal();
    }

    function _risk(uint128 line) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: 1.5e18,
            chop: 0.1e18,
            cut: 0.1e18,
            chip: 0.01e18,
            rateFloor: 0.005e18,
            yieldFee: 0,
            skew: 0.02e18,
            pegFloor: 0,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 4,
            redeemCap: 0
        });
    }

    function _add(bytes32 ilk, address ledger) internal {
        address t = address(new W1GovStub());
        ParametersBase.Config memory c;
        c.token = t;
        c.join = address(new W1GovStubJoin(t, ledger));
        c.median = IFeed(address(new W1GovStub()));
        c.spot = c.median;
        c.redeemable = true;
        params.addGenesisIlk(ilk, c, _risk(1_000_000e18));
    }

    function _proposeBatch(bytes memory second) internal {
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(uint8(1), ETH, _risk(2_000_000e18)); // an ETH line raise
        items[1] = second;
        vm.prank(gov);
        params.propose(abi.encode(uint8(17), items)); // BATCH
    }

    /// Control: with well-formed items, the Safe can freeze WBTC at once and the ETH batch stays queued.
    function test_control_wellFormedBatchKeepsInstantLowers() public {
        _proposeBatch(abi.encode(uint8(3), uint256(0)));
        vm.prank(gov);
        params.lowerLine(WBTC, 0);
        assertEq(params.storedRisk(WBTC).line, 0);
    }

    /// The one-word item is refused at propose, alone or inside a batch.
    function test_malformedMigratorLineIsRefusedAtPropose() public {
        bytes[] memory items = new bytes[](2);
        items[0] = abi.encode(uint8(1), ETH, _risk(2_000_000e18));
        items[1] = abi.encode(uint8(3)); // one word
        vm.startPrank(gov);
        vm.expectRevert(bytes("")); // the one-word item fails to decode at propose (no reason data), not some other check
        params.propose(abi.encode(uint8(17), items));
        vm.expectRevert(bytes(""));
        params.propose(abi.encode(uint8(3)));
        vm.stopPrank();
        (, uint256 eta) = params.pendingOf(17);
        assertEq(eta, 0, "nothing queued");
    }

    /// The batch's own type can still be lowered at once (the lower cancels the batch, which carries its line).
    function test_instantLowerOfTheBatchedTypeStillWorks() public {
        _proposeBatch(abi.encode(uint8(3), uint256(0)));
        vm.prank(gov);
        params.lowerLine(ETH, 0);
        assertEq(params.storedRisk(ETH).line, 0);
        (, uint256 eta) = params.pendingOf(17);
        assertEq(eta, 0, "the batch carrying ETH's line is cancelled");
    }
}
