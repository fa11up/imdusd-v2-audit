// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The Robinhood stock-token registry's surface we read (AccessControlledRegistry on 4663): global pause, blocklist.
contract MockStockRegistry {
    bool public paused;
    mapping(address => bool) public isBlocked;

    function setPaused(bool p) external {
        paused = p;
    }

    function setBlocked(address a, bool b) external {
        isBlocked[a] = b;
    }
}

/// @notice A Robinhood stock token as measured on 4663: 18 decimals, token and global pause (both in
/// `paused()`), an oracle-pause flag, ERC-8056 multiplier with a scheduled change, `adminBurn`, and a blocklist checked on
/// sender, recipient and caller of every transfer.
contract MockStockToken is ERC20 {
    MockStockRegistry public immutable registry;
    bool public tokenPaused;
    bool public oraclePaused;
    uint256 internal _mult = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;
    bool private _admin;

    error Paused();
    error Blocked(address who);

    constructor(string memory sym, MockStockRegistry registry_) ERC20(sym, sym) {
        registry = registry_;
    }

    function ACCESS_CONTROLLED_REGISTRY() external view returns (address) {
        return address(registry);
    }

    function paused() public view returns (bool) {
        return tokenPaused || registry.paused();
    }

    function uiMultiplier() external view returns (uint256) {
        return block.timestamp >= effectiveAt ? newUIMultiplier : _mult;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev The issuer's burn ignores pauses and the blocklist (that is how a blocked holder's balance is seized).
    function adminBurn(address from, uint256 amount) external {
        _admin = true;
        _burn(from, amount);
        _admin = false;
    }

    function setPaused(bool p) external {
        tokenPaused = p;
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }

    /// @dev Schedule `next` from `at` (the issuer's two-step multiplier change).
    function scheduleMultiplier(uint256 next, uint256 at) external {
        _mult = block.timestamp >= effectiveAt ? newUIMultiplier : _mult;
        newUIMultiplier = next;
        effectiveAt = at;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_admin) return super._update(from, to, value);
        if (paused()) revert Paused();
        if (registry.isBlocked(from)) revert Blocked(from);
        if (registry.isBlocked(to)) revert Blocked(to);
        if (registry.isBlocked(msg.sender)) revert Blocked(msg.sender);
        super._update(from, to, value);
    }
}
