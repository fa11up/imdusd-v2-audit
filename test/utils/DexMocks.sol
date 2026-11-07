// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "./Mocks.sol";

/// @notice sIMD's one-block hold, reproduced from the verified StakedIMD (0x9Efa…7247): WHOLE ADDRESS. A positive
/// mint stamps the receiver; a positive transfer carries the sender's stamp to the receiver (never lowering it);
/// burns and zero moves stamp nothing; withdraw/redeem by a stamped owner reverts SameBlockRedeem, and
/// maxWithdraw/maxRedeem report 0 while stamped. Virtual shares with a 6-decimal offset (24-dec shares).
contract MockSIMD is ERC4626 {
    mapping(address => uint256) public lastDepositBlock;

    error SameBlockRedeem();

    constructor(IERC20 asset_) ERC20("Staked IMD", "sIMD") ERC4626(asset_) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice A drip: underlying arrives in the vault, raising the share rate.
    function drip(uint256 assets) external {
        MockERC20(asset()).mint(address(this), assets);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (value != 0 && to != address(0)) {
            if (from == address(0)) lastDepositBlock[to] = block.number;
            else if (lastDepositBlock[from] > lastDepositBlock[to]) lastDepositBlock[to] = lastDepositBlock[from];
        }
        super._update(from, to, value);
    }

    function _withdraw(address by, address to, address owner, uint256 assets, uint256 shares) internal override {
        if (block.number == lastDepositBlock[owner]) revert SameBlockRedeem();
        super._withdraw(by, to, owner, assets, shares);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (block.number == lastDepositBlock[owner]) return 0;
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (block.number == lastDepositBlock[owner]) return 0;
        return super.maxRedeem(owner);
    }
}

/// @notice sINFER's one-block hold, reproduced from the verified StakedInfer (0x5e3B…6cE4): PER LOT. Newly minted
/// shares are held for the block; a transfer spends the sender's unlocked shares first and carries any held part
/// to the receiver with its hold; older shares stay redeemable (maxRedeem excludes only the held lot).
contract MockSINFER is ERC4626 {
    mapping(address => uint256) public lastDepositBlock;
    mapping(address => uint256) private _lockedShares;
    /// @notice Test switch: a vault that pauses or caps deposits.
    bool public depositsPaused;

    error DepositsPaused();

    function pauseDeposits(bool on) external {
        depositsPaused = on;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (depositsPaused) revert DepositsPaused();
        super._deposit(caller, receiver, assets, shares);
    }

    error SameBlockRedeem();

    constructor(IERC20 asset_) ERC20("Staked INFER", "sINFER") ERC4626(asset_) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function drip(uint256 assets) external {
        MockERC20(asset()).mint(address(this), assets);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (shares > maxRedeem(owner)) revert SameBlockRedeem();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 held;
        if (value != 0 && from != to) {
            if (from == address(0)) {
                held = value;
            } else {
                uint256 unlocked = balanceOf(from) - lockedShares(from);
                held = value > unlocked ? value - unlocked : 0;
            }
        }
        super._update(from, to, value);
        if (held != 0) {
            if (from != address(0)) _lockedShares[from] -= held;
            if (to != address(0)) {
                _lockedShares[to] = lockedShares(to) + held;
                lastDepositBlock[to] = block.number;
            }
        }
    }

    function lockedShares(address owner) public view returns (uint256) {
        return block.number == lastDepositBlock[owner] ? _lockedShares[owner] : 0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner) - lockedShares(owner);
    }
}

/// @notice A v4 router for the Compound DEX: exact input or output, any hookData; settles what it owes, takes what
/// it is owed, and forwards the output to the caller.
contract CdxRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, SwapParams memory p, bytes memory hookData) external returns (BalanceDelta d) {
        d = abi.decode(pm.unlock(abi.encode(msg.sender, key, p, hookData)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (address payer, PoolKey memory key, SwapParams memory p, bytes memory hookData) =
            abi.decode(data, (address, PoolKey, SwapParams, bytes));
        BalanceDelta d = pm.swap(key, p, hookData);
        _square(key.currency0, BalanceDeltaLibrary.amount0(d), payer);
        _square(key.currency1, BalanceDeltaLibrary.amount1(d), payer);
        return abi.encode(d);
    }

    function _square(Currency c, int128 delta, address payer) private {
        if (delta < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).safeTransferFrom(payer, address(pm), uint128(-delta));
            pm.settle();
        } else if (delta > 0) {
            pm.take(c, payer, uint128(delta));
        }
    }
}

/// @notice The Treasury as the Compound DEX reads it: only its `token()` (imdUSD), for the D3 listing check.
contract DexTreasuryStub {
    address public token;

    constructor(address token_) {
        token = token_;
    }
}
