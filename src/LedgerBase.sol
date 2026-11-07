// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TransientReentrancyGuard} from "./TransientReentrancyGuard.sol";
import {ImdUSD} from "./ImdUSD.sol";
import {ParametersBase} from "./ParametersBase.sol";
import {Parameters} from "./Parameters.sol";
import {Pricer} from "./Pricer.sol";
import {Join} from "./Join.sol";
import {SortedPositions} from "./SortedPositions.sol";
import {IERC4626Min} from "./interfaces/IERC4626Min.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {Adjust, IHolderJoin} from "./interfaces/IPositions.sol";

interface IRateSource {
    function rate() external view returns (uint256);
}

interface IPulse {
    function poke() external;
}

interface ISavingsAssets {
    /// @dev The vault's assets less this block's deposits (SavingsVault.settledAssets): the flash-proof uptake figure.
    function settledAssets() external view returns (uint256);
    /// @dev Fold arrivals into the vesting stream (SavingsVault.sync), so vesting starts at arrival.
    function sync() external;
}

/// @notice What the Ledger calls on the edge Backstop sleeve.
interface IEdgeSleeve {
    function sync() external;
    function edgeCapacity(bytes32 ilk, uint256 inAuction) external view returns (uint256);
}

/// @notice The Liquidator's running total of edge-type debt under a live mark.
interface IEdgeAuctions {
    function edgeInAuction() external view returns (uint256);
}

/// @dev An auction type's join: void the position's auction, if it is healthy or has no debt.
interface IAuctionJoin {
    function cancel(uint256 id) external;
}

interface IRevenueMeter {
    function noteRevenue(bytes32 ilk, uint256 amount) external;
}

/// @notice Shared state, events and helpers of the Ledger and its settlement module (size split). The
/// Ledger delegate-calls LedgerSettlement for redemption, liquidation and write-off: one fixed module, deployed by the
/// Ledger's own constructor with the same immutables, so both run the same helpers on the same storage. Nothing is
/// upgradeable.
///
/// Positions by id: collateral of one type, debt, a borrower-set rate. Mints and burns imdUSD.
/// The Redeemer and Liquidator act on positions only through the module functions here.
///
/// POSITIONS ARE ACCOUNTS. Each position is an ERC-721 of `nft` (PositionNFT), any number per owner and type, its whole
/// state under its id (a transfer carries the rate, cooldown and premium rate). Ids are counterfactual:
/// `positionId(owner, ilk, salt)` is known before the position exists, so a batch (EIP-5792), a signature or a contract can
/// name it in advance; `open` creates it on first use (for the caller), `PositionNFT.openFor` for a signer. The owner can do anything;
/// an operator only what the owner granted on the NFT (ADD, REPAY, SET_RATE, WITHDRAW / BORROW to the owner, WITHDRAW_ANY /
/// BORROW_ANY to any address). Anyone may add collateral to (`addFor`) or repay (`repayFor`) any position.
/// HOLDER-BOUND TYPES (a join that is its own token: seats). Their units follow the seats' holder, so collateral of such a
/// position comes only from its owner and leaves only to its owner, and a transfer moves the seats (`IHolderJoin`).
///
/// INTEREST. Each position accrues simple interest at its own annual rate on its recorded
/// debt since its last touch. The type keeps `weighted = Σ debt_i * rate_i`, so the interest the whole
/// type has accrued is `weighted * dt` and is minted to the Treasury on every touch without visiting
/// each position (Liquity v2's aggregate pattern). The aggregate rounds UP and each position rounds
/// down, so the type's recorded debt is never below the sum of its positions'.
///
/// SUPPLY (invariant): at rest,
///   token.totalSupply() == Σ ilk.debt + Σ ilk.badDebt + reserveBacked + migrator outstanding + peg keeper outstanding
///                          + bridge.received − bridge.sent   (ImdBridge's cumulative mints and burns on this chain)
/// Every function below moves the two sides together.
///
/// YIELD. For a type with a `yieldRate`, a position with debt pays down that debt from its
/// collateral's yield: on every touch (and on `harvest`) the shares that are pure yield since the last
/// harvest, measured at the CAPPED share rate, move to the Treasury; 1 - yieldFee of their value is
/// credited against the debt. The debt so cancelled is now backed by the Treasury's shares instead of a
/// position, which is `reserveBacked`. A position with no debt keeps its yield (its high-water mark just
/// follows the rate), so no yield is ever taken from a period with nothing to repay.
abstract contract LedgerBase is TransientReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct Position {
        uint128 collateral;
        uint128 debt; // recorded at lastUpdate
        uint64 rate; // annual, 1e18
        uint64 lastUpdate;
        uint64 lastRateChange;
        uint64 premiumRate; // the rate before the last rate change: debt added inside the cooldown pays 7 days of it
        uint192 yieldMark; // capped share rate at the last harvest (high-water mark)
        uint32 version; // liquidation-risk version bound at the last risk-increasing action
    }

    struct IlkState {
        uint128 debt; // Σ position debt incl. interest accrued to lastAccrual
        uint128 collateral;
        uint256 weighted; // Σ debt_i * rate_i (1e36)
        uint64 lastAccrual;
        uint128 badDebt; // debt liquidation could not cover, still in circulation
    }

    // PositionNFT's rights (kept equal to its constants)
    uint8 internal constant RIGHT_ADD = 1;
    uint8 internal constant RIGHT_REPAY = 2;
    uint8 internal constant RIGHT_SET_RATE = 4;
    uint8 internal constant RIGHT_WITHDRAW = 8;
    uint8 internal constant RIGHT_BORROW = 16;
    uint8 internal constant RIGHT_WITHDRAW_ANY = 32;
    uint8 internal constant RIGHT_BORROW_ANY = 64;

    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_RATE = 1e18; // 100% a year
    /// @dev Changing your rate within this long of your last change pays this long of interest at the OLD rate on the
    /// debt (either direction, as Liquity v2: a free raise would spike the type's average and tax every newcomer's
    /// upfront fee, and raise-ahead-of-a-redemption would be free). Debt added inside the cooldown pays the
    /// same on the added amount at `premiumRate` (the rate before the change), so a dust reopen followed by a top-up
    /// costs what one reopen does. A position's rate and `lastRateChange` survive a repayment (or redemption) to
    /// zero, so reopening at another rate inside the cooldown pays the premium (a flash mint cannot launder a rate drop).
    uint256 public constant RATE_COOLDOWN = 7 days;
    /// @notice `writeOff` needs the custody worthless at two readings this far apart, the first no older than the window:
    /// an issuer's burn-then-reissue inside an hour writes nothing off. 1 h = a keeper's polling horizon and well
    /// inside the 4663 Pulse grace; the debt keeps accruing on a worthless type meanwhile, which is all the delay costs.
    uint256 public constant WRITEOFF_DELAY = 1 hours;
    uint256 public constant WRITEOFF_WINDOW = 7 days;
    /// @notice The least of each accrual savers get while there are any: the effective share scales with uptake
    /// between this floor and `Parameters.savingsShare`.
    uint256 public constant SAVINGS_FLOOR = 0.05e18;

    ImdUSD public immutable token;
    Parameters public immutable params;
    Pricer public immutable pricer;
    SortedPositions public immutable sorted;
    PositionNFT public immutable nft;
    address public immutable treasury;
    address public immutable wirer;
    /// @notice The chain's sequencer-outage grace, poked on every accrual; zero on chains that do not use one (mainnet).
    IPulse public immutable pulse;

    address public redeemer;
    address public liquidator;

    mapping(uint256 id => Position) internal _positions;
    /// @notice The collateral type of a position (zero: no such position).
    mapping(uint256 id => bytes32) public ilkOf;
    mapping(bytes32 ilk => IlkState) public ilkState;

    /// @notice imdUSD whose position debt was repaid by harvested yield now held by the Treasury.
    uint256 public reserveBacked;
    /// @notice Σ ilkState.badDebt over every type: what liquidation could not cover and nobody has burned yet.
    uint256 public totalBadDebt;
    /// @notice When `writeOff` first saw `ilk`'s custody worth nothing (0 = not seen, or seen worth something since).
    mapping(bytes32 ilk => uint256) public worthlessSince;

    error Unauthorized();
    /// @notice Unbacked supply (`unbacked()`) is past `Parameters.unbackedBrake` of the circulating supply: no new debt on
    /// any type until cover (`Treasury.coverBadDebt`, anyone's `cover`) brings it back under.
    error Braked(uint256 unbacked, uint256 allowed);
    error AlreadyWired();
    error UnknownIlk();
    error RateOutOfRange();
    error NotPriced();
    error Unhealthy();
    error CeilingExceeded();
    error DustDebt();
    error InsufficientCollateral();
    error NoDebt();
    error NotYieldBearing();
    error ExcessRepayment();
    error ChainLineExceeded();
    error GroupLineExceeded();
    error NotWorthless();
    error WriteOffTooSoon(uint256 at);
    error UpfrontFeeTooHigh(uint256 fee);
    error UnknownPosition();
    error WrongType();
    error HolderBound();
    error NotOwner();
    /// @notice The summed debt of the edge types would exceed what the edge sleeve stands behind.
    error EdgeCapacityExceeded(uint256 debt, uint256 capacity);

    event Opened(uint256 indexed id, bytes32 indexed ilk, address indexed owner, uint256 salt);
    event Adjusted(uint256 indexed id, bytes32 indexed ilk, int256 dCollateral, int256 dDebt, uint256 debt);
    event RateSet(uint256 indexed id, bytes32 indexed ilk, uint256 rate, uint256 premium);
    event Harvested(uint256 indexed id, bytes32 indexed ilk, uint256 shares, uint256 credit);
    event InterestMinted(bytes32 indexed ilk, uint256 amount);
    event Redeemed(uint256 indexed id, bytes32 indexed ilk, uint256 debt, uint256 collateral);
    event Liquidated(uint256 indexed id, bytes32 indexed ilk, uint256 repaid, uint256 seized, uint256 badDebt);
    event Covered(bytes32 indexed ilk, uint256 amount);
    event UpfrontFee(uint256 indexed id, bytes32 indexed ilk, uint256 fee);
    event Retired(uint256 amount);

    constructor(
        ImdUSD token_,
        Parameters params_,
        Pricer pricer_,
        address treasury_,
        address wirer_,
        IPulse pulse_,
        SortedPositions sorted_,
        PositionNFT nft_
    ) {
        token = token_;
        pulse = pulse_;
        params = params_;
        pricer = pricer_;
        treasury = treasury_;
        wirer = wirer_;
        sorted = sorted_;
        nft = nft_;
    }

    /// @notice Supply nothing backs: Σ bad debt less the imdUSD the Treasury holds and could burn against it
    /// (`Treasury.coverBadDebt`). The loss absorber of last resort is the holder: the Treasury's other assets reach bad
    /// debt only through a Safe sale. Ops alert on any non-zero reading; the brake acts on it.
    function unbacked() public view returns (uint256) {
        uint256 bad = totalBadDebt;
        uint256 cover_ = token.balanceOf(treasury);
        return bad > cover_ ? bad - cover_ : 0;
    }


    // ================================================================ internals

    /// @dev The type's quote, or an unpriced one if a feed reverts outright: repayment and deposits never need a price, so
    /// a broken feed must not block them. Everything that needs a price checks `priced`/`borrowable` and still refuses.
    function _quote(bytes32 ilk) internal view returns (Pricer.Quote memory q) {
        try pricer.quote(ilk) returns (Pricer.Quote memory got) {
            q = got;
        } catch {}
    }

    function _ilkOf(uint256 id) internal view returns (bytes32 ilk) {
        ilk = ilkOf[id];
        if (ilk == bytes32(0)) revert UnknownPosition();
    }

    function _config(bytes32 ilk) internal view returns (ParametersBase.Config memory c) {
        c = params.config(ilk);
        if (c.token == address(0)) revert UnknownIlk();
    }

    function _accrue(bytes32 ilk, IlkState storage s) internal {
        if (address(pulse) != address(0)) pulse.poke();
        uint256 dt = block.timestamp - s.lastAccrual;
        if (dt == 0) return;
        s.lastAccrual = uint64(block.timestamp);
        if (s.weighted == 0) return;
        uint256 interest = Math.mulDiv(s.weighted, dt, YEAR * 1e18, Math.Rounding.Ceil);
        s.debt += interest.toUint128();
        _mintInterest(ilk, interest);
        emit InterestMinted(ilk, interest);
    }

    /// @dev Interest goes to the Treasury, less the savers' share to sImdUSD while
    /// the vault has savers. With none, it all goes to the Treasury: nobody would own it. The Treasury's
    /// part is reported to its revenue meter (the fee-note cap).
    function _mintInterest(bytes32 ilk, uint256 amount) internal {
        (address savings, uint256 share) = params.savingsSplit();
        uint256 toSavings;
        if (share != 0 && IERC20(savings).totalSupply() != 0) {
            // Effective share = min(share, max(SAVINGS_FLOOR, saved / supply)): savers are paid in proportion to how much
            // of the coin they hold, so a small vault does not take most of the interest. Both figures are flash-proof:
            // `saved` is the vault's assets less this block's deposits (a flash mint parked in the
            // vault for the call counts for nothing, and an empty vault stays empty), `supply` is THIS chain's
            // circulating supply (totalSupply less flash loans in flight; bridged-in imdUSD included, other chains'
            // excluded): each chain's vault splits only its own chain's interest.
            uint256 saved = ISavingsAssets(savings).settledAssets();
            uint256 supply = token.circulating();
            uint256 uptake = supply == 0 ? 0 : Math.mulDiv(saved, 1e18, supply);
            if (uptake < SAVINGS_FLOOR) uptake = SAVINGS_FLOOR;
            if (uptake < share) share = uptake;
            if (saved != 0) toSavings = Math.mulDiv(amount, share, 1e18);
            if (toSavings != 0) {
                token.mint(savings, toSavings);
                ISavingsAssets(savings).sync(); // vesting starts at arrival, not at the next deposit
            }
        }
        // The edge sleeve takes its premium from an edge type's interest after the savers: first loss is paid for.
        if (amount > toSavings && params.edgeIlk(ilk)) {
            address edge = params.edgeBackstop();
            uint256 toEdge = Math.min(Math.mulDiv(amount, params.edgePremium(), 1e18), amount - toSavings);
            if (toEdge != 0) {
                token.mint(edge, toEdge);
                IEdgeSleeve(edge).sync(); // streams over 7 days; a no-op inside an open bid (closeBid counts it then)
                toSavings += toEdge; // so the Treasury gets the rest
            }
        }
        if (amount > toSavings) {
            uint256 toTreasury = amount - toSavings;
            token.mint(treasury, toTreasury);
            IRevenueMeter(treasury).noteRevenue(ilk, toTreasury);
        }
    }

    /// @dev amount x average rate x RATE_COOLDOWN / YEAR, rounded up. Average = Σ debt_i rate_i / the type's debt (recorded
    /// at the last accrual, so marginally below the exact figure); `ownRate` when the type has no borrower. "No borrower"
    /// is `weighted == 0`, not `debt == 0`: the type's debt keeps a rounding residue after its last position closes
    /// (the aggregate rounds up, each position down), which would otherwise read as an average of zero.
    /// `harvested`: what this call's harvest took off `s.debt` so far. `s.weighted` moves only when the position is recorded,
    /// so without it a borrower harvested to nothing divides by zero, or by a residue.
    function _upfrontFee(IlkState storage s, uint256 amount, uint256 ownRate, uint256 harvested) internal view returns (uint256) {
        uint256 avg = s.weighted == 0 ? ownRate : s.weighted / (s.debt + harvested);
        return _premium(amount, avg);
    }

    /// @dev RATE_COOLDOWN of interest on `amount` at `rate`, rounded up.
    function _premium(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return Math.mulDiv(amount, rate * RATE_COOLDOWN, YEAR * 1e18, Math.Rounding.Ceil);
    }

    /// @dev F3's brake: new debt stops on every type while `unbacked()` exceeds the governed fraction of the circulating
    /// supply. Cover (Treasury or anyone burning imdUSD against the hole) releases it.
    function _checkBrake() internal view {
        uint256 u = unbacked();
        if (u == 0) return;
        uint256 allowed = Math.mulDiv(token.circulating(), params.unbackedBrake(), 1e18);
        if (u > allowed) revert Braked(u, allowed);
    }

    function _debtOf(Position storage p) internal view returns (uint256) {
        uint256 d = p.debt;
        if (d == 0) return 0;
        return d + Math.mulDiv(d, uint256(p.rate) * (block.timestamp - p.lastUpdate), YEAR * 1e18);
    }

    /// @dev Write the position's new recorded debt and rate, and move the type's weighted sum with it.
    function _record(
        IlkState storage s,
        Position storage p,
        uint256 oldDebt,
        uint256 oldRate,
        uint256 newDebt,
        uint256 newRate
    ) internal {
        s.weighted = s.weighted - oldDebt * oldRate + newDebt * newRate;
        p.debt = newDebt.toUint128();
        p.rate = newRate.toUint64();
        p.lastUpdate = uint64(block.timestamp);
    }

    /// @dev Pay `debt` down from yield accrued since `p.yieldMark` (see the contract docstring). Returns
    /// the new debt. Does not write `p.debt`; the caller records it. Skips when unpriced.
    function _harvest(
        bytes32 ilk,
        uint256 id,
        ParametersBase.Config memory c,
        ParametersBase.Risk memory r,
        Pricer.Quote memory q,
        IlkState storage s,
        Position storage p,
        uint256 debt
    ) internal returns (uint256) {
        if (c.yieldRate == address(0)) return debt;
        uint256 rateNow = IRateSource(c.yieldRate).rate();
        uint256 mark = p.yieldMark;
        if (rateNow == 0 || rateNow <= mark) return debt; // a loss is never harvested; the mark holds
        if (debt == 0 || mark == 0 || p.collateral == 0) {
            p.yieldMark = uint192(rateNow);
            return debt;
        }
        if (!q.priced) return debt; // keep the mark: harvest later at a trustworthy price
        uint256 yieldShares = Math.mulDiv(p.collateral, rateNow - mark, rateNow);
        uint256 net = Math.mulDiv(Math.mulDiv(yieldShares, q.low, 1e18), 1e18 - r.yieldFee, 1e18);
        uint256 credit = Math.min(net, debt);
        uint256 taken = credit == net ? yieldShares : Math.mulDiv(yieldShares, credit, net, Math.Rounding.Ceil);
        p.yieldMark = uint192(rateNow);
        if (credit == 0) return debt;
        p.collateral -= taken.toUint128();
        s.collateral -= taken.toUint128();
        s.debt -= credit.toUint128();
        reserveBacked += credit;
        Join(c.join).exit(treasury, taken);
        emit Harvested(id, ilk, taken, credit);
        return debt - credit;
    }

    /// @dev A deposit while the mark lags the rate (harvest skipped because unpriced) must not let the new
    /// shares be harvested for yield they never earned: move the mark so the position's unharvested yield
    /// is unchanged, i.e. mark' = rate - old * (rate - mark) / (old + added).
    function _blendMark(address rateSource, Position storage p, uint256 added) internal {
        uint256 rateNow = IRateSource(rateSource).rate();
        uint256 mark = p.yieldMark;
        if (rateNow == 0 || mark == 0 || rateNow <= mark) return;
        uint256 old = p.collateral;
        p.yieldMark = uint192(rateNow - Math.mulDiv(old, rateNow - mark, old + added));
    }

    /// @dev The chain's global cap and the borrowing type's group cap (stock + SGOV debt within 25% of the
    /// chain line), checked only where debt is created: Σ recorded debt + bad debt over every type (over the group's types) must
    /// stay within `Parameters.chainLine` when the chain is capped (within the group's line when the type is in a group). Kept
    /// out of storage (one loop over the few types, on the borrow path only) so no other path changes.
    function _checkLines(bytes32 ilk) internal view {
        (bool capped, uint256 line) = params.chainCap();
        (uint8 group, uint256 gLine) = params.groupCap(ilk);
        if (!capped && group == 0) return;
        uint256 n = params.ilkCount();
        uint256 total;
        uint256 inGroup;
        for (uint256 i; i < n; ++i) {
            bytes32 k = params.ilks(i);
            IlkState storage t = ilkState[k];
            uint256 d = uint256(t.debt) + t.badDebt;
            total += d;
            if (group != 0 && params.groupOf(k) == group) inGroup += d;
        }
        if (capped && total > line) revert ChainLineExceeded();
        if (inGroup > gLine && group != 0) revert GroupLineExceeded();
    }

    /// @dev The SUM of every edge type's debt (incl. bad debt) stays within what the edge sleeve stands behind
    /// for the borrowing type, less the edge debt under a live mark. Checked only where an edge type's debt is created.
    function _checkEdge(bytes32 ilk) internal view {
        if (!params.edgeIlk(ilk)) return;
        uint256 n = params.edgeIlkCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            IlkState storage t = ilkState[params.edgeIlks(i)];
            sum += uint256(t.debt) + t.badDebt;
        }
        uint256 cap = IEdgeSleeve(params.edgeBackstop()).edgeCapacity(ilk, IEdgeAuctions(liquidator).edgeInAuction());
        if (sum > cap) revert EdgeCapacityExceeded(sum, cap);
    }

    /// @dev Partial liquidation to the type's target (Aave v4's target health factor): the debt `x` to repay so
    /// that (C - x(1+chop)/P) P >= T (D - x), T = mat + targetBuffer, i.e. x = (T D - C P) / (T - 1 - chop), rounded up.
    /// Returns `debt` (close in full) when the type closes in full (buffer 0), the collateral cannot pay the full debt plus
    /// penalty, the target is not above 1 + chop (no repayment can raise the ratio then), or the remainder would be dust.
    function _liquidationNeed(
        uint256 collateral,
        uint256 debt,
        uint256 price,
        uint256 mat,
        uint256 chop,
        uint256 buffer,
        uint256 dust
    ) internal pure returns (uint256) {
        if (buffer == 0 || debt == 0) return debt;
        if (Math.mulDiv(Math.mulDiv(debt, 1e18, price), 1e18 + chop, 1e18, Math.Rounding.Ceil) > collateral) return debt;
        uint256 t = mat + buffer;
        if (t <= 1e18 + chop) return debt;
        uint256 owed = Math.mulDiv(debt, t, 1e18, Math.Rounding.Ceil);
        uint256 worth = Math.mulDiv(collateral, price, 1e18);
        if (owed <= worth) return 0; // already at the target: nothing to take
        uint256 need = Math.mulDiv(owed - worth, 1e18, t - 1e18 - chop, Math.Rounding.Ceil);
        if (need >= debt || debt - need < dust) return debt;
        return need;
    }

    /// @dev The mat and chop that bind `p` for liquidation now: its version's, or a newer bound version's;
    /// `liveMat` (the quote's) on an NHI-linked type.
    function _liq(bytes32 ilk, Position storage p, uint256 liveMat) internal view returns (uint256 mat, uint256 chop) {
        (mat, chop) = params.liqRisk(ilk, p.version);
        if (mat == 0) mat = liveMat;
    }

    function _healthy(uint256 collateral, uint256 debt, uint256 price, uint256 mat) internal pure returns (bool) {
        if (debt == 0) return true;
        return Math.mulDiv(collateral, price, 1e18) >= Math.mulDiv(debt, mat, 1e18, Math.Rounding.Ceil);
    }

    /// @dev Keep the redemption order equal to {positions with recorded debt}, sorted by rate.
    function _relist(
        bytes32 ilk,
        uint256 id,
        bool listed,
        bool has,
        bool rateChanged,
        uint256 prevHint,
        uint256 nextHint
    ) internal {
        uint64 rate = _positions[id].rate;
        if (!listed && has) sorted.insert(ilk, id, rate, prevHint, nextHint);
        else if (listed && !has) sorted.remove(ilk, id);
        else if (listed && has && rateChanged) sorted.reinsert(ilk, id, rate, prevHint, nextHint);
    }}
