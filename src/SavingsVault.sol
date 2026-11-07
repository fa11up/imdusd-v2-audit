// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice sImdUSD: deposit imdUSD, earn the savers' share of borrower interest.
/// @dev No owner, no parameters. The Ledger mints `Parameters.savingsShare` of every interest accrual
/// straight to this contract; nothing here knows where imdUSD comes from.
///
/// SMOOTHING. Any imdUSD that arrives without a deposit (interest, or a donation) is not counted at once.
/// It joins a linear stream that vests over `STREAM`, and a new arrival is blended into the stream still
/// running by a value-weighted end time (Yearn v3's profit unlocking). So a deposit placed just before a
/// large accrual and withdrawn just after earns only the vested sliver of it, and a donation cannot move
/// the share price within a block, which with OpenZeppelin's virtual shares (`_decimalsOffset` = 6)
/// closes the first-depositor inflation attack twice over.
///
/// ACCOUNTING. `tracked` = deposits - withdrawals + every arrival folded in by `sync`. Arrivals not yet
/// synced are simply `balance - tracked` and are treated as fully unvested, so the view `totalAssets`
/// is the same before and after a sync; every deposit and withdrawal syncs first.
///
/// UPTAKE. The Ledger pays savers in proportion to `settledAssets()`: `totalAssets()` less what was
/// deposited at THIS timestamp (every transaction of a block shares it, so a flash mint parked here for one call
/// (deposit, accrue, redeem) reads as no uptake at all, and cannot lift the savers' share or make an empty vault look
/// held). Real deposits count from the next block; nothing is held or locked (withdrawals are never gated).
contract SavingsVault is ERC4626 {
    uint256 public constant STREAM = 7 days;

    /// @notice imdUSD this vault accounts for (counted or streaming).
    uint256 public tracked;
    /// @notice Unvested amount at `lastSync`; vests linearly to zero at `streamEnd`.
    uint256 public unvestedAtSync;
    uint64 public lastSync;
    uint64 public streamEnd;
    /// @notice The timestamp of the latest deposit, and what was deposited (net of same-block withdrawals) at it.
    uint64 public depositAt;
    uint256 public depositedAt;

    event Streamed(uint256 received, uint256 unvested, uint256 streamEnd);

    constructor(IERC20 imdUSD) ERC20("Savings imdUSD", "sImdUSD") ERC4626(imdUSD) {
        lastSync = uint64(block.timestamp);
        streamEnd = uint64(block.timestamp);
    }

    /// @notice Arrivals still to vest, rounded up so `totalAssets` never overstates.
    function unvested() public view returns (uint256) {
        uint256 end = streamEnd;
        if (block.timestamp >= end) return 0;
        return Math.mulDiv(unvestedAtSync, end - block.timestamp, end - lastSync, Math.Rounding.Ceil);
    }

    function totalAssets() public view override returns (uint256) {
        return tracked - unvested();
    }

    /// @notice `totalAssets()` less this block's deposits: the uptake figure the Ledger's savings split reads.
    function settledAssets() external view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 recent = depositAt == block.timestamp ? depositedAt : 0;
        return assets > recent ? assets - recent : 0;
    }

    /// @notice Fold new arrivals into the stream. Permissionless; also runs on every deposit and withdrawal.
    function sync() public {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 t = tracked;
        if (bal <= t) return;
        uint256 received = bal - t;
        uint256 u = unvested();
        uint256 end = streamEnd;
        uint256 remaining = end > block.timestamp ? end - block.timestamp : 0;
        uint256 total = u + received;
        uint256 duration = (u * remaining + received * STREAM) / total;
        if (duration == 0) duration = 1;
        tracked = bal;
        unvestedAtSync = total;
        lastSync = uint64(block.timestamp);
        streamEnd = uint64(block.timestamp + duration);
        emit Streamed(received, total, block.timestamp + duration);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        sync();
        super._deposit(caller, receiver, assets, shares);
        tracked += assets;
        if (depositAt == block.timestamp) {
            depositedAt += assets;
        } else {
            depositAt = uint64(block.timestamp);
            depositedAt = assets;
        }
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        sync();
        tracked -= assets;
        if (depositAt == block.timestamp) {
            uint256 recent = depositedAt;
            depositedAt = assets < recent ? recent - assets : 0;
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
