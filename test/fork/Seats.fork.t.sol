// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatSystem} from "../utils/SeatSystem.sol";
import {MockFeed, MockSeatFeed} from "../utils/Mocks.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {ChainlinkFeed} from "../../src/feeds/ChainlinkFeed.sol";
import {SeatAccount, IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IAggregatorF {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev The live IMDSeatStrategy (proxy "IMD6900"), IMD-accepted; hive-seat-vault forks against it too.
interface IRefStrategy {
    function workerAuthorizationDigest(SeatAccount.WorkerAuthorization calldata auth) external view returns (bytes32);
    function IMD_AGENT_ADAPTER() external view returns (address);
}

/// @notice Seats against the REAL identity.md collection (Solady ERC-721) and a real seat, its owner
/// impersonated. Sale feeds are mocks (the nft-sale-median recipe is not live yet); ETH/USD is Chainlink.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/Seats.fork.t.sol
contract SeatsForkTest is SeatSystem {
    address constant IDMD = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant REF_STRATEGY = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    bytes32 constant ETH = "ETH";
    /// Same message as test/unit/SeatDigest.t.sol, computed by the plane's TypeScript (eip712.ts + viem).
    bytes32 constant PLANE_DIGEST = 0xb4e5e0f756c1533aa83f20c580898b17d9604c32bc0d15a98651daa93753e7a7;

    IERC721 nft = IERC721(IDMD);
    MockSeatFeed median;
    MockFeed spot;
    uint256 seat;
    address holder;
    address bob = makeAddr("bob");
    address adapter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        _freshenEth();
        _deploySystem(IERC20(Mainnet.V1_IMDUSD));
        IFeed eth = new ChainlinkFeed(Mainnet.CL_ETH_USD, 18, 1 hours + 10 minutes);
        _addIlk(ETH, Mainnet.WETH, eth, eth, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        median = new MockSeatFeed(1.95e18, 150); // floor ~1.95 ETH, median 1.97
        spot = new MockFeed(1.95e18);
        adapter = IRefStrategy(REF_STRATEGY).IMD_AGENT_ADAPTER();
        _addSeatIlk(nft, IImdAgentAdapter(adapter), median, spot, eth, 100_000e18);
        params.seal();

        // A real seat held by an EOA (skip contract holders: strategies, vaults).
        for (uint256 id = 1; id <= 2000; ++id) {
            address o = nft.ownerOf(id);
            if (o.code.length == 0) {
                seat = id;
                holder = o;
                break;
            }
        }
        vm.prank(holder);
        nft.setApprovalForAll(address(seatJoin), true);
    }

    function _freshenEth() internal {
        (uint80 id, int256 answer,,, uint80 ans) = IAggregatorF(Mainnet.CL_ETH_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer, block.timestamp, block.timestamp, ans)
        );
    }

    function _auth(address acct) internal view returns (SeatAccount.WorkerAuthorization memory a) {
        a.deviceKey = keccak256("device-key");
        a.wallet = acct;
        a.tokenId = seat;
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

    /// The digest equals both the plane's TypeScript output and the live IMD-accepted strategy's.
    function test_fork_digestByteIdentical() public {
        SeatAccount.WorkerAuthorization memory a = SeatAccount.WorkerAuthorization({
            deviceKey: keccak256("device-key"),
            wallet: 0x1111111111111111111111111111111111111111,
            tokenId: 1343,
            nonce: keccak256("nonce"),
            expiresAt: 1800003600,
            relayOrigin: "https://api.imd.fun"
        });
        SeatAccount impl = SeatAccount(seatJoin.implementation());
        assertEq(impl.workerAuthorizationDigest(a), PLANE_DIGEST, "plane TypeScript");
        assertEq(IRefStrategy(REF_STRATEGY).workerAuthorizationDigest(a), PLANE_DIGEST, "live strategy");
    }

    function test_fork_roundTripAndPairing() public {
        vm.prank(holder);
        SeatAccount acct = SeatAccount(seatJoin.deposit(seat));
        assertEq(nft.ownerOf(seat), address(acct), "real NFT in its account");

        (, int256 px,,,) = IAggregatorF(Mainnet.CL_ETH_USD).latestRoundData();
        uint256 seatUsd = 1.95e18 * uint256(px) * 1e10 / 1e18;
        uint256 debt = seatUsd * 1e18 / 2.6e18; // just under 40% LTV
        vm.startPrank(holder);
        ledger.open(SEAT, 0, Adjust(1e18, int256(debt), 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        bytes32 digest = acct.authorizeWorker(_auth(address(acct)));
        vm.stopPrank();
        assertEq(acct.isValidSignature(digest, ""), bytes4(0x1626ba7e), "the plane's isValidSignature passes");
        assertEq(usd.balanceOf(holder) >= debt, true);
        _assertSupply();

        // The position owes the borrow plus its upfront fee; the fee was minted to the Treasury, so fund it by
        // borrowing against WETH (the fee of that borrow stays in the ETH position: the supply equation holds).
        uint256 owed = ledger.debtOf(_pid(SEAT, holder));
        assertGt(owed, debt, "upfront fee on top of the borrow");
        vm.deal(holder, 1 ether);
        vm.startPrank(holder);
        (bool ok,) = Mainnet.WETH.call{value: 1 ether}("");
        assertTrue(ok);
        IERC20(Mainnet.WETH).approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(1e18, 200e18, 0.02e18, 0, 0, false, type(uint256).max, address(0)));
        ledger.open(SEAT, 0, Adjust(-1e18, -int256(owed), 0, 0, 0, false, type(uint256).max, address(0)));
        seatJoin.withdraw(seat, holder);
        vm.stopPrank();
        assertEq(ledger.debtOf(_pid(SEAT, holder)), 0, "seat debt closed in full");
        assertEq(nft.ownerOf(seat), holder, "real NFT back");
        assertEq(acct.isValidSignature(digest, ""), bytes4(0xffffffff), "pairing revoked");
        _assertSupply();
    }

    function test_fork_registerAgentAgainstLiveAdapter() public {
        vm.prank(holder);
        SeatAccount acct = SeatAccount(seatJoin.deposit(seat));
        vm.prank(holder);
        uint256 id = acct.registerAgent("ipfs://imdusd-seat");
        assertGt(id, 0);
    }

    function test_fork_liquidationMovesRealNft() public {
        vm.prank(holder);
        SeatAccount acct = SeatAccount(seatJoin.deposit(seat));
        (, int256 px,,,) = IAggregatorF(Mainnet.CL_ETH_USD).latestRoundData();
        uint256 debt = 1.95e18 * uint256(px) * 1e10 / 1e18 * 1e18 / 2.6e18;
        vm.prank(holder);
        ledger.open(SEAT, 0, Adjust(1e18, int256(debt), 0.08e18, 0, 0, false, type(uint256).max, address(0)));

        median.set(1.6e18);
        spot.set(1.6e18);
        liquidator.liquidate(_pid(SEAT, holder));

        deal(Mainnet.WETH, bob, 100e18);
        vm.startPrank(bob);
        IERC20(Mainnet.WETH).approve(address(ledger), type(uint256).max);
        ledger.open(ETH, 0, Adjust(100e18, 50_000e18, 0.02e18, 0, 0, false, type(uint256).max, address(0)));
        usd.approve(address(seatJoin), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _freshenEth();
        median.set(1.6e18);
        spot.set(1.6e18);
        seatJoin.take(_pid(SEAT, holder), type(uint256).max);
        vm.stopPrank();
        assertEq(nft.ownerOf(seat), bob, "the auction winner holds the real NFT");
        assertEq(acct.custodyEpoch(), 1);
        assertEq(ledger.debtOf(_pid(SEAT, holder)), 0);
        _assertSupply();
    }
}
