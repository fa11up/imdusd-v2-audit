// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Join} from "../Join.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {Ledger} from "../Ledger.sol";
import {Liquidator} from "../Liquidator.sol";
import {Parameters} from "../Parameters.sol";
import {Pricer} from "../Pricer.sol";
import {IERC4626Min} from "../interfaces/IERC4626Min.sol";
import {IAuctionJoin} from "../interfaces/IPositions.sol";

/// @notice Custody (a `Join` holding the type's `StockVault` shares) and the USDG Dutch auction that sells a liquidated stock
/// position: SeatJoin's sale generalised from one NFT priced in imdUSD to fungible units paid in
/// the chain's settlement stable.
///
/// SALE. `Liquidator.bite` opens an auction for the whole position. Its price is LIVE: the type's quote (`low`, the price
/// borrowing and health use) times a factor falling linearly from 1 to `floor` over `auctionTime`, so a stale opening price
/// is never sold at after a gap. The auction lapses at 2 x `auctionTime` (the position, if still unhealthy, is marked and
/// bitten again at a fresh price). `take` works only while the type is priced: never outside the NYSE session, never while
/// the token or its oracle is paused (MarketHoursFeed), so a market-closed liquidation waits for the open.
///
/// SETTLEMENT (one transaction). The Liquidator settles the position at the taker's price with `reserve = true`: the Ledger
/// seizes every unit, books the debt the sale covers (`repaid`) as reserve-backed supply instead of burning imdUSD, makes any
/// shortfall the type's bad debt, and pays the penalty's cuts IN UNITS (vault shares: never blocklisted) to the Treasury and
/// the marker. The taker pays USDG for the units that are not penalty (`seized - bonus`, the same rounding as the Ledger) and
/// receives the stock they redeem for; the units of penalty not cut go to the Treasury; of the USDG, `repaid` (at par,
/// rounded up) goes to the Treasury, which now backs that imdUSD, and the rest is the borrower's, claimable here (`owed`), so
/// a borrower USDG cannot pay (frozen by Paxos) cannot block the sale.
/// A taker the issuer blocklists, or a paused token, makes the stock transfer revert: the whole take reverts and the auction
/// runs on for the next taker.
/// POSITIONS: auctions are keyed by position id; the leftover USDG is owed to the position's owner AT THE
/// SALE (claimed by address with `claim`), so a position sold after a transfer pays its new owner.
contract StockJoin is Join, TransientReentrancyGuard, IAuctionJoin {
    using SafeERC20 for IERC20;

    struct Auction {
        uint64 startAt;
        address marker;
    }

    bytes32 public immutable ilk;
    IERC20 public immutable usdg;
    /// @notice USDG raw units per 1e18 of a dollar: 10^(18 - decimals).
    uint256 public immutable usdScale;
    /// @notice Seconds for the price factor to fall from 1 to `floor`; the auction lapses at twice this.
    uint256 public immutable auctionTime;
    /// @notice The lowest price factor, 1e18 = 100% of the type's quote.
    uint256 public immutable floor;

    mapping(uint256 id => Auction) public auctions;
    /// @notice USDG a sale owes a borrower (the excess over debt and penalty), claimed with `claim`.
    mapping(address owner => uint256) public owed;

    error BadAuction();
    error AuctionLive();
    error NoAuction();
    error NotPriced();
    error PriceAboveMax();
    error StillUnhealthy();

    event Opened(uint256 indexed id, address marker);
    event Cancelled(uint256 indexed id);
    event Taken(uint256 indexed id, address indexed taker, uint256 units, uint256 price, uint256 paid, uint256 bad);
    event Claimed(address indexed owner, address to, uint256 amount);

    constructor(bytes32 ilk_, address vault_, IERC20 usdg_, address wirer_, uint256 auctionTime_, uint256 floor_)
        Join(vault_, wirer_)
    {
        uint8 dec = IERC20Metadata(address(usdg_)).decimals();
        if (auctionTime_ == 0 || auctionTime_ > 1 days || floor_ < 0.5e18 || floor_ > 1e18 || dec > 18) revert BadAuction();
        ilk = ilk_;
        usdg = usdg_;
        usdScale = 10 ** (18 - dec);
        auctionTime = auctionTime_;
        floor = floor_;
    }

    // ---------------------------------------------------------------- auction

    /// @notice Liquidator only: put a marked, unhealthy position on sale. A lapsed auction may be replaced.
    function open(uint256 id, address marker) external {
        if (msg.sender != Ledger(ledger).liquidator()) revert Unauthorized();
        Auction memory a = auctions[id];
        if (a.startAt != 0 && block.timestamp <= a.startAt + 2 * auctionTime) revert AuctionLive();
        auctions[id] = Auction({startAt: uint64(block.timestamp), marker: marker});
        emit Opened(id, marker);
    }

    /// @notice USD per 1e18 units (vault shares) now; 0 while the type is unpriced or the auction is not live.
    function price(uint256 id) public view returns (uint256) {
        uint256 start = auctions[id].startAt;
        if (start == 0 || block.timestamp > start + 2 * auctionTime) return 0;
        Pricer.Quote memory q = Ledger(ledger).pricer().quote(ilk);
        if (!q.priced) return 0;
        uint256 elapsed = Math.min(block.timestamp - start, auctionTime);
        return Math.mulDiv(q.low, 1e18 - Math.mulDiv(1e18 - floor, elapsed, auctionTime), 1e18);
    }

    /// @notice Buy the position at the current price (at most `maxPrice` per 1e18 units). Approve this contract for the USDG
    /// first; the stock goes to the caller. Returns the units bought and the USDG paid.
    function take(uint256 id, uint256 maxPrice) external nonReentrant returns (uint256 units, uint256 paid) {
        Auction memory a = auctions[id];
        uint256 p = price(id);
        if (p == 0) revert NotPriced();
        if (p > maxPrice) revert PriceAboveMax();
        delete auctions[id];

        Ledger l = Ledger(ledger);
        IERC20 shares = IERC20(token);
        address treasury = l.treasury();
        uint256 before = shares.balanceOf(address(this));
        // The bonus uses the position's BOUND chop, the one the Ledger paid its cuts with.
        (, uint256 chop) = l.params().liqRisk(ilk, l.position(id).version);
        (uint256 repaid, uint256 seized, uint256 bad) = Liquidator(l.liquidator()).settle(id, p, a.marker, true);
        uint256 cuts = before - shares.balanceOf(address(this)); // the Ledger's cut + chip, sent in units
        uint256 bonus = Math.mulDiv(repaid, chop, p);
        units = seized - bonus;
        if (bonus > cuts) shares.safeTransfer(treasury, bonus - cuts);

        paid = Math.ceilDiv(Math.mulDiv(units, p, 1e18), usdScale);
        usdg.safeTransferFrom(msg.sender, address(this), paid);
        uint256 toTreasury = Math.min(paid, Math.ceilDiv(repaid, usdScale));
        if (toTreasury != 0) usdg.safeTransfer(treasury, toTreasury);
        owed[l.nft().ownerOf(id)] += paid - toTreasury;
        if (units != 0) IERC4626Min(token).redeem(units, msg.sender, address(this));
        emit Taken(id, msg.sender, units, p, paid, bad);
    }

    /// @notice An auction whose position is healthy again, or has no debt, is void.
    function cancel(uint256 id) external {
        if (auctions[id].startAt == 0) revert NoAuction();
        Ledger l = Ledger(ledger);
        if (l.debtOf(id) != 0) {
            (bool ok, bool priced) = l.healthy(id);
            if (!priced || !ok) revert StillUnhealthy();
        }
        delete auctions[id];
        emit Cancelled(id);
    }

    /// @notice Collect the USDG your liquidated position's sale left over.
    function claim(address to) external nonReentrant {
        uint256 amount = owed[msg.sender];
        owed[msg.sender] = 0;
        usdg.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }
}
