// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury, ICoverable} from "src/Treasury.sol";
import {FeeNotes, ITreasuryNotes} from "src/peg/FeeNotes.sol";

contract W1RkTok is ERC20 {
    uint8 private immutable d;
    constructor(string memory n, uint8 d_) ERC20(n, n) { d = d_; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burnFrom_(address from, uint256 a) external { _burn(from, a); }
}

/// Minimal Ledger: the parts Treasury calls (retire burns the caller's imdUSD against reserveBacked, like Ledger.retire).
contract W1RkMiniLedger {
    W1RkTok public token;
    Treasury public treasury;
    uint256 public reserveBacked;
    uint256 public totalBadDebt;
    constructor(W1RkTok t) { token = t; }
    function setTreasury(Treasury t) external { treasury = t; }
    function setReserveBacked(uint256 r) external { reserveBacked = r; }
    function retire(uint256 amount) external {
        if (amount > reserveBacked) amount = reserveBacked;
        reserveBacked -= amount;
        token.burnFrom_(msg.sender, amount);
    }
    function cover(bytes32, uint256) external {}
    function ilkState(bytes32) external pure returns (uint128, uint128, uint256, uint64, uint128) {}
    function mintInterest(bytes32 ilk, uint256 amount) external {
        token.mint(address(treasury), amount);
        treasury.noteRevenue(ilk, amount);
    }
}

contract W1RkProofRetireBlocksNotes is Test {
    W1RkTok imd;
    W1RkTok usdc;
    W1RkMiniLedger ledger;
    Treasury treasury;
    FeeNotes notes;
    address buyer = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new W1RkTok("imdUSD", 18);
        usdc = new W1RkTok("USDC", 6);
        ledger = new W1RkMiniLedger(imd);
        treasury = new Treasury(address(0x5AFE), IERC20(address(imd)), address(this));
        ledger.setTreasury(treasury);
        treasury.wire(ICoverable(address(ledger)));
        notes = new FeeNotes(IERC20(address(imd)), IERC20(address(usdc)), ITreasuryNotes(address(treasury)), address(this));
        treasury.wireNotes(address(notes));
    }

    function test_retireReserveLeavesNoteBacking() public {
        // Yield harvests booked 1,000 of reserve-backed supply; 1,000 of interest reached the Treasury.
        ledger.setReserveBacked(1_000e18);
        ledger.mintInterest("ETH", 1_000e18);
        assertEq(notes.capacity(), 2_000e18);

        // A series opens (Parameters) and a buyer pays USDC for 900 face.
        uint256 id = notes.open(30 days, 500, 1_000e18);
        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(notes), type(uint256).max);
        notes.buy(id, 900e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 37 days + 1);
        assertEq(imd.balanceOf(address(treasury)), 1_000e18, "Treasury holds the face");

        // No bad debt is booked, so anyone may burn the Treasury's whole balance against reserveBacked.
        vm.prank(attacker);
        treasury.retireReserve(type(uint256).max);

        // Expected: the matured note is still payable from the interest that backed it.
        // Actual: the Treasury balance is 0 and redeem reverts TreasuryShort(0).
        vm.prank(buyer);
        notes.redeem(id, 900e18);
        assertEq(imd.balanceOf(buyer), 900e18);
    }
}