// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatSystem} from "../utils/SeatSystem.sol";
import {MockERC20, MockFeed, MockSeatFeed} from "../utils/Mocks.sol";
import {MockSeatNFT, MockAgentAdapter} from "../utils/SeatMocks.sol";
import {Ledger} from "../../src/Ledger.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

contract SeatHandler is Test {
    bytes32 constant SEAT = "SEAT";
    bytes32 constant ETH = "ETH";
    Ledger ledger;
    Liquidator liquidator;
    SeatJoin join;
    MockSeatNFT nft;
    MockFeed median;
    MockFeed spot;
    MockFeed ethFeed;
    ImdUSD usd;
    address[] public users;
    address taker = makeAddr("taker");

    uint256 public ok_pledge;
    uint256 public ok_repay;
    uint256 public ok_exit;
    uint256 public ok_open;
    uint256 public ok_take;

    constructor(Ledger l, Liquidator q, SeatJoin j, MockSeatNFT n, MockFeed m, MockFeed s, MockFeed e, address[] memory u) {
        ledger = l;
        liquidator = q;
        join = j;
        nft = n;
        median = m;
        spot = s;
        ethFeed = e;
        usd = l.token();
        users = u;
        vm.prank(taker);
        usd.approve(address(j), type(uint256).max);
    }

    function _u(uint256 s) internal view returns (address) {
        return users[s % users.length];
    }

    function _fresh() internal {
        median.set(median.value());
        spot.set(spot.value());
        ethFeed.set(ethFeed.value());
    }

    /// Deposit one of the user's seats still in the wallet and borrow against the whole position.
    function pledge(uint256 u, uint256 debt) external {
        address who = _u(u);
        uint256 base = (u % users.length) * 10;
        for (uint256 id = base + 1; id <= base + 3; ++id) {
            if (nft.ownerOf(id) != who) continue;
            vm.startPrank(who);
            join.deposit(id);
            uint256 room = (ledger.position(_pid(SEAT, who)).collateral + 1e18) * median.value() * ethFeed.value() / 1e36 * 1e18 / 2.5e18;
            uint256 have = ledger.debtOf(_pid(SEAT, who));
            uint256 add = room > have + 100e18 ? bound(debt, 0, room - have) : 0;
            if (have == 0 && add < 100e18) add = 0;
            try ledger.open(SEAT, 0, Adjust(1e18, int256(add), 0.08e18, 0, 0, false, type(uint256).max, address(0))) {
                ok_pledge++;
            } catch {}
            vm.stopPrank();
            return;
        }
    }

    function repayAndExit(uint256 u) external {
        address who = _u(u);
        uint256 debt = ledger.debtOf(_pid(SEAT, who));
        uint256 coll = ledger.position(_pid(SEAT, who)).collateral;
        if (coll == 0 || usd.balanceOf(who) < debt) return;
        vm.startPrank(who);
        try ledger.open(SEAT, 0, Adjust(-int256(coll), -int256(debt), 0, 0, 0, false, type(uint256).max, address(0))) {
            ok_repay++;
            uint256[] memory ids = join.seatsOf(who);
            for (uint256 i; i < ids.length; ++i) join.withdraw(ids[i], who);
            ok_exit++;
        } catch {}
        vm.stopPrank();
    }

    function movePrice(uint256 wei_) external {
        uint256 v = bound(wei_, 0.5e18, 3e18);
        median.set(v);
        spot.set(v);
    }

    function passTime(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1, 3 days));
        _fresh();
    }

    function liquidate(uint256 u) external {
        try liquidator.liquidate(_pid(SEAT, _u(u))) {
            ok_open++;
        } catch {}
    }

    function take(uint256 u, uint256 wait) external {
        address who = _u(u);
        (, uint40 at,,,,) = join.auctions(_pid(SEAT, who));
        if (at == 0) return;
        vm.warp(vm.getBlockTimestamp() + bound(wait, 0, 7 hours));
        _fresh();
        uint256 need = join.price(_pid(SEAT, who)) * (ledger.position(_pid(SEAT, who)).collateral / 1e18);
        if (usd.balanceOf(taker) < need) {
            vm.prank(taker);
            try ledger.open(ETH, 0, Adjust(int256(need / 500 + 10e18), int256(need), 0.02e18, 0, 0, false, type(uint256).max, address(0))) {} catch {}
        }
        vm.prank(taker);
        try join.take(_pid(SEAT, who), type(uint256).max) {
            ok_take++;
        } catch {}
    }
}

/// @notice The supply equation and seat custody hold with seats in the system.
contract SeatInvariantsTest is SeatSystem {
    bytes32 constant ETH = "ETH";
    SeatHandler handler;
    MockSeatNFT nft;
    address[] users;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new MockSeatNFT();
        MockERC20 weth = new MockERC20("WETH", 18);
        MockFeed ethFeed = new MockFeed(2000e18);
        MockFeed median = new MockSeatFeed(2e18, 150);
        MockFeed spot = new MockFeed(2e18);
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 100_000_000e18));
        _addSeatIlk(IERC721(address(nft)), IImdAgentAdapter(address(new MockAgentAdapter())), median, spot, ethFeed, 100_000e18);
        params.seal();
        for (uint256 i; i < 4; ++i) {
            address u = makeAddr(string(abi.encodePacked("seat-user", i)));
            users.push(u);
            for (uint256 k = 1; k <= 3; ++k) nft.mint(u, i * 10 + k);
            vm.prank(u);
            nft.setApprovalForAll(address(seatJoin), true);
        }
        handler = new SeatHandler(ledger, liquidator, seatJoin, nft, median, spot, ethFeed, users);
        weth.mint(makeAddr("taker"), 1_000_000e18);
        vm.prank(makeAddr("taker"));
        weth.approve(address(ledger), type(uint256).max);
        // Borrowers repay with imdUSD from an ETH position too.
        for (uint256 i; i < users.length; ++i) {
            weth.mint(users[i], 100e18);
            vm.startPrank(users[i]);
            weth.approve(address(ledger), type(uint256).max);
            ledger.open(ETH, 0, Adjust(100e18, 50_000e18, 0.02e18, 0, 0, false, type(uint256).max, address(0)));
            vm.stopPrank();
        }
        targetContract(address(handler));
    }

    function invariant_seatSupply() public {
        ledger.accrue(ETH);
        ledger.accrue(SEAT);
        (uint128 d1,,,, uint128 b1) = ledger.ilkState(ETH);
        (uint128 d2,,,, uint128 b2) = ledger.ilkState(SEAT);
        assertEq(usd.totalSupply(), uint256(d1) + b1 + d2 + b2 + ledger.reserveBacked() + migrator.outstanding(), "supply");
    }

    /// Every unit is a seat in its account; the pool is the recorded collateral; positions hold whole seats;
    /// a holder's units (wallet + pledged) equal the seats held for them.
    function invariant_seatCustody() public view {
        uint256 held;
        for (uint256 i; i < users.length; ++i) {
            for (uint256 k = 1; k <= 3; ++k) {
                uint256 id = i * 10 + k;
                if (nft.ownerOf(id) == seatJoin.accountOf(id)) held++;
            }
            address u = users[i];
            uint256 pledged = ledger.position(_pid(SEAT, u)).collateral;
            assertEq(pledged % 1e18, 0, "whole seats");
            assertEq(seatJoin.balanceOf(u) + pledged, seatJoin.seatsOf(u).length * 1e18, "holder units");
        }
        assertEq(seatJoin.totalSupply(), held * 1e18, "units == seats");
        (, uint128 c,,,) = ledger.ilkState(SEAT);
        assertEq(seatJoin.balanceOf(address(seatJoin)), c, "pool");
    }

    function test_seatHandlerNotHollow() public {
        handler.pledge(0, 1_000e18);
        handler.pledge(0, 1_000e18);
        handler.pledge(1, 1_200e18);
        handler.pledge(2, 500e18);
        handler.repayAndExit(2);
        handler.movePrice(1.2e18);
        handler.liquidate(0);
        handler.take(0, 1 hours);
        handler.liquidate(1);
        handler.take(1, 7 hours);
        assertEq(handler.ok_pledge(), 4, "pledge");
        assertEq(handler.ok_exit(), 1, "exit");
        assertEq(handler.ok_open(), 2, "auctions");
        assertEq(handler.ok_take(), 2, "takes");
        invariant_seatSupply();
        invariant_seatCustody();
    }
}
