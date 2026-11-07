// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeed} from "../interfaces/IFeed.sol";

interface IPegVaultRead {
    function totals() external view returns (uint256 amount0, uint256 amount1);
    function positionAmounts() external view returns (uint256 amount0, uint256 amount1);
    function totalSupply() external view returns (uint256);
    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);
}

interface IDecimalsRead {
    function decimals() external view returns (uint8);
}

/// @notice Prices one PegLPVault share, so one `PegCollateral` (1:1, peg positions), in USD per 1e18 share units, 1e18-scaled (IFeed's
/// convention), from the vault's OWN holdings: imdUSD at $1 and the quote stable at min($1, its Chainlink answer).
/// @dev Why no market price is needed: a peg position's debt is imdUSD, and the vault's imdUSD leg repays it at par
/// whatever imdUSD trades at, so imdUSD counts as exactly 1. The quote leg (USDC) is capped at $1 and follows a depeg down.
///
/// MANIPULATION. `totals()` reads the position at the pool's CURRENT price, so a push moves the mix: selling imdUSD into
/// the band leaves the vault holding more imdUSD and less USDC. Both count at $1, so the sum moves only by the trade's
/// distance from $1, which is at most the band's half-width (±1% at the beta band) times the part of the position traded;
/// past the band the position holds one token and a push changes nothing. The type's `mat` (125%) is set well above that.
/// A donation to the vault raises every holder's share (the donor's loss) and cannot be withdrawn by the donor.
///
/// A feed that cannot read the vault, the pool or the quote stable's price returns 0, which the Pricer treats as unpriced
/// (no new debt, no withdrawal; repayment always works).
contract PegShareFeed is IFeed {
    IPegVaultRead public immutable vault;
    address public immutable stable; // imdUSD
    address public immutable quoteAggregator; // Chainlink USD feed of the quote stable (USDC/USD); zero = count it at $1
    uint256 public immutable quoteStaleAfter;
    bool private immutable stableIs0;
    uint256 private immutable quoteScale;
    /// @notice This instance is the type's SPOT leg. It reads the FULL share value (equal to the median)
    /// while the vault's POSITION is two-sided, meaning the USDC part of its value is within 25%-75%, and 0 outside. Idle
    /// balances do not count in the mix (a USDC donation sits idle below the band and must not flip the leg). The Pricer
    /// treats a spot of 0 as not ok: `low` = the median, `priced` true, `borrowable` false. So liquidation always measures at
    /// the full value and a mix change can never lower its price, while new PEG debt is refused against a one-sided vault.
    /// A push into the range opens borrowing for that transaction on collateral already held; it moves no value, and
    /// new collateral comes only through the zap (`PegCollateral`), not through a raw deposit.
    bool public immutable twoSidedOnly;
    uint256 public constant TWO_SIDED_MIN_BPS = 2_500;
    uint256 public constant TWO_SIDED_MAX_BPS = 7_500;

    error BadConfig();

    constructor(
        IPegVaultRead vault_,
        address stable_,
        address quoteAggregator_,
        uint256 quoteStaleAfter_,
        bool twoSidedOnly_
    ) {
        twoSidedOnly = twoSidedOnly_;
        address t0 = address(vault_.token0());
        address t1 = address(vault_.token1());
        if (stable_ != t0 && stable_ != t1) revert BadConfig();
        vault = vault_;
        stable = stable_;
        quoteAggregator = quoteAggregator_;
        quoteStaleAfter = quoteStaleAfter_;
        stableIs0 = stable_ == t0;
        address q = stableIs0 ? t1 : t0;
        uint8 ds = IDecimalsRead(stable_).decimals();
        uint8 dq = IDecimalsRead(q).decimals();
        if (dq > ds) revert BadConfig();
        quoteScale = 10 ** (ds - dq);
    }

    function latestValue() external view returns (uint256 value, uint64 updatedAt) {
        updatedAt = uint64(block.timestamp);
        uint256 supply = vault.totalSupply();
        if (supply == 0) return (0, updatedAt);
        uint256 a0;
        uint256 a1;
        try vault.totals() returns (uint256 x0, uint256 x1) {
            (a0, a1) = (x0, x1);
        } catch {
            return (0, updatedAt);
        }
        (uint256 s, uint256 q) = stableIs0 ? (a0, a1) : (a1, a0);
        uint256 qPrice = _quotePrice(); // 1e18 = $1
        if (qPrice == 0) return (0, updatedAt);
        uint256 quoteUsd = q * quoteScale * qPrice / 1e18;
        if (twoSidedOnly && !_twoSided(qPrice)) return (0, updatedAt);
        value = (s + quoteUsd) * 1e18 / supply;
    }

    /// @notice Never stale by age (it is read live); unpriced reads return 0 instead.
    function isStale() external view returns (bool) {
        return vault.totalSupply() == 0;
    }

    function maxAge() external pure returns (uint256) {
        return type(uint64).max;
    }

    /// @dev Whether the USDC part of the position's value (no idle balances) is within the bounds.
    function _twoSided(uint256 qPrice) private view returns (bool) {
        (uint256 a0, uint256 a1) = vault.positionAmounts();
        (uint256 s, uint256 q) = stableIs0 ? (a0, a1) : (a1, a0);
        uint256 quoteUsd = q * quoteScale * qPrice / 1e18;
        uint256 usd = s + quoteUsd;
        return quoteUsd * 10_000 >= usd * TWO_SIDED_MIN_BPS && quoteUsd * 10_000 <= usd * TWO_SIDED_MAX_BPS && usd != 0;
    }

    /// @dev min($1, the aggregator's answer); 0 when the aggregator is unreadable, non-positive or older than the bound.
    function _quotePrice() private view returns (uint256) {
        if (quoteAggregator == address(0)) return 1e18;
        (bool ok, bytes memory data) = quoteAggregator.staticcall(abi.encodeWithSignature("latestRoundData()"));
        (bool okd, bytes memory dd) = quoteAggregator.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || !okd || data.length < 160 || dd.length < 32) return 0;
        (, int256 answer,, uint256 at,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        uint256 dec = abi.decode(dd, (uint256));
        if (answer <= 0 || dec > 36 || at + quoteStaleAfter < block.timestamp) return 0;
        uint256 p = uint256(answer) * 10 ** (36 - dec) / 1e18;
        return p > 1e18 ? 1e18 : p;
    }
}
