// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A numeric feed in v1's convention (`ISwarmFeed`, byte-identical), so v2 reads v1's live feeds as-is.
/// @dev Every PRICE in v2 is "USD per 1e18 raw units of the token, 1e18-scaled". That makes collateral
/// arithmetic `amount * value / 1e18` correct for any token decimals with nothing reading `decimals()`
/// (the same convention as v1's SharePriceFeed). Non-price feeds (NHI, ratios) are plain
/// 1e18-scaled numbers.
interface IFeed {
    function latestValue() external view returns (uint256 value, uint64 updatedAt);

    /// @notice True before the first accepted value, or once the value is older than `maxAge`.
    function isStale() external view returns (bool);

    function maxAge() external view returns (uint256);
}
