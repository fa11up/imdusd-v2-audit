// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Stands in for a shielded pool (Railgun, Tacit, Privacy Pools): it pulls a token with `transferFrom` and later pays
/// it out with `transfer`, all inside one transaction, and checks it received exactly what it pulled. The units
/// we want shielded must survive exactly this.
contract Shield {
    function shield(IERC20 token, uint256 amount) external {
        uint256 before = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        require(token.balanceOf(address(this)) - before == amount, "fee-on-transfer");
    }

    function unshield(IERC20 token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "push");
    }
}
