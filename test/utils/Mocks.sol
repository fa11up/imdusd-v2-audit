// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, uint8 dec_) ERC20(name_, name_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A settable feed. `set` stamps it now; `setStale` forces staleness; `setMaxAge` changes its life (1 hour
/// by default; the seat median leaf lives 26 hours).
contract MockFeed is IFeed {
    /// @dev Stage 2 refuses an EXISTING feed that does not prove a capped stale allowance.
    uint256 public constant MAX_ALLOWANCE_BPS = 20_000;

    uint256 public value;
    uint64 public at;
    bool public stale;
    uint256 public maxAge = 1 hours;

    constructor(uint256 v) {
        set(v);
    }

    function set(uint256 v) public {
        value = v;
        at = uint64(block.timestamp);
        stale = false;
    }

    function setStale(bool s) external {
        stale = s;
    }

    function setMaxAge(uint256 a) external {
        maxAge = a;
    }

    function latestValue() external view returns (uint256, uint64) {
        return (value, at);
    }

    function isStale() external view returns (bool) {
        return stale || value == 0 || block.timestamp - at > maxAge;
    }
}

/// @notice A seat median leaf: a MockFeed that also carries the attestation's figure (distinct seats sold).
contract MockSeatFeed is MockFeed {
    uint256 public latestFigure;

    constructor(uint256 v, uint256 figure) MockFeed(v) {
        latestFigure = figure;
    }

    function setFigure(uint256 f) external {
        latestFigure = f;
    }

    uint64 private relayedAt;

    /// @notice Relay now an attestation signed at `signedAt` (a held or late-relayed attestation).
    function relay(uint256 v, uint64 signedAt) external {
        set(v);
        at = signedAt;
        relayedAt = uint64(block.timestamp);
    }

    /// @notice As SwarmFeed.acceptedAt: the relay time (a plain `set` relays at its own signature time).
    function acceptedAt() external view returns (uint64) {
        return relayedAt > at ? relayedAt : at;
    }
}

/// @notice A Chainlink-shaped aggregator.
contract MockAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public immutable decimals;

    constructor(uint8 dec, int256 a) {
        decimals = dec;
        set(a);
    }

    function set(int256 a) public {
        answer = a;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice A Chainlink-shaped USD feed that is always fresh (updatedAt = now) unless `setAge` pins it in the past, so suites
/// that warp through timelocks keep a live quote-stablecoin price (the PegHook's quote gate).
contract MockLiveAggregator {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public age; // seconds behind block.timestamp
    bool public broken;

    constructor(uint8 dec, int256 a) {
        decimals = dec;
        answer = a;
    }

    function set(int256 a) external {
        answer = a;
    }

    function setAge(uint256 a) external {
        age = a;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "broken feed");
        uint256 t = block.timestamp - age;
        return (1, answer, t, t, 1);
    }
}

/// @notice An ERC-4626 whose rate rises by `accrue` (mints underlying into itself) or `donate`.
contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("vShare", "vShare") ERC4626(asset_) {}

    function accrue(uint256 assets) external {
        MockERC20(asset()).mint(address(this), assets);
    }

    /// @dev A loss: burn underlying out of the vault by sending it to a dead address.
    function lose(uint256 assets) external {
        IERC20(asset()).transfer(address(0xdead), assets);
    }
}
