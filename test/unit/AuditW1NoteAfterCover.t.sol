// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury, ICoverable} from "src/Treasury.sol";
import {FeeNotes, ITreasuryNotes} from "src/peg/FeeNotes.sol";

contract W1NcPToken is ERC20 {
    uint8 private immutable dec;
    constructor(string memory n, uint8 d) ERC20(n, n) { dec = d; }
    function decimals() public view override returns (uint8) { return dec; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burn(address from, uint256 a) external { _burn(from, a); }
}

contract W1NcPParams {
    function edgeIlk(bytes32) external pure returns (bool) { return false; }
    function edgeBackstop() external pure returns (address) { return address(0); }
}

/// The Ledger's surface the Treasury and a sleeve use: bad debt per type, cover (burns the caller's imdUSD), revenue.
contract W1NcPLedger {
    W1NcPToken public usd;
    W1NcPParams public p = new W1NcPParams();
    mapping(bytes32 => uint128) public bad;
    uint256 public totalBadDebt;
    constructor(W1NcPToken u) { usd = u; }
    function params() external view returns (address) { return address(p); }
    function setBad(bytes32 ilk, uint128 b) external { totalBadDebt = totalBadDebt + b - bad[ilk]; bad[ilk] = b; }
    function ilkState(bytes32 ilk) external view returns (uint128, uint128, uint256, uint64, uint128) {
        return (0, 0, 0, 0, bad[ilk]);
    }
    function cover(bytes32 ilk, uint256 amount) external {
        if (amount > bad[ilk]) amount = bad[ilk];
        bad[ilk] -= uint128(amount);
        totalBadDebt -= amount;
        usd.burn(msg.sender, amount);
    }
    function retire(uint256) external {}
    function payInterest(Treasury t, bytes32 ilk, uint256 amount) external {
        usd.mint(address(t), amount);
        t.noteRevenue(ilk, amount);
    }
}

contract W1NcProofNotesBeforeBadDebt is Test {
    bytes32 constant ILK = "EDGE-A";

    /// Q3/Q4: a matured note is paid out of the Treasury's imdUSD while bad debt is booked and uncovered, so the
    /// balance that should have covered the hole leaves first (retireReserve refuses exactly this case).
    function test_noteWaitsForBookedBadDebtCover() public {
        W1NcPToken usd = new W1NcPToken("imdUSD", 18);
        W1NcPToken usdc = new W1NcPToken("USDC", 6);
        W1NcPLedger ledger = new W1NcPLedger(usd);
        Treasury t = new Treasury(address(0xBEEF), IERC20(address(usd)), address(this));
        t.wire(ICoverable(address(ledger)));
        FeeNotes notes = new FeeNotes(IERC20(address(usd)), IERC20(address(usdc)), ITreasuryNotes(address(t)), address(this));
        t.wireNotes(address(notes));

        ledger.payInterest(t, ILK, 600e18); // revenue 600 -> note capacity 1,200
        uint256 id = notes.open(30 days, 500, 1_000e18);
        address buyer = address(0xB0B);
        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(notes), type(uint256).max);
        notes.buy(id, 500e18);
        vm.stopPrank();

        // A liquidation books 1,000 of bad debt; its in-transaction cover found the Treasury empty of imdUSD beyond the
        // 600 (here: nobody has called coverBadDebt yet). The note matures.
        ledger.setBad(ILK, 1_000e18);
        vm.warp(1 + 37 days + 1);

        // Expected: the 600 imdUSD the Treasury holds goes to the booked hole first (as retireReserve's guard and the
        // NatSpec "bad-debt cover keeps first call on the balance" say). Actual: the note holder takes 500 of it.
        vm.prank(buyer);
        (bool ok,) = address(notes).call(abi.encodeCall(FeeNotes.redeem, (id, 500e18)));
        if (ok) {
            t.coverBadDebt(ILK);
            emit log_named_uint("bad debt left after cover (expected 400e18)", ledger.totalBadDebt());
        }
        assertFalse(ok, "note paid while bad debt is booked and uncovered");
    }
}