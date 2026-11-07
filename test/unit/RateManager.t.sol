// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {RateManager, IManagedLedger} from "../../src/managers/RateManager.sol";

/// @notice Rate delegation outside the core. Members grant SET_RATE only; the manager re-rates them only
/// outside their own cooldown (no premium, no debt added), inside the type's bounds and their own floor/ceiling.
contract RateManagerTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant OTHER = "OTHER";

    MockERC20 weth;
    MockERC20 wbtc;
    MockFeed ethFeed;
    MockFeed btcFeed;
    PositionNFT nft;
    RateManager rm;

    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    uint64 constant MIN = 0.02e18;
    uint64 constant MAX = 0.2e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        wbtc = new MockERC20("WBTC", 18);
        ethFeed = new MockFeed(2000e18);
        btcFeed = new MockFeed(50_000e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 100_000_000e18));
        _addIlk(OTHER, address(wbtc), btcFeed, btcFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 100_000_000e18));
        params.seal();
        nft = ledger.nft();
        bytes32[] memory ilks = new bytes32[](1);
        uint64[] memory mins = new uint64[](1);
        uint64[] memory maxs = new uint64[](1);
        (ilks[0], mins[0], maxs[0]) = (ETH, MIN, MAX);
        rm = new RateManager(IManagedLedger(address(ledger)), keeper, ilks, mins, maxs, 1 hours, 0.05e18);
        address[3] memory us = [alice, bob, eve];
        for (uint256 i; i < us.length; ++i) {
            weth.mint(us[i], 100_000e18);
            wbtc.mint(us[i], 1_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            wbtc.approve(address(ledger), type(uint256).max);
            usd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _open(address u, bytes32 ilk, uint256 salt, uint256 c, uint256 d, uint64 rate) internal returns (uint256 id) {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        vm.prank(u);
        id = ledger.open(ilk, salt, Adjust(int256(c), int256(d), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _joinNew(address u, uint256 salt) internal returns (uint256 id) {
        id = _open(u, ETH, salt, 10e18, 5_000e18, 0.05e18);
        vm.startPrank(u);
        nft.approveOperator(id, address(rm), 4);
        rm.join(id, 0, 0);
        vm.stopPrank();
    }

    function _one(uint256 id) internal pure returns (uint256[] memory a, uint256[] memory z) {
        a = new uint256[](1);
        a[0] = id;
        z = new uint256[](1);
    }

    function _set(uint64 rate, uint256 id) internal returns (uint256 rated) {
        (uint256[] memory ids, uint256[] memory z) = _one(id);
        vm.prank(keeper);
        rated = rm.setRates(ETH, rate, ids, z, z);
    }

    function _pastCooldown() internal {
        vm.warp(block.timestamp + 7 days + 1);
        ethFeed.set(ethFeed.value());
        btcFeed.set(btcFeed.value());
    }

    // ------------------------------------------------------------ membership

    function test_joinNeedsOwnerTypeAndRight() public {
        uint256 id = _open(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        vm.prank(alice);
        vm.expectRevert(RateManager.NoRight.selector);
        rm.join(id, 0, 0);
        vm.prank(alice);
        nft.approveOperator(id, address(rm), 4);
        vm.prank(bob);
        vm.expectRevert(RateManager.Unauthorized.selector);
        rm.join(id, 0, 0);
        uint256 other = _open(alice, OTHER, 0, 1e18, 5_000e18, 0.05e18);
        vm.startPrank(alice);
        nft.approveOperator(other, address(rm), 4);
        vm.expectRevert(RateManager.NotListed.selector);
        rm.join(other, 0, 0);
        vm.expectRevert(RateManager.OutOfBounds.selector);
        rm.join(id, 0.01e18, 0); // own floor below the manager's bounds
        rm.join(id, 0.03e18, 0.1e18);
        vm.stopPrank();
        (address owner, uint64 floor, uint64 ceiling,) = rm.members(id);
        assertEq(owner, alice);
        assertEq(floor, 0.03e18);
        assertEq(ceiling, 0.1e18);
    }

    function test_memberCanAlwaysLeaveAndSetOwnRate() public {
        uint256 id = _joinNew(alice, 0);
        _pastCooldown();
        vm.prank(alice);
        rm.leave(id);
        assertEq(_set(0.08e18, id), 0, "a leaver is never rated");
        vm.prank(alice);
        ledger.setRate(id, 0.12e18, 0, 0); // own rate, directly on the Ledger, always
        assertEq(ledger.position(id).rate, 0.12e18);
    }

    // ------------------------------------------------------------ rating

    function test_ratesInsideBoundsOutsideCooldown() public {
        uint256 id = _joinNew(alice, 0);
        // Opened just now: inside its own cooldown, so it is skipped (the Ledger would charge a premium).
        assertEq(_set(0.08e18, id), 0, "skipped inside cooldown");
        assertEq(ledger.position(id).rate, 0.05e18);
        _pastCooldown();
        uint256 debtBefore = ledger.debtOf(id);
        assertEq(_set(0.08e18, id), 1);
        assertEq(ledger.position(id).rate, 0.08e18);
        assertEq(ledger.debtOf(id), debtBefore, "no premium: the manager never adds debt");
    }

    function test_boundsStepAndFrequencyEnforced() public {
        uint256 id = _joinNew(alice, 0);
        _pastCooldown();
        (uint256[] memory ids, uint256[] memory z) = _one(id);
        vm.startPrank(keeper);
        vm.expectRevert(RateManager.OutOfBounds.selector);
        rm.setRates(ETH, 0.01e18, ids, z, z);
        vm.expectRevert(RateManager.OutOfBounds.selector);
        rm.setRates(ETH, 0.21e18, ids, z, z);
        rm.setRates(ETH, 0.08e18, ids, z, z);
        vm.expectRevert(abi.encodeWithSelector(RateManager.TooSoon.selector, block.timestamp + 1 hours));
        rm.setRates(ETH, 0.09e18, ids, z, z);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(RateManager.StepTooLarge.selector);
        rm.setRates(ETH, 0.14e18, ids, z, z); // more than 5 pts from the last target
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert(RateManager.Unauthorized.selector);
        rm.setRates(ETH, 0.09e18, ids, z, z);
    }

    function test_memberFloorAndCeilingClampTheTarget() public {
        uint256 id = _joinNew(alice, 0);
        vm.prank(alice);
        rm.setLimits(id, 0.06e18, 0.07e18);
        _pastCooldown();
        _set(0.03e18, id); // the manager pushes low: the member's floor holds
        assertEq(ledger.position(id).rate, 0.06e18, "floor");
        vm.warp(block.timestamp + 7 days + 1 hours);
        ethFeed.set(ethFeed.value());
        vm.prank(keeper);
        (uint256[] memory ids, uint256[] memory z) = _one(id);
        rm.setRates(ETH, 0.08e18, ids, z, z); // the manager pushes high: the member's ceiling holds
        assertEq(ledger.position(id).rate, 0.07e18, "ceiling");
    }

    // ------------------------------------------------------------ isolation and griefing

    function test_managerHoldsOnlySetRate() public {
        uint256 id = _joinNew(alice, 0);
        // The manager contract cannot move collateral or debt: the Ledger checks the right on every action.
        vm.prank(address(rm));
        vm.expectRevert();
        ledger.adjust(id, Adjust(-1e18, 0, 0, 0, 0, false, type(uint256).max, address(rm)));
        vm.prank(address(rm));
        vm.expectRevert();
        ledger.adjust(id, Adjust(0, 100e18, 0, 0, 0, false, type(uint256).max, address(rm)));
    }

    function test_revokedRightOrTransferEndsManagement() public {
        uint256 a = _joinNew(alice, 0);
        uint256 b = _joinNew(bob, 0);
        _pastCooldown();
        vm.prank(alice);
        nft.approveOperator(a, address(rm), 0); // revoke on the NFT, without leaving
        vm.prank(bob);
        nft.transferFrom(bob, eve, b); // the new owner never joined
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        uint256[] memory z = new uint256[](2);
        vm.prank(keeper);
        assertEq(rm.setRates(ETH, 0.08e18, ids, z, z), 0);
        assertEq(ledger.position(a).rate, 0.05e18);
        assertEq(ledger.position(b).rate, 0.05e18);
    }

    function test_managerCannotMakeAPositionLiquidatable() public {
        // A position near its line: a rate change outside cooldown adds no debt, so health is unchanged.
        uint256 id = _open(alice, ETH, 0, 10e18, 14_000e18, 0.05e18); // ~142% vs mat 140%
        vm.startPrank(alice);
        nft.approveOperator(id, address(rm), 4);
        rm.join(id, 0, 0);
        vm.stopPrank();
        _pastCooldown();
        (bool okBefore,) = ledger.healthy(id);
        _set(0.1e18, id);
        (bool okAfter,) = ledger.healthy(id);
        assertEq(okAfter, okBefore, "a re-rating never changes health");
    }

    function test_hostileKeyIsBoundedByFloorAndStep() public {
        uint256 id = _joinNew(alice, 0);
        vm.prank(alice);
        rm.setLimits(id, 0.05e18, 0);
        _pastCooldown();
        _set(0.02e18, id); // the lowest the type allows: the member's floor keeps them at 5%
        assertEq(ledger.position(id).rate, 0.05e18, "no push to the front of the queue below the member's floor");
    }

    // ------------------------------------------------------------ scale

    function test_gasPerMember() public {
        uint256 n = 50;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory z = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address u = address(uint160(0x10000 + i));
            weth.mint(u, 100e18);
            vm.prank(u);
            weth.approve(address(ledger), type(uint256).max);
            ids[i] = _open(u, ETH, 0, 10e18, 5_000e18, 0.05e18);
            vm.startPrank(u);
            nft.approveOperator(ids[i], address(rm), 4);
            rm.join(ids[i], 0, 0);
            vm.stopPrank();
        }
        _pastCooldown();
        vm.prank(keeper);
        uint256 g = gasleft();
        uint256 rated = rm.setRates(ETH, 0.07e18, ids, z, z);
        g -= gasleft();
        assertEq(rated, n);
        emit log_named_uint("gas per member (no hints, 50 members)", g / n);
    }
}
