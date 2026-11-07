// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Governed} from "./Governed.sol";

interface ICoverable {
    function totalBadDebt() external view returns (uint256);
    function cover(bytes32 ilk, uint256 amount) external;
    function retire(uint256 amount) external;
    function ilkState(bytes32 ilk)
        external
        view
        returns (uint128 debt, uint128 collateral, uint256 weighted, uint64 lastAccrual, uint128 badDebt);
}

/// @notice The Ledger's Parameters, read for the edge waterfall.
interface IEdgeParams {
    function edgeIlk(bytes32 ilk) external view returns (bool);
    function edgeBackstop() external view returns (address);
}

interface ILedgerParams {
    function params() external view returns (address);
}

/// @notice The edge sleeve's first-loss cover.
interface IEdgeCover {
    function coverBadDebt(bytes32 ilk) external returns (uint256);
}

/// @notice Receives interest (imdUSD), liquidation cuts and harvested yield shares. Scope:
/// hold, cover bad debt, and pay out only through the 48h timelock.
/// @dev `coverBadDebt` and `retireReserve` are permissionless because both only burn the Treasury's own
/// imdUSD against liabilities, which can never make the system less solvent. Investing reserves (the
/// burn path's swap, peg keeper) is a Safe act through the timelock payout.
///
/// REVENUE METER (fee notes). The Ledger reports every imdUSD it mints here as interest
/// (`noteRevenue`), into a ring of METER_DAYS daily buckets; `trailingRevenue()` is their sum over the last
/// METER_DAYS days, the figure the fee-note cap (2x) is measured against. Only imdUSD actually received is
/// counted: harvested yield fees arrive as collateral shares, not imdUSD, and the imdUSD the peg reserve buys
/// is an asset swap, not income, so neither is in the meter (conservative: the cap bounds an imdUSD liability
/// by imdUSD income).
///
/// FEE NOTES. `payNote` pays a matured note from this balance to its holder, only when called by the notes
/// contract (fixed once by the wirer). It never mints: a note is repaid from interest already minted here, so
/// the supply equation is untouched. A short balance reverts the redemption (fail closed) until the Safe funds
/// it; nothing here is earmarked for notes, so bad-debt cover keeps first call on the balance.
contract Treasury is Governed {
    using SafeERC20 for IERC20;

    uint256 public constant METER_DAYS = 90;
    /// @dev Backstop.BidOpen()
    bytes4 private constant BID_OPEN = bytes4(keccak256("BidOpen()"));
    bytes4 private constant UNKNOWN_ILK = bytes4(keccak256("UnknownIlk()")); // Backstop: the type is not covered

    IERC20 public immutable token;
    address public immutable wirer;
    ICoverable public ledger;
    /// @notice The fee-notes contract, the only caller of `payNote`. Set once by the wirer.
    address public notes;

    uint256[90] private _revenue; // imdUSD received per day slot (day % METER_DAYS)
    /// @notice The day (timestamp / 1 day) of the newest bucket written.
    uint64 public meterDay;
    /// @notice Sum of every bucket as of `meterDay`.
    uint256 public meterTotal;

    /// @notice A type's SURPLUS: the interest it has paid here, less the bad debt of its own that it has covered.
    /// `coverBadDebt` draws on it first and on the rest of the Treasury (other types' interest, reserves) only after, so the
    /// books show which types' earnings absorbed a loss.
    mapping(bytes32 ilk => uint256) public surplusOf;

    error Unauthorized();
    error EdgeBidOpen();
    error EdgeCoverFailed();
    error BadDebtOutstanding();
    error AlreadyWired();

    event Paid(address indexed asset, address indexed to, uint256 amount);
    event RevenueNoted(uint256 amount, uint256 day);
    event NotePaid(address indexed to, uint256 amount);
    event BadDebtCovered(bytes32 indexed ilk, uint256 fromSurplus, uint256 fromTreasury);

    constructor(address governor_, IERC20 token_, address wirer_) Governed(governor_) {
        token = token_;
        wirer = wirer_;
        meterDay = uint64(block.timestamp / 1 days);
    }

    function wire(ICoverable ledger_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (address(ledger) != address(0)) revert AlreadyWired();
        ledger = ledger_;
    }

    /// @notice Name the fee-notes contract. Once; the wirer's only other power here.
    function wireNotes(address notes_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (notes != address(0)) revert AlreadyWired();
        if (notes_.code.length == 0) revert Unauthorized();
        notes = notes_;
    }

    /// @notice Burn Treasury imdUSD against a type's bad debt, as much as both allow: the type's own surplus first, then the
    /// rest of the Treasury.
    function coverBadDebt(bytes32 ilk) external {
        // An edge type's bad debt is the edge sleeve's first, then the Treasury's. Permissionless both, so
        // ordering lives here: nobody can make the Treasury pay ahead of the sleeve. A sleeve that refuses (the type is
        // no longer covered: UnknownIlk; or it has nothing above its floor: it returns 0) leaves the rest to us. Any other
        // revert is not a refusal and reverts here: a standing bid open (a collateral token re-entering mid-liquidation), the
        // sleeve's reentrancy lock (a sale's route calling back), or a call starved of gas.
        IEdgeParams p = IEdgeParams(ILedgerParams(address(ledger)).params());
        if (p.edgeIlk(ilk)) {
            address edge = p.edgeBackstop();
            try IEdgeCover(edge).coverBadDebt(ilk) {}
            catch (bytes memory err) {
                bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
                if (sel == BID_OPEN) revert EdgeBidOpen();
                if (sel != UNKNOWN_ILK) revert EdgeCoverFailed();
            }
        }
        (,,,, uint128 bad) = ledger.ilkState(ilk);
        uint256 amount = bad < token.balanceOf(address(this)) ? bad : token.balanceOf(address(this));
        if (amount == 0) return;
        uint256 own = surplusOf[ilk];
        uint256 fromSurplus = amount < own ? amount : own;
        surplusOf[ilk] = own - fromSurplus;
        ledger.cover(ilk, amount);
        emit BadDebtCovered(ilk, fromSurplus, amount - fromSurplus);
    }

    /// @notice Burn `amount` of Treasury imdUSD against reserve-backed supply. Never while bad debt is booked: the same balance is
    /// what covers it, and anyone may call this.
    function retireReserve(uint256 amount) external {
        if (ledger.totalBadDebt() != 0) revert BadDebtOutstanding();
        uint256 bal = token.balanceOf(address(this));
        ledger.retire(amount < bal ? amount : bal);
    }

    // ---------------------------------------------------------------- revenue meter

    /// @notice The Ledger reports `amount` of imdUSD it has just minted here as interest paid by type `ilk`.
    function noteRevenue(bytes32 ilk, uint256 amount) external {
        if (msg.sender != address(ledger)) revert Unauthorized();
        surplusOf[ilk] += amount;
        uint256 day = block.timestamp / 1 days;
        _roll(day);
        _revenue[day % METER_DAYS] += amount;
        meterTotal += amount;
        emit RevenueNoted(amount, day);
    }

    /// @notice imdUSD received as interest over the last METER_DAYS days (today included).
    function trailingRevenue() public view returns (uint256 total) {
        total = meterTotal;
        uint256 day = block.timestamp / 1 days;
        uint256 last = meterDay;
        uint256 n = day - last;
        if (n > METER_DAYS) n = METER_DAYS;
        for (uint256 i = 1; i <= n; ++i) total -= _revenue[(last + i) % METER_DAYS];
    }

    /// @dev Clear the buckets of every day that has left the window since the last write.
    function _roll(uint256 day) private {
        uint256 last = meterDay;
        if (day == last) return;
        uint256 n = day - last;
        if (n > METER_DAYS) n = METER_DAYS;
        uint256 total = meterTotal;
        for (uint256 i = 1; i <= n; ++i) {
            uint256 idx = (last + i) % METER_DAYS;
            total -= _revenue[idx];
            _revenue[idx] = 0;
        }
        meterTotal = total;
        meterDay = uint64(day);
    }

    // ---------------------------------------------------------------- fee notes

    /// @notice Pay a matured note: `amount` imdUSD from this balance to `to`. The notes contract only.
    function payNote(address to, uint256 amount) external {
        if (msg.sender != notes) revert Unauthorized();
        token.safeTransfer(to, amount);
        emit NotePaid(to, amount);
    }

    function _validate(bytes memory payload) internal pure override {
        abi.decode(payload, (address, address, uint256));
    }

    /// @dev payload = (asset, to, amount)
    function _apply(bytes memory payload) internal override {
        (address asset, address to, uint256 amount) = abi.decode(payload, (address, address, uint256));
        IERC20(asset).safeTransfer(to, amount);
        emit Paid(asset, to, amount);
    }
}
