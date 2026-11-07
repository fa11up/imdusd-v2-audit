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
import {LedgerBase, IAuctionJoin, IPulse, IRateSource, ISavingsAssets, IRevenueMeter} from "./LedgerBase.sol";
import {LedgerSettlement} from "./LedgerSettlement.sol";

/// @notice Positions by id: collateral of one type, debt, a borrower-set rate. Mints and burns imdUSD.
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
contract Ledger is LedgerBase {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The settlement module this Ledger delegate-calls (deployed by this constructor; fixed).
    address public immutable settlement;

    constructor(
        ImdUSD token_,
        Parameters params_,
        Pricer pricer_,
        address treasury_,
        address wirer_,
        IPulse pulse_,
        PositionNFT nft_
    )
        LedgerBase(
            token_,
            params_,
            pricer_,
            treasury_,
            wirer_,
            pulse_,
            new SortedPositions(address(this)),
            nft_
        )
    {
        settlement = address(new LedgerSettlement(token_, params_, pricer_, treasury_, wirer_, pulse_, sorted, nft));
    }

    function wire(address redeemer_, address liquidator_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (redeemer != address(0)) revert AlreadyWired();
        if (nft.ledger() != address(this)) revert Unauthorized(); // the NFT must be bound to this Ledger first
        redeemer = redeemer_;
        liquidator = liquidator_;
    }

    // ================================================================ positions

    /// @notice The id of `owner`'s position number `salt` in `ilk`, before or after it exists.
    function positionId(address owner, bytes32 ilk, uint256 salt) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(owner, ilk, salt)));
    }

    /// @notice Open your position `positionId(msg.sender, ilk, salt)` if it does not exist yet, then change it by `a`.
    /// On an existing id (even one you no longer own) it is `adjust`.
    function open(bytes32 ilk, uint256 salt, Adjust calldata a) external nonReentrant returns (uint256 id) {
        id = _create(msg.sender, ilk, salt);
        _adjust(id, a, msg.sender, false);
    }

    /// @notice Change a position: as its owner, or as an operator with the rights the change needs.
    function adjust(uint256 id, Adjust calldata a) external nonReentrant {
        _adjust(id, a, msg.sender, false);
    }

    /// @notice PositionNFT only, after verifying the owner's signature (`openFor`, `borrowFor`): change position `id` (or,
    /// with `id == 0`, `owner`'s position `positionId(owner, ilk, salt)`, created if new) by `a` on `actor`'s funds. The
    /// signature covers the change, so no rights are needed; the owner must own the position.
    function execute(address owner, bytes32 ilk, uint256 salt, uint256 id, Adjust calldata a, address actor)
        external
        nonReentrant
        returns (uint256)
    {
        if (msg.sender != address(nft)) revert Unauthorized();
        if (id == 0) id = _create(owner, ilk, salt);
        if (nft.ownerOf(id) != owner) revert NotOwner();
        _adjust(id, a, actor, true);
        return id;
    }

    /// @notice Add collateral to any position (anyone may make a position safer). Not on holder-bound types.
    function addFor(uint256 id, uint256 amount, bool viaAsset) external nonReentrant {
        Adjust memory a;
        a.dCollateral = amount.toInt256();
        a.viaAsset = viaAsset;
        _adjust(id, a, msg.sender, true);
    }

    /// @notice Repay someone else's debt (anyone may make a position safer).
    function repayFor(uint256 id, uint256 amount) external nonReentrant {
        Adjust memory a;
        // Any amount at or above int256 max means "all of it"; the repayment clamps to the debt in _adjust
        a.dDebt = amount >= uint256(type(int256).max) ? -type(int256).max : -amount.toInt256();
        _adjust(id, a, msg.sender, true);
    }

    /// @notice Change a position's rate (its owner, or an operator with SET_RATE). A change within RATE_COOLDOWN of the last
    /// (either direction) adds RATE_COOLDOWN of interest at the old rate to the debt (minted as interest); after the
    /// cooldown it is free.
    function setRate(uint256 id, uint64 newRate, uint256 prevHint, uint256 nextHint) external nonReentrant {
        bytes32 ilk = _ilkOf(id);
        if (msg.sender != nft.ownerOf(id)) nft.checkRights(id, msg.sender, RIGHT_SET_RATE);
        ParametersBase.Config memory c = _config(ilk);
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        if (newRate < r.rateFloor || newRate > MAX_RATE) revert RateOutOfRange();
        Pricer.Quote memory q = _quote(ilk);
        Position storage p = _positions[id];
        IlkState storage s = ilkState[ilk];
        _accrue(ilk, s);
        uint256 oldDebt = p.debt;
        uint256 oldRate = p.rate;
        uint256 debt = _harvest(ilk, id, c, r, q, s, p, _debtOf(p));
        if (debt == 0) revert NoDebt();
        uint256 premium;
        bool inCooldown = block.timestamp < p.lastRateChange + RATE_COOLDOWN;
        if (newRate != oldRate && inCooldown) {
            // Only the owner may pay a cooldown premium; SET_RATE alone must not be able to add debt.
            if (msg.sender != nft.ownerOf(id)) revert NotOwner(); // re-read: a local here is one stack slot too many for solc
            premium = _premium(debt, oldRate);
            debt += premium;
            s.debt += premium.toUint128();
            if (uint256(s.debt) + s.badDebt > params.risk(ilk).line) revert CeilingExceeded(); // `r` is the stored risk: the depth rule binds here
            _checkLines(ilk);
            _checkEdge(ilk);
            _mintInterest(ilk, premium);
            if (!q.borrowable || !q.agree) revert NotPriced(); // a pair above the pool is not a price to add debt at
            // A rate change is not a borrow, so the cap does not measure its premium.
            if (!_healthy(p.collateral, debt, q.low, q.mat)) revert Unhealthy();
            p.version = uint32(params.riskVersion(ilk)); // a risk-increasing action rebinds to the newest version
        }
        // A charged change leaves its old rate for top-ups inside the new cooldown; a free one leaves none.
        if (newRate != oldRate) p.premiumRate = inCooldown ? uint64(oldRate) : 0;
        else if (!inCooldown) p.premiumRate = 0; // the clock restarts below: a lapsed premium must not come back with it
        p.lastRateChange = uint64(block.timestamp);
        _record(s, p, oldDebt, oldRate, debt, newRate);
        if (c.redeemable) _relist(ilk, id, true, true, true, prevHint, nextHint);
        emit RateSet(id, ilk, newRate, premium);
    }

    /// @notice Harvest yield into debt for a batch of positions of one type. Permissionless; also runs on every touch.
    function harvest(bytes32 ilk, uint256[] calldata ids) external nonReentrant {
        ParametersBase.Config memory c = _config(ilk);
        if (c.yieldRate == address(0)) revert NotYieldBearing();
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        Pricer.Quote memory q = _quote(ilk);
        IlkState storage s = ilkState[ilk];
        _accrue(ilk, s);
        for (uint256 i; i < ids.length; ++i) {
            if (ilkOf[ids[i]] != ilk) revert WrongType();
            Position storage p = _positions[ids[i]];
            uint256 debt = _debtOf(p);
            uint256 oldDebt = p.debt;
            uint256 newDebt = _harvest(ilk, ids[i], c, r, q, s, p, debt);
            if (newDebt != debt) {
                _record(s, p, oldDebt, p.rate, newDebt, p.rate);
                if (c.redeemable) _relist(ilk, ids[i], oldDebt != 0, newDebt != 0, false, 0, 0);
            }
        }
    }

    /// @notice PositionNFT only: a position changed hands. Holder-bound custody (seats) moves with it, and no position can
    /// change hands in the middle of a Ledger call.
    function onTransfer(uint256 id, address from, address to) external nonReentrant {
        if (msg.sender != address(nft)) revert Unauthorized();
        ParametersBase.Config memory c = params.config(ilkOf[id]);
        if (c.token == c.join) IHolderJoin(c.join).onPositionTransfer(from, to, _positions[id].collateral);
    }

    /// @dev One change to position `id` by `actor`. `authorized`: a signature by the owner covers it (openFor, borrowFor),
    /// or the change only makes the position safer (addFor, repayFor); otherwise the actor is the owner or holds the rights.
    function _adjust(uint256 id, Adjust memory a, address actor, bool authorized) private {
        bytes32 ilk = _ilkOf(id);
        address owner = nft.ownerOf(id);
        address to = a.to == address(0) ? owner : a.to;
        ParametersBase.Config memory c = _config(ilk);
        bool self = actor == owner || authorized;
        if (!self) nft.checkRights(id, actor, _rightsFor(a, to == owner));
        // Holder-bound units (seats) belong to their holder: in only from the owner, out only to the owner.
        if (c.token == c.join && ((a.dCollateral > 0 && actor != owner) || (a.dCollateral < 0 && to != owner))) {
            revert HolderBound();
        }
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        // Read only by the harvest (yield types) and by the health check below: a deposit or a repay on another type needs no price.
        Pricer.Quote memory q;
        if (c.yieldRate != address(0) || a.dDebt > 0 || a.dCollateral < 0) q = _quote(ilk);
        Position storage p = _positions[id];
        IlkState storage s = ilkState[ilk];

        _accrue(ilk, s);
        // Listed in the redemption order exactly while the RECORDED debt is non-zero: read it before the
        // harvest, which may pay the debt off entirely.
        uint256 oldDebt = p.debt;
        uint64 oldRate = p.rate;
        uint256 debt = _harvest(ilk, id, c, r, q, s, p, _debtOf(p));
        bool hadDebt = debt != 0;

        // collateral in
        if (a.dCollateral > 0) {
            uint256 amount = uint256(a.dCollateral);
            if (a.viaAsset) {
                IERC20(IERC4626Min(c.token).asset()).safeTransferFrom(actor, c.join, amount);
                amount = Join(c.join).wrap(amount);
            } else {
                IERC20(c.token).safeTransferFrom(actor, c.join, amount);
            }
            if (c.yieldRate != address(0)) _blendMark(c.yieldRate, p, amount);
            p.collateral += amount.toUint128();
            s.collateral += amount.toUint128();
        }

        // debt
        if (a.dDebt > 0) {
            uint256 amount = uint256(a.dDebt);
            // F1 (Liquity v2): every debt increase pays RATE_COOLDOWN of interest on the amount at the TYPE'S average rate,
            // read before this borrow; on an empty type, at the borrower's own rate. A rate drop through a fresh position
            // (repay, move the collateral, reborrow lower) therefore costs at least the market's 7 days of interest.
            {
                uint256 fee = _upfrontFee(s, amount, hadDebt ? p.rate : a.rate, _debtOf(p) - debt);
                if (fee > a.maxUpfrontFee) revert UpfrontFeeTooHigh(fee);
                if (fee != 0) {
                    debt += fee;
                    s.debt += fee.toUint128();
                    _mintInterest(ilk, fee); // line + health are checked below, with the borrow
                    emit UpfrontFee(id, ilk, fee);
                }
            }
            if (!hadDebt) {
                if (a.rate < r.rateFloor || a.rate > MAX_RATE) revert RateOutOfRange();
                // Reopening: the kept rate (0 if the position never had debt, or was liquidated) is the "old rate" of
                // setRate. Another rate inside the cooldown is a charged change (either direction): the old rate
                // becomes `premiumRate` and the cooldown restarts; after the cooldown the change is free and leaves none.
                if (a.rate != oldRate) {
                    // Choosing the rate is a rate change: an operator needs SET_RATE for it too.
                    if (!self) nft.checkRights(id, actor, RIGHT_SET_RATE);
                    bool charged = oldRate != 0 && block.timestamp < p.lastRateChange + RATE_COOLDOWN;
                    p.premiumRate = charged ? oldRate : 0;
                    p.lastRateChange = uint64(block.timestamp);
                }
                p.rate = a.rate;
            }
            // C2: every debt added inside the cooldown of a charged rate change (a reopen or a top-up alike) pays
            // RATE_COOLDOWN of interest on it at the rate before that change, so a dust reopen followed by a top-up,
            // or a repay-to-zero and same-rate reopen, costs what one reopen of the whole amount does.
            uint256 premium;
            if (p.premiumRate != 0 && block.timestamp < p.lastRateChange + RATE_COOLDOWN) {
                premium = _premium(amount, p.premiumRate);
            }
            if (premium != 0) {
                debt += premium;
                s.debt += premium.toUint128();
                _mintInterest(ilk, premium); // line + health are checked below, with the borrow
                emit RateSet(id, ilk, p.rate, premium);
            }
            debt += amount;
            s.debt += amount.toUint128();
            // F3: bad debt keeps its room in the type's line (a hole never re-lends), and new debt stops on every type
            // while the system's unbacked supply is past the brake.
            if (uint256(s.debt) + s.badDebt > params.risk(ilk).line) revert CeilingExceeded(); // `r` is the stored risk: the depth rule binds here
            _checkLines(ilk);
            _checkEdge(ilk);
            _checkBrake();
            token.mint(to, amount);
        } else if (a.dDebt < 0) {
            uint256 amount = uint256(-a.dDebt);
            if (amount > debt) amount = debt; // repay-all clamps (no race with accrual or a 1-wei repayFor)
            debt -= amount;
            s.debt -= amount.toUint128();
            token.burn(actor, amount);
        }
        // Only a call that moves debt is held to the minimum: harvested yield may legitimately leave a
        // position under dust, and its owner must still be able to add collateral.
        if (a.dDebt != 0 && debt != 0 && debt < r.dust) revert DustDebt();

        // collateral out
        if (a.dCollateral < 0) {
            uint256 amount = uint256(-a.dCollateral);
            if (amount > p.collateral) revert InsufficientCollateral();
            p.collateral -= amount.toUint128();
            s.collateral -= amount.toUint128();
            if (a.viaAsset) Join(c.join).unwrap(to, amount);
            else Join(c.join).exit(to, amount);
        }

        // Anything that could make the position less safe is measured at the borrow price (low, under the type's cap);
        // A withdrawal that repays enough not to lower the ratio is de-risking, and the cap does not stop it.
        if (debt != 0 && (a.dDebt > 0 || a.dCollateral < 0)) {
            if (!q.borrowable) revert NotPriced();
            if (!_healthy(p.collateral, debt, _adjustPrice(a, p.collateral, debt, q), q.mat)) revert Unhealthy();
            p.version = uint32(params.riskVersion(ilk)); // a risk-increasing action rebinds to the newest version
        }

        _record(s, p, oldDebt, oldRate, debt, p.rate);
        if (c.redeemable) _relist(ilk, id, oldDebt != 0, debt != 0, p.rate != oldRate, a.prevHint, a.nextHint);
        // A borrower who heals the position must not stay for sale at the old auction's decayed price if it dips again. The
        // join's `cancel` refuses unless the position is healthy, so a repayment that leaves it unhealthy cannot reset the sale.
        if (c.auction && (a.dDebt < 0 || a.dCollateral > 0)) {
            try IAuctionJoin(c.join).cancel(id) {} catch {}
        }
        emit Adjusted(id, ilk, a.dCollateral, a.dDebt, debt);
    }

    /// @dev The price an adjust is measured at, from the position's state after it: the cap applies unless the call only
    /// shrinks the position (repays and withdraws) and leaves collateral/debt no lower than before.
    function _adjustPrice(Adjust memory a, uint256 collateral, uint256 debt, Pricer.Quote memory q)
        private
        pure
        returns (uint256)
    {
        if (a.dDebt >= 0 || a.dCollateral >= 0) return q.borrow;
        uint256 before = collateral + uint256(-a.dCollateral);
        return collateral * (debt + uint256(-a.dDebt)) >= before * debt ? q.low : q.borrow;
    }

    /// @dev The rights an operator needs for `a`; withdrawals and borrows to the owner need the narrower right.
    function _rightsFor(Adjust memory a, bool toOwner) private pure returns (uint8 need) {
        if (a.dCollateral > 0) need |= RIGHT_ADD;
        if (a.dCollateral < 0) need |= toOwner ? RIGHT_WITHDRAW : RIGHT_WITHDRAW_ANY;
        if (a.dDebt > 0) need |= toOwner ? RIGHT_BORROW : RIGHT_BORROW_ANY;
        if (a.dDebt < 0) need |= RIGHT_REPAY;
    }

    /// @dev Create `positionId(owner, ilk, salt)` if it does not exist yet.
    function _create(address owner, bytes32 ilk, uint256 salt) private returns (uint256 id) {
        id = positionId(owner, ilk, salt);
        if (ilkOf[id] == bytes32(0)) {
            _config(ilk);
            ilkOf[id] = ilk;
            nft.mint(owner, id);
            emit Opened(id, ilk, owner, salt);
        }
    }

    // ================================================================ system

    /// @notice Burn your imdUSD against a type's bad debt. The Treasury's `cover` calls this.
    function cover(bytes32 ilk, uint256 amount) external nonReentrant {
        IlkState storage s = ilkState[ilk];
        if (amount > s.badDebt) amount = s.badDebt;
        s.badDebt -= amount.toUint128();
        totalBadDebt -= amount;
        token.burn(msg.sender, amount);
        emit Covered(ilk, amount);
    }

    /// @notice Burn your imdUSD against `reserveBacked` (its burn path).
    function retire(uint256 amount) external nonReentrant {
        if (amount > reserveBacked) amount = reserveBacked;
        reserveBacked -= amount;
        token.burn(msg.sender, amount);
        emit Retired(amount);
    }

    /// @notice Settle a type's interest into the Treasury. Permissionless.
    function accrue(bytes32 ilk) external nonReentrant {
        _accrue(ilk, ilkState[ilk]);
    }

    // ================================================================ module actions (in LedgerSettlement)

    /// @notice Redeemer: take up to `maxDebt` of this position's debt for collateral at `price`, less `fee`
    /// (LedgerSettlement.redeemPosition).
    function redeemPosition(uint256, uint256, uint256, uint256, address) external returns (uint256, uint256) {
        _settle();
    }

    /// @notice Liquidator: close this position (LedgerSettlement.liquidatePosition).
    function liquidatePosition(uint256, uint256, address, address, bool) external returns (uint256, uint256, uint256) {
        _settle();
    }

    /// @notice Realise a position whose collateral its issuer has destroyed (LedgerSettlement.writeOff). Permissionless.
    function writeOff(uint256) external {
        _settle();
    }

    /// @dev Run this call in LedgerSettlement on this contract's storage and return (or revert) exactly what it did.
    function _settle() private {
        address m = settlement;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), m, ptr, calldatasize(), 0, 0)
            let n := returndatasize()
            returndatacopy(ptr, 0, n)
            if iszero(ok) { revert(ptr, n) }
            return(ptr, n)
        }
    }

    /// @notice Redeemer only: burn the redeemer's imdUSD once per redemption.
    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != redeemer) revert Unauthorized();
        token.burn(from, amount);
    }

    // ================================================================ views

    function position(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @notice Current debt including interest accrued since the last touch (before any pending harvest).
    function debtOf(uint256 id) external view returns (uint256) {
        return _debtOf(_positions[id]);
    }

    /// @notice The upfront fee a borrow of `amount` would pay now, for a new position opening at `rate` (an existing
    /// position's own rate only matters on an empty type). Add a margin before passing it as `maxUpfrontFee`.
    function upfrontFeeFor(bytes32 ilk, uint256 amount, uint64 rate) external view returns (uint256) {
        return _upfrontFee(ilkState[ilk], amount, rate, 0);
    }

    /// @notice A type's debt including interest not yet minted.
    function ilkDebt(bytes32 ilk) external view returns (uint256) {
        IlkState storage s = ilkState[ilk];
        return s.debt + Math.mulDiv(s.weighted, block.timestamp - s.lastAccrual, YEAR * 1e18, Math.Rounding.Ceil);
    }

    /// @notice The debt one liquidation of `id` at `price` would repay now: the whole debt on a type that closes
    /// in full, or what restores `mat + targetBuffer`. 0 if already at the target.
    function liquidationNeed(uint256 id, uint256 price) external view returns (uint256) {
        bytes32 ilk = ilkOf[id];
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        Position storage p = _positions[id];
        uint256 buffer = params.config(ilk).auction ? 0 : params.targetBuffer(ilk);
        (uint256 mat, uint256 chop) = _liq(ilk, p, pricer.quote(ilk).mat);
        return _liquidationNeed(p.collateral, _debtOf(p), price, mat, chop, buffer, r.dust);
    }

    /// @notice Liquidation health, at the position's bound risk version.
    function healthy(uint256 id) external view returns (bool ok, bool priced) {
        bytes32 ilk = ilkOf[id];
        Pricer.Quote memory q = pricer.quote(ilk);
        Position storage p = _positions[id];
        (uint256 mat,) = _liq(ilk, p, q.mat);
        return (_healthy(p.collateral, _debtOf(p), q.low, mat), q.priced);
    }

}
