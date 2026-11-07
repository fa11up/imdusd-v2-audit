// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice One change to a position, shared by the Ledger and the PositionNFT that verifies signed ones.
/// @param dCollateral   > 0 deposit (from the caller), < 0 withdraw (to `to`); in the type's token, shares for ERC-4626 types
/// @param dDebt         > 0 borrow (minted to `to`), < 0 repay (burned from the caller)
/// @param rate          annual rate (1e18) if this opens debt; ignored otherwise (use `Ledger.setRate`)
/// @param prevHint      redemption-order hints (position ids; 0 = none): gas only, never the outcome
/// @param nextHint
/// @param viaAsset      ERC-4626 types: a deposit is |dCollateral| of the underlying asset, staked for the position; a
///                      withdrawal is redeemed to the underlying (reverts if the vault cannot pay)
/// @param maxUpfrontFee F1: the most upfront fee a borrow may add (the type's average moves between quote and inclusion)
/// @param to            receives borrowed imdUSD and withdrawn collateral; zero = the position's owner
struct Adjust {
    int256 dCollateral;
    int256 dDebt;
    uint64 rate;
    uint256 prevHint;
    uint256 nextHint;
    bool viaAsset;
    uint256 maxUpfrontFee;
    address to;
}

/// @notice A custody join whose collateral units follow a HOLDER (seats: units are fungible among one holder's seats, and a
/// holder's units in wallet + in the Ledger equal the seats held for them). The Ledger tells it when a position changes hands
/// so the seats move with the units. Such a join is its own token (`Config.token == Config.join`).
interface IHolderJoin {
    function onPositionTransfer(address from, address to, uint256 units) external;
}

/// @notice An auction join (`Config.auction`): the Liquidator opens a sale of a whole position.
interface IAuctionJoin {
    function open(uint256 id, address marker) external;
}
