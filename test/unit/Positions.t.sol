// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {System} from "../utils/System.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @dev An ERC-1271 wallet: valid signatures are its signer key's over the digest.
contract Wallet1271 {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(sig[:64], (bytes32, bytes32));
        uint8 v = uint8(sig[64]);
        return ecrecover(hash, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev A contract that cannot receive ERC-721s (no onERC721Received).
contract NoReceiver {}

/// @notice Positions as accounts. Ids, many per owner, transfers that carry state, operator rights,
/// signatures, redemption order and liquidation across a change of owner.
contract PositionsTest is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";

    MockERC20 weth;
    MockERC20 simd;
    MockFeed ethFeed;
    MockFeed simdFeed;
    MockFeed nhi;
    PositionNFT nft;

    uint256 aliceKey = 0xA11CE;
    address alice = vm.addr(0xA11CE);
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address op = makeAddr("operator");
    address relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        simd = new MockERC20("sIMD", 18);
        ethFeed = new MockFeed(2000e18);
        simdFeed = new MockFeed(5e18);
        nhi = new MockFeed(0.98e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        ParametersBase.Risk memory ir = _risk(1.7e18, 1_000_000e18);
        ir.chop = 0.2e18;
        _addIlk(SIMD, address(simd), simdFeed, simdFeed, nhi, address(0), address(0), true, ir);
        params.seal();
        nft = ledger.nft();
        address[5] memory us = [alice, bob, carol, op, relayer];
        for (uint256 i; i < us.length; ++i) {
            weth.mint(us[i], 1_000e18);
            simd.mint(us[i], 100_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            simd.approve(address(ledger), type(uint256).max);
            usd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ helpers

    function _a(int256 c, int256 d, uint64 rate) internal pure returns (Adjust memory) {
        return Adjust(c, d, rate, 0, 0, false, type(uint256).max, address(0));
    }

    function _openAt(address u, bytes32 ilk, uint256 salt, uint256 c, uint256 d, uint64 rate) internal returns (uint256 id) {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        Adjust memory a = _a(int256(c), int256(d), rate);
        (a.prevHint, a.nextHint) = (p, n);
        vm.prank(u);
        id = ledger.open(ilk, salt, a);
    }

    function _refresh() internal {
        ethFeed.set(ethFeed.value());
        simdFeed.set(simdFeed.value());
        nhi.set(nhi.value());
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(nft.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _permitSig(uint256 key, address owner, uint256 id, address operator, uint8 mask, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            key, keccak256(abi.encode(nft.PERMIT_TYPEHASH(), owner, id, operator, mask, nft.nonces(owner), deadline))
        );
    }

    function _openSig(uint256 key, address owner, bytes32 ilk, uint256 salt, Adjust memory a, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            key,
            keccak256(
                abi.encode(
                    nft.OPEN_TYPEHASH(),
                    owner,
                    ilk,
                    salt,
                    a.dCollateral,
                    a.dDebt,
                    a.rate,
                    a.viaAsset,
                    a.maxUpfrontFee,
                    a.to,
                    nft.nonces(owner),
                    deadline
                )
            )
        );
    }

    function _borrowSig(uint256 key, address owner, uint256 id, uint256 amount, address to, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            key,
            keccak256(
                abi.encode(nft.BORROW_TYPEHASH(), owner, id, amount, to, type(uint256).max, nft.nonces(owner), deadline)
            )
        );
    }

    // ------------------------------------------------------------ ids and ownership

    function test_idIsCounterfactualAndOwnedByOpener() public {
        uint256 want = ledger.positionId(alice, ETH, 7);
        assertEq(ledger.ilkOf(want), bytes32(0), "not yet");
        uint256 id = _openAt(alice, ETH, 7, 10e18, 5_000e18, 0.05e18);
        assertEq(id, want);
        assertEq(nft.ownerOf(id), alice);
        assertEq(ledger.ilkOf(id), ETH);
        assertEq(_pid(ETH, alice), ledger.positionId(alice, ETH, 0), "test helper = salt 0");
    }

    function test_manyPositionsPerOwnerPerType() public {
        uint256 a = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.03e18);
        uint256 b = _openAt(alice, ETH, 1, 20e18, 8_000e18, 0.09e18);
        assertTrue(a != b);
        assertEq(sorted.size(ETH), 2);
        assertEq(sorted.first(ETH), a, "lower rate first");
        assertEq(sorted.next(ETH, a), b);
        assertEq(ledger.position(a).collateral, 10e18);
        assertEq(ledger.position(b).collateral, 20e18);
        // Changing one leaves the other untouched.
        Ledger.Position memory before = ledger.position(b);
        vm.prank(alice);
        ledger.adjust(a, _a(0, -1_000e18, 0));
        assertEq(ledger.position(b).debt, before.debt, "the other position is untouched");
        assertEq(ledger.position(b).collateral, before.collateral);
        assertEq(nft.balanceOf(alice), 2);
    }

    function test_openOnSomeoneElsesIdIsAdjustAndNeedsRights() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        // alice's salt 0 now belongs to bob: alice opening it again is an operator call with no rights.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.NoRight.selector, uint8(16)));
        ledger.open(ETH, 0, _a(0, 100e18, 0.05e18));
        // ...and she opens a fresh one with another salt.
        uint256 id2 = _openAt(alice, ETH, 1, 10e18, 1_000e18, 0.05e18);
        assertEq(nft.ownerOf(id2), alice);
    }

    // ------------------------------------------------------------ transfers carry state

    /// The rate cooldown and premium rate live on the position: a charged rate change followed by a transfer and a
    /// top-up costs the new owner exactly what it would have cost the old one.
    function test_transferCarriesCooldownAndPremium() public {
        uint256 a = _openAt(alice, ETH, 0, 100e18, 10_000e18, 0.08e18);
        uint256 b = _openAt(carol, ETH, 0, 100e18, 10_000e18, 0.08e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _refresh();
        // Both drop their rate inside the cooldown (charged), then both top up inside the new cooldown.
        vm.prank(alice);
        ledger.setRate(a, 0.02e18, 0, 0);
        vm.prank(carol);
        ledger.setRate(b, 0.02e18, 0, 0);
        assertEq(ledger.position(a).premiumRate, 0.08e18, "premium recorded");
        vm.prank(alice);
        nft.transferFrom(alice, bob, a);
        assertEq(ledger.position(a).premiumRate, 0.08e18, "premium survives the transfer");
        assertEq(ledger.position(a).lastRateChange, ledger.position(b).lastRateChange, "cooldown survives");
        vm.prank(bob);
        ledger.adjust(a, _a(0, 1_000e18, 0));
        vm.prank(carol);
        ledger.adjust(b, _a(0, 1_000e18, 0));
        assertEq(ledger.debtOf(a), ledger.debtOf(b), "the transferred position paid the same premium");
        assertGt(ledger.debtOf(a), 11_000e18 + ledger.upfrontFeeFor(ETH, 1_000e18, 0), "premium charged");
        // A rate change by the new owner inside the cooldown is charged as well.
        uint256 before = ledger.debtOf(a);
        vm.prank(bob);
        ledger.setRate(a, 0.05e18, 0, 0);
        assertGt(ledger.debtOf(a), before, "charged change after transfer");
    }

    function test_operatorsDoNotSurviveATransfer() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        vm.prank(alice);
        nft.approveOperator(id, op, uint8(2) | uint8(16));
        assertEq(nft.rightsOf(id, op), uint8(2) | uint8(16));
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.rightsOf(id, op), 0, "granted by alice, gone with her ownership");
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.NoRight.selector, uint8(16)));
        ledger.adjust(id, _a(0, 100e18, 0));
    }

    // ------------------------------------------------------------ operator rights

    function _expectOnly(uint256 id, uint8 right) internal {
        uint8[7] memory all =
            [uint8(1), uint8(2), uint8(4), uint8(8), uint8(16), uint8(32), uint8(64)];
        for (uint256 i; i < 7; ++i) {
            uint8 r = all[i];
            bool allowed = r == right || (right == uint8(32) && r == uint8(8))
                || (right == uint8(64) && r == uint8(16));
            uint256 snap = vm.snapshotState();
            vm.prank(op);
            if (!allowed) vm.expectRevert();
            _act(id, r);
            vm.revertToState(snap);
        }
    }

    /// @dev One action per right, by the operator. WITHDRAW/BORROW go to the owner; the _ANY ones to the operator.
    function _act(uint256 id, uint8 r) internal {
        if (r == uint8(1)) ledger.adjust(id, _a(1e18, 0, 0));
        else if (r == uint8(2)) ledger.adjust(id, _a(0, -100e18, 0));
        else if (r == uint8(4)) ledger.setRate(id, 0.06e18, 0, 0);
        else if (r == uint8(8)) ledger.adjust(id, _a(-1e18, 0, 0));
        else if (r == uint8(16)) ledger.adjust(id, _a(0, 100e18, 0));
        else if (r == uint8(32)) ledger.adjust(id, Adjust(-1e18, 0, 0, 0, 0, false, type(uint256).max, op));
        else ledger.adjust(id, Adjust(0, 100e18, 0, 0, 0, false, type(uint256).max, op));
    }

    function test_eachRightAllowsExactlyItsAction() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        // Past the opening rate cooldown: an operator's SET_RATE is a free change only.
        vm.warp(block.timestamp + 8 days);
        _refresh();
        vm.prank(alice);
        usd.transfer(op, 1_000e18);
        uint8[7] memory all =
            [uint8(1), uint8(2), uint8(4), uint8(8), uint8(16), uint8(32), uint8(64)];
        for (uint256 i; i < 7; ++i) {
            vm.prank(alice);
            nft.approveOperator(id, op, all[i]);
            _expectOnly(id, all[i]);
        }
    }

    function test_withdrawAndBorrowGoToTheOwnerOnly() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        vm.prank(alice);
        nft.approveOperator(id, op, uint8(8) | uint8(16));
        uint256 w = weth.balanceOf(alice);
        uint256 u = usd.balanceOf(alice);
        vm.startPrank(op);
        ledger.adjust(id, _a(-1e18, 100e18, 0)); // to = 0: the owner
        ledger.adjust(id, Adjust(-1e18, 100e18, 0, 0, 0, false, type(uint256).max, alice)); // to = owner, named
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.NoRight.selector, uint8(32)));
        ledger.adjust(id, Adjust(-1e18, 0, 0, 0, 0, false, type(uint256).max, op));
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.NoRight.selector, uint8(64)));
        ledger.adjust(id, Adjust(0, 100e18, 0, 0, 0, false, type(uint256).max, op));
        vm.stopPrank();
        assertEq(weth.balanceOf(alice), w + 2e18, "collateral to the owner");
        assertEq(usd.balanceOf(alice), u + 200e18, "imdUSD to the owner");
        assertEq(weth.balanceOf(op), 1_000e18, "operator got nothing");
    }

    function test_allPositionsGrant() public {
        uint256 a = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        uint256 b = _openAt(alice, ETH, 1, 10e18, 5_000e18, 0.05e18);
        vm.prank(alice);
        nft.approveOperator(0, op, uint8(2));
        assertEq(nft.rightsOf(a, op), uint8(2));
        assertEq(nft.rightsOf(b, op), uint8(2));
        vm.prank(alice);
        vm.expectRevert(PositionNFT.Unauthorized.selector);
        nft.approveOperator(_pid(ETH, bob), op, uint8(2)); // not hers (does not exist)
    }

    function test_anyoneMayAddAndRepay() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        vm.prank(alice);
        usd.transfer(carol, 1_000e18);
        vm.startPrank(carol);
        ledger.addFor(id, 2e18, false);
        ledger.repayFor(id, 500e18);
        // Anything that makes the position less safe needs a right.
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.NoRight.selector, uint8(8)));
        ledger.adjust(id, _a(-1e18, 0, 0));
        vm.stopPrank();
        assertEq(ledger.position(id).collateral, 12e18);
    }

    // ------------------------------------------------------------ signatures

    function test_permitOperator() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _permitSig(aliceKey, alice, id, op, uint8(2), deadline);
        nft.permitOperator(alice, id, op, uint8(2), deadline, sig);
        assertEq(nft.rightsOf(id, op), uint8(2));
        // replay: the nonce moved on
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.permitOperator(alice, id, op, uint8(2), deadline, sig);
    }

    function test_permitExpiredAndWrongSigner() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _permitSig(aliceKey, alice, id, op, uint8(64), deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(PositionNFT.Expired.selector);
        nft.permitOperator(alice, id, op, uint8(64), deadline, sig);
        deadline = vm.getBlockTimestamp() + 1 hours;
        sig = _permitSig(0xB0B, alice, id, op, uint8(64), deadline);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.permitOperator(alice, id, op, uint8(64), deadline, sig);
        // A changed field breaks the signature too.
        sig = _permitSig(aliceKey, alice, id, op, uint8(2), deadline);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.permitOperator(alice, id, op, uint8(64), deadline, sig);
    }

    function test_bumpNonceCancels() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _permitSig(aliceKey, alice, id, op, uint8(2), deadline);
        uint256 next = nft.nonces(alice) + 1;
        vm.prank(alice);
        nft.bumpNonce(next);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.permitOperator(alice, id, op, uint8(2), deadline, sig);
    }

    function test_permitByErc1271Wallet() public {
        uint256 signerKey = 0x5AFE;
        Wallet1271 w = new Wallet1271(vm.addr(signerKey));
        weth.mint(address(w), 10e18);
        vm.prank(address(w));
        weth.approve(address(ledger), type(uint256).max);
        uint256 id = _openAt(address(w), ETH, 0, 10e18, 5_000e18, 0.05e18);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _permitSig(signerKey, address(w), id, op, uint8(2), deadline);
        nft.permitOperator(address(w), id, op, uint8(2), deadline, sig);
        assertEq(nft.rightsOf(id, op), uint8(2));
        sig = _permitSig(0xBAD, address(w), id, op, uint8(16), deadline);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.permitOperator(address(w), id, op, uint8(16), deadline, sig);
    }

    /// A fresh key that never held gas or collateral owns a position; the relayer pays the collateral; the proceeds go to
    /// the signed address (straight into a shielded pool's deposit address).
    function test_openForFreshKey() public {
        uint256 key = 0xF2E5;
        address fresh = vm.addr(key);
        address sink = makeAddr("shielded deposit box");
        Adjust memory a = Adjust(10e18, 5_000e18, 0.05e18, 0, 0, false, type(uint256).max, sink);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _openSig(key, fresh, ETH, 0, a, deadline);
        vm.prank(relayer);
        uint256 id = nft.openFor(fresh, ETH, 0, a, deadline, sig);
        assertEq(id, ledger.positionId(fresh, ETH, 0));
        assertEq(nft.ownerOf(id), fresh);
        assertEq(usd.balanceOf(sink), 5_000e18, "proceeds to the signed address");
        assertEq(weth.balanceOf(relayer), 990e18, "relayer paid the collateral");
        assertEq(fresh.balance, 0);
        // replay
        vm.prank(relayer);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.openFor(fresh, ETH, 0, a, deadline, sig);
    }

    function test_openForRejectsTamperingAndWrongSigner() public {
        uint256 key = 0xF2E5;
        address fresh = vm.addr(key);
        Adjust memory a = Adjust(10e18, 5_000e18, 0.05e18, 0, 0, false, type(uint256).max, makeAddr("sink"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _openSig(key, fresh, ETH, 0, a, deadline);
        Adjust memory b = a;
        b.to = relayer; // redirect the proceeds
        vm.prank(relayer);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.openFor(fresh, ETH, 0, b, deadline, sig);
        sig = _openSig(0xBAD, fresh, ETH, 0, a, deadline);
        vm.prank(relayer);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.openFor(fresh, ETH, 0, a, deadline, sig);
        // Hints are not signed: a relayer may pick them.
        sig = _openSig(key, fresh, ETH, 0, a, deadline);
        a.prevHint = 123;
        vm.prank(relayer);
        nft.openFor(fresh, ETH, 0, a, deadline, sig);
    }

    function test_openForRefusesAPositionTheSignerNoLongerOwns() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        Adjust memory a = Adjust(0, 100e18, 0, 0, 0, false, type(uint256).max, alice);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _openSig(aliceKey, alice, ETH, 0, a, deadline);
        vm.expectRevert(LedgerBase.NotOwner.selector);
        nft.openFor(alice, ETH, 0, a, deadline, sig);
    }

    function test_borrowFor() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        address sink = makeAddr("sink");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _borrowSig(aliceKey, alice, id, 1_000e18, sink, deadline);
        vm.prank(relayer);
        nft.borrowFor(id, 1_000e18, sink, type(uint256).max, deadline, sig);
        assertEq(usd.balanceOf(sink), 1_000e18);
        vm.prank(relayer);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.borrowFor(id, 1_000e18, sink, type(uint256).max, deadline, sig);
        // wrong signer, and a signature that binds a different recipient
        sig = _borrowSig(0xBAD, alice, id, 1_000e18, sink, deadline);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.borrowFor(id, 1_000e18, sink, type(uint256).max, deadline, sig);
        sig = _borrowSig(aliceKey, alice, id, 1_000e18, sink, deadline);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.borrowFor(id, 1_000e18, relayer, type(uint256).max, deadline, sig);
        // after a transfer the old owner's signature is worthless
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.expectRevert(PositionNFT.BadSignature.selector);
        nft.borrowFor(id, 1_000e18, sink, type(uint256).max, deadline, sig);
        // a position with no debt has no rate to borrow at
        uint256 empty = _openAt(alice, ETH, 1, 10e18, 0, 0);
        sig = _borrowSig(aliceKey, alice, empty, 1_000e18, sink, deadline);
        vm.expectRevert(LedgerBase.RateOutOfRange.selector);
        nft.borrowFor(empty, 1_000e18, sink, type(uint256).max, deadline, sig);
    }

    // ------------------------------------------------------------ safe transfers

    function test_safeTransferToANonReceiverReverts() public {
        uint256 id = _openAt(alice, ETH, 0, 10e18, 5_000e18, 0.05e18);
        NoReceiver nr = new NoReceiver();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(nr)));
        nft.safeTransferFrom(alice, address(nr), id);
        // A plain transfer is the sender's choice (as for any NFT); the position still works for its debt.
        vm.prank(alice);
        nft.transferFrom(alice, address(nr), id);
        assertEq(nft.ownerOf(id), address(nr));
        vm.prank(bob);
        vm.expectRevert(PositionNFT.Unauthorized.selector);
        nft.mint(bob, 1);
    }

    // ------------------------------------------------------------ redemption and liquidation across owners

    function test_redemptionOrderUnchangedByTransfer() public {
        uint256 a = _openAt(alice, ETH, 0, 100e18, 10_000e18, 0.02e18);
        uint256 b = _openAt(bob, ETH, 0, 100e18, 10_000e18, 0.08e18);
        vm.prank(alice);
        nft.transferFrom(alice, carol, a);
        assertEq(sorted.first(ETH), a, "the low rate is still first");
        assertEq(sorted.next(ETH, a), b);
        uint256 debtBefore = ledger.debtOf(a);
        uint256 bBefore = ledger.position(b).debt;
        vm.startPrank(bob);
        redeemer.redeem(ETH, 1_000e18, 1e18, 10, 0);
        vm.stopPrank();
        assertLt(ledger.debtOf(a), debtBefore, "the transferred low-rate position was redeemed");
        assertEq(ledger.position(b).debt, bBefore, "b untouched");
    }

    /// A mark and its grace belong to the position: a transfer mid-grace neither restarts nor ends it.
    function test_liquidationAfterOwnerChangedMidGrace() public {
        uint256 id = _openAt(alice, SIMD, 0, 1_000e18, 2_900e18, 0.05e18);
        _openAt(carol, ETH, 0, 100e18, 50_000e18, 0.05e18);
        simdFeed.set(4e18);
        vm.prank(carol);
        liquidator.bark(id);
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        _refresh();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Liquidator.InGrace.selector, vm.getBlockTimestamp() + 3 hours));
        liquidator.bite(id);
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        _refresh();
        vm.prank(carol);
        liquidator.bite(id);
        assertEq(ledger.debtOf(id), 0);
        assertEq(nft.ownerOf(id), bob, "the position stays with its new owner, emptied");
    }
}
