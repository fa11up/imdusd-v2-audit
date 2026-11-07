// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {Ledger} from "../Ledger.sol";
import {Adjust} from "../interfaces/IPositions.sol";
import {ParametersBase} from "../ParametersBase.sol";
import {Parameters} from "../Parameters.sol";
import {Pricer} from "../Pricer.sol";
import {IFeed} from "../interfaces/IFeed.sol";

/// @notice The staked collateral token (sIMD): an ERC-4626 over the vault's asset (IMD).
interface IStakedToken {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

/// @notice A route the caller supplies. Before calling it the vault has transferred `amountIn` of `tokenIn` to the
/// router; the router must send its output of `tokenOut` to `msg.sender` (the vault) before returning. The vault
/// measures what arrived; `data` is the router's own business.
/// @dev One fixed selector, so the vault never makes an arbitrary call: a "router" that is the Ledger, imdUSD, IMD or
/// any other contract the vault has an allowance at has no such function and reverts.
interface ILoopRouter {
    function loopSwap(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata data) external;
}

/// @notice The two imdUSD views the vault reads: the flash cap left in this transaction and the peg keeper (PegHook).
interface ILoopImdUSD {
    function keeper() external view returns (address);
    function maxFlashLoan(address token) external view returns (uint256);
}

/// @notice The peg hook's 30-minute TWAP, ticks of imdUSD's price from $1 (negative = below the peg).
interface IPegTwap {
    function twapTicks() external view returns (int24);
}

/// @title LoopVault (imdUSD v2)
/// @notice Deposit IMD, hold a target leverage on sIMD through ONE v2 position (positions are keyed to msg.sender, so
/// this contract is the borrower). Depositors own the position pro rata through this ERC-20 share (`loopIMD`).
///
/// SHARE PRICE. A share is its slice of (collateral in IMD + idle balances − debt converted to IMD). A DEPOSIT is
/// priced with the debt converted at the HIGHEST of the type's median, spot and live-pool price: the debt is the
/// fewest IMD, the vault reads richest and the depositor receives the fewest shares. A WITHDRAWAL takes a proportional
/// slice of collateral AND debt in kind, which needs no price at all, and the leaver settles the debt slice
/// themselves (in imdUSD, or by selling part of their IMD through a route they pick), i.e. at the worst price they
/// choose to accept. Pushing the live pool up only shrinks the pusher's own deposit; pushing it down changes nothing,
/// because the deposit leg is then an attested one. The spread between the legs is the entry cost, by design.
///
/// REBALANCING. Target 250% CR at the low leg, rebalanced only outside 220-280%. `lever` and `delever` are
/// permissionless, move at most MAX_STEP_BPS of the collateral's value per call, and swap through a router the caller
/// chooses. The proceeds must be at least an oracle-bounded minimum: IMD is bought at no more than min(low, live) and
/// sold at no less than max(low, live), each less MAX_SLIPPAGE_BPS. The live leg is only used in the vault's favour,
/// so a pushed pool makes a fill harder, never cheaper; the most a router can keep is the slippage allowance on one
/// step. `lever` needs fresh, agreeing feeds and the live pool within GATE_BPS of the low leg. `delever` flash-mints
/// imdUSD to repay first, so the vault never needs to hold imdUSD: at fresh feeds it steps toward the target; while
/// the Ledger will not release collateral from an indebted position (stale or disagreeing feeds), it may only UNWIND
/// fully (repay all the debt, so no price check applies), still bounded by the last attested low leg.
///
/// WITHDRAWALS are never gated by this contract. The Ledger refuses to release collateral from a position that keeps
/// debt while feeds are stale or disagree; that is the Ledger's rule for every borrower, and a partial exit then
/// waits. The last holder out repays everything and needs no price.
///
/// FEE. 10% of the collateral's yield (sIMD share-rate growth, in IMD) over the borrow cost (interest at the
/// position's rate, converted at the low leg), minted to the Treasury as shares at the deposit leg. A deficit
/// carries forward; nothing is charged on a period that did not net a gain, nor while unpriced.
///
/// SIZE. The vault's debt is capped at K_LOOP × the posted IMD depth (`Parameters.depthIMD`,
/// the 7-day low of all IMD exit pools to −15%, the number the sIMD line's own rule uses), so every rebalance it can
/// ever need fits in the market it must trade through. A step is also capped by the flash room left in the
/// transaction and by the caller's `maxStep` (a thin route is walked in smaller pieces). `lever` is refused while the
/// peg pool's TWAP is below PEG_FLOOR_TICKS: the vault never sells borrowed imdUSD into a pool already under the peg.
///
/// NO OWNER, NO PARAMETERS. Type, Ledger and Treasury are fixed at construction; band, step, slippage and gate are
/// constants.
contract LoopVault is ERC20, IERC3156FlashBorrower, TransientReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TARGET_CR = 2.5e18;
    uint256 public constant BAND_LOW = 2.2e18;
    uint256 public constant BAND_HIGH = 2.8e18;
    uint256 public constant MAX_STEP_BPS = 1000; // one lever/delever moves at most 10% of the collateral's value
    /// @dev 1.5% (was 2%): IMD's deep market is a 1%-fee pool, so the allowance must cover that
    /// fee; the rest (0.5%) covers impact and the gap the 1% live-vs-attested gate admits. A caller is now paid a
    /// bounty (below), so the allowance no longer has to double as the caller's wage.
    uint256 public constant MAX_SLIPPAGE_BPS = 150; // a fill may be at most 1.5% worse than the oracle reference
    uint256 public constant GATE_BPS = 100; // deposits and lever need the live pool within 1% of the attested legs
    uint256 public constant PERFORMANCE_FEE_BPS = 1000;
    /// @notice E4: a caller is paid BOUNTY_USD per successful lever/delever (never more than BOUNTY_STEP_BPS of the
    /// step, so many tiny steps earn no more than one big one), in shares, out of `bountyBudget`: IMD set aside from
    /// the performance fee (the Treasury's share is minted net of it) up to BOUNTY_BUDGET_USD. Never principal: with
    /// no fee charged yet, there is no bounty. $2 covers a ~500k-gas rebalance up to ~1.7 gwei at $2,300 ETH.
    uint256 public constant BOUNTY_USD = 2e18;
    /// @notice E6: once the attested legs go stale, the unwind's floor (the last attested low) decays by this much per
    /// hour of staleness, so in a fast fall the bound reaches the live market (p99 1-hour IMD fall ~10-12%)
    /// instead of waiting above it for the next attestation. A push of the live pool still
    /// cannot buy the vault's IMD below the decayed floor.
    uint256 public constant UNWIND_DECAY_BPS_PER_HOUR = 1000;
    uint256 public constant BOUNTY_STEP_BPS = 10;
    uint256 public constant BOUNTY_BUDGET_USD = 200e18;
    /// @notice E3: debt <= K_LOOP × Parameters.depthIMD(). 0.25: the sIMD line's rule spends k = 0.8 of the same depth
    /// on line × (1 + chop) + redeemCap, so the vault is at most ~30% of the line's room; and a
    /// full delever from the 250% target to the 170% mat sells (2.5 − 1.7) / 1.5 = 0.53 of the debt, i.e. at most 13%
    /// of the posted depth (~20% after depth shrinks ~1:1 with price in a −32% fall, the measured beta ~1.1).
    uint256 public constant K_LOOP = 0.25e18;
    /// @notice E3: `lever` waits while the peg pool's 30-minute TWAP is more than 25 ticks (0.25%) under $1.
    int24 public constant PEG_FLOOR_TICKS = -25;
    uint256 public constant DEAD_SHARES = 1000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant YEAR = 365 days;
    bytes32 private constant FLASH_RETURN = keccak256("ERC3156FlashBorrower.onFlashLoan");
    // keccak256("imdusd.LoopVault.flash"): the hash of the flash the vault expects (slot) and its result (slot + 1).
    uint256 private constant FLASH_SLOT = 0x970aacdfcc9f70e36b37e7e272ed0ead7090a5766e9e5fc58d5fb57819df1914;

    uint8 private constant ACT_DELEVER = 1;
    uint8 private constant ACT_EXIT = 2;

    Ledger public immutable ledger;
    Parameters public immutable params;
    Pricer public immutable pricer;
    bytes32 public immutable ilk;
    /// @notice The vault's one Ledger position: `ledger.positionId(this, ilk, 0)`, created on first use.
    uint256 public immutable positionId;
    IERC20 public immutable usd; // imdUSD, also the flash lender
    IERC20 public immutable imd;
    IStakedToken public immutable staked; // sIMD
    address public immutable treasury;

    /// @notice The state at the last action, for the fee: collateral shares, share rate, debt, time.
    uint256 public sharesMark;
    uint256 public rateMark;
    uint256 public debtMark;
    uint256 public markAt;
    /// @notice A rebalance in progress: 1 = levering, 2 = delevering, 0 = none. A rebalance starts only outside the
    /// band and, once started, may continue in capped steps until it reaches the target (hysteresis), so a capped
    /// step that lands inside the band does not strand the vault short of 250%.
    uint8 public rebalancing;
    /// @notice Yield (IMD) and borrow cost (imdUSD) accumulated and not yet charged.
    int256 public pendingYield;
    uint256 public pendingCost;
    /// @notice E4: IMD of performance fee set aside for rebalance bounties (shrinks pro rata on exits).
    uint256 public bountyBudget;
    /// @notice E7: the block an address last received new shares (minted, or sent by a holder that was itself holding
    /// new shares that block). It cannot exit in that block, so a deposit-then-withdraw around a known value event
    /// (a fee, a donation, a redemption) needs two blocks and carries the position's risk in between.
    mapping(address => uint256) public heldAt;

    error ZeroAddress();
    error BadType();
    error NotPriced();
    error OffMarket(uint256 live, uint256 low, uint256 high);
    error InBand();
    error ZeroAmount();
    error Slippage();
    error Insolvent();
    error DustRemainder();
    error ShortFill(uint256 got, uint256 minimum);
    error BadFlash();
    error AtCap(uint256 debt, uint256 cap);
    error BelowPeg(int24 twap);
    error Held();

    event Deposited(address indexed caller, address indexed to, uint256 amount, uint256 shares);
    event Withdrawn(address indexed owner, address indexed to, uint256 shares, uint256 imdOut, uint256 usdOut);
    event Levered(address indexed caller, address indexed router, uint256 borrowed, uint256 bought);
    event Delevered(address indexed caller, address indexed router, uint256 repaid, uint256 sold, bool unwind);
    event FeeCharged(uint256 feeImd, uint256 shares);
    event BountyPaid(address indexed caller, uint256 imdValue, uint256 shares);

    constructor(Ledger ledger_, bytes32 ilk_, address treasury_) ERC20("IMD Loop", "loopIMD") {
        if (address(ledger_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        ledger = ledger_;
        positionId = ledger_.positionId(address(this), ilk_, 0);
        params = ledger_.params();
        pricer = ledger_.pricer();
        usd = IERC20(address(ledger_.token()));
        treasury = treasury_;
        ilk = ilk_;
        ParametersBase.Config memory c = params.config(ilk_);
        // A share of IMD with a live pool leg: the deposit gate and the rebalance bounds read it.
        if (c.token == address(0) || address(c.liveSpot) == address(0)) revert BadType();
        staked = IStakedToken(c.token);
        imd = IERC20(staked.asset());
        if (staked.convertToAssets(1e18) == 0) revert BadType();
        // Standing allowances: the Ledger pulls IMD only on this contract's own `adjust`; imdUSD takes a flash mint
        // back only inside a `flashLoan` this contract initiated (the callback refuses any other).
        imd.forceApprove(address(ledger_), type(uint256).max);
        usd.forceApprove(address(usd), type(uint256).max);
        rateMark = staked.convertToAssets(1e18);
        markAt = block.timestamp;
    }

    // ================================================================ views

    /// @notice The type's quote and its live-pool leg (0 when unreadable). Prices are USD per 1e18 raw sIMD.
    function legs() public view returns (Pricer.Quote memory q, uint256 live) {
        q = pricer.quote(ilk);
        IFeed f = params.config(ilk).liveSpot;
        (uint256 v,) = f.latestValue();
        live = f.isStale() ? 0 : v;
    }

    /// @notice USD per 1e18 raw IMD implied by a USD-per-sIMD price.
    function imdPrice(uint256 sharePrice) public view returns (uint256) {
        return Math.mulDiv(sharePrice, 1e18, staked.convertToAssets(1e18));
    }

    /// @notice The vault's position: collateral (sIMD) and debt (imdUSD incl. accrued interest).
    function position() public view returns (uint256 collateral, uint256 debt) {
        collateral = ledger.position(positionId).collateral;
        debt = ledger.debtOf(positionId);
    }

    /// @notice Net value in IMD (collateral + idle − debt) with the debt converted at `sharePrice`; < 0 underwater.
    function nav(uint256 sharePrice) public view returns (int256) {
        (uint256 c, uint256 d) = position();
        uint256 value = staked.convertToAssets(c) + imd.balanceOf(address(this));
        uint256 idle = usd.balanceOf(address(this));
        uint256 p = imdPrice(sharePrice);
        if (idle >= d) return (value + Math.mulDiv(idle - d, 1e18, p)).toInt256();
        return value.toInt256() - Math.mulDiv(d - idle, 1e18, p, Math.Rounding.Ceil).toInt256();
    }

    /// @notice Collateral ratio at the low leg, 1e18; max when there is no debt; 0 when unpriced.
    function collateralRatio() public view returns (uint256) {
        (Pricer.Quote memory q,) = legs();
        if (!q.priced) return 0;
        (uint256 c, uint256 d) = position();
        return d == 0 ? type(uint256).max : Math.mulDiv(Math.mulDiv(c, q.low, 1e18), 1e18, d);
    }

    /// @notice E3: the most the vault may owe, K_LOOP × the posted IMD depth (USD = imdUSD, 1e18). 0 without a posted
    /// depth: then the vault never levers.
    function debtCap() public view returns (uint256) {
        return Math.mulDiv(params.depthIMD(), K_LOOP, 1e18);
    }

    /// @notice Shares a deposit of `amount` IMD would mint now, before any pending fee (0 if deposits are closed).
    function previewDeposit(uint256 amount) external view returns (uint256) {
        (Pricer.Quote memory q, uint256 live) = legs();
        if (!q.priced || live == 0 || !_withinGate(q, live)) return 0;
        return _sharesFor(amount, totalSupply(), nav(Math.max(q.high, live)));
    }

    /// @notice What burning `shares` releases: collateral (IMD), debt to settle (imdUSD), idle IMD, idle imdUSD.
    function previewWithdraw(uint256 shares)
        external
        view
        returns (uint256 collateralImd, uint256 debt, uint256 idleImd, uint256 idleUsd)
    {
        (uint256 c, uint256 d, uint256 ii, uint256 iu) = _slice(shares, totalSupply());
        return (staked.convertToAssets(c), d, ii, iu);
    }

    // ================================================================ deposit

    /// @notice Deposit `amount` IMD for at least `minShares`, priced at the highest leg. Refused while unpriced or
    /// while the live pool is more than GATE_BPS outside the attested legs.
    function deposit(uint256 amount, uint256 minShares, address to) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        (Pricer.Quote memory q, uint256 live) = legs();
        if (!q.priced || live == 0) revert NotPriced();
        if (!_withinGate(q, live)) revert OffMarket(live, q.low, q.high);
        _checkpoint(q, live);
        uint256 supply = totalSupply();
        if (supply == 0) {
            if (amount <= DEAD_SHARES) revert ZeroAmount();
            _mint(DEAD, DEAD_SHARES);
            shares = amount - DEAD_SHARES;
        } else {
            int256 n = nav(Math.max(q.high, live));
            if (n <= 0 && !(n == 0 && supply == DEAD_SHARES)) revert Insolvent();
            shares = _sharesFor(amount, supply, n);
        }
        if (shares == 0 || shares < minShares) revert Slippage();
        imd.safeTransferFrom(msg.sender, address(this), amount);
        _adj(amount.toInt256(), 0, 0, true, type(uint256).max);
        _mint(to, shares);
        _mark();
        emit Deposited(msg.sender, to, amount, shares);
    }

    // ================================================================ withdraw

    /// @notice Burn `shares`: repay their slice of the debt from the caller's imdUSD (pulled; approve this vault) and
    /// receive their slice of the collateral and idle balances in IMD. Needs no price of its own.
    function withdraw(uint256 shares, uint256 minImdOut, address to)
        external
        nonReentrant
        returns (uint256 imdOut, uint256 usdOut)
    {
        return _exit(shares, minImdOut, to, 0, address(0), "");
    }

    /// @notice Burn `shares`: their slice of the collateral is unstaked and `sellImd` of it is sold through `router`;
    /// the sale must cover the slice's debt (a flash mint bridges the repayment). The caller receives the rest of the
    /// IMD and any imdUSD the sale returned above the debt. The route and its slippage are the caller's.
    function withdrawSelling(
        uint256 shares,
        uint256 minImdOut,
        address to,
        uint256 sellImd,
        address router,
        bytes calldata data
    ) external nonReentrant returns (uint256 imdOut, uint256 usdOut) {
        if (router == address(0)) revert ZeroAddress();
        return _exit(shares, minImdOut, to, sellImd, router, data);
    }

    function _exit(uint256 shares, uint256 minImdOut, address to, uint256 sellImd, address router, bytes memory data)
        private
        returns (uint256 imdOut, uint256 usdOut)
    {
        if (shares == 0) revert ZeroAmount();
        if (heldAt[msg.sender] == block.number) revert Held();
        (Pricer.Quote memory q, uint256 live) = legs();
        _checkpoint(q, live); // charges only when priced; otherwise carries
        uint256 supply = totalSupply();
        (uint256 coll, uint256 debt, uint256 idleImd, uint256 idleUsd) = _slice(shares, supply);
        if (supply - shares == DEAD_SHARES) {
            // The last real holder takes everything, the dead slice included: nothing is stranded behind dust.
            (coll, debt) = position();
            idleImd = imd.balanceOf(address(this));
            idleUsd = usd.balanceOf(address(this));
            bountyBudget = 0; // the value behind it left with the leaver
        } else {
            bountyBudget -= Math.mulDiv(bountyBudget, shares, supply);
            (, uint256 d) = position();
            if (debt < d && d - debt < params.risk(ilk).dust) revert DustRemainder();
        }
        _burn(msg.sender, shares);

        uint256 owed = debt > idleUsd ? debt - idleUsd : 0; // the leaver's idle imdUSD covers part of their debt
        uint256 usdKeep = usd.balanceOf(address(this)) - idleUsd; // the others' idle imdUSD
        uint256 imdKeep = imd.balanceOf(address(this)) - idleImd;
        if (router == address(0)) {
            if (owed != 0) usd.safeTransferFrom(msg.sender, address(this), owed);
            _release(coll, debt);
        } else if (owed == 0) {
            _release(coll, debt);
        } else {
            _flash(owed, abi.encode(ACT_EXIT, coll, debt, sellImd, router, usdKeep + owed, data));
        }
        imdOut = imd.balanceOf(address(this)) - imdKeep;
        usdOut = usd.balanceOf(address(this)) - usdKeep;
        if (imdOut < minImdOut) revert Slippage();
        if (imdOut != 0) imd.safeTransfer(to, imdOut);
        if (usdOut != 0) usd.safeTransfer(to, usdOut);
        _mark();
        emit Withdrawn(msg.sender, to, shares, imdOut, usdOut);
    }

    // ================================================================ rebalance

    /// @notice Borrow toward the target ratio and buy IMD through `router`, staking it as collateral. Permissionless.
    /// Needs fresh, agreeing feeds, the live pool within GATE_BPS of the low leg, the peg pool's TWAP no lower than
    /// PEG_FLOOR_TICKS, a ratio above the band and debt under `debtCap()`. Borrows at most `maxStep` imdUSD.
    function lever(address router, uint256 maxStep, bytes calldata data)
        external
        nonReentrant
        returns (uint256 borrowed, uint256 bought)
    {
        if (router == address(0)) revert ZeroAddress();
        (Pricer.Quote memory q, uint256 live) = legs();
        if (!q.borrowable || live == 0) revert NotPriced();
        if (!_near(live, q.low)) revert OffMarket(live, q.low, q.high);
        _checkPeg();
        _checkpoint(q, live);
        (uint256 c, uint256 d) = position();
        uint256 v = Math.mulDiv(c, q.low, 1e18);
        if (d != 0) {
            uint256 cr = Math.mulDiv(v, 1e18, d);
            if (cr <= (rebalancing == 1 ? TARGET_CR : BAND_HIGH)) revert InBand();
        }
        uint64 r = d == 0 ? params.risk(ilk).rateFloor : ledger.position(positionId).rate;
        // The Ledger's upfront fee per 1e18 borrowed: the debt grows by x (1 + f), so
        // (v + x) / (d + x (1 + f)) = T  =>  x = (v - T d) / (T (1 + f) - 1), capped at one step.
        uint256 f = ledger.upfrontFeeFor(ilk, 1e36, r) / 1e18 + 1; // rounded up
        borrowed = Math.mulDiv(
            v - Math.mulDiv(TARGET_CR, d, 1e18), 1e18, Math.mulDiv(TARGET_CR, 1e18 + f, 1e18) - 1e18
        );
        uint256 cap = _stepCap(v, maxStep);
        {
            uint256 dc = debtCap();
            if (d >= dc) revert AtCap(d, dc);
            cap = Math.min(cap, Math.mulDiv(dc - d, 1e18, 1e18 + f));
        }
        rebalancing = borrowed > cap ? 1 : 0;
        borrowed = Math.min(borrowed, cap);
        if (borrowed == 0) revert ZeroAmount();
        _adj(0, borrowed.toInt256(), params.risk(ilk).rateFloor, false,
            ledger.upfrontFeeFor(ilk, borrowed, r)
        );
        uint256 minOut =
            Math.mulDiv(borrowed, 1e18 * (10_000 - MAX_SLIPPAGE_BPS), imdPrice(Math.min(q.low, live)) * 10_000);
        bought = _route(router, usd, borrowed, imd, data);
        if (bought < minOut) revert ShortFill(bought, minOut);
        _adj(bought.toInt256(), 0, 0, true, type(uint256).max);
        _payBounty(borrowed, Math.max(q.high, live));
        _mark();
        emit Levered(msg.sender, router, borrowed, bought);
    }

    /// @notice Repay toward the target ratio: flash-mint imdUSD, repay, unstake collateral, sell it through `router`
    /// for at least the oracle minimum, repay the flash. Permissionless; only below the band. At fresh, agreeing feeds
    /// it steps toward the target. Otherwise the Ledger will not release collateral from an indebted position, so it
    /// unwinds fully (all the debt), measured and bounded by the last attested low leg and the live pool.
    /// A step repays at most `maxStep` imdUSD (and never more than the flash room left); a full unwind repays all.
    function delever(address router, uint256 maxStep, bytes calldata data)
        external
        nonReentrant
        returns (uint256 repaid, uint256 sold)
    {
        if (router == address(0)) revert ZeroAddress();
        (Pricer.Quote memory q, uint256 live) = legs();
        _checkpoint(q, live);
        (uint256 c, uint256 d) = position();
        if (d == 0) revert InBand();
        bool unwind = !q.borrowable;
        uint256 risk; // price the ratio is measured at: the lower known one
        uint256 refPrice; // price the vault sells at no less than (less slippage): the higher known one
        if (unwind) {
            (uint256 last, uint256 floor_) = _lastLow();
            if (last == 0 || live == 0) revert NotPriced();
            (risk, refPrice) = (Math.min(last, live), Math.max(floor_, live));
        } else {
            (risk, refPrice) = (q.low, Math.max(q.low, live));
        }
        uint256 v = Math.mulDiv(c, risk, 1e18);
        if (Math.mulDiv(v, 1e18, d) >= (rebalancing == 2 && !unwind ? TARGET_CR : BAND_LOW)) revert InBand();
        rebalancing = 0;
        if (unwind) {
            repaid = d;
        } else {
            // (v - x) / (d - x) = T  =>  x = (T d - v) / (T - 1), capped at one step and at the debt.
            repaid = Math.mulDiv(Math.mulDiv(TARGET_CR, d, 1e18) - v, 1e18, TARGET_CR - 1e18);
            uint256 cap = _stepCap(v, maxStep);
            if (repaid > cap) (repaid, rebalancing) = (cap, 2);
            repaid = Math.min(repaid, d);
            if (d - repaid < params.risk(ilk).dust) (repaid, rebalancing) = (d, 0); // close rather than leave dust
        }
        // Withdraw enough that the worst allowed fill still covers the repayment.
        uint256 refImd = imdPrice(refPrice);
        uint256 toSell = Math.mulDiv(repaid, 1e18 * 10_000, refImd * (10_000 - MAX_SLIPPAGE_BPS), Math.Rounding.Ceil);
        uint256 shares = Math.min(c, staked.convertToShares(toSell) + 1);
        uint256 before = usd.balanceOf(address(this));
        sold = _flash(repaid, abi.encode(ACT_DELEVER, shares, repaid, refImd, router, before + repaid, data));
        // Proceeds above the repayment pay more debt down where the Ledger's dust rule allows, else stay idle.
        uint256 extra = usd.balanceOf(address(this)) - before;
        (, uint256 left) = position();
        if (extra != 0 && left != 0) {
            extra = Math.min(extra, left);
            if (left - extra == 0 || left - extra >= params.risk(ilk).dust) {
                _adj(0, -extra.toInt256(), 0, false, type(uint256).max);
                repaid += extra;
            }
        }
        _payBounty(repaid, unwind ? refPrice : Math.max(q.high, live));
        _mark();
        emit Delevered(msg.sender, router, repaid, sold, unwind);
    }

    /// @notice Repay debt from imdUSD idle here (surplus proceeds, donations). Needs no price. Permissionless.
    function repayIdle() external nonReentrant returns (uint256 repaid) {
        (Pricer.Quote memory q, uint256 live) = legs();
        _checkpoint(q, live);
        (, uint256 d) = position();
        repaid = Math.min(usd.balanceOf(address(this)), d);
        uint256 dust = params.risk(ilk).dust;
        if (repaid != 0 && d - repaid != 0 && d - repaid < dust) repaid = d > dust ? d - dust : 0;
        if (repaid != 0) _adj(0, -repaid.toInt256(), 0, false, type(uint256).max);
        _mark();
    }

    /// @notice Settle the performance fee up to now. Permissionless; every action does this first anyway.
    function checkpoint() external nonReentrant {
        (Pricer.Quote memory q, uint256 live) = legs();
        _checkpoint(q, live);
        _mark();
    }

    // ================================================================ flash

    function _flash(uint256 amount, bytes memory data) private returns (uint256 result) {
        bytes32 h = keccak256(abi.encode(amount, data));
        assembly ("memory-safe") {
            tstore(FLASH_SLOT, h)
        }
        IERC3156FlashLender(address(usd)).flashLoan(this, address(usd), amount, data);
        assembly ("memory-safe") {
            result := tload(add(FLASH_SLOT, 1))
            tstore(add(FLASH_SLOT, 1), 0)
        }
    }

    /// @dev Only imdUSD, only for the flash this contract just asked for (same amount and data), exactly once.
    function onFlashLoan(address initiator, address token, uint256 amount, uint256, bytes calldata data)
        external
        returns (bytes32)
    {
        bytes32 expected;
        assembly ("memory-safe") {
            expected := tload(FLASH_SLOT)
            tstore(FLASH_SLOT, 0)
        }
        if (
            msg.sender != address(usd) || token != address(usd) || initiator != address(this) || expected == 0
                || keccak256(abi.encode(amount, data)) != expected
        ) revert BadFlash();
        uint256 result = abi.decode(data, (uint8)) == ACT_DELEVER ? _deleverInFlash(data) : _exitInFlash(data);
        assembly ("memory-safe") {
            tstore(add(FLASH_SLOT, 1), result)
        }
        return FLASH_RETURN;
    }

    function _deleverInFlash(bytes calldata data) private returns (uint256 sold) {
        (, uint256 shares, uint256 repaid, uint256 refImd, address router, uint256 mustHold, bytes memory rd) =
            abi.decode(data, (uint8, uint256, uint256, uint256, address, uint256, bytes));
        uint256 before = imd.balanceOf(address(this));
        _release(shares, repaid);
        sold = imd.balanceOf(address(this)) - before;
        uint256 got = _route(router, imd, sold, usd, rd);
        uint256 minOut = Math.max(repaid, Math.mulDiv(sold, refImd * (10_000 - MAX_SLIPPAGE_BPS), 1e18 * 10_000));
        if (got < minOut) revert ShortFill(got, minOut);
        if (usd.balanceOf(address(this)) < mustHold) revert ShortFill(got, minOut);
    }

    function _exitInFlash(bytes calldata data) private returns (uint256) {
        (, uint256 coll, uint256 debt, uint256 sellImd, address router, uint256 mustHold, bytes memory rd) =
            abi.decode(data, (uint8, uint256, uint256, uint256, address, uint256, bytes));
        uint256 before = imd.balanceOf(address(this));
        _release(coll, debt);
        uint256 sell = Math.min(sellImd, imd.balanceOf(address(this)) - before);
        if (sell != 0) _route(router, imd, sell, usd, rd);
        uint256 have = usd.balanceOf(address(this));
        if (have < mustHold) revert ShortFill(have, mustHold); // the sale must cover the slice's debt
        return sell;
    }

    // ================================================================ internals

    /// @dev One change to the vault's position (created by the first).
    function _adj(int256 dc, int256 dd, uint64 rate, bool viaAsset, uint256 maxFee) private {
        ledger.open(ilk, 0, Adjust(dc, dd, rate, 0, 0, viaAsset, maxFee, address(0)));
    }

    /// @dev Withdraw `coll` collateral (unstaked to IMD here) and repay `debt`, in one Ledger call.
    function _release(uint256 coll, uint256 debt) private {
        if (coll == 0 && debt == 0) return;
        _adj(-coll.toInt256(), -debt.toInt256(), 0, true, type(uint256).max);
    }

    /// @dev Send `amountIn` to the router, call it, return what arrived (reverts if `tokenOut` left instead).
    function _route(address router, IERC20 tokenIn, uint256 amountIn, IERC20 tokenOut, bytes memory data)
        private
        returns (uint256 got)
    {
        uint256 before = tokenOut.balanceOf(address(this));
        tokenIn.safeTransfer(router, amountIn);
        ILoopRouter(router).loopSwap(address(tokenIn), amountIn, address(tokenOut), data);
        got = tokenOut.balanceOf(address(this)) - before;
    }

    /// @dev Pro-rata slice: collateral and idle balances rounded down, debt rounded up.
    function _slice(uint256 shares, uint256 supply)
        private
        view
        returns (uint256 coll, uint256 debt, uint256 idleImd, uint256 idleUsd)
    {
        if (supply == 0) return (0, 0, 0, 0);
        (uint256 c, uint256 d) = position();
        coll = Math.mulDiv(c, shares, supply);
        debt = Math.min(d, Math.mulDiv(d, shares, supply, Math.Rounding.Ceil));
        idleImd = Math.mulDiv(imd.balanceOf(address(this)), shares, supply);
        idleUsd = Math.mulDiv(usd.balanceOf(address(this)), shares, supply);
    }

    /// @dev Shares for `amount` IMD against a net value `n`. Only dead shares and nothing behind them: 1:1.
    function _sharesFor(uint256 amount, uint256 supply, int256 n) private pure returns (uint256) {
        if (supply == 0) return amount > DEAD_SHARES ? amount - DEAD_SHARES : 0;
        if (n <= 0) return supply == DEAD_SHARES && n == 0 ? amount : 0;
        return Math.mulDiv(amount, supply, uint256(n));
    }

    /// @dev min(median, spot) as last attested, stale or not (0 if never written), and the unwind's floor: that
    /// low less UNWIND_DECAY_BPS_PER_HOUR per hour since the first leg went stale (no decay while both are fresh).
    function _lastLow() private view returns (uint256 low, uint256 floor_) {
        ParametersBase.Config memory c = params.config(ilk);
        (uint256 m, uint64 mt) = c.median.latestValue();
        (uint256 s, uint64 st) = c.spot.latestValue();
        low = m == 0 ? s : (s == 0 ? m : Math.min(m, s));
        uint256 staleAt = Math.min(
            m == 0 ? type(uint256).max : mt + c.median.maxAge(), s == 0 ? type(uint256).max : st + c.spot.maxAge()
        );
        if (block.timestamp <= staleAt) return (low, low);
        uint256 cut = (block.timestamp - staleAt) * UNWIND_DECAY_BPS_PER_HOUR / 1 hours;
        floor_ = cut >= 10_000 ? 0 : Math.mulDiv(low, 10_000 - cut, 10_000);
    }

    /// @dev E4: pay the caller min(BOUNTY_USD, BOUNTY_STEP_BPS of the step) in IMD value, at most the budget, as shares
    /// at the richest known price (fewest shares), exactly as the Treasury's fee is minted.
    function _payBounty(uint256 stepUsd, uint256 sharePrice) private {
        uint256 b = bountyBudget;
        if (b == 0) return;
        uint256 usdAmt = Math.min(BOUNTY_USD, stepUsd * BOUNTY_STEP_BPS / 10_000);
        b = Math.min(b, Math.mulDiv(usdAmt, 1e18, imdPrice(sharePrice)));
        int256 n = nav(sharePrice);
        if (b == 0 || n <= b.toInt256()) return;
        uint256 shares = Math.mulDiv(b, totalSupply(), uint256(n) - b);
        if (shares == 0) return;
        bountyBudget -= b;
        _mint(msg.sender, shares);
        emit BountyPaid(msg.sender, b, shares);
    }

    /// @dev E3: one step moves at most min(MAX_STEP_BPS of the collateral's value, the flash room, the caller's cap).
    function _stepCap(uint256 v, uint256 maxStep) private view returns (uint256) {
        uint256 cap = Math.min(Math.mulDiv(v, MAX_STEP_BPS, 10_000), maxStep);
        return Math.min(cap, ILoopImdUSD(address(usd)).maxFlashLoan(address(usd)));
    }

    /// @dev E3: never lever into a peg pool trading under the peg. No peg keeper on this chain: nothing to read. A
    /// keeper whose TWAP cannot be read (e.g. NoTwap in its first 30 minutes) refuses.
    function _checkPeg() private view {
        address k = ILoopImdUSD(address(usd)).keeper();
        if (k == address(0)) return;
        try IPegTwap(k).twapTicks() returns (int24 t) {
            if (t < PEG_FLOOR_TICKS) revert BelowPeg(t);
        } catch {
            revert BelowPeg(type(int24).min);
        }
    }

    function _withinGate(Pricer.Quote memory q, uint256 live) private pure returns (bool) {
        return
            live >= Math.mulDiv(q.low, 10_000 - GATE_BPS, 10_000)
                && live <= Math.mulDiv(q.high, 10_000 + GATE_BPS, 10_000);
    }

    function _near(uint256 live, uint256 ref) private pure returns (bool) {
        return
            live >= Math.mulDiv(ref, 10_000 - GATE_BPS, 10_000) && live <= Math.mulDiv(ref, 10_000 + GATE_BPS, 10_000);
    }

    /// @dev Accrue yield (share-rate growth on the marked shares, IMD) and cost (interest on the marked debt at the
    /// position's rate, imdUSD, rounded up) since the mark. Redemptions and actions in between are not yield. When
    /// priced, charge 10% of any net gain as shares to the Treasury at the deposit leg; a deficit carries.
    function _checkpoint(Pricer.Quote memory q, uint256 live) private {
        (uint256 c, uint256 d) = position();
        uint256 sh = Math.min(sharesMark, c);
        uint256 rateNow = staked.convertToAssets(1e18);
        pendingYield += Math.mulDiv(sh, rateNow, 1e18).toInt256() - Math.mulDiv(sh, rateMark, 1e18).toInt256();
        uint256 rate = ledger.position(positionId).rate;
        pendingCost += Math.mulDiv(
            Math.min(debtMark, d), rate * (block.timestamp - markAt), YEAR * 1e18, Math.Rounding.Ceil
        );
        (sharesMark, rateMark, debtMark, markAt) = (c, rateNow, d, block.timestamp);
        if (!q.priced) return;
        int256 net = pendingYield - Math.mulDiv(pendingCost, 1e18, imdPrice(q.low), Math.Rounding.Ceil).toInt256();
        if (net <= 0) return;
        uint256 fee = uint256(net) * PERFORMANCE_FEE_BPS / 10_000;
        uint256 supply = totalSupply();
        int256 n = nav(Math.max(q.high, live));
        if (fee == 0 || supply == 0 || n <= fee.toInt256()) return;
        // E4: the bounty budget is topped up first, out of the fee (never out of principal).
        uint256 room = Math.mulDiv(BOUNTY_BUDGET_USD, 1e18, imdPrice(q.low));
        uint256 topUp = bountyBudget < room ? Math.min(fee, room - bountyBudget) : 0;
        uint256 toTreasury = fee - topUp;
        uint256 shares = toTreasury == 0 ? 0 : Math.mulDiv(toTreasury, supply, uint256(n) - toTreasury);
        if (shares == 0 && topUp == 0) return;
        (pendingYield, pendingCost) = (0, 0);
        bountyBudget += topUp;
        if (shares != 0) _mint(treasury, shares);
        emit FeeCharged(fee, shares);
    }

    /// @dev E7: the hold travels with new shares: a mint stamps the receiver, and so does a transfer from a holder
    /// stamped this block (only fresh shares' owners can pass a stamp on, so nobody can stamp a stranger for free).
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to != address(0) && (from == address(0) || heldAt[from] == block.number)) heldAt[to] = block.number;
    }

    function _mark() private {
        (uint256 c, uint256 d) = position();
        (sharesMark, rateMark, debtMark, markAt) = (c, staked.convertToAssets(1e18), d, block.timestamp);
    }
}
