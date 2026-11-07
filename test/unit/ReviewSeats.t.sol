// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SeatsTest} from "./Seats.t.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {SeatAccount} from "../../src/seats/SeatAccount.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @dev A "reward token" anyone can deploy: `balanceOf` reads nonzero so `sync` reports it; `transfer` burns every unit
/// of gas it is given (INVALID). Three of them, each eating (63/64)^3 of the gas left through three nested frames, left
/// ~6k gas of a 60M block in the review's PoC (seats S1).
contract GasBurnerToken {
    uint256 internal _n = 1;

    function bump() external {
        ++_n;
    }

    function balanceOf(address) external view returns (uint256) {
        return _n;
    }

    function transfer(address, uint256) external pure returns (bool) {
        assembly {
            invalid()
        }
    }
}

/// @dev Cheap variant: a plain token that works, deployed many times.
contract PlainToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice Regression for an earlier internal review's seats S1 (CRITICAL): reported reward tokens must never be able to block a
/// seat's sale, the Treasury's floor option or the holder's withdrawal. Every custody call is made with the mainnet
/// block gas limit, because foundry's default test gas (2^30) hides the 63/64 effect. Fails on main (OutOfGas), passes
/// once custody no longer walks reward tokens (credits settle at report time, `collect` is separate).
contract ReviewSeatsTest is SeatsTest {
    uint256 constant BLOCK_GAS = 60_000_000; // mainnet block gas limit (Oct 2026)

    function _burners(SeatAccount acct) internal returns (GasBurnerToken b1, GasBurnerToken b2, GasBurnerToken b3) {
        vm.startPrank(carol); // no seat, no position, no imdUSD
        b1 = new GasBurnerToken();
        b2 = new GasBurnerToken();
        b3 = new GasBurnerToken();
        acct.sync(address(b1));
        acct.sync(address(b2));
        acct.sync(address(b3));
        vm.stopPrank();
    }

    /// Control: with no griefing the auction clears.
    function test_s1_control_takeSucceeds() public {
        _pledge(alice, 1, 1_500e18);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        seatJoin.take{gas: BLOCK_GAS}(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), bob);
    }

    /// Three gas burners reported by a stranger: the auction still clears in one block.
    function test_s1_threeBurnerTokensDoNotBlockTake() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, 1_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        _burners(acct);
        _crash();
        liquidator.liquidate(_pid(SEAT, alice));
        _cash(bob, 5_000e18);
        vm.startPrank(bob);
        usd.approve(address(seatJoin), type(uint256).max);
        seatJoin.take{gas: BLOCK_GAS}(_pid(SEAT, alice), type(uint256).max);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), bob, "sold");
        assertEq(ledger.debtOf(_pid(SEAT, alice)), 0, "debt closed");
        _assertSupply();
        _assertUnits();
    }

    /// The Treasury's floor option is not blocked either.
    function test_s1_threeBurnerTokensDoNotBlockTakeFloor() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        vm.prank(alice);
        ledger.open(SEAT, 0, Adjust(1e18, 1_500e18, 0.08e18, 0, 0, false, type(uint256).max, address(0)));
        _burners(acct);
        _cash(bob, 5_000e18);
        vm.prank(bob);
        usd.transfer(address(treasury), 3_000e18);
        _governTreasury(address(usd), address(seatJoin), 3_000e18);
        _crash();
        _refresh();
        liquidator.liquidate(_pid(SEAT, alice));
        _skip(6 hours);
        _refresh();
        seatJoin.takeFloor{gas: BLOCK_GAS}(_pid(SEAT, alice));
        assertEq(seatJoin.holderOf(1), address(treasury), "kept by the Treasury");
        assertEq(ledger.debtOf(_pid(SEAT, alice)), 0);
        _assertUnits();
    }

    /// Nor the owner's way out.
    function test_s1_threeBurnerTokensDoNotBlockWithdraw() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        _burners(acct);
        vm.prank(alice);
        seatJoin.withdraw{gas: BLOCK_GAS}(1, alice);
        assertEq(nft.ownerOf(1), alice, "the seat leaves");
    }

    /// No tricks: 1,500 ordinary 1-wei tokens (the PoC's "plain" case) do not block a withdrawal either.
    function test_s1_manyPlainTokensDoNotBlockWithdraw() public {
        vm.prank(alice);
        SeatAccount acct = SeatAccount(seatJoin.deposit(1));
        PlainToken last;
        for (uint256 i; i < 1_500; ++i) {
            last = new PlainToken();
            last.mint(address(acct), 1);
            acct.sync(address(last));
        }
        vm.prank(alice);
        seatJoin.withdraw{gas: BLOCK_GAS}(1, alice);
        assertEq(nft.ownerOf(1), alice);
    }
}
