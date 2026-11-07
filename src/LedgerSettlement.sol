// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ImdUSD} from "./ImdUSD.sol";
import {ParametersBase} from "./ParametersBase.sol";
import {Parameters} from "./Parameters.sol";
import {Pricer} from "./Pricer.sol";
import {Join} from "./Join.sol";
import {SortedPositions} from "./SortedPositions.sol";
import {IERC4626Min} from "./interfaces/IERC4626Min.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {Adjust, IHolderJoin} from "./interfaces/IPositions.sol";
import {LedgerBase, IPulse, IRateSource, ISavingsAssets, IRevenueMeter} from "./LedgerBase.sol";

/// @notice The Ledger's redemption, liquidation and write-off (size split). Runs ONLY by delegatecall from the
/// Ledger that deployed it (`onlyLedger`), on that Ledger's storage, with the same immutables; a direct call reverts. Fixed
/// at deployment: nothing here or in the Ledger can point it anywhere else.
contract LedgerSettlement is LedgerBase {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The Ledger this module serves: `address(this)` inside a delegatecall from it.
    address public immutable ledger;

    error DirectCall();
    error NotUnhealthyAtTarget();

    modifier onlyLedger() {
        if (address(this) != ledger) revert DirectCall();
        _;
    }

    constructor(
        ImdUSD token_,
        Parameters params_,
        Pricer pricer_,
        address treasury_,
        address wirer_,
        IPulse pulse_,
        SortedPositions sorted_,
        PositionNFT nft_
    ) LedgerBase(token_, params_, pricer_, treasury_, wirer_, pulse_, sorted_, nft_) {
        ledger = msg.sender;
    }

    // ================================================================ module actions (run by delegatecall from the Ledger)

    /// @notice Redeemer: take up to `maxDebt` of this position's debt for collateral at `price`, less `fee`.
    /// The position gives up exactly `taken / price` of collateral for `taken` of debt (whole on the principal); the
    /// redeemer receives it less the fee, and the fee's collateral goes to the Treasury (left in the position it
    /// made self-redemption free). Skips (returns 0) a position whose collateral is worth less than its debt. Leaves
    /// either no debt or at least dust.
    function redeemPosition(uint256 id, uint256 maxDebt, uint256 price, uint256 fee, address to)
        external
        onlyLedger
        nonReentrant // the Ledger's own lock slot (delegatecall), so a hook token cannot re-enter mid-adjust
        returns (uint256 taken, uint256 collateralOut)
    {
        if (msg.sender != redeemer) revert Unauthorized();
        bytes32 ilk = ilkOf[id];
        ParametersBase.Config memory c = params.config(ilk);
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        Position storage p = _positions[id];
        IlkState storage s = ilkState[ilk];
        _accrue(ilk, s);
        uint256 oldDebt = p.debt;
        Pricer.Quote memory q; // only a yield type's harvest reads it; the Redeemer has already quoted this type
        if (c.yieldRate != address(0)) q = pricer.quote(ilk);
        uint256 debt = _harvest(ilk, id, c, r, q, s, p, _debtOf(p));
        // Skipped: worth less than its debt, or a dust-sized remainder that cannot be split.
        bool skip = debt == 0 || Math.mulDiv(p.collateral, price, 1e18) < debt;
        if (!skip) {
            taken = Math.min(maxDebt, debt);
            if (taken < debt && debt - taken < r.dust) {
                if (debt <= r.dust) skip = true;
                else taken = debt - r.dust;
            }
        }
        uint256 gross; // $1 of collateral per imdUSD taken, at `price`
        if (skip) {
            taken = 0;
        } else {
            gross = Math.mulDiv(taken, 1e18, price);
            collateralOut = Math.mulDiv(gross, 1e18 - fee, 1e18);
        }
        // Recorded either way: a skipped position's harvest still has to land.
        p.collateral -= gross.toUint128();
        s.collateral -= gross.toUint128();
        s.debt -= taken.toUint128();
        _record(s, p, oldDebt, p.rate, debt - taken, p.rate);
        if (c.redeemable) _relist(ilk, id, oldDebt != 0, debt != taken, false, 0, 0);
        if (collateralOut != 0) Join(c.join).exit(to, collateralOut);
        if (gross > collateralOut) Join(c.join).exit(treasury, gross - collateralOut);
        if (taken != 0) emit Redeemed(id, ilk, taken, collateralOut);
    }

    /// @notice Liquidator: close this position. `payer` pays the debt the collateral covers and receives
    /// the collateral less the Treasury's `cut` and the marker's `chip` of the penalty. Debt the
    /// collateral cannot cover becomes the type's bad debt. Health is checked by the Liquidator.
    /// `reserve` (an auction join that sold the position for a reserve asset the Treasury now holds, e.g. USDG): the
    /// debt is not burned; the imdUSD stays in circulation backed by that asset, as `reserveBacked` (the yield burn path
    /// retires it later), exactly as harvested yield repays debt.
    function liquidatePosition(uint256 id, uint256 price, address payer, address marker, bool reserve)
        external
        onlyLedger
        nonReentrant // the Ledger's own lock slot (delegatecall)
        returns (uint256 repaid, uint256 seized, uint256 bad)
    {
        if (msg.sender != liquidator) revert Unauthorized();
        bytes32 ilk = ilkOf[id];
        ParametersBase.Config memory c = params.config(ilk);
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        Position storage p = _positions[id];
        IlkState storage s = ilkState[ilk];
        _accrue(ilk, s);
        uint256 debt = _debtOf(p);
        if (debt == 0) revert NoDebt();
        // The position's bound version sets the penalty and the target (mat), not the type's newest.
        (uint256 vMat, uint256 vChop) = _liq(ilk, p, pricer.quote(ilk).mat);
        r.chop = uint64(vChop);
        // SOLVENCY BEFORE PENALTY. The collateral's worth repays the debt FIRST; the penalty (and the
        // Treasury's and marker's cuts of it) comes only from what is left, and bad debt is booked only when the
        // collateral is worth less than the debt. (Maker's convention, penalty first, booked avoidable bad debt in the
        // band 100% <= CR < 1 + chop and paid the Treasury in collateral while doing so.)
        uint256 bonus;
        if (c.auction) {
            // Non-fungible: every unit goes, at the price the auction's taker paid for the whole position.
            // The join settles what the taker paid: debt burned here, the penalty's cuts below, the rest to the
            // borrower. Only the penalty carries a bonus, and only out of what the sale left after the debt.
            seized = p.collateral;
            uint256 paid = Math.mulDiv(seized, price, 1e18);
            repaid = Math.min(debt, paid);
            bad = debt - repaid;
            bonus = Math.mulDiv(Math.min(paid - repaid, Math.mulDiv(repaid, r.chop, 1e18)), 1e18, price);
        } else {
            uint256 full = Math.mulDiv(Math.mulDiv(debt, 1e18, price), 1e18 + r.chop, 1e18, Math.Rounding.Ceil);
            // On a type with a target buffer, repay only what restores mat + buffer (the dust rule and the
            // can't-cover case close in full, inside `_liquidationNeed`).
            uint256 need = debt;
            uint256 buffer = params.targetBuffer(ilk);
            if (buffer != 0) {
                need = _liquidationNeed(p.collateral, debt, price, vMat, r.chop, buffer, r.dust);
                if (need == 0) revert NotUnhealthyAtTarget();
            }
            if (need < debt) {
                repaid = need;
                seized = Math.mulDiv(Math.mulDiv(need, 1e18, price), 1e18 + r.chop, 1e18, Math.Rounding.Ceil);
            } else if (full <= p.collateral) {
                repaid = debt;
                seized = full;
            } else {
                seized = p.collateral;
                repaid = Math.min(debt, Math.mulDiv(seized, price, 1e18));
                bad = debt - repaid;
            }
            bonus = seized - Math.min(seized, Math.mulDiv(repaid, 1e18, price));
        }
        // A position that books bad debt pays the Treasury nothing: its cut would be collateral the Treasury cannot burn
        // against the hole it is being paid out of.
        uint256 toTreasury = bad == 0 ? Math.mulDiv(bonus, r.cut, 1e18) : 0;
        uint256 toMarker = Math.mulDiv(bonus, r.chip, 1e18);

        uint256 oldDebt = p.debt;
        p.collateral -= seized.toUint128();
        s.collateral -= seized.toUint128();
        uint256 left = debt - repaid - bad; // non-zero only after a partial liquidation
        s.debt -= (debt - left).toUint128();
        s.badDebt += bad.toUint128();
        totalBadDebt += bad;
        if (left != 0) {
            // Partial: the position stays open at its own rate and place in the redemption order.
            _record(s, p, oldDebt, p.rate, left, p.rate);
        } else {
            // A liquidated position forgets its rate (it cannot be self-induced for free: the penalty dwarfs the
            // premium), so reopening after a liquidation is a fresh open. Repayment and redemption to zero keep it.
            _record(s, p, oldDebt, p.rate, 0, 0);
            if (c.redeemable) _relist(ilk, id, oldDebt != 0, false, false, 0, 0);
        }

        if (reserve) reserveBacked += repaid;
        else token.burn(payer, repaid);
        Join join = Join(c.join);
        if (toTreasury != 0) join.exit(treasury, toTreasury);
        if (toMarker != 0) _exitMarker(join, marker, toMarker);
        join.exit(payer, seized - toTreasury - toMarker);
        emit Liquidated(id, ilk, repaid, seized, bad);
    }

    /// @dev A marker the collateral token refuses (blocklisted, paused for it) must not freeze the
    /// liquidation: its chip goes to the Treasury instead. (A helper keeps liquidatePosition's stack within solc's reach.)
    function _exitMarker(Join join, address marker, uint256 amount) private {
        try join.exit(marker, amount) {}
        catch {
            join.exit(treasury, amount);
        }
    }

    /// @notice Realise a position whose collateral its issuer has destroyed: permissionless, only while one whole
    /// share of the type's ERC-4626 custody redeems for nothing (`convertToAssets(1e18) == 0`, e.g. the issuer `adminBurn`ed
    /// the vault's stock). No price is needed, or available: such a type reads unpriced. The debt becomes the type's bad debt
    /// (covered by the Treasury's `coverBadDebt`, the type's own surplus first) and the seized shares go to the Treasury:
    /// if the issuer reissues (burn-then-reissue for a migration or corporate action), the value is governable,
    /// not stranded in the Join. A type whose custody keeps any value is liquidated instead, at a price.
    /// STICKY ZERO: two readings >= WRITEOFF_DELAY apart. The first call that sees the custody worthless only
    /// records the time; a call that sees it worth something again clears that record (and returns, so the clearing
    /// persists); a record older than WRITEOFF_WINDOW is re-armed rather than trusted. A reissue inside the delay writes
    /// nothing off.
    function writeOff(uint256 id) external onlyLedger nonReentrant {
        bytes32 ilk = _ilkOf(id);
        ParametersBase.Config memory c = _config(ilk);
        uint256 since = worthlessSince[ilk];
        if (IERC4626Min(c.token).convertToAssets(1e18) != 0) {
            if (since == 0) revert NotWorthless();
            delete worthlessSince[ilk];
            return;
        }
        if (since == 0 || block.timestamp > since + WRITEOFF_WINDOW) {
            worthlessSince[ilk] = block.timestamp;
            return;
        }
        if (block.timestamp < since + WRITEOFF_DELAY) revert WriteOffTooSoon(since + WRITEOFF_DELAY);
        Position storage p = _positions[id];
        IlkState storage s = ilkState[ilk];
        _accrue(ilk, s);
        uint256 debt = _debtOf(p);
        if (debt == 0) revert NoDebt();
        uint256 oldDebt = p.debt;
        uint256 seized = p.collateral;
        s.collateral -= p.collateral;
        p.collateral = 0;
        s.debt -= debt.toUint128();
        s.badDebt += debt.toUint128();
        totalBadDebt += debt;
        _record(s, p, oldDebt, p.rate, 0, 0); // as a liquidation: the rate is forgotten
        if (c.redeemable) _relist(ilk, id, true, false, false, 0, 0);
        if (seized != 0) Join(c.join).exit(treasury, seized);
        emit Liquidated(id, ilk, 0, seized, debt);
    }

}
