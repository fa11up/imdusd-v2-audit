// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What the Liquidator, Ledger, Treasury and Parameters call on a Backstop sleeve. See
/// Liquidator.bite and Treasury.coverBadDebt for the exact call sequence.
interface IBackstop {
    /// @notice imdUSD this sleeve can spend on a standing bid for `ilk` now (0 if it does not cover `ilk`).
    function bidRoom(bytes32 ilk) external view returns (uint256);

    /// @notice Liquidator only: start a standing bid on `ilk`. Records this sleeve's imdUSD and collateral balances. The
    /// Liquidator must then call `Ledger.liquidatePosition(ilk, id, price, address(this), marker, false)` and then
    /// `closeBid(ilk)` in the same transaction.
    function openBid(bytes32 ilk) external;

    /// @notice Liquidator only: book the bid. `repaid` is what `Ledger.liquidatePosition` returned as repaid (the imdUSD
    /// it burned from this sleeve). Reverts unless repaid <= the room at open, the sleeve's imdUSD fell by no more than
    /// `repaid` (anything that arrived meanwhile, e.g. the edge premium minted by the Ledger's accrual, is an arrival and
    /// streams), and the collateral received is worth at least `repaid` at the type's low price.
    function closeBid(bytes32 ilk, uint256 repaid) external returns (uint256 spent, uint256 received);

    /// @notice Edge sleeve only, permissionless: burn this sleeve's imdUSD against `ilk`'s bad debt (first loss).
    function coverBadDebt(bytes32 ilk) external returns (uint256 covered);

    /// @notice Edge sleeve: the most `ilk`'s line may be given the sleeve standing behind it, less `inAuction` (debt of
    /// `ilk` positions currently in a Dutch auction).
    function edgeCapacity(bytes32 ilk, uint256 inAuction) external view returns (uint256);
}

/// @notice Prices for the collateral a sleeve holds: imdUSD per 1e18 raw units, the type's low and high legs.
interface IBackstopOracle {
    function priceOf(address token) external view returns (uint256 low, uint256 high, bool ok);
    /// @notice When every leg `token`'s price needs last updated (the oldest of them); 0 if unknown. A retired token whose legs
    /// have updated since was not dead after all (Backstop.retire).
    function pricedAt(address token) external view returns (uint256);
}

/// @notice The Ledger's permissionless bad-debt burn and its per-type state (badDebt is the 5th field).
interface ILedgerCover {
    function cover(bytes32 ilk, uint256 amount) external;
    function ilkState(bytes32 ilk) external view returns (uint128, uint128, uint256, uint64, uint128);
}

/// @notice The allowlisted seller (the future allocator): receives collateral, must pay imdUSD back in the same call.
interface IBackstopSeller {
    function onBackstopSell(address token, uint256 amount, bytes calldata data) external;
}
