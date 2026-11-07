// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {System} from "../../utils/System.sol";
import {MockERC20, MockFeed} from "../../utils/Mocks.sol";
import {ParametersBase} from "../../../src/ParametersBase.sol";
import {Ledger} from "../../../src/Ledger.sol";
import {LedgerBase} from "../../../src/LedgerBase.sol";
import {PositionNFT} from "../../../src/PositionNFT.sol";
import {IFeed} from "../../../src/interfaces/IFeed.sol";
import {Adjust} from "../../../src/interfaces/IPositions.sol";

/// Positions: PoCs for four findings of the 2026-11 internal review, turned into regressions.
contract PanelP04RegressionTest is System {
    bytes32 constant ETH = "ETH";

    MockERC20 weth;
    MockFeed ethFeed;
    PositionNFT nft;

    uint256 aliceKey = 0xA11CE;
    address alice = vm.addr(0xA11CE);
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");
    address relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        ethFeed = new MockFeed(2000e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.5e18, 10_000_000e18));
        params.seal();
        nft = ledger.nft();
        address[4] memory us = [alice, bob, mallory, relayer];
        for (uint256 i; i < us.length; ++i) {
            weth.mint(us[i], 1_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _a(int256 c, int256 d, uint64 rate) internal pure returns (Adjust memory) {
        return Adjust(c, d, rate, 0, 0, false, type(uint256).max, address(0));
    }

    function _open(address u, uint256 salt, uint256 c, uint256 d, uint64 rate) internal returns (uint256 id) {
        vm.prank(u);
        id = ledger.open(ETH, salt, _a(int256(c), int256(d), rate));
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(nft.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _borrowSig(uint256 id, uint256 amount, address to, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            aliceKey,
            keccak256(abi.encode(nft.BORROW_TYPEHASH(), alice, id, amount, to, type(uint256).max, nonce, deadline))
        );
    }

    function _permitSig(uint256 id, address operator, uint8 mask, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(aliceKey, keccak256(abi.encode(nft.PERMIT_TYPEHASH(), alice, id, operator, mask, nonce, deadline)));
    }

    // ------------------------------------------------------------ bumpNonce cancels ONE signature, not all

    /// Alice pre-signs two borrowFor messages for a relayer (nonces 0 and 1; e.g. a private-borrowing flow that splits
    /// a borrow into two shielded deposits). She changes her mind and calls `bumpNonce`, which the NatSpec says
    /// "cancels every outstanding signature". It burns nonce 0 only, and in doing so makes the nonce-1 signature valid
    /// IMMEDIATELY: the relayer (or anyone who saw it) borrows to the signed `to` anyway.
    // Fixed: a repayment above the debt clamps to it, so a full close never races accrual or a 1-wei repayFor.

    function test_P04_fullCloseOneSlotLaterSucceeds() public {
        uint256 id = _open(alice, 0, 10e18, 1_000e18, 0.05e18);
        _open(bob, 0, 100e18, 10_000e18, 0.05e18);
        vm.prank(bob);
        usd.transfer(alice, 1_000e18);
        vm.warp(block.timestamp + 30 days);
        uint256 quoted = ledger.debtOf(id);
        vm.warp(block.timestamp + 12);
        uint256 owed = ledger.debtOf(id);
        uint256 bal = usd.balanceOf(alice);
        vm.prank(alice);
        ledger.adjust(id, Adjust(-10e18, -int256(quoted + 1e18), 0, 0, 0, false, 0, address(0)));
        assertEq(ledger.debtOf(id), 0, "closed");
        assertEq(bal - usd.balanceOf(alice), owed, "burned exactly the debt, not the margin");
    }

    function test_P04_repayForOneWeiNoLongerGriefsAClose() public {
        uint256 id = _open(alice, 0, 10e18, 1_000e18, 0.05e18);
        _open(bob, 0, 100e18, 10_000e18, 0.05e18);
        vm.prank(bob);
        usd.transfer(alice, 1_100e18);
        vm.warp(block.timestamp + 30 days);
        uint256 exact = ledger.debtOf(id);
        vm.prank(bob);
        usd.transfer(mallory, 1);
        vm.prank(mallory);
        ledger.repayFor(id, 1);
        vm.prank(alice);
        ledger.adjust(id, Adjust(-10e18, -int256(exact), 0, 0, 0, false, 0, address(0)));
        assertEq(ledger.debtOf(id), 0, "closed despite the front-run");
    }

    function test_P04_repayForMaxRepaysAll() public {
        uint256 id = _open(alice, 0, 10e18, 1_000e18, 0.05e18);
        _open(bob, 0, 100e18, 10_000e18, 0.05e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(bob);
        ledger.repayFor(id, type(uint256).max);
        assertEq(ledger.debtOf(id), 0, "repayFor(max) repays the whole debt");
    }

    // Fixed: a SET_RATE-only operator cannot add debt through cooldown premiums.
    function test_P02_operatorCannotPayCooldownPremiums() public {
        uint256 id = _open(alice, 0, 10e18, 8_000e18, 0.05e18);
        vm.prank(alice);
        nft.approveOperator(id, mallory, 4); // SET_RATE only
        vm.warp(block.timestamp + 8 days); // outside the opening cooldown
        ethFeed.set(ethFeed.value());
        uint256 debt0 = ledger.debtOf(id);
        vm.prank(mallory);
        ledger.setRate(id, 0.06e18, 0, 0); // free change: allowed
        assertEq(ledger.debtOf(id), debt0, "a free change adds no debt");
        vm.prank(mallory);
        vm.expectRevert(LedgerBase.NotOwner.selector);
        ledger.setRate(id, 0.07e18, 0, 0); // inside the cooldown: would cost a premium, refused for an operator
        vm.prank(alice);
        ledger.setRate(id, 0.07e18, 0, 0); // the owner may still choose to pay it
        assertGt(ledger.debtOf(id), debt0, "the owner paid the premium");
    }
}
