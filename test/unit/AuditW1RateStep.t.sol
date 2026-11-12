// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {RateManager, IManagedLedger} from "src/managers/RateManager.sol";

contract W1PrLedger {
    address public nft = address(0xBEEF);
    function RATE_COOLDOWN() external pure returns (uint256) { return 7 days; }
}

/// With a type minRate of 0 (accepted by the constructor), a target of 0 stores lastRate = 0, which
/// `setRates` reads as "no prior call": the next call skips the maxStep check entirely.
/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 4; the judge's proof): RateManager keeps the maxStep reference after a target of 0.
contract AuditW1RateStepTest is Test {
    RateManager rm;
    bytes32 constant ETH = "ETH";

    function setUp() public {
        bytes32[] memory ilks = new bytes32[](1);
        uint64[] memory mins = new uint64[](1);
        uint64[] memory maxs = new uint64[](1);
        (ilks[0], mins[0], maxs[0]) = (ETH, 0, 0.2e18);
        rm = new RateManager(IManagedLedger(address(new W1PrLedger())), address(this), ilks, mins, maxs, 1 hours, 0.01e18);
    }

    function test_maxStepHoldsAfterZeroTarget() public {
        uint256[] memory none = new uint256[](0);
        vm.warp(1_000_000);
        rm.setRates(ETH, 0.01e18, none, none, none); // first call: 1%
        vm.warp(1_000_000 + 1 hours);
        rm.setRates(ETH, 0, none, none, none); // one 1-point step down to 0: allowed
        vm.warp(1_000_000 + 2 hours);
        vm.expectRevert(RateManager.StepTooLarge.selector); // expected: 0 -> 20% is a 20-point step
        rm.setRates(ETH, 0.2e18, none, none, none); // actual: accepted (prior == 0 skips the check)
    }
}