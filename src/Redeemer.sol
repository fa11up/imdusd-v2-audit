// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransientReentrancyGuard} from "./TransientReentrancyGuard.sol";
import {Ledger} from "./Ledger.sol";
import {ImdUSD} from "./ImdUSD.sol";
import {Pricer} from "./Pricer.sol";
import {ParametersBase} from "./ParametersBase.sol";
import {Parameters} from "./Parameters.sol";
import {SortedPositions} from "./SortedPositions.sol";

/// @notice The peg floor: anyone burns imdUSD for $1 of a redeemable type's collateral, less a fee,
/// taken from the lowest-rate positions first.
/// @dev PER TYPE: each type has its own decaying base rate (half-life ~12h), its own
/// fee floor and divisor from Parameters, and the fee cap is 5% for all. A run on one type no longer
/// raises the fee on another, so stablecoin redemptions stay cheap while sIMD is being drained.
/// The fee's collateral leaves the redeemed position for the Treasury (-10-30): were it left in the
/// position, a borrower who is the type's first position could redeem their own debt for free and pin the type's fee
/// at the cap. The borrower stays whole on the principal (debt and $1 of collateral per imdUSD leave together).
/// FEE BASE: the ramp and the base-rate rise divide by `ImdUSD.circulating()` (supply less flash loans in flight), not
/// `totalSupply()`, so a flash mint of any nesting cannot dilute them.
/// Payout is at the quote's `payout`: max(median, spot, live pool) on a type with a live leg.
/// WINDOW CAP: a type with `redeemCap != 0` admits at most that much imdUSD per rolling window, counted
/// in BUCKET-second buckets over WINDOW + BUCKET, so every 2h window, however aligned, sees at most the cap
/// (the counted span is 10 min longer than 2h: conservative). An over-size request is filled up to what
/// the window has left, and reverts only when nothing is left.
contract Redeemer is TransientReentrancyGuard {
    uint256 public constant FEE_CAP = 0.05e18;
    uint256 public constant WINDOW = 2 hours;
    uint256 public constant BUCKET = 10 minutes;
    /// @dev Buckets summed per check: the current one and the WINDOW / BUCKET before it.
    uint256 private constant SPAN = WINDOW / BUCKET + 1;
    /// @dev v1's per-second decay factor (half-life ~12h).
    uint256 private constant SECOND_DECAY = 999983955055097432;

    Ledger public immutable ledger;
    Pricer public immutable pricer;
    Parameters public immutable params;
    SortedPositions public immutable sorted;
    IERC20 public immutable token;

    struct Rate {
        uint192 baseRate;
        uint64 lastRedemptionAt;
    }

    mapping(bytes32 ilk => Rate) public rates;
    /// @notice imdUSD redeemed against a type in each BUCKET (keyed by block.timestamp / BUCKET).
    mapping(bytes32 ilk => mapping(uint256 bucket => uint256)) public redeemedIn;

    error NotRedeemable();
    error NotPriced();
    error FeeTooHigh(uint256 fee);
    error NothingRedeemed();
    error ZeroAmount();
    error WindowFull();
    error CollateralTooLow(uint256 collateral);

    event Redemption(bytes32 indexed ilk, address indexed redeemer, uint256 amount, uint256 fee, uint256 collateral);

    constructor(Ledger ledger_) {
        ledger = ledger_;
        pricer = ledger_.pricer();
        params = ledger_.params();
        sorted = ledger_.sorted();
        token = IERC20(address(ledger_.token()));
    }

    /// @notice Current fee for redeeming `amount` against `ilk`, 1e18.
    function feeFor(bytes32 ilk, uint256 amount) public view returns (uint256) {
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        return _fee(ilk, amount, r);
    }

    /// @notice The type's base rate now. A type never redeemed starts AT THE CAP from the moment it went live
    /// (`Parameters.listedAt`: the seal for a genesis type, its addition for a later one) and decays from there, so
    /// the fee falls from 5% to a 0.5% floor in ~40h after launch. Before the seal it reads the cap.
    function decayedBaseRate(bytes32 ilk) public view returns (uint256) {
        Rate memory rt = rates[ilk];
        uint256 base = rt.baseRate;
        uint256 since = rt.lastRedemptionAt;
        if (since == 0) {
            since = params.listedAt(ilk);
            if (since == 0) return FEE_CAP;
            base = FEE_CAP;
        }
        if (base == 0) return 0;
        return Math.mulDiv(base, _pow(SECOND_DECAY, block.timestamp - since), 1e18);
    }

    /// @notice imdUSD that may still be redeemed against `ilk` now (type(uint256).max when uncapped).
    function windowLeft(bytes32 ilk) public view returns (uint256) {
        uint256 cap = params.storedRisk(ilk).redeemCap;
        if (cap == 0) return type(uint256).max;
        uint256 used = redeemedInWindow(ilk);
        return used >= cap ? 0 : cap - used;
    }

    /// @notice imdUSD redeemed against `ilk` in the counted span (the current bucket and the WINDOW before it).
    function redeemedInWindow(bytes32 ilk) public view returns (uint256 used) {
        uint256 b = block.timestamp / BUCKET;
        for (uint256 i; i < SPAN && i <= b; ++i) {
            used += redeemedIn[ilk][b - i];
        }
    }

    /// @notice Redeem up to `amount` imdUSD against `ilk`, visiting at most `maxPositions` positions.
    /// Burns only what was actually redeemed, and never more than the type's window has left.
    /// `minCollateralOut`: reverts if the collateral received is less. With max-of-legs payout prices a front-runner
    /// can move the payout price up between quote and inclusion; `maxFee` alone does not bound that. It bounds the TOTAL
    /// out, so a fill cut short by the window or by `maxPositions` counts against it: size it for what you expect to fill.
    function redeem(bytes32 ilk, uint256 amount, uint256 maxFee, uint256 maxPositions, uint256 minCollateralOut)
        external
        nonReentrant
        returns (uint256 redeemed, uint256 collateral)
    {
        if (amount == 0) revert ZeroAmount();
        if (!params.config(ilk).redeemable) revert NotRedeemable();
        Pricer.Quote memory q = pricer.quote(ilk);
        if (!q.priced || q.payout == 0) revert NotPriced();
        ParametersBase.Risk memory r = params.storedRisk(ilk);
        if (r.redeemCap != 0) {
            uint256 left = windowLeft(ilk);
            if (left == 0) revert WindowFull();
            if (amount > left) amount = left;
        }
        uint256 fee = _fee(ilk, amount, r);
        if (fee > maxFee) revert FeeTooHigh(fee);

        uint256 id = sorted.first(ilk);
        for (uint256 i; i < maxPositions && id != 0 && redeemed < amount; ++i) {
            uint256 next_ = sorted.next(ilk, id);
            (uint256 taken, uint256 out) = ledger.redeemPosition(id, amount - redeemed, q.payout, fee, msg.sender);
            redeemed += taken;
            collateral += out;
            id = next_;
        }
        if (redeemed == 0) revert NothingRedeemed();
        if (collateral < minCollateralOut) revert CollateralTooLow(collateral);
        ledger.burnFrom(msg.sender, redeemed);
        if (r.redeemCap != 0) redeemedIn[ilk][block.timestamp / BUCKET] += redeemed;

        // The type's base rate rises by the redeemed share of the circulating supply BEFORE this burn, as in v1.
        uint256 supplyBefore = ImdUSD(address(token)).circulating() + redeemed;
        uint256 next = decayedBaseRate(ilk) + Math.mulDiv(redeemed, 1e18, supplyBefore) / r.redeemDivisor;
        rates[ilk] = Rate(uint192(Math.min(next, FEE_CAP)), uint64(block.timestamp));
        emit Redemption(ilk, msg.sender, redeemed, fee, collateral);
    }

    function _fee(bytes32 ilk, uint256 amount, ParametersBase.Risk memory r) private view returns (uint256) {
        uint256 supply = ImdUSD(address(token)).circulating();
        uint256 increase = supply == 0 ? FEE_CAP : Math.mulDiv(amount, 1e18, supply) / r.redeemDivisor;
        return Math.min(r.redeemFloor + decayedBaseRate(ilk) + increase, FEE_CAP);
    }

    function _pow(uint256 factor, uint256 n) private pure returns (uint256 result) {
        result = 1e18;
        unchecked {
            while (n != 0) {
                if (n & 1 != 0) result = result * factor / 1e18;
                n >>= 1;
                factor = factor * factor / 1e18;
            }
        }
    }
}
