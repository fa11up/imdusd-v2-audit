// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CompoundSystem} from "./CompoundSystem.sol";
import {MockERC20} from "./Mocks.sol";
import {MockSIMD, MockSINFER} from "./DexMocks.sol";

/// @notice The Compound DEX on a local PoolManager with mock IMD/INFER and vaults that reproduce sIMD's
/// whole-address hold and sINFER's per-lot hold. Both vaults start at a share rate above the 4626 default (an
/// outsider staked, then a drip arrived), so share and asset amounts differ everywhere.
abstract contract CompoundMockSystem is CompoundSystem {
    MockERC20 internal imd;
    MockERC20 internal infer;
    MockSIMD internal simd;
    MockSINFER internal sinfer;
    address internal outsider = makeAddr("outsider");

    uint256 internal constant SEED = 1_000_000e18;

    function _deployMock(uint160 sqrtP) internal {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        (address lo, address hi) =
            (address(0x1000000000000000000000000000000000000001), address(0xF000000000000000000000000000000000000001));
        (address ai, address an) = _imdIsToken0() ? (lo, hi) : (hi, lo);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("IMD", uint8(18)), ai);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("INFER", uint8(18)), an);
        imd = MockERC20(ai);
        infer = MockERC20(an);
        simd = new MockSIMD(IERC20(address(imd)));
        sinfer = new MockSINFER(IERC20(address(infer)));
        _outsiderStake(address(simd), imd, 5_000_000e18);
        _outsiderStake(address(sinfer), infer, 50_000_000e18);
        simd.drip(1_250_000e18); // rate 1.25 IMD per 1e6 shares-unit
        sinfer.drip(7_500_000e18); // rate 1.15
        _deployDex(IPoolManager(address(new PoolManager(address(this)))), simd, sinfer, sqrtP);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _outsiderStake(address vault, MockERC20 t, uint256 amount) private {
        t.mint(outsider, amount);
        vm.startPrank(outsider);
        t.approve(vault, amount);
        IERC4626(vault).deposit(amount, outsider);
        vm.stopPrank();
    }

    /// @dev Which underlying sorts first (tests run both orders).
    function _imdIsToken0() internal view virtual returns (bool) {
        return false;
    }

    function _fundRaw(address to, uint8 i, uint256 amount) internal override {
        MockERC20(address(_tok(i))).mint(to, amount);
    }

    /// @dev Side index of IMD (the whole-address-hold vault).
    function _imdSide() internal view returns (uint8) {
        return address(hook.token0()) == address(imd) ? 0 : 1;
    }

    function _drip(uint8 i, uint256 assets) internal {
        if (address(_vlt(i)) == address(simd)) simd.drip(assets);
        else sinfer.drip(assets);
    }

    function _next() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }
}
