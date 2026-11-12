// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {IBackstop, IBackstopOracle, ILedgerCover, IBackstopSeller} from "./IBackstop.sol";

/// @title Backstop sleeve: a standing bid for liquidated collateral, and the edge types' first loss.
/// @notice Depositors pool imdUSD. When a covered type's position is liquidated, the sleeve is the payer: it buys the
/// collateral in the liquidation's own transaction at the liquidation price plus the type's penalty, so the
/// liquidation's value goes to depositors and the kicker earns only the marker's chip. Two instances of this contract
/// exist per chain: `blue` (ETH, BTC, staked stables) and `edge` (sIMD, and later fungible edge types). Seat and stock
/// types sell by Dutch auction: no sleeve can list them (ADD_SLEEVE_ILK refuses an auction type), so they have no standing
/// bid and no first loss, and their bad debt goes to the Treasury. The edge sleeve also burns its
/// imdUSD against edge types' bad debt before the Treasury does (`coverBadDebt`), earns a premium (a share of edge
/// interest, minted here by the Ledger and streamed), and bounds edge lines (`edgeCapacity`).
///
/// ONE CONTRACT PER SLEEVE (not two share classes in one): independent accounting, a share token per risk, a smaller
/// contract and no path by which one sleeve's loss can touch the other's assets.
///
/// POOLED, MULTI-ASSET. Assets = vested imdUSD + the collateral bought, held per token (at most MAX_TOKENS). Exits are
/// pro rata IN KIND (imdUSD and each collateral), so no price is needed to leave and a sleeve that holds only collateral
/// still pays out exactly what it holds. A collateral transfer that fails (a paused or blocklisting token) never blocks
/// the rest of an exit: that token's part is credited to the leaver as `unsent` and pulled later with `claim`. Entries are priced: a deposit converts to shares at the net asset value with
/// collateral at its HIGH price (protects existing holders: a newcomer can only overpay), and waits while any held
/// collateral is unpriced (fail closed), with two exceptions so a dead feed cannot stop conversions for good: a
/// holding worth under DUST_VALUE at its last good high price counts as 0, and a token Parameters has `retired` (its
/// timelock) counts as 0 while it is unpriced. Exits always pay every held token in kind, retired or not.
///
/// NO JIT, NO EVASION. A deposit waits in a day bucket and becomes shares only once a full day has passed (bucket day D
/// converts from the start of day D+2). Until then it bears no gains or losses and buys nothing; it may be cancelled.
/// Withdrawals are a 7-day queue; queued shares keep taking gains and losses until paid. A flash loan can therefore
/// neither fund a bid nor take part in one. Nothing in the sleeve depends on who holds shares at the moment of a bid.
/// A matured request may be paid only within CLAIM_WINDOW (2 days) after its 7 days; after that it must be re-queued, so
/// no holder keeps a standing instant exit.
///
/// BOOKED LOSSES FIRST. On the edge sleeve, bad debt the Ledger has booked on a listed edge type but nobody has yet
/// covered (`owedBadDebt`) is netted out of the imdUSD used to price conversions, pay exits, bid and size edge lines, up
/// to the room a cover could take. An exit before the cover therefore takes its share of the loss, and a bucket that
/// converts while a loss is booked does not buy into it. While the booked loss EXCEEDS that room (`_lossOverRoom`, the
/// Treasury has yet to pay the rest) buckets wait: a conversion would put new money where the next cover burns it. Waiting
/// deposits are not bid room or capacity and can be cancelled in full; they convert once the loss fits the room.
///
/// STREAMED ARRIVALS. imdUSD that arrives without a deposit (the edge premium, donations) joins a 7-day linear stream
/// (SavingsVault's rule), so no arrival can move the share price inside a block. Collateral sent outside a bid is not
/// counted (it is stuck: never send collateral here).
///
/// FLOOR. A bid or a bad-debt cover never spends below a fixed residue of MIN_RESIDUE (1 imdUSD) of
/// vested imdUSD. The floor is NOT derived from the share supply: a supply-derived floor reached exactly turns every new
/// share into floor (a recapitalisation of a wiped sleeve was swallowed whole). With a fixed residue a deposit after a
/// wipe converts at the true (tiny) share price, so the old shares keep exactly the residue's worth and the new money
/// is the new depositors'. Share amounts are uint256 throughout (no silent truncation); imdUSD amounts are SafeCast.
/// Conversions wait (never revert) if the share price ever falls under 1/MAX_RATE per wei (only after many wipes).
/// What a cover cannot take stays bad debt for the Treasury.
contract Backstop is ERC20, TransientReentrancyGuard, IBackstop {
    using SafeERC20 for IERC20;

    uint256 public constant STREAM = 7 days;
    uint256 public constant QUEUE = 7 days;
    uint256 public constant BOOTSTRAP = 60 days;
    uint256 public constant EDGE_MULTIPLE = 3;
    uint256 public constant MAX_TOKENS = 6;
    uint256 public constant MAX_ILKS = 12;
    /// @notice How long a matured withdrawal request stays payable before it must be re-queued.
    uint256 public constant CLAIM_WINDOW = 2 days;
    uint256 public constant MAX_SALE_SLIPPAGE_BPS = 200; // a sale returns >= 98% of the collateral's low price
    /// @dev Minted to DEAD at the first conversion into an empty pool, so entries and exits price over the same supply (an
    /// entry-only offset hands its share of the pool to the next converter).
    uint256 private constant VIRTUAL_SHARES = 1e6;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice The least vested imdUSD a bid or a cover leaves in the pool (a fixed residue, not supply-derived).
    uint256 public constant MIN_RESIDUE = 1e18;
    /// @notice Most shares per wei a conversion may mint at; above it buckets wait (bounds every share figure < 2^256).
    uint256 public constant MAX_RATE = 1e36;
    /// @notice An unpriced holding worth less than this at its last good high price does not stop conversions.
    uint256 public constant DUST_VALUE = 10e18;

    // transient slots for the open bid
    uint256 private constant T_OPEN = 0x8a3b1f1c4b5e8f6c0d2a7e9b3c5d1f0e2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c01; // ilk
    uint256 private constant T_USD = 0x8a3b1f1c4b5e8f6c0d2a7e9b3c5d1f0e2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c02;
    uint256 private constant T_COLL = 0x8a3b1f1c4b5e8f6c0d2a7e9b3c5d1f0e2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c03;
    uint256 private constant T_ROOM = 0x8a3b1f1c4b5e8f6c0d2a7e9b3c5d1f0e2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c04;
    uint256 private constant T_SALE = 0x8a3b1f1c4b5e8f6c0d2a7e9b3c5d1f0e2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c05; // sale in progress

    struct Ilk {
        address token; // the collateral a liquidation of this type pays out
        uint64 listedAt;
        uint128 genesisLine; // edge: the bootstrap allowance at listing
        bool on;
    }

    struct Limit {
        uint128 max; // most collateral (raw units) the seller may take at once
        uint128 slope; // refill per second
        uint128 level; // available at `at`
        uint64 at;
    }

    struct Bucket {
        uint128 amount;
        uint256 shares;
        bool listed; // pushed to `openDays` (once, even if cancelled to zero and refilled)
        bool converted;
    }

    struct Pend {
        uint64 day;
        uint128 amount;
    }

    struct Request {
        uint256 shares;
        uint64 at;
    }

    IERC20 public immutable imdUSD;
    ILedgerCover public immutable ledger;
    IBackstopOracle public immutable oracle;
    bool public immutable edge;
    address public immutable deployer;

    address public liquidator;
    /// @notice Parameters: lists and disables types after `seal` (its timelock governs that).
    address public params;
    address public seller;
    bool public isSealed;

    mapping(bytes32 ilk => Ilk) public ilks;
    /// @notice Every type ever listed (bounded by MAX_ILKS): the edge sleeve nets their booked bad debt.
    bytes32[] public ilkList;
    address[] public tokens;
    mapping(address token => bool) public isToken;
    /// @notice Collateral held per token (bought in bids, not yet paid out or sold).
    mapping(address token => uint256) public coll;
    mapping(address token => Limit) public saleLimit;
    /// @notice The last good high price seen per held token (imdUSD per 1e18 raw), for the dust rule.
    mapping(address token => uint256) public lastHigh;
    /// @notice Tokens Parameters has retired: valued at 0 for conversions while unpriced.
    mapping(address token => bool) public retired;
    mapping(address token => uint256) public retiredAt;

    /// @notice imdUSD in the pool, counted or streaming (excludes deposits still waiting in buckets).
    uint256 public tracked;
    /// @notice imdUSD waiting in unconverted buckets.
    uint256 public staged;
    uint256 public unvestedAtSync;
    uint64 public lastSync;
    uint64 public streamEnd;

    mapping(uint256 day => Bucket) public buckets;
    uint256[] public openDays;
    uint256 public openHead;
    mapping(address user => Pend[2]) internal _pend;
    mapping(address user => Request) public requests;
    /// @notice Collateral an exit could not send (the token refused the transfer): the leaver's to `claim`.
    mapping(address user => mapping(address token => uint256)) public unsent;

    event Deposited(address indexed from, address indexed to, uint256 amount, uint256 day);
    event Cancelled(address indexed user, uint256 amount);
    event Converted(uint256 indexed day, uint256 amount, uint256 shares);
    event Realized(address indexed user, uint256 shares);
    event WithdrawRequested(address indexed user, uint256 shares, uint256 total);
    event WithdrawCancelled(address indexed user);
    event Withdrawn(address indexed user, address indexed to, uint256 shares, uint256 imdUSDOut);
    event Unsent(address indexed user, address indexed token, uint256 amount);
    event Claimed(address indexed user, address indexed token, address to, uint256 amount);
    event Bid(bytes32 indexed ilk, uint256 spent, uint256 received);
    event BadDebtCovered(bytes32 indexed ilk, uint256 amount);
    event Streamed(uint256 received, uint256 unvested, uint256 streamEnd);
    event Sold(address indexed token, uint256 amount, uint256 imdUSDIn);
    event IlkListed(bytes32 indexed ilk, address token, uint256 genesisLine);
    event IlkDisabled(bytes32 indexed ilk);
    event Retired(address indexed token, bool retired);

    error Unauthorized();
    error Sealed();
    error AlreadyWired();
    error BidOpen();
    error NoBid();
    error UnknownIlk();
    error TooManyTokens();
    error TooManyPending();
    error ZeroAmount();
    error Locked();
    error NotReady();
    error OverRoom();
    error BadPrice();
    error SaleLimit();
    error SaleShort();
    error Exists();
    error Expired();
    error StillPriced();

    constructor(IERC20 imdUSD_, ILedgerCover ledger_, IBackstopOracle oracle_, bool edge_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        imdUSD = imdUSD_;
        ledger = ledger_;
        oracle = oracle_;
        edge = edge_;
        deployer = msg.sender;
        lastSync = uint64(block.timestamp);
        streamEnd = uint64(block.timestamp);
    }

    modifier notInBid() {
        if (_openIlk() != bytes32(0)) revert BidOpen();
        _;
    }

    // ================================================================ setup

    /// @notice Deployer, once: the Liquidator (bids), Parameters (listing after seal) and the seller (may be zero).
    function wire(address liquidator_, address params_, address seller_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (liquidator != address(0)) revert AlreadyWired();
        liquidator = liquidator_;
        params = params_;
        seller = seller_;
    }

    /// @notice List a type: the deployer before `seal`, then only Parameters. `genesisLine` is the edge bootstrap
    /// allowance (ignored on the blue sleeve). The sale limit bounds the seller per collateral token. A type disabled
    /// earlier may be listed again with the same token (disabling is not final); its listing restarts, `listedAt`
    /// and `genesisLine` included, so a re-listing opens a fresh 60-day bootstrap allowance (a governance power: the
    /// Safe's instant disable plus a 48h ADD_SLEEVE_ILK can keep edge capacity above what vested imdUSD supports).
    function addIlk(bytes32 ilk, address token, uint128 genesisLine, uint128 saleMax, uint128 saleSlope) external {
        if (isSealed ? msg.sender != params : msg.sender != deployer) revert Unauthorized();
        Ilk storage k = ilks[ilk];
        if (k.token != address(0)) {
            if (k.on || k.token != token) revert Exists();
            k.on = true;
            k.listedAt = uint64(block.timestamp);
            k.genesisLine = edge ? genesisLine : 0;
            emit IlkListed(ilk, token, edge ? genesisLine : 0);
            return;
        }
        if (token == address(0) || token == address(imdUSD)) revert UnknownIlk();
        if (!isToken[token]) {
            if (tokens.length == MAX_TOKENS) revert TooManyTokens();
            isToken[token] = true;
            tokens.push(token);
            saleLimit[token] = Limit({max: saleMax, slope: saleSlope, level: saleMax, at: uint64(block.timestamp)});
        }
        if (ilkList.length == MAX_ILKS) revert TooManyTokens();
        ilkList.push(ilk);
        ilks[ilk] = Ilk({token: token, listedAt: uint64(block.timestamp), genesisLine: edge ? genesisLine : 0, on: true});
        emit IlkListed(ilk, token, edge ? genesisLine : 0);
    }

    /// @notice Stop bidding on a type (instant: the safe direction). Parameters after seal, the deployer before.
    function disableIlk(bytes32 ilk) external {
        if (isSealed ? msg.sender != params : msg.sender != deployer) revert Unauthorized();
        if (ilks[ilk].token == address(0)) revert UnknownIlk();
        ilks[ilk].on = false;
        emit IlkDisabled(ilk);
    }

    function seal() external {
        if (msg.sender != deployer) revert Unauthorized();
        isSealed = true;
    }

    /// @notice Parameters only (RETIRE_SLEEVE_TOKEN, its 48h timelock): value a held token at 0 for conversions while it has no price (a dead
    /// feed, a written-off stock), so new deposits convert again. It dilutes the holders' claim on that token's value,
    /// which they still receive in kind on exit; RETIRE_SLEEVE_TOKEN with `on` false undoes it. Refused while the token has a
    /// price (at apply), and it holds only while the token's legs have not updated since: a recovery nobody transacted in
    /// must not leave it at 0 at the next stale read, a gift to whoever's bucket converted then. The next
    /// conversion step clears a flag so overtaken.
    function retire(address token, bool on) external {
        if (msg.sender != params) revert Unauthorized();
        if (!isToken[token]) revert UnknownIlk();
        if (on) {
            (, uint256 high, bool good) = oracle.priceOf(token);
            if (good && high != 0) revert StillPriced();
        }
        retired[token] = on;
        retiredAt[token] = on ? block.timestamp : 0;
        emit Retired(token, on);
    }

    // ================================================================ views

    /// @notice Arrivals still to vest, rounded up so the vested figure never overstates.
    function unvested() public view returns (uint256) {
        uint256 end = streamEnd;
        if (block.timestamp >= end) return 0;
        return Math.mulDiv(unvestedAtSync, end - block.timestamp, end - lastSync, Math.Rounding.Ceil);
    }

    /// @notice imdUSD the pool may spend or pay out now.
    function vested() public view returns (uint256) {
        return tracked - unvested();
    }

    /// @notice The least imdUSD a bid or a cover leaves in the pool.
    function floor() public pure returns (uint256) {
        return MIN_RESIDUE;
    }

    /// @notice Edge sleeve: bad debt booked on its live types that a cover would take now (0 on the blue sleeve).
    function owedBadDebt() public view returns (uint256 owed) {
        if (!edge) return 0;
        for (uint256 i; i < ilkList.length; ++i) {
            bytes32 ilk = ilkList[i];
            if (!ilks[ilk].on) continue; // a disabled type's losses are the Treasury's (coverBadDebt refuses it)
            (,,,, uint128 bad) = ledger.ilkState(ilk);
            owed += bad;
        }
    }

    /// @notice Vested imdUSD less the booked, uncovered edge bad debt a cover would burn (never below the floor's
    /// residue): the figure conversions, exits, bids and edge lines use.
    function netVested() public view returns (uint256 a) {
        a = vested();
        uint256 f = floor();
        if (a <= f) return a;
        uint256 owed = owedBadDebt();
        a -= Math.min(owed, a - f);
    }

    function bidRoom(bytes32 ilk) public view returns (uint256) {
        if (!ilks[ilk].on) return 0;
        uint256 a = netVested();
        uint256 f = floor();
        return a > f ? a - f : 0;
    }

    /// @notice What `bidRoom` will read inside the next bid: matured deposits convert in `openBid`, so the site and the
    /// keeper should show this, not `bidRoom`, as the room available now. A view; converts nothing.
    function bidRoomNow(bytes32 ilk) external view returns (uint256) {
        if (!ilks[ilk].on) return 0;
        uint256 today = block.timestamp / 1 days;
        uint256 matured;
        // The same gates as `_convert`: a bucket it would leave waiting is no room.
        (uint256 value, bool ok) = nav();
        bool waits = !ok || _lossOverRoom() || _priceSupply() / (value + 1) >= MAX_RATE;
        for (uint256 h = waits ? openDays.length : openHead; h < openDays.length; ++h) {
            uint256 day = openDays[h];
            if (day + 2 > today) break;
            matured += buckets[day].amount;
        }
        uint256 a = netVested() + matured;
        uint256 f = floor();
        return a > f ? a - f : 0;
    }

    /// @notice Net asset value with collateral at its high price and booked edge bad debt netted (`netVested`); `ok`
    /// false while any held collateral is unpriced.
    function nav() public view returns (uint256 value, bool ok) {
        value = netVested();
        for (uint256 i; i < tokens.length; ++i) {
            uint256 c = coll[tokens[i]];
            if (c == 0) continue;
            (, uint256 high, bool good) = oracle.priceOf(tokens[i]);
            if (!good || high == 0) {
                // A retired token, or dust at its last good price, counts as 0; anything else fails closed.
                if (_stillRetired(tokens[i]) || Math.mulDiv(c, lastHigh[tokens[i]], 1e18) < DUST_VALUE) continue;
                return (value, false);
            }
            value += Math.mulDiv(c, high, 1e18);
        }
        ok = true;
    }

    /// @notice The edge bootstrap allowance for `ilk`: its genesis line, falling linearly to zero over 60 days.
    function bootstrap(bytes32 ilk) public view returns (uint256) {
        Ilk memory k = ilks[ilk];
        uint256 elapsed = block.timestamp - k.listedAt;
        if (elapsed >= BOOTSTRAP) return 0;
        return Math.mulDiv(k.genesisLine, BOOTSTRAP - elapsed, BOOTSTRAP);
    }

    function edgeCapacity(bytes32 ilk, uint256 inAuction) external view returns (uint256) {
        if (!edge || !ilks[ilk].on) return 0;
        uint256 c = Math.max(EDGE_MULTIPLE * netVested(), bootstrap(ilk));
        return c > inAuction ? c - inAuction : 0;
    }

    /// @notice A user's deposits still in buckets: (day, amount) for each slot.
    function pendingOf(address user) external view returns (Pend[2] memory) {
        return _pend[user];
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function ilkCount() external view returns (uint256) {
        return ilkList.length;
    }

    function openDaysLength() external view returns (uint256) {
        return openDays.length;
    }

    // ================================================================ deposits

    /// @notice Deposit imdUSD for `to`. It waits in today's bucket and becomes shares from the start of the day after
    /// tomorrow (at least one full day), at the asset value then. A deposit for someone else may only add to their slot of
    /// today (audit wave 1: two wei from a stranger could fill both of a user's pending slots and block their deposits).
    function deposit(uint256 amount, address to) external nonReentrant notInBid {
        if (amount == 0) revert ZeroAmount();
        sync();
        _convert();
        _realize(to);
        uint256 before = imdUSD.balanceOf(address(this));
        imdUSD.safeTransferFrom(msg.sender, address(this), amount);
        amount = imdUSD.balanceOf(address(this)) - before;
        uint256 day = block.timestamp / 1 days;
        Bucket storage b = buckets[day];
        if (!b.listed) {
            b.listed = true;
            openDays.push(day);
        }
        uint128 a128 = SafeCast.toUint128(amount);
        b.amount += a128;
        staged += amount;
        Pend[2] storage p = _pend[to];
        if (p[0].day == day && p[0].amount != 0) p[0].amount += a128;
        else if (p[1].day == day && p[1].amount != 0) p[1].amount += a128;
        else if (to != msg.sender) revert TooManyPending();
        else if (p[0].amount == 0) p[0] = Pend(uint64(day), a128);
        else if (p[1].amount == 0) p[1] = Pend(uint64(day), a128);
        else revert TooManyPending();
        emit Deposited(msg.sender, to, amount, day);
    }

    /// @notice Take back deposits that have not become shares yet (they took no part in anything).
    function cancelDeposit(uint256 amount) external nonReentrant notInBid {
        if (amount == 0) revert ZeroAmount();
        sync();
        _convert();
        _realize(msg.sender);
        Pend[2] storage p = _pend[msg.sender];
        uint256 left = amount;
        for (uint256 i = 2; i > 0 && left != 0; --i) {
            Pend storage s = p[i - 1];
            if (s.amount == 0) continue;
            Bucket storage b = buckets[s.day];
            if (b.converted) continue;
            uint256 take = Math.min(left, s.amount);
            s.amount -= uint128(take);
            b.amount -= uint128(take);
            left -= take;
        }
        if (left != 0) revert NotReady();
        staged -= amount;
        imdUSD.safeTransfer(msg.sender, amount);
        emit Cancelled(msg.sender, amount);
    }

    /// @notice Convert matured buckets and hand `user` the shares their deposits became. Permissionless.
    function realize(address user) external nonReentrant notInBid {
        sync();
        _convert();
        _realize(user);
    }

    // ================================================================ withdrawals

    /// @notice Queue `shares` to leave. They stay in the pool (gains and losses) until `withdraw`, 7 days after the
    /// latest request and at most CLAIM_WINDOW after that; adding to a request restarts its clock, and
    /// `requestWithdraw(0)` re-queues an existing request as it stands.
    function requestWithdraw(uint256 shares) external nonReentrant notInBid {
        Request storage r = requests[msg.sender];
        if (shares == 0 && r.shares == 0) revert ZeroAmount();
        sync();
        _convert();
        _realize(msg.sender);
        if (balanceOf(msg.sender) - r.shares < shares) revert Locked();
        r.shares += shares;
        r.at = uint64(block.timestamp);
        emit WithdrawRequested(msg.sender, shares, r.shares);
    }

    function cancelWithdraw() external nonReentrant notInBid {
        delete requests[msg.sender];
        emit WithdrawCancelled(msg.sender);
    }

    /// @notice Pay out a matured request: the shares' pro-rata part of vested imdUSD and of every collateral held.
    function withdraw(address to) external nonReentrant notInBid returns (uint256 usdOut, uint256[] memory collOut) {
        sync();
        Request memory r = requests[msg.sender];
        if (r.shares == 0 || block.timestamp < uint256(r.at) + QUEUE) revert NotReady();
        if (block.timestamp >= uint256(r.at) + QUEUE + CLAIM_WINDOW) revert Expired();
        uint256 shares = r.shares;
        uint256 supply = totalSupply();
        delete requests[msg.sender];
        usdOut = Math.mulDiv(netVested(), shares, supply);
        collOut = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            collOut[i] = Math.mulDiv(coll[tokens[i]], shares, supply);
            coll[tokens[i]] -= collOut[i];
        }
        tracked -= usdOut;
        _burn(msg.sender, shares);
        if (usdOut != 0) imdUSD.safeTransfer(to, usdOut);
        for (uint256 i; i < tokens.length; ++i) {
            if (collOut[i] == 0 || _trySend(tokens[i], to, collOut[i])) continue;
            unsent[msg.sender][tokens[i]] += collOut[i]; // a paused/blocklisting token: pull it later
            emit Unsent(msg.sender, tokens[i], collOut[i]);
        }
        emit Withdrawn(msg.sender, to, shares, usdOut);
    }

    /// @notice Pull collateral an exit could not send, to any address (e.g. once the token unpauses, or to an address
    /// the issuer does not block).
    function claim(address token, address to) external nonReentrant notInBid returns (uint256 amount) {
        amount = unsent[msg.sender][token];
        if (amount == 0) revert ZeroAmount();
        delete unsent[msg.sender][token];
        IERC20(token).safeTransfer(to, amount);
        emit Claimed(msg.sender, token, to, amount);
    }

    // ================================================================ standing bid

    function openBid(bytes32 ilk) external nonReentrant notInBid {
        if (msg.sender != liquidator) revert Unauthorized();
        if (!ilks[ilk].on || ilk == bytes32(0)) revert UnknownIlk();
        sync();
        // Matured deposit buckets join the pool here too, so bid room never waits for a keeper's `realize` (that only
        // hands a depositor the shares their bucket became; the imdUSD counts from conversion). Bounded: a bucket per day.
        _convert();
        uint256 room = bidRoom(ilk);
        uint256 usd = imdUSD.balanceOf(address(this));
        uint256 c = IERC20(ilks[ilk].token).balanceOf(address(this));
        assembly ("memory-safe") {
            tstore(T_OPEN, ilk)
            tstore(T_USD, usd)
            tstore(T_COLL, c)
            tstore(T_ROOM, room)
        }
    }

    function closeBid(bytes32 ilk, uint256 repaid) external nonReentrant returns (uint256 spent, uint256 received) {
        if (msg.sender != liquidator) revert Unauthorized();
        if (_openIlk() != ilk || ilk == bytes32(0)) revert NoBid();
        uint256 usdBefore;
        uint256 collBefore;
        uint256 room;
        assembly ("memory-safe") {
            usdBefore := tload(T_USD)
            collBefore := tload(T_COLL)
            room := tload(T_ROOM)
            tstore(T_OPEN, 0)
            tstore(T_USD, 0)
            tstore(T_COLL, 0)
            tstore(T_ROOM, 0)
        }
        address token = ilks[ilk].token;
        uint256 usdAfter = imdUSD.balanceOf(address(this));
        uint256 collAfter = IERC20(token).balanceOf(address(this));
        // The sleeve lost at most what the Ledger reports it burned (an arrival during the bid only raises usdAfter).
        if (collAfter < collBefore || usdAfter + repaid < usdBefore) revert OverRoom();
        spent = repaid;
        received = collAfter - collBefore;
        if (spent > room) revert OverRoom();
        if (spent != 0) {
            (uint256 low, uint256 high, bool ok) = oracle.priceOf(token);
            if (!ok || Math.mulDiv(received, low, 1e18, Math.Rounding.Ceil) < spent) revert BadPrice();
            if (high != 0) lastHigh[token] = high;
        }
        tracked -= spent;
        coll[token] += received;
        emit Bid(ilk, spent, received);
    }

    // ================================================================ edge first loss

    function coverBadDebt(bytes32 ilk) external nonReentrant notInBid returns (uint256 covered) {
        if (!edge || !ilks[ilk].on) revert UnknownIlk();
        sync();
        (,,,, uint128 bad) = ledger.ilkState(ilk);
        uint256 a = vested();
        uint256 f = floor();
        uint256 room = a > f ? a - f : 0;
        uint256 amount = Math.min(bad, room);
        if (amount == 0) return 0;
        uint256 before = imdUSD.balanceOf(address(this));
        ledger.cover(ilk, amount);
        covered = before - imdUSD.balanceOf(address(this));
        if (covered > amount) revert OverRoom();
        tracked -= covered;
        emit BadDebtCovered(ilk, covered);
    }

    // ================================================================ arrivals

    /// @notice Fold imdUSD that arrived without a deposit (premium, donations) into the 7-day stream. Permissionless.
    /// A no-op during a bid and during a sale (the sale counts what arrives in it, once).
    function sync() public {
        uint256 bal = imdUSD.balanceOf(address(this));
        uint256 counted = tracked + staged;
        uint256 inSale;
        assembly ("memory-safe") {
            inSale := tload(T_SALE)
        }
        if (bal <= counted || inSale != 0 || _openIlk() != bytes32(0)) return;
        uint256 received = bal - counted;
        uint256 u = unvested();
        uint256 end = streamEnd;
        uint256 remaining = end > block.timestamp ? end - block.timestamp : 0;
        uint256 total = u + received;
        uint256 duration = (u * remaining + received * STREAM) / total;
        if (duration == 0) duration = 1;
        tracked += received;
        unvestedAtSync = total;
        lastSync = uint64(block.timestamp);
        streamEnd = uint64(block.timestamp + duration);
        emit Streamed(received, total, block.timestamp + duration);
    }

    // ================================================================ sale path (the allocator)

    /// @notice The allowlisted seller takes `amount` of held collateral and must pay at least `minOut` imdUSD (and at
    /// least 98% of its low price) back in the same call. Rate-limited per token.
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata data)
        external
        nonReentrant
        notInBid
        returns (uint256 got)
    {
        if (msg.sender != seller || seller == address(0)) revert Unauthorized();
        if (amount == 0 || amount > coll[token]) revert ZeroAmount();
        Limit storage l = saleLimit[token];
        uint256 level = Math.min(uint256(l.max), uint256(l.level) + uint256(l.slope) * (block.timestamp - l.at));
        if (amount > level) revert SaleLimit();
        l.level = uint128(level - amount);
        l.at = uint64(block.timestamp);
        (uint256 low, uint256 high, bool ok) = oracle.priceOf(token);
        if (!ok) revert BadPrice();
        if (high != 0) lastHigh[token] = high;
        uint256 floorOut = Math.mulDiv(Math.mulDiv(amount, low, 1e18), 10_000 - MAX_SALE_SLIPPAGE_BPS, 10_000);
        sync();
        uint256 before = imdUSD.balanceOf(address(this));
        coll[token] -= amount;
        assembly ("memory-safe") {
            tstore(T_SALE, 1)
        }
        IERC20(token).safeTransfer(msg.sender, amount);
        IBackstopSeller(msg.sender).onBackstopSell(token, amount, data);
        assembly ("memory-safe") {
            tstore(T_SALE, 0)
        }
        got = imdUSD.balanceOf(address(this)) - before;
        if (got < minOut || got < floorOut) revert SaleShort();
        tracked += got; // replaces the collateral's value at once: not an arrival
        emit Sold(token, amount, got);
    }

    // ================================================================ internals

    /// @dev ERC-20 transfer that reports failure instead of reverting (SafeERC20's success rule: no return data from a
    /// contract, or a returned true). Copies at most one word of return data.
    function _trySend(address token, address to, uint256 amount) internal returns (bool ok) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        assembly ("memory-safe") {
            ok := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            if ok {
                switch returndatasize()
                case 0 { ok := gt(extcodesize(token), 0) }
                default { ok := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
    }

    function _openIlk() internal view returns (bytes32 ilk) {
        assembly ("memory-safe") {
            ilk := tload(T_OPEN)
        }
    }

    /// @dev The supply a conversion now would price over: DEAD's shares are minted by that conversion if the pool is empty.
    function _priceSupply() private view returns (uint256) {
        uint256 s = totalSupply();
        return s == 0 ? VIRTUAL_SHARES : s;
    }

    function _stillRetired(address token) private view returns (bool) {
        return retired[token] && oracle.pricedAt(token) <= retiredAt[token];
    }

    /// @dev A retired token with a good price again, or whose legs have updated since, stops being retired. Runs on every conversion
    /// step, before any bucket has to have matured, so a recovered feed clears the flag at the first deposit, realize or bid after it.
    function _clearRetired() private {
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            if (!retired[t]) continue;
            (, uint256 high, bool good) = oracle.priceOf(t);
            if ((good && high != 0) || !_stillRetired(t)) {
                retired[t] = false;
                emit Retired(t, false);
            }
        }
    }

    /// @dev True while booked edge bad debt is more than a cover could take from the pool (a conversion now would be burned).
    function _lossOverRoom() internal view returns (bool) {
        uint256 a = vested();
        uint256 f = floor();
        return owedBadDebt() > (a > f ? a - f : 0);
    }

    /// @dev Convert every bucket that has matured (day + 2 <= today), oldest first, at the asset value now. Waits (all of
    /// them convert later) while held collateral is unpriced (fail closed) or a booked loss exceeds the room (BOOKED LOSSES).
    function _convert() internal {
        _clearRetired();
        uint256 today = block.timestamp / 1 days;
        uint256 h = openHead;
        uint256 n = openDays.length;
        if (h == n || openDays[h] + 2 > today) return;
        for (uint256 i; i < tokens.length; ++i) {
            if (coll[tokens[i]] == 0) continue;
            (, uint256 high, bool good) = oracle.priceOf(tokens[i]);
            if (good && high != 0) lastHigh[tokens[i]] = high; // the dust rule's reference
        }
        (uint256 value, bool ok) = nav();
        if (!ok || _lossOverRoom()) return;
        while (h < n) {
            uint256 day = openDays[h];
            if (day + 2 > today) break;
            Bucket storage b = buckets[day];
            uint256 amount = b.amount;
            uint256 shares;
            if (amount != 0) {
                // Into an empty pool: what it already holds (unvested premium, an exit's remainder) stays with DEAD's shares.
                if (totalSupply() == 0) _mint(DEAD, VIRTUAL_SHARES);
                uint256 supply = totalSupply();
                if (supply / (value + 1) >= MAX_RATE) break; // share price too low to price new money: wait
                shares = Math.mulDiv(amount, supply, value + 1);
                b.shares = shares;
                staged -= amount;
                tracked += amount;
                value += amount;
                _mint(address(this), shares);
            }
            b.converted = true;
            emit Converted(day, amount, shares);
            ++h;
        }
        openHead = h;
    }

    function _realize(address user) internal {
        Pend[2] storage p = _pend[user];
        uint256 total;
        for (uint256 i; i < 2; ++i) {
            Pend memory s = p[i];
            if (s.amount == 0) continue;
            Bucket memory b = buckets[s.day];
            if (!b.converted) continue;
            total += b.amount == 0 ? 0 : Math.mulDiv(s.amount, b.shares, b.amount);
            delete p[i];
        }
        if (total != 0) {
            _transfer(address(this), user, total);
            emit Realized(user, total);
        }
    }

    /// @dev Queued shares cannot move; the contract's own (bucket) shares move only to their owners.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from != address(this) && to != address(0)) {
            if (balanceOf(from) - requests[from].shares < value) revert Locked();
        }
        super._update(from, to, value);
    }
}
