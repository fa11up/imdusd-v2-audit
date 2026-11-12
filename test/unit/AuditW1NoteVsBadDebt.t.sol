// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury, ICoverable} from "src/Treasury.sol";
import {FeeNotes, ITreasuryNotes} from "src/peg/FeeNotes.sol";

contract W1NbNUSD is ERC20 {
    constructor() ERC20("imdUSD", "imdUSD") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burn(address from, uint256 a) external { _burn(from, a); }
}

contract W1NbNUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev The Ledger as the Treasury sees it: books bad debt, burns the coverer's imdUSD, reports interest.
contract W1NbNLedger is ICoverable {
    W1NbNUSD public usd;
    Treasury public treasury;
    uint128 public bad;
    constructor(W1NbNUSD u) { usd = u; }
    function setTreasury(Treasury t) external { treasury = t; }
    function setBad(uint128 b) external { bad = b; }
    function totalBadDebt() external view returns (uint256) { return bad; }
    function cover(bytes32, uint256 amount) external {
        if (amount > bad) amount = bad;
        bad -= uint128(amount);
        usd.burn(msg.sender, amount);
    }
    function retire(uint256) external {}
    function ilkState(bytes32) external view returns (uint128, uint128, uint256, uint64, uint128) { return (0, 0, 0, 0, bad); }
    // Treasury.coverBadDebt reads ledger.params().edgeIlk(ilk): this contract answers both, with no edge types.
    function params() external view returns (address) { return address(this); }
    function edgeIlk(bytes32) external pure returns (bool) { return false; }
    function edgeBackstop() external pure returns (address) { return address(0); }
    /// @dev Interest minted to the Treasury and reported to its meter, as LedgerBase._mintInterest does.
    function pay(bytes32 ilk, uint256 amount) external {
        usd.mint(address(treasury), amount);
        treasury.noteRevenue(ilk, amount);
    }
}

/// Treasury.sol says: "nothing here is earmarked for notes, so bad-debt cover keeps first call on the balance", and
/// `retireReserve` refuses while `totalBadDebt != 0` for that reason. A matured note redeems the same balance with no
/// such check: the note holder is paid first and the booked bad debt stays uncovered.
contract W1NbProofNoteRedeemAheadOfBadDebt is Test {
    W1NbNUSD usd;
    W1NbNUSDC usdc;
    W1NbNLedger ledger;
    Treasury treasury;
    FeeNotes notes;
    address governor = makeAddr("governor");
    address buyer = makeAddr("buyer");
    bytes32 constant ILK = "ETH";

    function setUp() public {
        vm.warp(1_800_000_000);
        usd = new W1NbNUSD();
        usdc = new W1NbNUSDC();
        ledger = new W1NbNLedger(usd);
        treasury = new Treasury(governor, IERC20(address(usd)), address(this));
        ledger.setTreasury(treasury);
        treasury.wire(ICoverable(address(ledger)));
        notes = new FeeNotes(IERC20(address(usd)), IERC20(address(usdc)), ITreasuryNotes(address(treasury)), address(this));
        treasury.wireNotes(address(notes));
        // 1,000 imdUSD of interest in the meter: capacity 2,000 of face.
        ledger.pay(ILK, 1_000e18);
        uint256 id = notes.open(30 days, 500, 1_000e18);
        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(notes), type(uint256).max);
        notes.buy(id, 1_000e18);
        vm.stopPrank();
        skip(7 days + 30 days); // matured
    }

    function test_matureNoteCannotTakeTheBalanceThatCoversBookedBadDebt() public {
        // A liquidation booked 1,000 of bad debt; the cover in its own transaction failed (e.g. EdgeBidOpen at the
        // time) and the Treasury's balance now equals the hole.
        ledger.setBad(1_000e18);
        assertEq(usd.balanceOf(address(treasury)), 1_000e18);
        assertEq(ledger.totalBadDebt(), 1_000e18);
        // retireReserve refuses while bad debt is booked...
        vm.expectRevert(Treasury.BadDebtOutstanding.selector);
        treasury.retireReserve(1);
        // ...a note redemption should hold for the same reason, or at least leave what the bad debt needs.
        vm.prank(buyer);
        try notes.redeem(1, 1_000e18) {} catch {}
        treasury.coverBadDebt(ILK);
        assertEq(ledger.totalBadDebt(), 0, "bad-debt cover had first call on the Treasury balance");
    }
}