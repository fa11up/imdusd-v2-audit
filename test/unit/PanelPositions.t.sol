// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {RateManager, IManagedLedger} from "../../src/managers/RateManager.sol";

/// @notice Regressions from the 2026-11 internal review: bumpNonce cancels the whole queue, and grants and
/// RateManager membership never come back when a position returns to an earlier owner.
/// Each test failed before the fix.
contract PanelPositionsTest is System {
    bytes32 constant ETH = "ETH";

    MockERC20 weth;
    MockFeed ethFeed;
    PositionNFT nft;
    RateManager rm;

    uint256 aliceKey = 0xA11CE;
    address alice = vm.addr(0xA11CE);
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");
    address relayer = makeAddr("relayer");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        ethFeed = new MockFeed(2000e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.5e18, 10_000_000e18));
        params.seal();
        nft = ledger.nft();
        bytes32[] memory ilks = new bytes32[](1);
        uint64[] memory mins = new uint64[](1);
        uint64[] memory maxs = new uint64[](1);
        (ilks[0], mins[0], maxs[0]) = (ETH, 0.02e18, 0.2e18);
        rm = new RateManager(IManagedLedger(address(ledger)), keeper, ilks, mins, maxs, 1 hours, 0.05e18);
        address[4] memory us = [alice, bob, mallory, relayer];
        for (uint256 i; i < us.length; ++i) {
            weth.mint(us[i], 1_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _open(address u, uint256 salt, uint256 c, uint256 d, uint64 rate) internal returns (uint256 id) {
        vm.prank(u);
        id = ledger.open(ETH, salt, Adjust(int256(c), int256(d), rate, 0, 0, false, type(uint256).max, address(0)));
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(nft.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _borrowSig(uint256 id, uint256 amount, address to, uint256 nonce, uint256 dl) internal view returns (bytes memory) {
        return _sign(keccak256(abi.encode(nft.BORROW_TYPEHASH(), alice, id, amount, to, type(uint256).max, nonce, dl)));
    }

    function _permitSig(uint256 id, address op, uint8 mask, uint256 nonce, uint256 dl) internal view returns (bytes memory) {
        return _sign(keccak256(abi.encode(nft.PERMIT_TYPEHASH(), alice, id, op, mask, nonce, dl)));
    }

    // ------------------------------------------------------------ bumpNonce cancels the queue

    function test_M12_bumpNonceCancelsTheWholeQueue() public {
        uint256 id = _open(alice, 0, 10e18, 1_000e18, 0.05e18);
        uint256 dl = block.timestamp + 1 days;
        bytes memory s0 = _borrowSig(id, 3_000e18, mallory, 0, dl);
        bytes memory s1 = _borrowSig(id, 3_000e18, mallory, 1, dl);
        vm.prank(alice);
        nft.bumpNonce(2); // cancel both
        assertEq(nft.nonces(alice), 2);
        vm.startPrank(relayer);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.borrowFor(id, 3_000e18, mallory, type(uint256).max, dl, s0);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.borrowFor(id, 3_000e18, mallory, type(uint256).max, dl, s1);
        vm.stopPrank();
        assertEq(usd.balanceOf(mallory), 0, "no cancelled borrow went through");
    }

    function test_M12_bumpNonceCancelsPresignedPermit() public {
        uint256 id = _open(alice, 0, 10e18, 1_000e18, 0.05e18);
        uint256 dl = block.timestamp + 1 days;
        bytes memory p1 = _permitSig(id, mallory, 64, 1, dl);
        vm.prank(alice);
        nft.bumpNonce(5);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.permitOperator(alice, id, mallory, 64, dl, p1);
        // A signature at the new nonce works.
        bytes memory p5 = _permitSig(id, mallory, 2, 5, dl);
        nft.permitOperator(alice, id, mallory, 2, dl, p5);
        assertEq(nft.idRights(id, alice, mallory), 2);
    }

    function test_M12_bumpNonceMustMoveForwardBounded() public {
        vm.startPrank(alice);
        vm.expectRevert(PositionNFT.BadNonce.selector);
        nft.bumpNonce(0);
        nft.bumpNonce(3);
        vm.expectRevert(PositionNFT.BadNonce.selector);
        nft.bumpNonce(3);
        vm.expectRevert(PositionNFT.BadNonce.selector);
        nft.bumpNonce(3 + uint256(type(uint64).max) + 1);
        nft.bumpNonce(3 + uint256(type(uint64).max));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ grants do not come back

    function test_P03_rightsDoNotResurrectWhenPositionReturns() public {
        uint256 id = _open(alice, 0, 10e18, 1_000e18, 0.05e18);
        vm.prank(alice);
        nft.approveOperator(id, mallory, 64); // BORROW_ANY
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.rightsOf(id, mallory), 0, "dropped under bob");
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.rightsOf(id, mallory), 0, "the old grant stays dead after the round trip");
        assertEq(nft.idRights(id, alice, mallory), 0);
        vm.prank(mallory);
        vm.expectRevert();
        ledger.adjust(id, Adjust(0, 5_000e18, 0, 0, 0, false, type(uint256).max, mallory));
        // A fresh grant in the new epoch works.
        vm.prank(alice);
        nft.approveOperator(id, mallory, 64);
        vm.prank(mallory);
        ledger.adjust(id, Adjust(0, 5_000e18, 0, 0, 0, false, type(uint256).max, mallory));
        assertEq(usd.balanceOf(mallory), 5_000e18);
    }

    /// Documented behaviour: an all-positions grant follows its owner to positions sent to them.
    function test_P03_allRightsFollowTheOwner() public {
        vm.prank(alice);
        nft.approveOperator(0, mallory, 64);
        uint256 id = _open(bob, 0, 10e18, 1_000e18, 0.05e18);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.rightsOf(id, mallory) & 64, 64);
    }

    function test_P03_rateManagerMembershipEndsForGoodOnTransfer() public {
        uint256 id = _open(alice, 0, 10e18, 1_000e18, 0.05e18);
        vm.startPrank(alice);
        nft.approveOperator(0, address(rm), 4); // an all-positions SET_RATE grant survives transfers by design
        rm.join(id, 0, 0);
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        vm.warp(block.timestamp + 8 days);
        ethFeed.set(ethFeed.value());
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory z = new uint256[](1);
        vm.prank(keeper);
        assertEq(rm.setRates(ETH, 0.08e18, ids, z, z), 0, "the old membership is not revived");
        vm.prank(alice);
        vm.expectRevert(RateManager.Unauthorized.selector);
        rm.setLimits(id, 0, 0);
        // Re-joining works.
        vm.prank(alice);
        rm.join(id, 0, 0);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        assertEq(rm.setRates(ETH, 0.08e18, ids, z, z), 1);
    }
}
