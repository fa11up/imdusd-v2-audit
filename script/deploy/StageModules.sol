// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {LoopVault} from "../../src/earn/LoopVault.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {CompoundCurve} from "../../src/dex/CompoundCurve.sol";
import {CompoundOracle} from "../../src/dex/CompoundOracle.sol";
import {CompoundLens} from "../../src/dex/CompoundLens.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";

/// @notice Stage 5, the optional modules (the FULL config only): LoopVault and the Compound DEX (its two
/// linked libraries, the hook at a mined CREATE2 address, its NoOp pool, the lens). Only a script that inherits this
/// contract links CompoundCurve/CompoundOracle, so the beta's stages never deploy them.
abstract contract StageModules is DeployBase {
    // 6. Earn vaults. No owner, no wirer: fixed at construction.
    function _stageModules(DeployTypes.Config memory cfg, Deployed memory d) internal {
        uint256 g;
        if (cfg.loopVault.enabled) {
            if (
                !(
                    _has(address(d.loop))
                        && _ok(
                            d.loop.ledger() == d.ledger && d.loop.ilk() == cfg.loopVault.ilk
                                && d.loop.treasury() == address(d.treasury),
                            "LoopVault"
                        )
                )
            ) {
                g = gasleft();
                d.loop = new LoopVault(d.ledger, cfg.loopVault.ilk, address(d.treasury));
                _rec("LoopVault", g, type(LoopVault).creationCode.length + 96);
            }
        }

        // 7. The Compound DEX: libraries at deterministic addresses, hook at a mined CREATE2 address, its
        // NoOp pool initialised at the opening price. No liquidity: the first deposit is a Safe act.
        if (cfg.dex.enabled) _deployDex(cfg, d);
    }

    /// @notice The DEX's opening price: the config's, or the market pool's slot0 at this block.
    function dexPriceFor(DeployTypes.Config memory cfg) public view returns (uint160 sp) {
        sp = cfg.dex.sqrtPriceX96;
        if (sp == 0) (sp,,,) = StateLibrary.getSlot0(IPoolManager(cfg.poolManager), PoolId.wrap(cfg.dex.marketPoolId));
        if (sp <= TickMath.MIN_SQRT_PRICE || sp >= TickMath.MAX_SQRT_PRICE) revert BadDexPrice(sp);
    }

    /// @dev What the hook is deployed with. The single-run deploy reads the market; the launch's Stage 5 takes
    /// the figure the operator compared instead, because forge simulates twice (the pool may move in between).
    function _dexOpeningPrice(DeployTypes.Config memory cfg) internal view virtual returns (uint160) {
        return dexPriceFor(cfg);
    }

    function _deployDex(DeployTypes.Config memory cfg, Deployed memory d) internal {
        // The linked libraries: `forge script` deploys them before the run through the CREATE2 deployer (salt
        // `create2_library_salt`, 0) whenever that deployer exists on the chain, so their addresses, the hook's linked
        // init code and therefore its mined salt are all fixed before anything is broadcast. Forge's test runner links
        // them at its own addresses; either way they must exist here.
        d.curveLib = address(CompoundCurve);
        d.oracleLib = address(CompoundOracle);
        if (d.curveLib.code.length == 0) revert LibraryMissing(d.curveLib);
        if (d.oracleLib.code.length == 0) revert LibraryMissing(d.oracleLib);
        // A hook kept from an earlier run keeps its own opening price (an immutable); a new one opens at today's.
        bool kept = _has(address(d.dexHook))
            && _ok(
                d.dexHook.treasury() == address(d.treasury) && address(d.dexHook.poolManager()) == cfg.poolManager,
                "CompoundHook"
            );
        uint160 sp = kept ? d.dexHook.initialSqrtPriceX96() : _dexOpeningPrice(cfg);
        if (!kept) {
            bytes memory init = abi.encodePacked(
                type(CompoundHook).creationCode,
                abi.encode(
                    IPoolManager(cfg.poolManager), IERC4626(cfg.dex.vaultA), IERC4626(cfg.dex.vaultB), address(d.treasury), sp
                )
            );
            (address a, bytes32 salt) = _create2Mined(init, _dexFlags(), "CompoundHook (+CompoundPocket)");
            d.dexHook = CompoundHook(a);
            _dexHookSalt = salt;
        }
        d.dexKey = PoolKey(
            Currency.wrap(address(d.dexHook.token0())),
            Currency.wrap(address(d.dexHook.token1())),
            d.dexHook.FEE_PIPS(),
            d.dexHook.TICK_SPACING(),
            IHooks(address(d.dexHook))
        );
        uint256 g;
        if (!d.dexHook.initialized()) {
            g = gasleft();
            IPoolManager(cfg.poolManager).initialize(d.dexKey, sp);
            _rec("poolManager.initialize (dex)", g, CALL_DATA);
        }
        if (!_has(address(d.dexLens))) {
            g = gasleft();
            d.dexLens = new CompoundLens();
            _rec("CompoundLens", g, type(CompoundLens).creationCode.length);
        }
    }

    function _dexFlags() internal pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    }
}
