// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientReentrancyGuard} from "./TransientReentrancyGuard.sol";
import {ImdUSD} from "./ImdUSD.sol";
import {Parameters} from "./Parameters.sol";

/// @notice imdUSD v1 <-> imdUSD, 1:1, no fee.
/// @dev v1's token has a permanent minter (its own vault), so v2 cannot mint v1; this is how one unit
/// circulates instead of two. `toV2` is capped by `Parameters.migratorLine` because every v1 it holds is
/// v1's own vault's risk carried into v2; `toV1` is bounded by `outstanding` (the v1 taken in through `toV2`), never by
/// the line, and never by donated v1. The count is kept here rather than read from the v1 balance, so a donation of v1
/// cannot create mint or burn room.
contract Migrator is TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable v1;
    ImdUSD public immutable v2;
    Parameters public immutable params;

    /// @notice v1 held = v2 minted through here and not yet converted back.
    uint256 public outstanding;

    error OverLine();

    event ToV2(address indexed account, uint256 amount);
    event ToV1(address indexed account, uint256 amount);

    constructor(IERC20 v1_, ImdUSD v2_, Parameters params_) {
        v1 = v1_;
        v2 = v2_;
        params = params_;
    }

    function toV2(uint256 amount) external nonReentrant {
        if (outstanding + amount > params.migratorLine()) revert OverLine();
        outstanding += amount;
        v1.safeTransferFrom(msg.sender, address(this), amount);
        v2.mint(msg.sender, amount);
        emit ToV2(msg.sender, amount);
    }

    function toV1(uint256 amount) external nonReentrant {
        outstanding -= amount;
        v2.burn(msg.sender, amount);
        v1.safeTransfer(msg.sender, amount);
        emit ToV1(msg.sender, amount);
    }
}
