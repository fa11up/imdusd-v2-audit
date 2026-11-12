// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {Ledger} from "../Ledger.sol";
import {Parameters} from "../Parameters.sol";
import {Liquidator} from "../Liquidator.sol";
import {IFeed} from "../interfaces/IFeed.sol";
import {SeatFeed} from "../feeds/SeatFeed.sol";
import {SeatAccount, IImdAgentAdapter} from "./SeatAccount.sol";
import {IHolderJoin, IAuctionJoin} from "../interfaces/IPositions.sol";

/// @dev The median leaf's relay time (SwarmFeed.acceptedAt): when the chain first held the live attestation.
interface IRelayedAt {
    function acceptedAt() external view returns (uint64);
}

interface IDistributorFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @notice Custody and sale of identity.md seats as collateral. The Ledger's change for this type is
/// one branch: it seizes a whole position. Everything per-tokenId lives here.
///
/// UNITS. The Ledger counts collateral in fungible units, so this contract is also the type's "token":
/// `deposit(tokenId)` moves the NFT into that seat's `SeatAccount` and mints 1e18 units to the depositor,
/// who pledges them with `Ledger.adjust` as with any token. Units move only (a) from a holder into the
/// Ledger's pool and back (the Ledger's `transferFrom` / `exit`), and (b) out of the Treasury's wallet
/// (a timelocked payout of seats it kept). A holder's seats are fungible among themselves: `withdraw`
/// burns 1e18 units for any one of their seats, and a sale takes the position's n seats from their list.
/// Invariant: every holder's units in wallet + in the Ledger == 1e18 x the seats held for them.
///
/// SALE. `Liquidator.bite` opens a Dutch auction at the fall-capped 7-day median
/// (`SeatFeed.medianUsd`), decaying to AUCTION_FLOOR x that start over AUCTION_TIME. `take` pays n x price in imdUSD; the Ledger (through
/// `Liquidator.settle`) burns the debt from it and seizes every unit; the penalty's chip goes to the
/// marker and the rest of the penalty to the Treasury (the taker's reward is the discount, so the
/// liquidator share is not paid twice); anything above debt + penalty goes back to the borrower; the
/// taker receives the NFTs and every pairing dies. `takeFloor`: at the floor, with the raw spot no lower
/// and a Treasury budget on hand (sent here by the Treasury's own timelock), the Treasury buys and KEEPS
/// the seats in their accounts, as holder, rewards included.
///
/// REWARDS. A SeatAccount reports token arrivals; the join CREDITS each arrival, at the moment it
/// is reported, to the seat's holder then (`owed[tokenId][token][holder]`; a seat between holders credits
/// the last one), and `collect` pays a credit to its owner, less `yieldFee` in kind to the Treasury
/// (the pass-through case; the swap-and-credit cases are the harvest module's, not built here).
/// Custody never touches a reward token: `withdraw`, `take` and `takeFloor` move the seat and nothing
/// else, so no token anyone can report can block a seat's exit or sale, and a
/// token that will not transfer only blocks its own credit.
///
/// AUCTION CLOCK. An auction runs on PRICED time: the Dutch decay and the auction's life
/// (`AUCTION_LIFE`) advance only while the median attestation is within its life (`SeatFeed.median`'s
/// `maxAge`), reconstructed from the attestation windows between ticks (anyone may `tick`; `take`,
/// `reopen` and `open` read the same clock), so a missed daily refresh pauses the sale instead of
/// running it to the floor unseen. After `AUCTION_LIFE` of priced time the auction is void: `take` and
/// `takeFloor` refuse it, and the next `bite` (or `reopen` on a still unhealthy position) starts again
/// from the fresh median, so a position that healed and dips again weeks later is never sold at a
/// month-old floor. A repayment or deposit that heals the position ends its auction there (the Ledger calls `cancel`);
/// one healed by the price alone stays open until someone calls `cancel` (permissionless; the keeper does).
///
/// POSITIONS. Positions are Ledger ids; a holder may have several in this type. Units stay fungible
/// among a holder's seats, so a sale takes the position's n seats from its OWNER's list, and when a position changes
/// hands the Ledger calls `onPositionTransfer`, which moves n seats (and their custody epoch: pairings die) to the new
/// owner, within the new owner's `perBorrower`. Auctions are keyed by position id; the surplus goes to the owner at sale.
contract SeatJoin is TransientReentrancyGuard, IHolderJoin, IAuctionJoin {
    using SafeERC20 for IERC20;

    struct Auction {
        uint176 startPrice; // fall-capped median (SeatFeed.medianUsd), USD per seat
        uint40 startAt; // wall clock of the opening
        uint40 lastTick; // priced time is reconstructed from here
        address marker;
        uint40 attestedAt; // `updatedAt` of the median attestation live at `lastTick`
        uint40 ran; // priced seconds counted up to `lastTick`
    }

    uint256 public constant UNIT = 1e18;
    uint256 public constant AUCTION_TIME = 6 hours;
    uint256 public constant AUCTION_FLOOR = 0.7e18;
    /// @notice Priced seconds an auction stays takeable; then it is void and restarts from a fresh median.
    uint256 public constant AUCTION_LIFE = 24 hours;
    uint8 public constant RULE_DIRECT = 1;
    uint8 public constant RULE_FACTORY = 2;

    string public constant name = "imdUSD seat units";
    string public constant symbol = "SEAT";
    uint8 public constant decimals = 18;

    bytes32 public immutable ilk;
    IERC721 public immutable nft;
    address public immutable implementation;
    address public immutable wirer;

    Ledger public ledger;
    Parameters public params;
    address public treasury;
    IERC20 public usd;

    uint256 public maxSeats;
    uint256 public perBorrower;
    /// @notice Seats held for borrowers (the Treasury's kept seats are not exposure and do not count).
    uint256 public seatCount;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(uint256 tokenId => address) public holderOf;
    mapping(address holder => uint256[]) internal _seats;
    mapping(uint256 tokenId => uint256) internal _seatIndex;

    mapping(uint256 id => Auction) public auctions;
    /// @dev Set only inside `_settle`: the Ledger's liquidation cuts are fractional units, retired at once.
    bool private _settling;

    mapping(address target => mapping(bytes4 => uint8)) public claimRule;
    /// @notice Rewards credited to `who` for a seat, per token: paid by `collect`.
    mapping(uint256 tokenId => mapping(address token => mapping(address who => uint256))) public owed;
    /// @notice The holder a seat last had: arrivals reported while the seat is between holders are theirs.
    mapping(uint256 tokenId => address) public lastHolder;

    error Unauthorized();
    error AlreadyWired();
    error NotWired();
    error TooManySeats();
    error NotHolder();
    error NoUnits();
    error WholeSeatsOnly();
    error NoAuction();
    error AuctionLive();
    error PriceAboveMax();
    error NoPosition();
    error NotAtFloor();
    error SpotBelowFloor();
    error NoBudget();
    error StillUnhealthy();
    error NothingNew();
    error NotSeatAccount();
    error Untransferable();
    error AuctionExpired();
    error Healthy();
    error NotPriced();
    error NotStray();

    event Deposited(uint256 indexed tokenId, address indexed holder, address account);
    event Withdrawn(uint256 indexed tokenId, address indexed holder, address to);
    event Opened(uint256 indexed id, uint256 startPrice, address marker);
    event Cancelled(uint256 indexed id);
    event Taken(uint256 indexed id, address indexed taker, uint256 seats, uint256 price, uint256 repaid, uint256 bad);
    event Kept(uint256 indexed id, uint256 seats, uint256 price, uint256 repaid, uint256 bad);
    event Assigned(uint256 indexed tokenId, address indexed from, address indexed to);
    event LimitsSet(uint256 maxSeats, uint256 perBorrower);
    event ClaimRuleSet(address target, bytes4 selector, uint8 rule);
    event Rewarded(uint256 indexed tokenId, address indexed token, address indexed who, uint256 amount);
    event Collected(uint256 indexed tokenId, address indexed token, address to, uint256 amount, uint256 fee);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event BudgetRecalled(uint256 amount);
    event Ticked(uint256 indexed id, uint256 ran);
    event Rescued(uint256 indexed strayId, address account, address to);

    constructor(bytes32 ilk_, IERC721 nft_, IImdAgentAdapter adapter_, address wirer_, uint256 maxSeats_, uint256 perBorrower_) {
        ilk = ilk_;
        nft = nft_;
        wirer = wirer_;
        implementation = address(new SeatAccount(address(this), nft_, adapter_));
        maxSeats = maxSeats_;
        perBorrower = perBorrower_;
    }

    // ---------------------------------------------------------------- wiring and governance

    function wire(address ledger_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (address(ledger) != address(0)) revert AlreadyWired();
        ledger = Ledger(ledger_);
        params = ledger.params();
        treasury = ledger.treasury();
        usd = IERC20(address(ledger.token()));
    }

    /// @notice The Join interface the Parameters checks: this contract is its own token.
    function token() external view returns (address) {
        return address(this);
    }

    modifier onlyLedger() {
        if (msg.sender != address(ledger) || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    modifier onlyParams() {
        if (msg.sender != address(params) || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    /// @notice Through Parameters' timelock (SET_SEAT_LIMITS). Lowering below the seats held only stops deposits.
    function setLimits(uint256 maxSeats_, uint256 perBorrower_) external onlyParams {
        maxSeats = maxSeats_;
        perBorrower = perBorrower_;
        emit LimitsSet(maxSeats_, perBorrower_);
    }

    /// @notice Through Parameters' timelock (SET_SEAT_CLAIM). RULE_DIRECT allows `target.selector`;
    /// RULE_FACTORY allows `selector` on any distributor `target.distributorOf(launch)` names.
    function setClaimRule(address target, bytes4 selector, uint8 rule) external onlyParams {
        claimRule[target][selector] = rule;
        emit ClaimRuleSet(target, selector, rule);
    }

    /// @notice Send the idle Treasury budget back. The governor only, no delay: it moves money to the Treasury.
    function recallBudget() external {
        if (msg.sender != params.governor()) revert Unauthorized();
        uint256 bal = usd.balanceOf(address(this));
        usd.safeTransfer(treasury, bal);
        emit BudgetRecalled(bal);
    }

    // ---------------------------------------------------------------- units (the Ledger's token view)

    /// @notice Only the Ledger pulls units, and only into its pool here.
    function transferFrom(address from, address to, uint256 amount) external onlyLedger returns (bool) {
        if (to != address(this)) revert Untransferable();
        if (amount % UNIT != 0) revert WholeSeatsOnly();
        _move(from, to, amount);
        return true;
    }

    /// @notice Only the Treasury moves units from its wallet: whole seats it kept, to a new holder.
    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        if (msg.sender != treasury) revert Untransferable();
        if (amount % UNIT != 0) revert WholeSeatsOnly();
        uint256 n = amount / UNIT;
        if (to != treasury) _admit(to, n);
        for (uint256 i; i < n; ++i) {
            uint256[] storage list = _seats[treasury];
            if (list.length == 0) revert NoUnits();
            _assign(list[list.length - 1], treasury, to);
        }
        _move(treasury, to, amount);
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        revert Untransferable();
    }

    /// @notice Ledger: units leave the pool for `to` (a withdrawal, or a liquidation's cuts).
    function exit(address to, uint256 amount) external onlyLedger {
        // Positions hold whole seats only, so a seat can always be withdrawn; a sale's cuts are the exception.
        if (amount % UNIT != 0 && !_settling) revert WholeSeatsOnly();
        _move(address(this), to, amount);
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert NoUnits();
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) private {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) private {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert NoUnits();
        balanceOf[from] = bal - amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ---------------------------------------------------------------- custody

    /// @notice Pledge a seat: it moves into its own account and you receive 1e18 units to put in the Ledger.
    function deposit(uint256 tokenId) external nonReentrant returns (address account) {
        if (address(ledger) == address(0)) revert NotWired();
        if (msg.sender == treasury) revert Unauthorized();
        _admit(msg.sender, 1);
        account = _accountFor(tokenId, true);
        nft.transferFrom(msg.sender, account, tokenId);
        if (nft.ownerOf(tokenId) != account) revert NotSeatAccount();
        holderOf[tokenId] = msg.sender;
        _seatIndex[tokenId] = _seats[msg.sender].length;
        _seats[msg.sender].push(tokenId);
        seatCount += 1;
        _mint(msg.sender, UNIT);
        emit Deposited(tokenId, msg.sender, account);
    }

    /// @notice Take a seat of yours back, burning 1e18 of your units (withdraw them from the Ledger first).
    function withdraw(uint256 tokenId, address to) external nonReentrant {
        if (holderOf[tokenId] != msg.sender) revert NotHolder();
        _burn(msg.sender, UNIT);
        _unlist(tokenId, msg.sender);
        seatCount -= 1;
        SeatAccount(_accountFor(tokenId, false)).release(to);
        emit Withdrawn(tokenId, msg.sender, to);
    }

    function accountOf(uint256 tokenId) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, bytes32(tokenId));
    }

    function seatsOf(address holder) external view returns (uint256[] memory) {
        return _seats[holder];
    }

    /// @notice Ledger only: a position holding `units` changed hands; its seats go with it (any n of the old owner's, as
    /// units are fungible among a holder's seats), within the new owner's limit. The Treasury never receives one this way.
    function onPositionTransfer(address from, address to, uint256 units) external onlyLedger {
        uint256 n = units / UNIT;
        if (n == 0) return;
        if (to == treasury) revert Unauthorized();
        // A holder-to-holder move leaves seatCount unchanged: only the new owner's perBorrower applies.
        if (_seats[to].length + n > perBorrower) revert TooManySeats();
        for (uint256 i; i < n; ++i) {
            uint256[] storage list = _seats[from];
            _assign(list[list.length - 1], from, to);
        }
    }

    function _accountFor(uint256 tokenId, bool create) private returns (address account) {
        account = accountOf(tokenId);
        if (account.code.length == 0) {
            if (!create) revert NotSeatAccount();
            Clones.cloneDeterministic(implementation, bytes32(tokenId));
            SeatAccount(account).initialize(tokenId);
        }
    }

    function _admit(address holder, uint256 n) private view {
        if (_seats[holder].length + n > perBorrower || seatCount + n > maxSeats) revert TooManySeats();
    }

    function _unlist(uint256 tokenId, address holder) private {
        uint256[] storage list = _seats[holder];
        uint256 i = _seatIndex[tokenId];
        uint256 last = list[list.length - 1];
        list[i] = last;
        _seatIndex[last] = i;
        list.pop();
        delete _seatIndex[tokenId];
        delete holderOf[tokenId];
        lastHolder[tokenId] = holder;
    }

    /// @dev Move a seat between holders without moving the NFT. Pairings die with the custody epoch.
    function _assign(uint256 tokenId, address from, address to) private {
        _unlist(tokenId, from);
        holderOf[tokenId] = to;
        _seatIndex[tokenId] = _seats[to].length;
        _seats[to].push(tokenId);
        if (from == treasury) seatCount += 1;
        if (to == treasury) seatCount -= 1;
        SeatAccount(_accountFor(tokenId, false)).bump();
        emit Assigned(tokenId, from, to);
    }

    /// @notice Governor only, no delay: hand a STRAY token of the collection, one that sits in a seat's
    /// account without ever having been deposited (a plain `transferFrom`), to `to`. The seat an
    /// account holds for its holder can never be moved this way: only a token that is not the account's
    /// own deposited seat qualifies, so no position is touched and no pairing dies. The account is created
    /// if the stray reached its address before any deposit. Where it goes is the governor's call: the chain
    /// does not record who sent it.
    function rescue(uint256 accountSeat, uint256 strayId, address to) external nonReentrant {
        if (msg.sender != params.governor()) revert Unauthorized();
        if (to == address(0)) revert NotStray();
        address account = _accountFor(accountSeat, true);
        if (nft.ownerOf(strayId) != account) revert NotStray();
        // The account's own seat is a deposit while someone holds it; a stray is anything else.
        if (strayId == accountSeat && holderOf[strayId] != address(0)) revert NotStray();
        if (strayId == accountSeat) {
            // Its own token, never deposited (or withdrawn and sent back plainly): the account refuses to move
            // `tokenId` (it has no way to tell a stray from a deposit), so release it as a custody change.
            SeatAccount(account).release(to);
        } else {
            SeatAccount(account).rescue(strayId, to);
        }
        emit Rescued(strayId, account, to);
    }

    // ---------------------------------------------------------------- auction

    /// @notice Liquidator only: a marked, unhealthy position goes on sale at the fall-capped median (never
    /// below what the priced leg's median says: a washed or crashed attestation cannot open the seat cheaper
    /// than the 20%-per-update cap allows; the Dutch decay finds a lower price if the market is lower).
    /// An auction past its life is void and is replaced here (the Liquidator has just re-checked health).
    function open(uint256 id, address marker) external {
        if (msg.sender != ledger.liquidator()) revert Unauthorized();
        Auction memory a = auctions[id];
        if (a.startAt != 0 && !_expired(a)) revert AuctionLive();
        _open(id, marker);
    }

    function _open(uint256 id, address marker) private {
        SeatFeed f = _feed();
        uint256 start = f.medianUsd();
        if (start == 0) revert NoAuction();
        (, uint64 at) = f.median().latestValue();
        auctions[id] = Auction({
            startPrice: uint176(start),
            startAt: uint40(block.timestamp),
            lastTick: uint40(block.timestamp),
            marker: marker,
            attestedAt: uint40(at),
            ran: 0
        });
        emit Opened(id, start, marker);
    }

    /// @notice USD per seat now: the start price decaying linearly to AUCTION_FLOOR of it over AUCTION_TIME
    /// of PRICED time. Reads a void (expired) auction's price too; `take` refuses it.
    function price(uint256 id) public view returns (uint256) {
        return _price(auctions[id]);
    }

    /// @notice Priced seconds the auction has run (its Dutch clock); `AUCTION_TIME` puts it at the floor,
    /// `AUCTION_LIFE` voids it.
    function elapsed(uint256 id) external view returns (uint256) {
        Auction memory a = auctions[id];
        return a.startAt == 0 ? 0 : _elapsed(a);
    }

    function expired(uint256 id) external view returns (bool) {
        Auction memory a = auctions[id];
        return a.startAt != 0 && _expired(a);
    }

    /// @notice Record the priced time run so far (anyone; the keeper after each median relay). Only needed
    /// for exactness across more than one stale gap between two readings: a single gap is reconstructed.
    function tick(uint256 id) external {
        Auction memory a = auctions[id];
        if (a.startAt == 0) revert NoAuction();
        _tick(a);
        auctions[id] = a;
        emit Ticked(id, a.ran);
    }

    function _tick(Auction memory a) private view {
        a.ran = uint40(_elapsed(a));
        a.lastTick = uint40(block.timestamp);
        (, uint64 at) = _feed().median().latestValue();
        a.attestedAt = uint40(at);
    }

    /// @dev Priced seconds since the opening: `ran` plus, since `lastTick`, the time the median attestation
    /// then live (`attestedAt`, fresh for the leaf's `maxAge`) or the one live now was within its life.
    /// Exact when at most one attestation landed since `lastTick` (they are daily; the feed is read at
    /// every opening, take and tick); with more, the time between the old window's end and the NEWEST
    /// attestation is treated as stale (not counted) even where an intermediate attestation priced it:
    /// the clock only ever runs slow, never fast (a slower decay, a longer life), and a `tick` after each
    /// relay makes it exact. The ETH/USD leg's own staleness blocks a sale (`NotPriced`) but is not
    /// reconstructed here.
    /// The new attestation's window opens when the chain first held it, max(signed, relayed), not at its signature
    /// (audit wave 1, panel 6): one signed before the old window closed but relayed after it, or signed in the gap and relayed
    /// later, must not count the hours the chain read stale (when `take` refused `NotPriced`) as priced time.
    function _elapsed(Auction memory a) private view returns (uint256 ran) {
        ran = a.ran;
        IFeed m = _feed().median();
        (, uint64 newAt) = m.latestValue();
        uint256 life = m.maxAge();
        uint256 t = block.timestamp;
        uint256 from = a.lastTick;
        uint256 freshUntil = uint256(a.attestedAt) + life;
        uint256 opened = Math.max(uint256(newAt), uint256(IRelayedAt(address(m)).acceptedAt()));
        if (opened <= freshUntil) {
            // The current attestation (the same one, or a refresh relayed before the old one aged out): fresh
            // without a gap until the newest window closes.
            uint256 end = Math.min(t, Math.max(freshUntil, uint256(newAt) + life));
            if (end > from) ran += end - from;
        } else {
            // A gap: the old window closed before the new attestation reached the chain.
            uint256 end1 = Math.min(t, freshUntil);
            if (end1 > from) ran += end1 - from;
            uint256 from2 = Math.max(from, opened);
            uint256 end2 = Math.min(t, uint256(newAt) + life);
            if (end2 > from2) ran += end2 - from2;
        }
    }

    function _expired(Auction memory a) private view returns (bool) {
        return _elapsed(a) >= AUCTION_LIFE;
    }

    function _price(Auction memory a) private view returns (uint256) {
        if (a.startAt == 0) return 0;
        uint256 run = Math.min(_elapsed(a), AUCTION_TIME);
        uint256 drop = Math.mulDiv(a.startPrice, (1e18 - AUCTION_FLOOR) * run, 1e18 * AUCTION_TIME);
        return a.startPrice - drop;
    }

    /// @notice Buy the position's seats at the current price (at most `maxPrice` each). Pay n x price in
    /// imdUSD; receive the n NFTs. Rewards credited to the borrower stay theirs (`collect`).
    function take(uint256 id, uint256 maxPrice) external nonReentrant returns (uint256 p, uint256 n) {
        Auction memory a = auctions[id];
        if (a.startAt == 0) revert NoAuction();
        if (_expired(a)) revert AuctionExpired();
        p = _price(a);
        if (p > maxPrice) revert PriceAboveMax();
        n = _positionSeats(id);
        usd.safeTransferFrom(msg.sender, address(this), n * p);
        address owner = ledger.nft().ownerOf(id);
        (uint256 repaid, uint256 bad) = _settle(id, owner, a.marker, p, n);
        uint256[] storage list = _seats[owner];
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = list[list.length - 1];
            _unlist(tokenId, owner);
            SeatAccount(_accountFor(tokenId, false)).release(msg.sender);
        }
        seatCount -= n;
        emit Taken(id, msg.sender, n, p, repaid, bad);
    }

    /// @notice The Treasury option: once the price sits at the floor, with the raw 1-day spot no
    /// lower than it and budget on hand, anyone may have the Treasury buy the seats and keep them here.
    function takeFloor(uint256 id) external nonReentrant returns (uint256 p, uint256 n) {
        Auction memory a = auctions[id];
        if (a.startAt == 0) revert NoAuction();
        uint256 run = _elapsed(a);
        if (run >= AUCTION_LIFE) revert AuctionExpired();
        if (run < AUCTION_TIME) revert NotAtFloor();
        p = _price(a);
        SeatFeed f = _feed();
        if (!f.rawSpotFresh() || f.rawSpotUsd() < p) revert SpotBelowFloor();
        n = _positionSeats(id);
        if (usd.balanceOf(address(this)) < n * p) revert NoBudget();
        address owner = ledger.nft().ownerOf(id);
        (uint256 repaid, uint256 bad) = _settle(id, owner, a.marker, p, n);
        uint256[] storage list = _seats[owner];
        for (uint256 i; i < n; ++i) {
            _assign(list[list.length - 1], owner, treasury);
        }
        _mint(treasury, n * UNIT);
        emit Kept(id, n, p, repaid, bad);
    }

    /// @notice An auction whose position is healthy again, or has no debt, is void.
    function cancel(uint256 id) external {
        if (auctions[id].startAt == 0) revert NoAuction();
        if (ledger.debtOf(id) != 0) {
            (bool ok, bool priced) = ledger.healthy(id);
            if (!priced || !ok) revert StillUnhealthy();
        }
        delete auctions[id];
        emit Cancelled(id);
    }

    /// @notice Start again from the median as it stands: at the floor with a newer median attested since the
    /// auction opened (a fresh price for a stuck sale), or once the auction is void, if the position is still
    /// unhealthy at a live price (a healthy one is `cancel`led instead). The marker is kept.
    function reopen(uint256 id) external {
        Auction memory a = auctions[id];
        if (a.startAt == 0) revert NoAuction();
        if (_expired(a)) {
            (bool ok, bool priced) = ledger.healthy(id);
            if (!priced) revert NotPriced();
            if (ok) revert Healthy();
        } else {
            if (_elapsed(a) < AUCTION_TIME) revert NotAtFloor();
            (, uint64 at) = _feed().median().latestValue();
            if (at <= a.startAt) revert NothingNew();
        }
        _open(id, a.marker);
    }

    /// @dev Close the position through the Liquidator at `p` per seat, then pay everyone from the n x p held here.
    function _settle(uint256 id, address owner, address marker, uint256 p, uint256 n)
        private
        returns (uint256 repaid, uint256 bad)
    {
        uint256 tBefore = balanceOf[treasury];
        uint256 mBefore = balanceOf[marker];
        uint256 poolBefore = balanceOf[address(this)];
        // The penalty the Ledger applies is the position's BOUND version's, read before settling.
        (, uint256 chop) = params.liqRisk(ilk, ledger.position(id).version);
        _settling = true;
        (repaid,, bad) = Liquidator(ledger.liquidator()).settle(id, p, marker, false);
        _settling = false;
        // The sold units are retired: the cuts the Ledger handed out and the pool's share alike.
        uint256 mUnits = balanceOf[marker] - mBefore;
        balanceOf[treasury] = tBefore;
        balanceOf[marker] = mBefore;
        balanceOf[address(this)] = poolBefore - n * UNIT;
        totalSupply -= n * UNIT;
        emit Transfer(address(this), address(0), n * UNIT);
        delete auctions[id];

        uint256 left = n * p - repaid; // what the Ledger did not burn
        uint256 penalty = Math.min(Math.mulDiv(repaid, chop, 1e18), left);
        uint256 toMarker = Math.min(Math.mulDiv(mUnits, p, 1e18), penalty);
        uint256 toBorrower = left - penalty;
        if (toMarker != 0) usd.safeTransfer(marker, toMarker);
        if (toBorrower != 0) usd.safeTransfer(owner, toBorrower);
        if (penalty - toMarker != 0) usd.safeTransfer(treasury, penalty - toMarker);
    }

    function _positionSeats(uint256 id) private view returns (uint256 n) {
        n = ledger.position(id).collateral / UNIT;
        if (n == 0) revert NoPosition();
    }

    function _feed() private view returns (SeatFeed) {
        return SeatFeed(address(params.config(ilk).median));
    }

    // ---------------------------------------------------------------- rewards

    function claimAllowed(address target, bytes4 selector, address factory, uint256 hint) external view returns (bool) {
        if (claimRule[target][selector] == RULE_DIRECT) return true;
        if (factory == address(0) || claimRule[factory][selector] != RULE_FACTORY) return false;
        return IDistributorFactory(factory).distributorOf(uint64(hint)) == target && target != address(0);
    }

    /// @notice A seat's account reports an arrival: credited to the seat's holder now, or, between holders,
    /// to the last one (S4); a seat that never had one credits the Treasury. Credit follows the holder when the arrival is
    /// REPORTED, not when it was earned: arrivals left unreported at a change of holder go to the next holder who reports.
    function onRewards(uint256 tokenId, address token, uint256 amount) external {
        if (msg.sender != accountOf(tokenId)) revert NotSeatAccount();
        address who = holderOf[tokenId];
        if (who == address(0)) who = lastHolder[tokenId];
        if (who == address(0)) who = treasury;
        owed[tokenId][token][who] += amount;
        emit Rewarded(tokenId, token, who, amount);
    }

    /// @notice Pay `who`'s credit of `token` for a seat to `who`, less the type's `yieldFee` in kind to the
    /// Treasury (none on the Treasury's own). Anyone may trigger it; the money has one destination. A token
    /// that will not transfer reverts here and only here: the credit waits.
    function collect(uint256 tokenId, address token, address who) external nonReentrant {
        uint256 amount = owed[tokenId][token][who];
        if (amount == 0) return;
        owed[tokenId][token][who] = 0;
        uint256 fee = who == treasury ? 0 : Math.mulDiv(amount, params.risk(ilk).yieldFee, 1e18);
        SeatAccount account = SeatAccount(_accountFor(tokenId, false));
        if (fee != 0) account.send(token, treasury, fee);
        account.send(token, who, amount - fee);
        emit Collected(tokenId, token, who, amount - fee, fee);
    }
}
