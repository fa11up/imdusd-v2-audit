// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IERC20Metadata, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice The pooled custody of one Robinhood stock token. Ownerless ERC-4626; its shares are the type's collateral.
/// @dev Why a vault and not the raw token: the issuer can `adminBurn` any holder's balance, and that holder is our custody.
/// A burn from a pool of raw tokens would leave the Ledger recording collateral that no longer exists, with no fair way to say
/// whose. Here the burn lands on the vault, so every share loses the same fraction at once: `convertToAssets` falls, the
/// type's price (`RateFeed` over this rate x the market-hours feed) takes the fall in full, and positions are marked down
/// pro rata with no Ledger change. A position left worth less than its debt is liquidated (debt the sale cannot cover becomes
/// the type's bad debt); one left worth nothing (a share redeems for zero) is written off (`Ledger.writeOff`).
/// A donation can only raise every share's value; the RateFeed caps how fast a rise is believed. OpenZeppelin's virtual
/// share/asset offset makes the first-depositor inflation attack cost more than it can take.
contract StockVault is ERC4626 {
    constructor(IERC20Metadata stock_)
        ERC20(string.concat("imdUSD custody ", stock_.symbol()), string.concat("c", stock_.symbol()))
        ERC4626(stock_)
    {}

    /// @dev 10^6 virtual shares per asset unit (OZ's documented mitigation), so donating to or inflating an
    /// emptied vault costs 10^6 more. Shares carry 6 more decimals than the stock; the RateFeed reads `convertToAssets(1e18)`
    /// and the Ledger values shares x that rate, so prices per share scale down by the same 10^6 and values are unchanged.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev A HOLLOW vault (shares outstanding, no stock: the issuer burned the custody) takes no deposit. At
    /// `totalAssets == 0` a dust deposit would mint ~all shares and claim any later reissue; the offset alone does not stop
    /// that (it prices against `totalSupply`, which is large). Deposits reopen once stock is back (a reissue).
    function maxDeposit(address) public view override returns (uint256) {
        return _hollow() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return _hollow() ? 0 : type(uint256).max;
    }

    function _hollow() private view returns (bool) {
        return totalAssets() == 0 && totalSupply() != 0;
    }
}
