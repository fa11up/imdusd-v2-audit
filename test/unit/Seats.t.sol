// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatSystem} from "../utils/SeatSystem.sol";
import {MockERC20, MockFeed, MockSeatFeed} from "../utils/Mocks.sol";
import {
    MockSeatNFT, MockAgentAdapter, MockDistributor, MockDistributorFactory, MockStuckToken, MockHungryToken
} from "../utils/SeatMocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Join} from "../../src/Join.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {SeatFeed} from "../../src/feeds/SeatFeed.sol";
import {SeatAccount, IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";

contract SeatsTest is SeatSystem {
    bytes32 constant ETH = "ETH";
    bytes4 constant VALID = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;

    MockSeatNFT nft;
    MockAgentAdapter adapter;
    MockERC20 weth;
    MockERC20 reward;
    MockFeed ethFeed;
    MockSeatFeed median; // its figure is sales7d
    MockFeed spot;
    MockDistributor dist;
    MockDistributorFactory factory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockSeatNFT();
        adapter = new MockAgentAdapter();
        weth = new MockERC20("WETH", 18);
        reward = new MockERC20("IMD", 18);
        ethFeed = new MockFeed(2000e18); // USD per 1e18 wei
        median = new MockSeatFeed(2e18, 150); // 2 ETH per seat: $4,000; 150 distinct seats sold in 7 days
        median.setMaxAge(26 hours); // the live leaf's life (beta config); the auction clock runs on it
        spot = new MockFeed(2e18);
        dist = new MockDistributor();
        factory = new MockDistributorFactory();

        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        // line: 25 seats x $4,000 x 40% = $40,000 at the reference price; the 25-seat count is the join's.
        _addSeatIlk(IERC721(address(nft)), IImdAgentAdapter(address(adapter)), median, spot, ethFeed, 40_000e18);
        params.seal();

        for (uint256 i = 1; i <= 3; ++i) nft.mint(alice, i);
        nft.mint(bob, 10);
        weth.mint(bob, 1_000e18);
        weth.mint(keeper, 1_000e18);
        reward.mint(address(dist), 1_000_000e18);
        vm.prank(alice);
        nft.setApprovalForAll(address(seatJoin), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(seatJoin), true);
        vm.prank(bob);
        weth.approve(address(ledger), type(uint256).max);
        vm.prank(keeper);
        weth.approve(address(ledger), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev via_ir caches block.timestamp across a test body: warp from the VM's clock.
    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _refresh() internal {
        ethFeed.set(ethFeed.value());
        median.set(median.value());
        spot.set(spot.value());
    }

    /// @dev The most that can be borrowed against `max` of room once the upfront fee at the seat floor rate (8%, the
    /// type's average here) is added: whole imdUSD.
    function _net(uint256 max) internal pure returns (uint256) {
        return max * 365 days / (365 days + 0.08e18 * 7 days / 1e18) / 1e18 * 1e18;
    }

    function _pledge(address who, uint256 tokenId, uint256 debt) internal {
        vm.startPrank(who);
        seatJoin.deposit(tokenId);
        ledger.open(SEAT, 0, Adjust(1e18, int256(debt), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
    }

    function _cash(address who, uint256 amount) internal {
        vm.prank(who);
        ledger.open(ETH, 0, Adjust(100e18, int256(amount), 0.02e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function _auth(SeatAccount acct, uint256 tokenId) internal view returns (SeatAccount.WorkerAuthorization memory a) {
        a.deviceKey = keccak256("device-key");
        a.wallet = address(acct);
        a.tokenId = tokenId;
        a.nonce = keccak256("nonce");
        a.expiresAt = uint64(block.timestamp + 1 hours);
        a.relayOrigin = "https://api.imd.fun";
    }

    function _assertSupply() internal {
        ledger.accrue(ETH);
        ledger.accrue(SEAT);
        (uint128 d1,,,, uint128 b1) = ledger.ilkState(ETH);
        (uint128 d2,,,, uint128 b2) = ledger.ilkState(SEAT);
        assertEq(usd.totalSupply(), uint256(d1) + b1 + d2 + b2 + ledger.reserveBacked() + migrator.outstanding(), "supply");
    }

    /// Units == 1e18 x seats held in accounts; the pool == the type's recorded collateral.
    function _assertUnits() internal view {
        uint256 held;
        for (uint256 id = 1; id <= 40; ++id) {
            try nft.ownerOf(id) returns (address o) {
                if (o == seatJoin.accountOf(id)) held++;
            } catch {}
        }
        assertEq(seatJoin.totalSupply(), held * 1e18, "units == seats held");
        (, uint128 c,,,) = ledger.ilkState(SEAT);
        assertEq(seatJoin.balanceOf(address(seatJoin)), c, "pool == collateral");
    }

    function _governTreasury(address asset, address to, uint256 amount) internal {
        vm.prank(governor);
        treasury.propose(abi.encode(asset, to, amount));
        _skip(48 hours);
        treasury.applyPending();
        _refresh();
    }

    // ------------------------------------------------------------------ custody round trip

    function test_depositBorrowRepayExit() public {
        vm.prank(alice);
        address acct = seatJoin.deposit(1);
        assertEq(acct, seatJoin.accountOf(1));
        assertEq(nft.ownerOf(1), acct, "NFT in its own account");
        assertEq(seatJoin.holderOf(1), alice);
        assertEq(seatJoin.balanceOf(alice), 1e18);

        vm.startPrank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, int256(_net(1_600e18)), 0.08e18, 0, 0, false, type(uint256).max, address(0))); // 40% of $4,000 incl. the fee
        assertEq(usd.balanceOf(alice), _net(1_600e18));
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        ledger.open(SEAT, 0, Adjust(0, 1e18, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        _assertSupply();
        _assertUnits();

        _skip(30 days);
        _refresh();
        _cash(bob, 1_000e18);
        vm.prank(bob);
        usd.transfer(alice, 200e18);
        uint256 debt = ledger.debtOf(_pid(SEAT, alice));
        assertGt(debt, _net(1_600e18) * 1.0015e18 / 1e18, "upfront fee + interest at >= 8%");
        vm.startPrank(alice);
        ledger.open(SEAT, 0, Adjust(-1e18, -int256(debt), 0, 0, 0, false, type(uint256).max, address(0)));
        seatJoin.withdraw(1, alice);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), alice, "seat back");
        assertEq(seatJoin.balanceOf(alice), 0);
        assertEq(seatJoin.holderOf(1), address(0));
        _assertSupply();
        _assertUnits();
    }

    function test_rateFloorIs8Percent() public {
        vm.startPrank(alice);
        seatJoin.deposit(1);
        vm.expectRevert(LedgerBase.RateOutOfRange.selector);
        ledger.open(SEAT, 0, Adjust(1e18, 500e18, 0.0799e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
    }

    function test_cannotWithdrawPledgedSeat() public {
        _pledge(alice, 1, 500e18);
        vm.prank(alice);
        vm.expectRevert(SeatJoin.NoUnits.selector);
        seatJoin.withdraw(1, alice);
        vm.prank(bob);
        vm.expectRevert(SeatJoin.NotHolder.selector);
        seatJoin.withdraw(1, bob);
    }

    function test_unitsAreWholeAndNotTransferable() public {
        vm.startPrank(alice);
        seatJoin.deposit(1);
        vm.expectRevert(SeatJoin.WholeSeatsOnly.selector);
        ledger.open(SEAT, 0, Adjust(0.5e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(SEAT, 0, Adjust(1e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.expectRevert(SeatJoin.WholeSeatsOnly.selector);
        ledger.open(SEAT, 0, Adjust(-0.5e18, 0, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.expectRevert(SeatJoin.Untransferable.selector);
        seatJoin.transfer(bob, 1e18);
        vm.expectRevert(SeatJoin.Unauthorized.selector);
        seatJoin.transferFrom(alice, bob, 1e18);
        vm.stopPrank();
    }

    function test_strayNftRefused() public {
        vm.prank(alice);
        address acct = seatJoin.deposit(1);
        vm.prank(alice);
        vm.expectRevert(SeatAccount.Unauthorized.selector);
        nft.safeTransferFrom(alice, acct, 2);
    }

    // ------------------------------------------------------------------ launch limits

    function test_threeSeatsPerBorrower() public {
        nft.mint(alice, 4);
        vm.startPrank(alice);
        seatJoin.deposit(1);
        seatJoin.deposit(2);
        seatJoin.deposit(3);
        vm.expectRevert(SeatJoin.TooManySeats.selector);
        seatJoin.deposit(4);
        vm.stopPrank();
    }

    function test_twentyFiveSeatLine() public {
        uint256 id = 100;
        for (uint256 u; u < 9; ++u) {
            address who = makeAddr(string(abi.encodePacked("holder", u)));
            vm.prank(who);
            nft.setApprovalForAll(address(seatJoin), true);
            for (uint256 k; k < 3; ++k) {
                nft.mint(who, id);
                vm.prank(who);
                if (u * 3 + k >= 25) vm.expectRevert(SeatJoin.TooManySeats.selector);
                seatJoin.deposit(id);
                id++;
            }
        }
        assertEq(seatJoin.seatCount(), 25);
    }

    function test_limitsMoveOnlyThroughTimelock() public {
        vm.expectRevert(SeatJoin.Unauthorized.selector);
        seatJoin.setLimits(100, 10);
        bytes memory p = abi.encode(params.SET_SEAT_LIMITS(), address(seatJoin), uint256(50), uint256(5));
        vm.prank(governor);
        params.propose(p);
        vm.expectRevert();
        params.applyPending();
        _skip(48 hours);
        params.applyPending();
        assertEq(seatJoin.maxSeats(), 50);
        assertEq(seatJoin.perBorrower(), 5);
        // Out of bounds is refused at proposal.
        p = abi.encode(params.SET_SEAT_LIMITS(), address(seatJoin), uint256(2001), uint256(5));
        vm.prank(governor);
        vm.expectRevert(ParametersBase.OutOfBounds.selector);
        params.propose(p);
    }

    // ------------------------------------------------------------------ pairing (ERC-1271)

    function test_pairingAcceptedOnlyStoredUnexpiredOwned() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        SeatAccount.WorkerAuthorization memory a = _auth(acct, 1);
        bytes32 digest = acct.workerAuthorizationDigest(a);
        assertEq(acct.isValidSignature(digest, ""), INVALID, "not stored yet");

        vm.prank(bob);
        vm.expectRevert(SeatAccount.Unauthorized.selector);
        acct.authorizeWorker(a);

        vm.prank(alice);
        assertEq(acct.authorizeWorker(a), digest);
        assertEq(acct.isValidSignature(digest, ""), VALID, "stored");

        // Expires on chain.
        vm.warp(a.expiresAt);
        assertEq(acct.isValidSignature(digest, ""), INVALID, "expired");
    }

    function test_pairingRejectsBadStructs() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        SeatAccount.WorkerAuthorization memory a = _auth(acct, 1);
        vm.startPrank(alice);
        a.wallet = alice;
        vm.expectRevert(SeatAccount.WrongWallet.selector);
        acct.authorizeWorker(a);
        a.wallet = address(acct);
        a.tokenId = 2;
        vm.expectRevert(SeatAccount.WrongToken.selector);
        acct.authorizeWorker(a);
        a.tokenId = 1;
        a.expiresAt = uint64(block.timestamp);
        vm.expectRevert(SeatAccount.AuthorizationExpired.selector);
        acct.authorizeWorker(a);
        vm.stopPrank();
    }

    function test_permitAndSeaportDigestsRejected() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        acct.authorizeWorker(_auth(acct, 1));
        // EIP-2612 Permit for imdUSD, signed "by" the account.
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                address(acct),
                bob,
                type(uint256).max,
                0,
                block.timestamp + 1 days
            )
        );
        bytes32 permit = keccak256(abi.encodePacked("\x19\x01", usd.DOMAIN_SEPARATOR(), permitHash));
        assertEq(acct.isValidSignature(permit, ""), INVALID, "permit");
        // A Seaport 1.6 order digest selling the seat for 1 wei (domain + an arbitrary order hash).
        bytes32 seaportDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Seaport"),
                keccak256("1.6"),
                block.chainid,
                0x0000000000000068F116a894984e2DB1123eB395
            )
        );
        bytes32 seaport = keccak256(abi.encodePacked("\x19\x01", seaportDomain, keccak256("order: seat 1 for 1 wei")));
        assertEq(acct.isValidSignature(seaport, ""), INVALID, "seaport");
        // The SeatPause message under the same domain (same fields reordered) is also not a pairing.
        assertEq(acct.isValidSignature(bytes32(0), ""), INVALID, "zero");
    }

    function test_epochBumpOnWithdrawRevokesAndDoesNotRearm() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        SeatAccount.WorkerAuthorization memory a = _auth(acct, 1);
        vm.prank(alice);
        bytes32 digest = acct.authorizeWorker(a);
        vm.prank(alice);
        seatJoin.withdraw(1, alice);
        assertEq(acct.custodyEpoch(), 1);
        assertEq(acct.isValidSignature(digest, ""), INVALID, "withdrawn");
        // Re-deposit lands in the SAME account (deterministic clone): the old digest stays dead.
        vm.prank(alice);
        assertEq(seatJoin.deposit(1), address(acct));
        assertEq(acct.isValidSignature(digest, ""), INVALID, "not re-armed");
        vm.prank(alice);
        acct.authorizeWorker(a);
        assertEq(acct.isValidSignature(digest, ""), VALID, "fresh pairing works");
    }

    function test_epochBumpOnLiquidation() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.startPrank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, 1_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        bytes32 digest = acct.authorizeWorker(_auth(acct, 1));
        vm.stopPrank();
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        assertEq(acct.isValidSignature(digest, ""), VALID, "an open auction does not end the pairing");
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        assertEq(acct.isValidSignature(digest, ""), INVALID, "sold");
    }

    function test_registerAgent() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(bob);
        vm.expectRevert(SeatAccount.Unauthorized.selector);
        acct.registerAgent("ipfs://agent");
        vm.prank(alice);
        uint256 id = acct.registerAgent("ipfs://agent");
        assertEq(id, 100);
        assertEq(acct.agentId(), 100);
        vm.prank(alice);
        vm.expectRevert(SeatAccount.AlreadyRegistered.selector);
        acct.registerAgent("ipfs://agent");
    }

    function test_implementationAndCloneCannotBeReinitialized() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.expectRevert(SeatAccount.Unauthorized.selector);
        acct.initialize(5);
        SeatAccount impl = SeatAccount(seatJoin.implementation());
        vm.prank(address(seatJoin));
        vm.expectRevert(SeatAccount.AlreadyInitialized.selector);
        impl.initialize(5);
    }

    // ------------------------------------------------------------------ rewards

    function _allow(address target, bytes4 sel, uint8 rule) internal {
        bytes memory p = abi.encode(params.SET_SEAT_CLAIM(), address(seatJoin), target, sel, rule);
        vm.prank(governor);
        params.propose(p);
        _skip(48 hours);
        params.applyPending();
        _refresh();
    }

    function test_claimAllowlist() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        address[] memory toks = new address[](1);
        toks[0] = address(reward);
        bytes memory data = abi.encodeCall(MockDistributor.claim, (address(acct), address(reward), 100e18));

        vm.expectRevert(SeatAccount.ClaimNotAllowed.selector);
        acct.claim(address(dist), data, toks, address(0), 0);

        _allow(address(dist), MockDistributor.claim.selector, 1);
        acct.claim(address(dist), data, toks, address(0), 0); // permissionless
        assertEq(seatJoin.owed(1, address(reward), alice), 100e18, "credited to the holder at report time");

        // Same target, another selector: refused.
        bytes memory other = abi.encodeCall(MockDistributor.other, (address(acct), address(reward), 1e18));
        vm.expectRevert(SeatAccount.ClaimNotAllowed.selector);
        acct.claim(address(dist), other, toks, address(0), 0);

        // Never the NFT, whatever governance allows (approve/transfer of the seat itself).
        bytes memory steal = abi.encodeCall(IERC721.setApprovalForAll, (bob, true));
        vm.expectRevert(SeatAccount.ClaimNotAllowed.selector);
        acct.claim(address(nft), steal, toks, address(0), 0);

        // Collect (anyone may trigger it): 90% to the credited holder, 10% in kind to the Treasury.
        vm.prank(bob);
        seatJoin.collect(1, address(reward), alice);
        assertEq(reward.balanceOf(alice), 90e18);
        assertEq(reward.balanceOf(address(treasury)), 10e18);
        assertEq(reward.balanceOf(address(acct)), 0);
    }

    function test_claimByFactoryRule() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        MockDistributor d2 = new MockDistributor();
        reward.mint(address(d2), 1_000e18);
        factory.set(1282, address(d2));
        _allow(address(factory), MockDistributor.claim.selector, 2);
        address[] memory toks = new address[](1);
        toks[0] = address(reward);
        bytes memory data = abi.encodeCall(MockDistributor.claim, (address(acct), address(reward), 7e18));
        acct.claim(address(d2), data, toks, address(factory), 1282);
        assertEq(seatJoin.owed(1, address(reward), alice), 7e18);
        // The factory rule does not cover a distributor the factory did not deploy under that launch.
        vm.expectRevert(SeatAccount.ClaimNotAllowed.selector);
        acct.claim(address(dist), data, toks, address(factory), 1282);
        vm.expectRevert(SeatAccount.ClaimNotAllowed.selector);
        acct.claim(address(d2), data, toks, address(factory), 1);
    }

    function test_airdropSyncAndPaidOutBeforeWithdraw() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        reward.mint(address(acct), 50e18); // an airdrop simply arrives
        acct.sync(address(reward));
        acct.sync(address(reward)); // idempotent
        assertEq(seatJoin.owed(1, address(reward), alice), 50e18);
        // Audit wave 1: the seat collection (balanceOf reads the held seat) and the join are never booked as rewards.
        vm.expectRevert(SeatAccount.WrongToken.selector);
        acct.sync(address(nft));
        vm.expectRevert(SeatAccount.WrongToken.selector);
        acct.sync(address(seatJoin));
        vm.prank(alice);
        seatJoin.withdraw(1, alice);
        assertEq(reward.balanceOf(alice), 0, "the withdrawal moves the seat and nothing else (S1)");
        assertEq(seatJoin.owed(1, address(reward), alice), 50e18, "the credit outlives the custody");
        seatJoin.collect(1, address(reward), alice);
        assertEq(reward.balanceOf(alice), 45e18, "collected separately, less the fee");
        assertEq(reward.balanceOf(address(treasury)), 5e18);
    }

    function test_stuckRewardTokenDoesNotBlockSale() public {
        MockStuckToken stuck = new MockStuckToken();
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, 1_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        stuck.mint(address(acct), 10e18);
        acct.sync(address(stuck));
        stuck.block_(address(acct));
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), bob);
        assertEq(seatJoin.owed(1, address(stuck), alice), 10e18, "still the old holder's");
        // Only its own collection fails, and only while the token refuses.
        vm.expectRevert(SeatAccount.SendFailed.selector);
        seatJoin.collect(1, address(stuck), alice);
        stuck.block_(address(0));
        seatJoin.collect(1, address(stuck), alice);
        assertEq(stuck.balanceOf(alice), 9e18);
    }

    /// A transfer to a first-time recipient at Glamsterdam's prices fits the bound, and a token that spends everything still fails inside it.
    function test_collectFitsAnExpensiveTransfer() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        MockHungryToken hungry = new MockHungryToken(400_000);
        hungry.mint(address(acct), 10e18);
        acct.sync(address(hungry));
        seatJoin.collect(1, address(hungry), alice);
        assertEq(hungry.balanceOf(alice), 9e18);
        MockHungryToken greedy = new MockHungryToken(acct.SEND_GAS() + 1);
        greedy.mint(address(acct), 10e18);
        acct.sync(address(greedy));
        vm.expectRevert(SeatAccount.SendFailed.selector);
        seatJoin.collect(1, address(greedy), alice);
    }

    /// S4: an arrival reported between holders is the LAST holder's (the operator who earned it); one reported after
    /// a new deposit is the new holder's. The collector's identity never matters.
    function test_rewardsCreditedToHolderAtReport() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, 1_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        assertEq(seatJoin.holderOf(1), address(0));
        assertEq(seatJoin.lastHolder(1), alice);
        // The launch allocation alice's seat earned lands an hour after the sale.
        reward.mint(address(acct), 30e18);
        acct.sync(address(reward));
        assertEq(seatJoin.owed(1, address(reward), alice), 30e18, "the earner's, not the next depositor's");
        // bob pledges the seat he bought; what lands now is his.
        vm.prank(bob);
        nft.setApprovalForAll(address(seatJoin), true);
        vm.prank(bob);
        assertEq(seatJoin.deposit(1), address(acct));
        reward.mint(address(acct), 10e18);
        acct.sync(address(reward));
        assertEq(seatJoin.owed(1, address(reward), bob), 10e18);
        assertEq(seatJoin.owed(1, address(reward), alice), 30e18);
        vm.prank(carol); // anyone triggers, the money has one destination
        seatJoin.collect(1, address(reward), alice);
        seatJoin.collect(1, address(reward), bob);
        assertEq(reward.balanceOf(alice), 27e18);
        assertEq(reward.balanceOf(bob), 9e18);
        assertEq(reward.balanceOf(address(treasury)), 4e18);
        assertEq(reward.balanceOf(address(acct)), 0);
        assertEq(acct.reported(address(reward)), 0);
    }

    // ------------------------------------------------------------------ stray seats

    function test_rescueStraySeat() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        bytes32 digest = acct.authorizeWorker(_auth(acct, 1));
        // bob's seat 10 reaches alice's seat account by a plain transferFrom (no hook, nothing refuses it).
        vm.prank(bob);
        nft.transferFrom(bob, address(acct), 10);
        assertEq(nft.ownerOf(10), address(acct));
        vm.prank(bob);
        vm.expectRevert(SeatJoin.Unauthorized.selector);
        seatJoin.rescue(1, 10, bob);
        // The deposited seat itself is never a stray.
        vm.prank(governor);
        vm.expectRevert(SeatJoin.NotStray.selector);
        seatJoin.rescue(1, 1, governor);
        vm.prank(governor);
        vm.expectRevert(SeatJoin.NotStray.selector);
        seatJoin.rescue(2, 10, bob); // not where it sits
        vm.prank(governor);
        seatJoin.rescue(1, 10, bob);
        assertEq(nft.ownerOf(10), bob, "back with its sender");
        assertEq(nft.ownerOf(1), address(acct), "the deposit is untouched");
        assertEq(acct.isValidSignature(digest, ""), VALID, "and so is its pairing");
        _assertUnits();

        // A seat sent to ITS OWN account address before any deposit (the clone does not exist yet).
        address acct2 = seatJoin.accountOf(2);
        assertEq(acct2.code.length, 0);
        vm.prank(alice);
        nft.transferFrom(alice, acct2, 2);
        vm.prank(alice);
        vm.expectRevert(); // deposit needs the caller to own it: no way in
        seatJoin.deposit(2);
        vm.prank(governor);
        seatJoin.rescue(2, 2, alice);
        assertEq(nft.ownerOf(2), alice);
        assertGt(acct2.code.length, 0, "created to move it out");
        vm.prank(alice);
        assertEq(seatJoin.deposit(2), acct2, "and it deposits normally afterwards");
    }

    // ------------------------------------------------------------------ price: reflexive LTV and freeze

    /// @dev A new median attestation (one second later, same price) carrying figure `f`, recorded by a poke.
    function _relayFigure(uint256 f) private {
        vm.warp(vm.getBlockTimestamp() + 1); // not block.timestamp: via-IR caches it within a test
        median.set(median.value());
        median.setFigure(f);
        seatFeed.poke();
    }

    function test_liquidityChannel() public {
        // The figure steps down at most 20% per new attestation (audit wave 1, panel 6): relay 50 until it is accepted.
        for (uint256 i; i < 10 && seatFeed.acceptedFigure() != 50; ++i) _relayFigure(50);
        assertEq(seatFeed.acceptedFigure(), 50, "half the 100-sale threshold");
        assertEq(seatFeed.liquidity(), 0.5e18);
        (uint256 v,) = seatFeed.latestValue();
        assertEq(v, 2_000e18, "$4,000 x 0.5");
        vm.startPrank(alice);
        seatJoin.deposit(1);
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        ledger.open(SEAT, 0, Adjust(1e18, int256(_net(800e18) + 1e18), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(SEAT, 0, Adjust(1e18, int256(_net(800e18)), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        _relayFigure(300);
        assertEq(seatFeed.acceptedFigure(), 63, "a rise steps at most 25% + 1");
        for (uint256 i; i < 10 && seatFeed.acceptedFigure() < 100; ++i) _relayFigure(300);
        assertEq(seatFeed.liquidity(), 1e18, "capped at 1");
    }

    /// Audit wave 1, panel 6: one attestation that keeps the price and drops the figure moves the priced legs at most 20%.
    function test_figureFallIsCappedPerAttestation() public {
        assertEq(seatFeed.acceptedFigure(), 150);
        (uint256 before,) = seatFeed.latestValue();
        assertEq(before, 4_000e18);
        median.setFigure(10); // the same attestation re-read with a lower figure: capped against the same base
        assertEq(seatFeed.acceptedFigure(), 120);
        (uint256 v,) = seatFeed.latestValue();
        assertEq(v, 4_000e18, "liquidity still 1 at 120");
        seatFeed.poke(); // record the replacement (unrecorded, the next attestation would count as the only step)
        assertEq(seatFeed.acceptedFigure(), 120, "recording a replacement does not step it further");
        _relayFigure(10); // a new attestation: one more 20% step, from 120
        assertEq(seatFeed.acceptedFigure(), 96);
        (v,) = seatFeed.latestValue();
        assertEq(v, 3_840e18, "$4,000 x 0.96, not x 0.10");
    }

    /// Audit wave 1 (seats low): over an empty cap (fresh leaf) the type prices at 0 until a poke records the first
    /// attestation, so no attestation before it is accepted raw.
    function test_emptyCapPricesNothingUntilPoked() public {
        MockSeatFeed m2 = new MockSeatFeed(0, 0);
        SeatFeed f2 = new SeatFeed(m2, spot, ethFeed);
        m2.set(2e18);
        m2.setFigure(150);
        assertEq(f2.acceptedMedian(), 0, "unrecorded: unpriced");
        (uint256 v,) = f2.latestValue();
        assertEq(v, 0);
        f2.poke();
        assertEq(f2.acceptedMedian(), 2e18, "the first recorded attestation is accepted raw");
        vm.warp(vm.getBlockTimestamp() + 1);
        m2.set(1e18); // a 50% fall
        assertEq(f2.acceptedMedian(), 1.6e18, "the next one is capped");
    }

    function test_trendChannelTightensOnFall() public {
        median.set(2.5e18); // $5,000
        spot.set(2.5e18);
        seatFeed.poke();
        _skip(31 days);
        median.set(2e18); // $4,000 now
        spot.set(2e18);
        ethFeed.set(2000e18);
        median.setFigure(150);
        assertEq(seatFeed.median30dAgo(), 5_000e18);
        assertEq(seatFeed.trend(), 0.8e18);
        (uint256 v,) = seatFeed.latestValue();
        assertEq(v, 3_200e18, "$4,000 x 0.8");
        (uint256 s,) = seatSpot.latestValue();
        assertEq(s, 3_200e18, "the spot leg carries the same factor");
        vm.startPrank(alice);
        seatJoin.deposit(1);
        vm.expectRevert(LedgerBase.Unhealthy.selector);
        ledger.open(SEAT, 0, Adjust(1e18, int256(_net(1_280e18) + 1e18), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(SEAT, 0, Adjust(1e18, int256(_net(1_280e18)), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
    }

    function test_trendNeverLoosensOnRise() public {
        median.set(1e18);
        seatFeed.poke();
        _skip(31 days);
        _refresh();
        median.set(2e18);
        assertEq(seatFeed.trend(), 1e18);
        (uint256 v,) = seatFeed.latestValue();
        assertEq(v, 4_000e18);
    }

    function test_ringPicksNewestPointAtLeast30DaysOld() public {
        for (uint256 d; d <= 31; ++d) {
            median.set(2e18 + d * 0.01e18); // day d: $4,000 + $20 d (rises: the fall cap never binds)
            ethFeed.set(2000e18);
            seatFeed.poke();
            seatFeed.poke(); // second poke the same day is ignored
            _skip(1 days);
        }
        // Today = start + 32 days; newest point >= 30 days old is day 2.
        assertEq(seatFeed.median30dAgo(), 4_040e18);
    }

    function test_noHistoryMeansTrendOne() public view {
        assertEq(seatFeed.median30dAgo(), 0);
        assertEq(seatFeed.trend(), 1e18);
    }

    function test_freezeOnSkewButRepayAndMarksContinue() public {
        _pledge(alice, 1, 1_000e18);
        spot.set(1.4e18); // 30% under the median
        Pricer.Quote memory q = pricer.quote(SEAT);
        assertTrue(q.priced);
        assertFalse(q.borrowable, "frozen");
        assertEq(q.low, 4_000e18, "marks on the median");
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(SEAT, 0, Adjust(0, 1e18, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.prank(alice);
        ledger.open(SEAT, 0, Adjust(0, -100e18, 0, 0, 0, false, type(uint256).max, address(0))); // repaying still works
        spot.set(1.6e18); // 20% under: agreeing again
        q = pricer.quote(SEAT);
        assertTrue(q.borrowable);
        assertEq(q.low, 3_200e18, "min(median, spot)");
    }

    function test_staleMedianStopsEverything() public {
        _pledge(alice, 1, 1_000e18);
        median.setStale(true); // the count rides on the median attestation: stale together
        Pricer.Quote memory q = pricer.quote(SEAT);
        assertFalse(q.priced);
    }

    // ------------------------------------------------------------------ redemption exemption

    // ------------------------------------------------------------------ fall cap: 20% per new attestation

    /// A NEW median attestation (strictly newer timestamp) with fresh companions, then a poke.
    function _attest(uint256 v) internal {
        _skip(1);
        median.set(v);
        spot.set(v);
        ethFeed.set(ethFeed.value());
        seatFeed.poke();
    }

    function test_fallCap_constant() public view {
        assertEq(seatFeed.MAX_FALL_PER_UPDATE_BPS(), 2000);
        (uint128 base, uint128 raw, uint64 at,,) = seatFeed.cap();
        assertEq(base, 2e18, "anchored at deployment");
        assertEq(raw, 2e18);
        assertEq(at, uint64(block.timestamp));
    }

    function test_fallCap_15PercentPassesInOneUpdate() public {
        _attest(1.7e18);
        assertEq(seatFeed.acceptedMedian(), 1.7e18);
        (uint256 v,) = seatFeed.latestValue();
        assertEq(v, 3_400e18);
    }

    function test_fallCap_40PercentTakesThreeUpdates() public {
        _attest(1.2e18);
        assertEq(seatFeed.acceptedMedian(), 1.6e18, "0.8");
        (uint256 v,) = seatFeed.latestValue();
        assertEq(v, 3_200e18, "the priced leg reads the capped median");
        assertEq(seatFeed.rawMedianUsd(), 2_400e18, "raw stays readable");
        _attest(1.2e18);
        assertEq(seatFeed.acceptedMedian(), 1.28e18, "0.64");
        _attest(1.2e18);
        assertEq(seatFeed.acceptedMedian(), 1.2e18, "0.6: the raw value, reached on the third update");
        _attest(1.2e18);
        assertEq(seatFeed.acceptedMedian(), 1.2e18, "and stays there");
    }

    function test_fallCap_sameAttestationNeverStepsFurther() public {
        _attest(1.2e18);
        for (uint256 i; i < 10; ++i) {
            seatFeed.poke();
            assertEq(seatFeed.acceptedMedian(), 1.6e18);
            pricer.quote(SEAT);
        }
        // An equal-time replacement (SwarmFeed admits issuedAt == updatedAt) is not a new update: it is
        // capped against the same base as the attestation it replaced.
        median.set(0.5e18);
        assertEq(seatFeed.acceptedMedian(), 1.6e18, "same base");
        seatFeed.poke();
        seatFeed.poke();
        assertEq(seatFeed.acceptedMedian(), 1.6e18);
        (uint128 base, uint128 raw,,,) = seatFeed.cap();
        assertEq(base, 2e18);
        assertEq(raw, 0.5e18, "the replacement is what the next update steps from");
        _attest(0.5e18);
        assertEq(seatFeed.acceptedMedian(), 1.28e18);
    }

    function test_fallCap_viewIsCorrectWithoutPoke() public {
        _skip(1);
        median.set(1.2e18); // nobody pokes
        assertEq(seatFeed.acceptedMedian(), 1.6e18, "capped by the view alone");
        (uint256 v,) = seatFeed.latestValue();
        assertEq(v, 3_200e18);
        seatFeed.poke();
        assertEq(seatFeed.acceptedMedian(), 1.6e18, "a poke records what the view already said");
        // Two attestations with no poke between them count as one step: capped harder, never looser.
        _skip(1);
        median.set(1.2e18);
        _skip(1);
        median.set(1.1e18);
        assertEq(seatFeed.acceptedMedian(), 1.28e18, "one step from the recorded 1.6");
    }

    function test_fallCap_risesPassImmediately() public {
        _attest(1.2e18);
        assertEq(seatFeed.acceptedMedian(), 1.6e18);
        _attest(3e18);
        assertEq(seatFeed.acceptedMedian(), 3e18, "uncapped rise");
        median.set(4e18); // even an equal-time replacement rises at once
        assertEq(seatFeed.acceptedMedian(), 4e18);
    }

    function test_fallCap_crashThenRecovery() public {
        _attest(1e18);
        _attest(1e18);
        assertEq(seatFeed.acceptedMedian(), 1.28e18);
        _attest(1.9e18); // recovery: back at once
        assertEq(seatFeed.acceptedMedian(), 1.9e18);
        _attest(1.5e18); // a new fall steps from the recovered value
        assertEq(seatFeed.acceptedMedian(), 1.52e18);
        _attest(1.5e18);
        assertEq(seatFeed.acceptedMedian(), 1.5e18);
    }

    function test_fallCap_stateSurvivesStaleFeed() public {
        _attest(1.2e18);
        _skip(2 days);
        assertTrue(median.isStale());
        assertFalse(pricer.quote(SEAT).priced, "stale: unpriced");
        seatFeed.poke(); // no new attestation: nothing changes, and it does not revert
        assertEq(seatFeed.acceptedMedian(), 1.6e18, "the cap is not reset by staleness");
        _attest(1e18); // the first fresh attestation after the gap steps from 1.6, not from the raw 1.2
        assertEq(seatFeed.acceptedMedian(), 1.28e18);
        assertTrue(pricer.quote(SEAT).priced);
    }

    function test_fallCap_auctionStartsAtCappedMedian() public {
        _pledge(alice, 1, 1_500e18);
        median.set(1e18); // a 50% print in the same block: accepted 1.6
        spot.set(1e18);
        assertEq(seatFeed.rawMedianUsd(), 2_000e18);
        assertEq(seatFeed.medianUsd(), 3_200e18);
        liquidator.liquidate(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_200e18, "not below what the capped feed says");
    }

    /// For any attestation series: the accepted value never falls more than 20% per new attestation, equals
    /// the raw value whenever the raw value is within 20% of the previous accepted value, and the view
    /// before a poke equals the recorded value after it (extra pokes and same-time re-reads change nothing).
    function testFuzz_fallCap(uint256[10] memory raws, uint256 extraPokes) public {
        uint256 prev = seatFeed.acceptedMedian();
        for (uint256 i; i < raws.length; ++i) {
            uint256 raw = bound(raws[i], 0.01e18, 20e18);
            _skip(1);
            median.set(raw);
            uint256 viewed = seatFeed.acceptedMedian();
            seatFeed.poke();
            if ((extraPokes >> i) & 1 == 1) seatFeed.poke();
            uint256 acc = seatFeed.acceptedMedian();
            assertEq(acc, viewed, "view == recorded");
            uint256 lowest = prev * 8000 / 10_000;
            assertGe(acc, lowest, "at most 20% per update");
            if (raw >= lowest) assertEq(acc, raw, "raw within the cap passes through");
            else assertEq(acc, lowest);
            prev = acc;
        }
    }

    function test_seatsAreNotRedeemable() public {
        _pledge(alice, 1, 1_000e18);
        assertEq(sorted.size(SEAT), 0, "never listed");
        vm.prank(alice);
        vm.expectRevert(Redeemer.NotRedeemable.selector);
        redeemer.redeem(SEAT, 100e18, 0.05e18, 5, 0);
    }

    // ------------------------------------------------------------------ auction

    /// Median and spot to 1.6 ETH ($3,200): a 1,500 debt needs $3,750 at 250%.
    function _crash() internal {
        median.set(1.6e18);
        spot.set(1.6e18);
    }

    function test_auctionDecay() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_200e18, "starts at the (capped) median");
        _skip(3 hours);
        assertEq(seatJoin.price(_pid(SEAT, alice)), 2_720e18, "halfway: 0.85x");
        _skip(3 hours);
        assertEq(seatJoin.price(_pid(SEAT, alice)), 2_240e18, "0.7x at 6h");
        _skip(6 hours);
        assertEq(seatJoin.price(_pid(SEAT, alice)), 2_240e18, "holds at the floor");
    }

    function test_auctionWinnerReceivesNftAndBorrowerTheSurplus() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, 1_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        _crash();
        vm.prank(keeper);
        liquidator.liquidate(_pid(SEAT, alice)); // keeper marks
        _cash(bob, 5_000e18);
        uint256 debt = ledger.debtOf(_pid(SEAT, alice));
        uint256 aliceBefore = usd.balanceOf(alice);
        uint256 tre0 = usd.balanceOf(address(treasury)); // already holds the upfront fees
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        vm.expectRevert(SeatJoin.PriceAboveMax.selector);
        seatJoin.take(_pid(SEAT, alice), 3_000e18);
        (uint256 p, uint256 n) = seatJoin.take(_pid(SEAT, alice), 3_200e18);
        vm.stopPrank();
        assertEq(p, 3_200e18);
        assertEq(n, 1);
        assertEq(nft.ownerOf(1), bob, "winner holds the NFT itself");
        assertEq(acct.custodyEpoch(), 1);
        assertEq(ledger.debtOf(_pid(SEAT, alice)), 0);
        assertEq(ledger.position(_pid(SEAT, alice)).collateral, 0);
        uint256 penalty = debt / 10;
        uint256 toKeeper = penalty / 10; // chip 10% of the penalty
        assertApproxEqAbs(usd.balanceOf(keeper), toKeeper, 1e6, "marker");
        assertApproxEqAbs(usd.balanceOf(address(treasury)) - tre0, penalty - toKeeper + _interestToTreasury(), 1e6);
        assertApproxEqAbs(usd.balanceOf(alice) - aliceBefore, 3_200e18 - debt - penalty, 1e6, "surplus back");
        assertEq(seatJoin.holderOf(1), address(0));
        assertEq(seatJoin.seatCount(), 0);
        _assertSupply();
        _assertUnits();
    }

    function _interestToTreasury() internal view returns (uint256) {
        return 0; // no time passed in this test: no interest minted
    }

    function test_auctionWithBadDebt() public {
        _pledge(alice, 1, _net(1_600e18));
        // $1,600 a seat: the floor (0.7x) cannot cover 1,600 + penalty. A 60% fall takes five attestations
        // under the 20%-per-update cap: 1.6, 1.28, 1.024, 0.8192, then 0.8.
        for (uint256 i; i < 5; ++i) _attest(0.8e18);
        assertEq(seatFeed.acceptedMedian(), 0.8e18);
        liquidator.liquidate(_pid(SEAT, alice));
        _skip(6 hours);
        _refresh();
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        (,,,, uint128 bad) = ledger.ilkState(SEAT);
        assertGt(bad, 0, "the shortfall is the type's bad debt");
        assertEq(nft.ownerOf(1), bob);
        _assertSupply();
        _assertUnits();
    }

    /// Audit wave 1: a seat sale's bad debt is covered in the sale's own transaction, as a bite's is.
    function test_auctionBadDebtIsCoveredAtOnce() public {
        _pledge(alice, 1, _net(1_600e18));
        for (uint256 i; i < 5; ++i) _attest(0.8e18);
        liquidator.liquidate(_pid(SEAT, alice));
        _skip(6 hours);
        _refresh();
        _cash(bob, 8_000e18);
        vm.startPrank(bob);
        usd.transfer(address(treasury), 2_000e18); // the Treasury holds imdUSD to cover with
        usd.approve(address(seatJoin), type(uint256).max);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        (,,,, uint128 bad) = ledger.ilkState(SEAT);
        assertEq(bad, 0, "covered from the Treasury in the same transaction");
        assertEq(ledger.totalBadDebt(), 0);
        _assertSupply();
        _assertUnits();
    }

    function test_takeAllSeatsOfMultiSeatPosition() public {
        vm.startPrank(alice);
        seatJoin.deposit(1);
        seatJoin.deposit(2);
        seatJoin.deposit(3);
        ledger.open(SEAT, 0, Adjust(3e18, 4_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _cash(bob, 20_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        (, uint256 n) = seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        assertEq(n, 3);
        for (uint256 i = 1; i <= 3; ++i) assertEq(nft.ownerOf(i), bob);
        _assertSupply();
        _assertUnits();
    }

    function test_healthyAgainCancelsAuction() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        vm.expectRevert(SeatJoin.StillUnhealthy.selector);
        seatJoin.cancel(_pid(SEAT, alice));
        median.set(2e18);
        spot.set(2e18);
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        vm.expectRevert(Liquidator.Healthy.selector);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        seatJoin.cancel(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 0);
        assertEq(nft.ownerOf(1), seatJoin.accountOf(1));
    }

    /// The owner repays out of an auction: it ends there, and a later dip starts from a new mark, not the old decayed price.
    function test_repayThatHealsEndsTheAuction() public {
        _pledge(alice, 1, 1_500e18);
        uint256 id = _pid(SEAT, alice);
        _crash();
        liquidator.liquidate(id);
        assertGt(seatJoin.price(id), 0);
        deal(address(usd), alice, 5_000e18, true);
        int256 repay = -int256(ledger.debtOf(id) - 200e18);
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, repay, 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(seatJoin.price(id), 0, "healed by the repayment: no sale left");
    }

    /// A repayment that leaves it unhealthy must not reset the sale: dust repayments could otherwise hold a liquidation off.
    function test_repayThatDoesNotHealLeavesTheAuction() public {
        _pledge(alice, 1, 1_500e18);
        uint256 id = _pid(SEAT, alice);
        _crash();
        liquidator.liquidate(id);
        vm.warp(block.timestamp + 1 hours);
        median.set(median.value());
        uint256 p = seatJoin.price(id);
        assertGt(p, 0);
        deal(address(usd), alice, 1e18, true);
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, -1e18, 0, 0, 0, false, type(uint256).max, address(0)));
        assertEq(seatJoin.price(id), p, "the sale runs on");
    }

    function test_onlyLiquidatorOpensOnlyJoinSettles() public {
        vm.expectRevert(SeatJoin.Unauthorized.selector);
        seatJoin.open(_pid(SEAT, alice), address(this));
        vm.expectRevert(Liquidator.Unauthorized.selector);
        liquidator.settle(_pid(SEAT, alice), 1, address(this), false);
        vm.expectRevert(SeatJoin.NoAuction.selector);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
    }

    // ------------------------------------------------------------------ Treasury keeps the seat

    function test_treasuryKeepsSeatAtFloor() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, 1_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        // The Treasury gets imdUSD (a payer donates it here) and sends a budget to the join by its timelock.
        _cash(bob, 5_000e18);
        vm.prank(bob);
        usd.transfer(address(treasury), 3_000e18);
        _governTreasury(address(usd), address(seatJoin), 3_000e18);

        _crash();
        _refresh();
        liquidator.liquidate(_pid(SEAT, alice));
        vm.expectRevert(SeatJoin.NotAtFloor.selector);
        seatJoin.takeFloor(_pid(SEAT, alice));
        _skip(6 hours);
        _refresh();
        spot.set(1.1e18); // raw spot $2,200 < floor $2,240: someone may be selling below it
        vm.expectRevert(SeatJoin.SpotBelowFloor.selector);
        seatJoin.takeFloor(_pid(SEAT, alice));
        spot.set(1.6e18);
        (uint256 p,) = seatJoin.takeFloor(_pid(SEAT, alice));
        assertEq(p, 2_240e18);
        assertEq(nft.ownerOf(1), address(acct), "kept in its account");
        assertEq(seatJoin.holderOf(1), address(treasury));
        assertEq(seatJoin.balanceOf(address(treasury)), 1e18);
        assertEq(seatJoin.seatCount(), 0, "a kept seat is not exposure");
        assertEq(acct.custodyEpoch(), 1, "the borrower's pairings are gone");
        assertEq(ledger.debtOf(_pid(SEAT, alice)), 0);
        _assertSupply();
        _assertUnits();

        // Its rewards now flow to the Treasury, with no fee.
        reward.mint(address(acct), 20e18);
        acct.sync(address(reward));
        seatJoin.collect(1, address(reward), address(treasury));
        assertEq(reward.balanceOf(address(treasury)), 20e18);

        // It can be sold or re-lent later, only through the Treasury's timelock.
        _governTreasury(address(seatJoin), carol, 1e18);
        assertEq(seatJoin.holderOf(1), carol);
        assertEq(acct.custodyEpoch(), 2);
        vm.prank(carol);
        seatJoin.withdraw(1, carol);
        assertEq(nft.ownerOf(1), carol);
        _assertUnits();
    }

    function test_takeFloorNeedsBudget() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _skip(6 hours);
        _refresh();
        vm.expectRevert(SeatJoin.NoBudget.selector);
        seatJoin.takeFloor(_pid(SEAT, alice));
    }

    function test_reopenFromNewerMedian() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _skip(6 hours);
        vm.expectRevert(SeatJoin.NothingNew.selector);
        seatJoin.reopen(_pid(SEAT, alice));
        median.set(1.7e18);
        ethFeed.set(2000e18);
        seatJoin.reopen(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_400e18);
    }

    // ------------------------------------------------------------------ auction life + priced clock

    /// S2: an auction is void after AUCTION_LIFE of priced time; a healed position that dips again weeks later is
    /// never sold at the old floor. The next bite, or `reopen` while unhealthy, starts from the median as it stands.
    function test_auctionExpiresAndRestartsFromFreshMedian() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_200e18);
        _skip(23 hours);
        _refresh();
        assertFalse(seatJoin.expired(_pid(SEAT, alice)));
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 23 hours);
        _skip(1 hours);
        _refresh();
        assertTrue(seatJoin.expired(_pid(SEAT, alice)), "24h of priced time");
        assertEq(seatJoin.price(_pid(SEAT, alice)), 2_240e18, "the floor is still readable");
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        vm.expectRevert(SeatJoin.AuctionExpired.selector);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        vm.expectRevert(SeatJoin.AuctionExpired.selector);
        seatJoin.takeFloor(_pid(SEAT, alice));

        // The position heals; nobody cancels. 31 days later the median dips 20%: unhealthy again by a hair.
        median.set(2e18);
        spot.set(2e18);
        vm.expectRevert(SeatJoin.AuctionExpired.selector); // void, whatever the health
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        _skip(31 days);
        _attest(1.6e18); // 20%: passes the fall cap in one update
        (bool ok, bool priced) = ledger.healthy(_pid(SEAT, alice));
        assertTrue(priced);
        assertFalse(ok);
        vm.prank(bob);
        vm.expectRevert(SeatJoin.AuctionExpired.selector);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max); // NOT at the month-old floor of $2,240
        vm.expectRevert(SeatJoin.StillUnhealthy.selector);
        seatJoin.cancel(_pid(SEAT, alice));
        // Restart from the fresh median: by anyone's `reopen`, or by the Liquidator's bite replacing the void auction.
        seatJoin.reopen(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_200e18, "a fresh Dutch clock from the current median");
        assertFalse(seatJoin.expired(_pid(SEAT, alice)));
        (, uint40 startAt,,,,) = seatJoin.auctions(_pid(SEAT, alice));
        assertEq(startAt, uint40(block.timestamp));
        _skip(24 hours);
        _refresh();
        assertTrue(seatJoin.expired(_pid(SEAT, alice)));
        vm.prank(keeper);
        liquidator.liquidate(_pid(SEAT, alice)); // `open` replaces a void auction instead of reverting AuctionLive
        (,, , address marker,,) = seatJoin.auctions(_pid(SEAT, alice));
        assertEq(marker, keeper, "the restart's marker");
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_200e18);
        vm.startPrank(bob);
        (uint256 p,) = seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        assertEq(p, 3_200e18, "sold at the fresh start, not the stale floor");
        assertEq(nft.ownerOf(1), bob);
        _assertSupply();
        _assertUnits();
    }

    /// A void auction on a HEALTHY position cannot be reopened (cancel it); on an unhealthy one it can.
    function test_reopenOfExpiredAuctionNeedsUnhealthy() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _skip(24 hours);
        _refresh();
        median.set(2e18);
        spot.set(2e18);
        vm.expectRevert(SeatJoin.Healthy.selector); // the auction is void and the position healthy: cancel instead
        seatJoin.reopen(_pid(SEAT, alice));
        seatJoin.cancel(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 0);
    }

    /// L4: the Dutch clock runs on PRICED time. A median attestation past its life pauses the decay (and the life)
    /// until the next one lands; the time between is not sold off unseen.
    function test_auctionClockPausesWhileMedianStale() public {
        _pledge(alice, 1, 1_500e18);
        _attest(1.6e18); // attested at T0
        _skip(25 hours); // fresh for 1 more hour
        _refresh_ethOnly();
        liquidator.liquidate(_pid(SEAT, alice));
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_200e18);
        _skip(1 hours);
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 1 hours);
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_040e18, "one hour of decay");
        _skip(3 hours); // the median has been stale for 3 hours
        assertTrue(median.isStale());
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 1 hours, "paused");
        assertEq(seatJoin.price(_pid(SEAT, alice)), 3_040e18);
        _refresh_ethOnly(); // ETH/USD (the ETH type's feed too) and the spot leg: only the median is stale
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        vm.expectRevert(Liquidator.NotPriced.selector);
        seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        // A tick during the gap records exactly the priced hour.
        seatJoin.tick(_pid(SEAT, alice));
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 1 hours);
        // The next attestation lands: the clock resumes from where it paused.
        median.set(1.6e18);
        spot.set(1.6e18);
        ethFeed.set(2000e18);
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 1 hours);
        _skip(2 hours);
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 3 hours, "1h before the gap + 2h after");
        assertEq(seatJoin.price(_pid(SEAT, alice)), 2_720e18, "the 3-hour price");
        _refresh_ethOnly(); // the 1-hour spot leg aged out meanwhile; the median (26 h) did not
        vm.prank(bob);
        (uint256 p,) = seatJoin.take(_pid(SEAT, alice), type(uint256).max);
        assertEq(p, 2_720e18);
    }

    /// The reconstruction without a tick equals the ticked clock, gap or no gap, and a refresh before the old
    /// attestation ages out counts as continuous time.
    function test_auctionClockReconstructionMatchesTicks() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        // Refreshed before aging out: continuous.
        _skip(20 hours);
        _refresh();
        _skip(2 hours);
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 22 hours);
        seatJoin.tick(_pid(SEAT, alice));
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 22 hours);
        // Then a gap: the attestation of hour 20 is fresh until hour 46, stale for 6 hours, then a new one lands.
        _skip(30 hours);
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 46 hours, "the stale hours are not counted");
        _attest(1.6e18);
        assertEq(seatJoin.elapsed(_pid(SEAT, alice)), 46 hours, "and the new attestation does not add them back");
        assertTrue(seatJoin.expired(_pid(SEAT, alice)));
    }

    function _refresh_ethOnly() internal {
        ethFeed.set(ethFeed.value());
        spot.set(spot.value());
    }

    function test_recallBudget() public {
        _cash(bob, 1_000e18);
        uint256 tre0 = usd.balanceOf(address(treasury)); // the borrow's upfront fee
        vm.prank(bob);
        usd.transfer(address(seatJoin), 500e18);
        vm.expectRevert(SeatJoin.Unauthorized.selector);
        seatJoin.recallBudget();
        vm.prank(governor);
        seatJoin.recallBudget();
        assertEq(usd.balanceOf(address(treasury)) - tre0, 500e18);
    }

    function test_auctionTypeRejectsYieldRate() public {
        ParametersBase.Config memory c = params.config(SEAT);
        assertTrue(c.auction);
        assertFalse(c.redeemable);
    }

    // ------------------------------------------------------------------ positions as accounts

    /// A seat position that changes hands takes its seats with it: the new owner can repay and withdraw the very NFT.
    function test_positionTransferMovesSeats() public {
        _pledge(alice, 1, 1_000e18);
        uint256 id = _pid(SEAT, alice);
        PositionNFT pn = ledger.nft();
        vm.prank(alice);
        pn.transferFrom(alice, carol, id);
        assertEq(seatJoin.holderOf(1), carol, "the seat follows the position");
        assertEq(seatJoin.seatsOf(alice).length, 0);
        uint256 owed = ledger.debtOf(id);
        _cash(bob, owed + 100e18);
        vm.prank(bob);
        usd.transfer(carol, owed);
        vm.startPrank(carol);
        ledger.adjust(id, Adjust(-1e18, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        seatJoin.withdraw(1, carol);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), carol);
        _assertSupply();
        _assertUnits();
    }

    /// Seat units belong to their holder: only the owner pledges them, and they leave only to the owner.
    function test_seatCollateralOnlyFromAndToTheOwner() public {
        _pledge(alice, 1, 1_000e18);
        uint256 id = _pid(SEAT, alice);
        PositionNFT pn = ledger.nft();
        vm.startPrank(alice);
        pn.approveOperator(id, keeper, uint8(1) | uint8(32));
        seatJoin.deposit(2);
        vm.stopPrank();
        vm.startPrank(bob);
        seatJoin.deposit(10);
        vm.expectRevert(LedgerBase.HolderBound.selector);
        ledger.addFor(id, 1e18, false); // bob's seat into alice's position
        vm.stopPrank();
        vm.prank(alice);
        ledger.adjust(id, Adjust(1e18, 0, 0, 0, 0, false, type(uint256).max, address(0))); // her own second seat
        vm.prank(keeper);
        vm.expectRevert(LedgerBase.HolderBound.selector);
        ledger.adjust(id, Adjust(-1e18, 0, 0, 0, 0, false, type(uint256).max, keeper)); // out to someone else
        _assertUnits();
    }

    function test_positionTransferRespectsPerBorrower() public {
        vm.startPrank(alice);
        for (uint256 i = 1; i <= 3; ++i) seatJoin.deposit(i); // alice holds the 3 she may
        vm.stopPrank();
        _pledge(bob, 10, 1_000e18);
        uint256 id = _pid(SEAT, bob);
        PositionNFT pn = ledger.nft();
        vm.prank(bob);
        vm.expectRevert(SeatJoin.TooManySeats.selector);
        pn.transferFrom(bob, alice, id);
    }

    /// A position sold after a transfer pays its NEW owner the surplus and takes the seats from the new owner's list.
    function test_auctionAfterTransfer() public {
        _pledge(alice, 1, 1_500e18);
        uint256 id = _pid(SEAT, alice);
        PositionNFT pn = ledger.nft();
        vm.prank(alice);
        pn.transferFrom(alice, carol, id);
        _crash();
        liquidator.liquidate(id);
        _cash(bob, 20_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        uint256 carolBefore = usd.balanceOf(carol);
        seatJoin.take(id, type(uint256).max);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), bob);
        assertEq(seatJoin.seatsOf(carol).length, 0);
        assertGe(usd.balanceOf(carol), carolBefore, "any surplus goes to the owner at the sale");
        _assertSupply();
        _assertUnits();
    }

    // ------------------------------------------------------------------ claim-rule selector denylist

    /// A claim rule may never allowlist a selector that moves or approves the account's tokens (SeatAccount.claim
    /// forwards any calldata): approving `reward.approve` would let anyone make every account approve them. Refused at
    /// propose; a token-moving selector can still be REMOVED (rule 0), and an ordinary claim selector is still accepted.
    function test_panelG4_claimRuleRefusesTokenMovingSelectors() public {
        bytes4[8] memory bad = [
            bytes4(0x095ea7b3), // approve
            0xa9059cbb, // transfer
            0x23b872dd, // transferFrom
            0xd505accf, // permit
            0xa22cb465, // setApprovalForAll
            0x42842e0e, // safeTransferFrom
            0xd73dd623, // increaseApproval (audit wave 1)
            0x87517c45 // Permit2 approve (audit wave 1)
        ];
        for (uint256 i; i < bad.length; ++i) {
            for (uint8 rule = 1; rule <= 2; ++rule) {
                bytes memory p = abi.encode(params.SET_SEAT_CLAIM(), address(seatJoin), address(reward), bad[i], rule);
                vm.prank(governor);
                vm.expectRevert(ParametersBase.BadConfig.selector);
                params.propose(p);
            }
        }
        // Removing such a rule is always allowed.
        uint8 k = params.SET_SEAT_CLAIM();
        vm.prank(governor);
        params.propose(abi.encode(k, address(seatJoin), address(reward), bad[0], uint8(0)));
        vm.prank(governor);
        params.cancel();
        // An ordinary claim selector still passes.
        vm.prank(governor);
        params.propose(abi.encode(k, address(seatJoin), address(dist), MockDistributor.claim.selector, uint8(1)));
    }

    /// Re-check: token standards whose calls move or approve tokens with a callback, and batching entry points that
    /// reach any of the above, are refused too. Selectors come from the signatures, so a typo in the denylist fails here.
    function test_G4_callbackAndBatchSelectorsRefused() public {
        string[11] memory sigs = [
            "transferAndCall(address,uint256)",
            "transferAndCall(address,uint256,bytes)",
            "transferFromAndCall(address,address,uint256)",
            "transferFromAndCall(address,address,uint256,bytes)",
            "approveAndCall(address,uint256)",
            "approveAndCall(address,uint256,bytes)",
            "send(address,uint256,bytes)",
            "operatorSend(address,address,uint256,bytes,bytes)",
            "authorizeOperator(address)",
            "multicall(bytes[])",
            "multicall(uint256,bytes[])"
        ];
        uint8 k = params.SET_SEAT_CLAIM();
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(governor);
            vm.expectRevert(ParametersBase.BadConfig.selector);
            params.propose(abi.encode(k, address(seatJoin), address(reward), bytes4(keccak256(bytes(sigs[i]))), uint8(1)));
        }
    }

    // ------------------------------------------------------------------ bound chop on the seat path

    /// A SET_RISK raising chop 10% -> 20% is in its 7-day grace: alice stays on her bound 10%. The auction settles at it in the
    /// Ledger, and SeatJoin's split must use the same 10%, not the newest: she keeps the surplus above debt + 10%.
    function test_M11_seatAuctionUsesBoundChop() public {
        _pledge(alice, 1, 1_500e18);
        ParametersBase.Risk memory r = params.storedRisk(SEAT);
        r.chop = 0.2e18;
        bytes memory payload = abi.encode(params.SET_RISK(), SEAT, r);
        vm.prank(governor);
        params.propose(payload);
        _skip(48 hours);
        _refresh();
        params.applyPending();
        (, uint256 bound) = params.liqRisk(SEAT, ledger.position(_pid(SEAT, alice)).version);
        assertEq(bound, 0.1e18, "bound to the old chop");
        assertEq(params.risk(SEAT).chop, 0.2e18, "newest is harsher");

        _crash();
        vm.prank(keeper);
        liquidator.liquidate(_pid(SEAT, alice));
        _cash(bob, 5_000e18);
        uint256 debt = ledger.debtOf(_pid(SEAT, alice));
        uint256 a0 = usd.balanceOf(alice);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        (uint256 p,) = seatJoin.take(_pid(SEAT, alice), 3_200e18);
        vm.stopPrank();
        assertApproxEqAbs(usd.balanceOf(alice) - a0, p - debt - debt / 10, 1e6, "the surplus at the bound 10%");
        _assertSupply();
        _assertUnits();
    }

    // ------------------------------------------------------------------ gas audit: median30dAgo

    /// @dev The scan `median30dAgo` falls back to, reading the ring from outside: the reference for its fast paths.
    function _scan30dAgo() internal view returns (uint256) {
        uint256 today = vm.getBlockTimestamp() / 1 days;
        (uint256 bestOld, uint256 bestOldDay, uint256 oldest, uint256 oldestDay) = (0, 0, 0, type(uint256).max);
        for (uint256 i; i < seatFeed.RING(); ++i) {
            (uint192 value, uint64 day) = seatFeed.ring(i);
            if (value == 0) continue;
            if (day + seatFeed.TREND_DAYS() <= today && day >= bestOldDay) (bestOld, bestOldDay) = (value, day);
            if (day < oldestDay) (oldest, oldestDay) = (value, day);
        }
        return bestOld != 0 ? bestOld : oldest;
    }

    /// Random poke histories: daily runs, gaps past the trend window, gaps past the whole ring, repeat pokes in a day.
    function testFuzz_gas_median30dAgoMatchesTheScan(uint256 seed) public {
        uint256[8] memory gaps = [uint256(0), 1, 1, 1, 1, 2, 5, 35];
        assertEq(seatFeed.median30dAgo(), _scan30dAgo(), "before the first poke");
        for (uint256 i; i < 90; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _skip(gaps[r % 8] * 1 days);
            assertEq(seatFeed.median30dAgo(), _scan30dAgo(), "after the gap");
            if (r >> 8 & 3 != 0) {
                _attest(1.5e18 + (r >> 16) % 1e18);
                assertEq(seatFeed.median30dAgo(), _scan30dAgo(), "after the poke");
            }
        }
    }

    function test_gas_median30dAgoDoesNotScanOnceTheRingHasAPoint() public {
        _attest(2e18);
        assertEq(uint256(seatFeed.firstDay()), vm.getBlockTimestamp() / 1 days);
        uint256 g = gasleft();
        uint256 v = seatFeed.median30dAgo();
        g -= gasleft();
        assertEq(v, _scan30dAgo());
        assertLt(g, 15_000, "two slots read, not thirty-two");
    }
}
