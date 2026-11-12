// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract W1PlCode {}

contract W1PlJoin {
    address public token;
    address public ledger;
    constructor(address t, address l) { token = t; ledger = l; }
}

/// postLowerDepth, the instant "lower" of the posted depth, raises depth from 0 on a chain with no ImdDepth.
/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 4; the judge's proof): postLowerDepth never raises the depth from 0 on a chain with no ImdDepth.
contract AuditW1PostLowerDepthTest is Test {
    Parameters params;
    address gov = address(0xA11CE);
    bytes32 constant SIMD = "SIMD";

    function setUp() public {
        params = new Parameters(gov, address(this));
        address ledger = address(new W1PlCode());
        params.wire(ledger, address(new W1PlCode()));
        address coll = address(new W1PlCode());
        IFeed f = IFeed(address(new W1PlCode()));
        ParametersBase.Config memory c = ParametersBase.Config(
            coll, address(new W1PlJoin(coll, ledger)), f, f, IFeed(address(0)), address(0), address(0), IFeed(address(0)), true, false
        );
        ParametersBase.Risk memory r = ParametersBase.Risk({
            mat: 1.5e18, chop: 0.2e18, cut: 0, chip: 0, rateFloor: 0.01e18, yieldFee: 0, skew: 0.02e18,
            pegFloor: 0, line: 50_000e18, dust: 0, redeemFloor: 0.005e18, redeemDivisor: 1, redeemCap: 0
        });
        params.addGenesisIlk(SIMD, c, r);
        params.setGenesisDepthRule(SIMD, 0.8e18, 0, 0, 0); // no ImdDepth: posted depth 0 = zero depth
        params.seal();
    }

    function test_postLowerDepthNeverRaisesLine() public {
        assertEq(params.risk(SIMD).line, 0);
        vm.prank(gov);
        vm.expectRevert(ParametersBase.OutOfBounds.selector); // no ImdDepth: 0 is zero depth, so this is a raise
        params.postLowerDepth(1e30); // an instant "lower"
        assertEq(params.risk(SIMD).line, 0, "instant post raised the line");
    }
}