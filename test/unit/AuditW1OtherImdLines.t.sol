// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract W1PoCode {}

contract W1PoJoin {
    address public token;
    address public ledger;
    constructor(address t, address l) { token = t; ledger = l; }
}

contract W1PoFeed {
    function latestValue() external view returns (uint256, uint64) { return (1e18, uint64(block.timestamp)); }
    function isStale() external pure returns (bool) { return false; }
    function maxAge() external pure returns (uint256) { return 1 hours; }
}

/// `lowerOtherImdLines` is an instant governor act that RAISES the depth-gated type's effective line
/// (`risk(depthIlk).line` = min(stored, depthLine())), with no 48h timelock. Beta values: k 0.8, otherImdLines
/// 3,000 at chop 0.2, sIMD chop 0.2.
/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 4; the judge's proof): lowerOtherImdLines is refused while the depth line binds (it would raise the enforced sIMD line).
contract AuditW1OtherImdLinesTest is Test {
    Parameters params;
    address gov = address(0xA11CE);
    bytes32 constant SIMD = "SIMD";

    function setUp() public {
        params = new Parameters(gov, address(this));
        address ledger = address(new W1PoCode());
        address token = address(new W1PoCode());
        params.wire(ledger, token);
        address coll = address(new W1PoCode());
        address join = address(new W1PoJoin(coll, ledger));
        IFeed f = IFeed(address(new W1PoFeed()));
        ParametersBase.Config memory c = ParametersBase.Config(
            coll, join, f, f, IFeed(address(0)), address(0), address(0), IFeed(address(0)), true, false
        );
        ParametersBase.Risk memory r = ParametersBase.Risk({
            mat: 1.5e18, chop: 0.2e18, cut: 0, chip: 0, rateFloor: 0.01e18, yieldFee: 0, skew: 0.02e18,
            pegFloor: 0, line: 50_000e18, dust: 0, redeemFloor: 0.005e18, redeemDivisor: 1, redeemCap: 0
        });
        params.addGenesisIlk(SIMD, c, r);
        // no ImdDepth here, so the posted 60k is the depth: room 48k, other chains 3,600, line (48k-3.6k)/1.2 = 37k
        params.setGenesisDepthRule(SIMD, 0.8e18, 60_000e18, 3_000e18, 0.2e18);
        params.seal();
    }

    function test_instantLowerDoesNotRaiseDepthGatedLine() public {
        uint256 before = params.risk(SIMD).line;
        assertEq(before, 37_000e18);
        vm.prank(gov);
        vm.expectRevert(ParametersBase.OutOfBounds.selector); // the depth line binds: refused, not raised
        params.lowerOtherImdLines(0); // the other chain still runs its 3,000 line; nothing checks that
        // Expected (README invariant 7 / trust model: instant acts only reduce risk): the sIMD line does not rise.
        assertLe(params.risk(SIMD).line, before, "instant act raised the sIMD line"); // before the fix: 40,000
    }
}