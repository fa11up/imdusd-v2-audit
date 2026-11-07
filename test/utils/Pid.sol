// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev `Ledger.positionId(owner, ilk, 0)`: a test's "the position of `owner` in `ilk`". Tests that use
/// one position per owner and type (the pre-id API's model) name it with this; `Ledger.open(ilk, 0, ...)` creates it.
function _pid(bytes32 ilk, address owner) pure returns (uint256) {
    return uint256(keccak256(abi.encode(owner, ilk, uint256(0))));
}
