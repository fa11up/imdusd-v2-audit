// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatSystem} from "../utils/SeatSystem.sol";
import {MockERC20, MockFeed, MockSeatFeed} from "../utils/Mocks.sol";
import {MockSeatNFT, MockAgentAdapter} from "../utils/SeatMocks.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";

/// Regression from the 2026-11 internal review: a seat position changes hands while the type's seat cap is full, because a
/// holder-to-holder move does not change `seatCount`; only the new owner's perBorrower applies. Failed before the fix.
contract PanelSeatTransferTest is SeatSystem {
    bytes32 constant ETH = "ETH";
    MockSeatNFT seatNft;
    MockFeed ethFeed;
    MockSeatFeed median;
    MockFeed spot;

    address alice = makeAddr("alice");
    address carol = makeAddr("carol"); // holds no seat at all

    function setUp() public {
        vm.warp(1_800_000_000);
        seatNft = new MockSeatNFT();
        ethFeed = new MockFeed(2000e18);
        median = new MockSeatFeed(2e18, 150);
        median.setMaxAge(26 hours);
        spot = new MockFeed(2e18);
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        _addIlk(ETH, address(new MockERC20("WETH", 18)), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        _addSeatIlk(IERC721(address(seatNft)), IImdAgentAdapter(address(new MockAgentAdapter())), median, spot, ethFeed, 40_000e18);
        params.seal();
    }

    function test_P05_seatPositionTransfersWhenCapFull() public {
        // alice pledges one seat and borrows.
        seatNft.mint(alice, 1);
        vm.startPrank(alice);
        seatNft.setApprovalForAll(address(seatJoin), true);
        seatJoin.deposit(1);
        uint256 id = ledger.open(SEAT, 0, Adjust(1e18, 500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        // 24 other holders fill the type to its 25-seat cap (3 each).
        uint256 tokenId = 100;
        for (uint256 h; h < 8; ++h) {
            address u = address(uint160(0xBEEF00 + h));
            vm.startPrank(u);
            seatNft.setApprovalForAll(address(seatJoin), true);
            for (uint256 k; k < 3; ++k) {
                seatNft.mint(u, ++tokenId);
                seatJoin.deposit(tokenId);
            }
            vm.stopPrank();
        }
        assertEq(seatJoin.seatCount(), 25);
        assertEq(seatJoin.seatsOf(carol).length, 0, "carol is far under perBorrower");

        PositionNFT pn = ledger.nft();
        vm.prank(alice);
        pn.transferFrom(alice, carol, id); // a 1-seat move between holders: seatCount stays 25
        assertEq(seatJoin.seatCount(), 25);
        assertEq(seatJoin.seatsOf(carol).length, 1);
        assertEq(seatJoin.seatsOf(alice).length, 0);
        // perBorrower still binds: a holder at the limit cannot receive another seat position.
        address full = address(uint160(0xBEEF00));
        assertEq(seatJoin.seatsOf(full).length, seatJoin.perBorrower());
        vm.prank(carol);
        vm.expectRevert(SeatJoin.TooManySeats.selector);
        pn.transferFrom(carol, full, id);
    }
}
