// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IApprove {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title CompoundPocket
/// @notice Where a CompoundHook's NEW stakes are minted, so that staking never stamps the hook's own address with a
/// whole-address one-block hold (sIMD). Its creator (the hook) may move or redeem everything it holds; it has no
/// runtime code at all: the two allowances set in the constructor are its whole behaviour.
contract CompoundPocket {
    constructor(address vault0, address vault1) {
        IApprove(vault0).approve(msg.sender, type(uint256).max);
        IApprove(vault1).approve(msg.sender, type(uint256).max);
    }
}
