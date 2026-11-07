// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

interface ITreasuryNotes {
    function trailingRevenue() external view returns (uint256);
    function payNote(address to, uint256 amount) external;
}

/// @title FeeNotes (imdUSD v2)
/// @notice Protocol "bonds": a non-transferable ERC-1155 claim, one id per series, on X imdUSD at the series'
/// maturity, sold now for USDC at X x (1 - d). The USDC goes straight to the Treasury (its asset; putting it
/// into peg liquidity is a Safe act through PegLPVault, not code here). At maturity the Treasury pays the
/// imdUSD from its balance: interest already minted to it, so a note never mints and the supply equation is
/// untouched. A short Treasury fails the redemption closed (it waits; the Safe unwinds LP).
///
/// SERIES are opened only by Parameters, i.e. only through its 48h timelock (OPEN_NOTE_SERIES: tenor, discount,
/// size cap). Each series sells for SALE_WINDOW from its opening and matures SALE_WINDOW + tenor after it, so
/// one id carries one maturity and every buyer waits at least the tenor: a last-minute buy cannot shorten it.
///
/// CAP: total outstanding face <= COVERAGE x the Treasury's trailing 90-day imdUSD revenue, checked at
/// every purchase against the Treasury's meter. Revenue rolling off later does not call notes; it only stops
/// new sales until the meter recovers.
///
/// NO OWNER, NO PARAMETERS of its own. Token, quote, Treasury and Parameters are fixed at construction.
contract FeeNotes is ERC1155, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SALE_WINDOW = 7 days;
    /// @notice Outstanding face may be at most this many times the trailing 90-day revenue.
    uint256 public constant COVERAGE = 2;
    uint256 public constant BPS = 10_000;

    struct Series {
        uint64 saleEnd;
        uint64 maturity;
        uint32 discountBps;
        uint128 cap; // most face this series may sell
        uint128 sold;
    }

    IERC20 public immutable token; // imdUSD
    IERC20 public immutable quote; // USDC
    ITreasuryNotes public immutable treasury;
    address public immutable params;
    uint256 private immutable quoteScale; // 10^(token decimals - quote decimals)

    mapping(uint256 id => Series) internal _series;
    /// @notice Number of series opened; ids run 1..count.
    uint256 public count;
    /// @notice Face value sold and not yet redeemed, over every series.
    uint256 public outstanding;

    error ZeroAddress();
    error OddDecimals();
    error Unauthorized();
    error UnknownSeries();
    error ZeroAmount();
    error SaleClosed(uint64 saleEnd);
    error SeriesFull(uint256 left);
    error CapExceeded(uint256 capacity);
    error NotMatured(uint64 maturity);
    error TreasuryShort(uint256 balance);
    error NonTransferable();

    event SeriesOpened(uint256 indexed id, uint64 tenor, uint32 discountBps, uint128 cap, uint64 saleEnd, uint64 maturity);
    event Bought(uint256 indexed id, address indexed buyer, uint256 face, uint256 paid);
    event Redeemed(uint256 indexed id, address indexed holder, uint256 face);

    constructor(IERC20 token_, IERC20 quote_, ITreasuryNotes treasury_, address params_) ERC1155("") {
        if (
            address(token_) == address(0) || address(quote_) == address(0) || address(treasury_) == address(0)
                || params_ == address(0)
        ) revert ZeroAddress();
        (uint8 td, uint8 qd) = (IDecimals(address(token_)).decimals(), IDecimals(address(quote_)).decimals());
        if (td < qd) revert OddDecimals();
        quoteScale = 10 ** (td - qd);
        (token, quote, treasury, params) = (token_, quote_, treasury_, params_);
    }

    // ---------------------------------------------------------------- views

    function series(uint256 id) external view returns (Series memory) {
        return _series[id];
    }

    /// @notice USDC due now for `face` imdUSD of series `id`: face x (1 - d), rounded up to the quote's unit.
    function priceOf(uint256 id, uint256 face) public view returns (uint256) {
        Series storage s = _series[id];
        if (s.maturity == 0) revert UnknownSeries();
        return Math.mulDiv(face, BPS - s.discountBps, BPS * quoteScale, Math.Rounding.Ceil);
    }

    /// @notice Face that may still be sold under the revenue cap, over every series.
    function capacity() public view returns (uint256) {
        uint256 limit = COVERAGE * treasury.trailingRevenue();
        return limit > outstanding ? limit - outstanding : 0;
    }

    // ---------------------------------------------------------------- governance (Parameters' timelock)

    /// @notice Open a series. Parameters only, i.e. after its 48h delay. Bounds are checked there.
    function open(uint64 tenor, uint32 discountBps, uint128 cap) external returns (uint256 id) {
        if (msg.sender != params) revert Unauthorized();
        id = ++count;
        uint64 saleEnd = uint64(block.timestamp + SALE_WINDOW);
        uint64 maturity = saleEnd + tenor;
        _series[id] = Series(saleEnd, maturity, discountBps, cap, 0);
        emit SeriesOpened(id, tenor, discountBps, cap, saleEnd, maturity);
    }

    // ---------------------------------------------------------------- buy / redeem

    /// @notice Buy `face` imdUSD of series `id` at maturity, paying `priceOf(id, face)` USDC now (approve first).
    function buy(uint256 id, uint256 face) external nonReentrant returns (uint256 paid) {
        Series storage s = _series[id];
        if (s.maturity == 0) revert UnknownSeries();
        if (face == 0) revert ZeroAmount();
        if (block.timestamp >= s.saleEnd) revert SaleClosed(s.saleEnd);
        uint256 left = s.cap - s.sold;
        if (face > left) revert SeriesFull(left);
        uint256 room = capacity();
        if (face > room) revert CapExceeded(room);
        paid = priceOf(id, face);
        s.sold += uint128(face);
        outstanding += face;
        quote.safeTransferFrom(msg.sender, address(treasury), paid);
        _mint(msg.sender, id, face, "");
        emit Bought(id, msg.sender, face, paid);
    }

    /// @notice Redeem `face` of your matured series `id` for `face` imdUSD from the Treasury. Reverts while the
    /// Treasury holds less than `face` (fail closed): the claim waits, nothing is lost.
    function redeem(uint256 id, uint256 face) external nonReentrant {
        Series storage s = _series[id];
        if (s.maturity == 0) revert UnknownSeries();
        if (face == 0) revert ZeroAmount();
        if (block.timestamp < s.maturity) revert NotMatured(s.maturity);
        uint256 bal = token.balanceOf(address(treasury));
        if (bal < face) revert TreasuryShort(bal);
        _burn(msg.sender, id, face);
        outstanding -= face;
        treasury.payNote(msg.sender, face);
        emit Redeemed(id, msg.sender, face);
    }

    // ---------------------------------------------------------------- non-transferable

    /// @dev Mint and burn only: a note stays with its buyer until maturity.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, ids, values);
    }

    function setApprovalForAll(address, bool) public pure override {
        revert NonTransferable();
    }
}
