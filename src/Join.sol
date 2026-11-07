// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626Min} from "./interfaces/IERC4626Min.sol";

/// @notice Custody for one collateral type. Holds the tokens; the Ledger holds the accounting.
/// @dev Only the Ledger moves anything out. The Ledger pulls deposits straight into this contract
/// (users approve the Ledger, not each join). `wrap` / `unwrap` exist for ERC-4626 types: a deposit of
/// the raw asset is staked into the vault on entry (as v1's `lockIMD`
/// stakes IMD into sIMD), and a withdrawal may ask for the asset back.
contract Join {
    using SafeERC20 for IERC20;

    address public immutable token;
    address public immutable wirer;
    address public ledger;

    error Unauthorized();
    error AlreadyWired();

    constructor(address token_, address wirer_) {
        token = token_;
        wirer = wirer_;
    }

    function wire(address ledger_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (ledger != address(0)) revert AlreadyWired();
        ledger = ledger_;
    }

    modifier onlyLedger() {
        if (msg.sender != ledger) revert Unauthorized();
        _;
    }

    function exit(address to, uint256 amount) external onlyLedger {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Stake `assets` of the vault's underlying, already sitting here, into the vault.
    function wrap(uint256 assets) external onlyLedger returns (uint256 shares) {
        address asset = IERC4626Min(token).asset();
        IERC20(asset).forceApprove(token, assets);
        shares = IERC4626Min(token).deposit(assets, address(this));
    }

    /// @notice Redeem `shares` to `to` in the underlying. Reverts when the vault cannot pay, so the
    /// caller can choose shares instead.
    function unwrap(address to, uint256 shares) external onlyLedger returns (uint256 assets) {
        assets = IERC4626Min(token).redeem(shares, to, address(this));
    }
}
