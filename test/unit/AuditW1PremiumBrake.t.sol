// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Join} from "../../src/Join.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";

/// @dev Permissions panel proofs: each test encodes the property the code's own NatSpec claims and fails on this commit.
contract W1PbProofPermissionsTest is System {
    bytes32 constant ETH = "ETH";

    MockERC20 weth;
    MockERC20 v1;
    MockFeed feed;
    Join ethJoin;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        v1 = new MockERC20("imdUSDv1", 18);
        feed = new MockFeed(2000e18);
        _deploySystem(IERC20(address(v1)));
        ethJoin = _addIlk(ETH, address(weth), feed, feed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 1_000_000e18));
        params.setGenesisCap(ETH, 1500e18); // a borrow price ceiling below the market (Sky's capped OSM)
        params.seal();
        address[2] memory us = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            weth.mint(us[i], 1000e18);
            vm.prank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
        }
    }

    function _open(address u, uint256 salt, uint256 coll, uint256 debt, uint64 rate) internal returns (uint256 id) {
        vm.prank(u);
        id = ledger.open(ETH, salt, Adjust(int256(coll), int256(debt), rate, 0, 0, false, type(uint256).max, address(0)));
    }

    /// LedgerBase.sol:164-166 and :320-321: while `unbacked()` is past the brake, "no new debt on any type". `_adjust`
    /// checks the brake on a borrow (Ledger.sol:301); `setRate`'s charged premium adds debt without it (Ledger.sol:159-166).
    function test_chargedRateChangeStopsAtTheUnbackedBrake() public {
        uint256 a = _open(alice, 0, 10e18, 10_000e18, 0.05e18); // CR at the cap (1500): 150%
        uint256 b = _open(bob, 0, 100e18, 20_000e18, 0.05e18);
        feed.set(500e18); // alice: 10 ETH = 5,000 against ~10,010 of debt; bob stays at CR 250%
        vm.prank(bob);
        liquidator.liquidate(a); // bob pays 5,000, ~5,010 is booked bad debt; the Treasury covers only its ~29 of fees
        assertGt(ledger.unbacked(), usd.circulating() / 100, "braked");
        vm.prank(bob);
        vm.expectPartialRevert(LedgerBase.Braked.selector);
        ledger.adjust(b, Adjust(0, 1, 0, 0, 0, false, type(uint256).max, address(0)));
        uint256 before = ledger.debtOf(b);
        vm.prank(bob);
        vm.expectPartialRevert(LedgerBase.Braked.selector); // expected: Braked, as for any other new debt
        ledger.setRate(b, 0.06e18, 0, 0);
        assertEq(ledger.debtOf(b), before, "no new debt while braked");
    }
}