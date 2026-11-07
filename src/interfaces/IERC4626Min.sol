// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The ERC-4626 surface v2 uses: deposit-on-entry, convert for pricing, redeem on exit.
interface IERC4626Min {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxRedeem(address owner) external view returns (uint256 shares);
}
