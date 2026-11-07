// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The PEG type's collateral token: PegLPVault shares, 1:1, that only PegPositionZap can create.
/// The Ledger takes any holder's collateral token, so a raw share as collateral let anyone deposit flash-minted imdUSD
/// into the vault and borrow against it (about 9x with no USDC). The zap brings the caller's USDC in the vault's proportion
/// and mints this, so PEG collateral exists only for a deposit made through it.
/// @dev Anyone may redeem for the shares at any time: a liquidator, the Treasury or an owner who withdrew keeps a claim
/// on the vault, and no price or gate stands in the way. It is a plain transferable ERC-20, so an owner holding some may
/// top up a position with it; raw shares can no longer be added. No owner: the wirer names the zap once at genesis.
contract PegCollateral is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable shares;
    address public immutable wirer;
    address public zap;

    error Unauthorized();
    error AlreadySet();

    constructor(IERC20 shares_, address wirer_) ERC20("imdUSD Peg Position Collateral", "pegLP-C") {
        shares = shares_;
        wirer = wirer_;
    }

    /// @notice The wirer, once.
    function setZap(address zap_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (zap != address(0)) revert AlreadySet();
        zap = zap_;
    }

    /// @notice The zap only: take `amount` vault shares from it and mint the same amount to `to`.
    function wrap(uint256 amount, address to) external {
        if (msg.sender != zap) revert Unauthorized();
        shares.safeTransferFrom(msg.sender, address(this), amount);
        _mint(to, amount);
    }

    /// @notice Burn your `amount` and receive the same amount of vault shares at `to`.
    function redeem(uint256 amount, address to) external {
        _burn(msg.sender, amount);
        shares.safeTransfer(to, amount);
    }
}
