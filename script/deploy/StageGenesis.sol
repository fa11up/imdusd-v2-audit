// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SavingsVault} from "../../src/SavingsVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PegHook, IKeeperCap} from "../../src/peg/PegHook.sol";
import {FeeNotes, ITreasuryNotes} from "../../src/peg/FeeNotes.sol";
import {PegLPVault, IPegHookView} from "../../src/earn/PegLPVault.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";
import {StagePeg} from "./StagePeg.sol";
import {ImdDepth} from "../../src/feeds/ImdDepth.sol";
import {DepthSampler} from "../../src/feeds/DepthSampler.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {IBackstopOracle, ILedgerCover} from "../../src/backstop/IBackstop.sol";
import {PricerOracle} from "../../src/backstop/PricerOracle.sol";
import {Allocator} from "../../src/peg/Allocator.sol";

/// @notice Stage 4, the genesis modules and the seal: SavingsVault + its share, FeeNotes (wired both ways, dormant),
/// the PegHook at a mined CREATE2 address with its pool opened at $1 and named the keeper minter, then `seal()`.
/// After it the deployer holds no power anywhere.
abstract contract StageGenesis is StagePeg {
    function _stageGenesis(DeployTypes.Config memory cfg, Deployed memory d) internal {
        uint256 g;
        // 4. sImdUSD.
        if (!(_has(address(d.savings)) && _ok(d.savings.asset() == address(d.usd), "SavingsVault"))) {
            g = gasleft();
            d.savings = new SavingsVault(IERC20(address(d.usd)));
            _rec("SavingsVault", g, type(SavingsVault).creationCode.length + 32);
        }
        (address sv, uint256 share) = d.params.savingsSplit();
        if (sv != address(d.savings) || share != cfg.savingsShare) {
            g = gasleft();
            d.params.setGenesisSavings(address(d.savings), cfg.savingsShare);
            _rec("params.setGenesisSavings", g, CALL_DATA);
        }

        // 4b. Fee notes: sold for the peg quote (USDC) to the Treasury; a series opens only through the
        // timelock, so nothing can be sold at launch.
        if (cfg.pegQuote != address(0)) {
            if (
                !(
                    _has(address(d.notes))
                        && _ok(
                            address(d.notes.token()) == address(d.usd) && address(d.notes.quote()) == cfg.pegQuote
                                && address(d.notes.treasury()) == address(d.treasury) && d.notes.params() == address(d.params),
                            "FeeNotes"
                        )
                )
            ) {
                g = gasleft();
                d.notes = new FeeNotes(
                    IERC20(address(d.usd)), IERC20(cfg.pegQuote), ITreasuryNotes(address(d.treasury)), address(d.params)
                );
                _rec("FeeNotes", g, type(FeeNotes).creationCode.length + 128);
            }
            if (d.treasury.notes() == address(0)) {
                g = gasleft();
                d.treasury.wireNotes(address(d.notes));
                _rec("treasury.wireNotes", g, CALL_DATA);
            } else if (d.treasury.notes() != address(d.notes)) {
                revert Mismatch("Treasury wired to other FeeNotes");
            }
            if (d.params.notes() != address(d.notes)) {
                g = gasleft();
                d.params.setGenesisNotes(address(d.notes));
                _rec("params.setGenesisNotes", g, CALL_DATA);
            }
        }

        // 5. The peg hook: mined CREATE2 address, its pool opened at $1, wired as the keeper minter.
        if (cfg.poolManager != address(0)) {
            if (
                !(
                    _has(address(d.hook))
                        && _ok(
                            d.hook.stable() == address(d.usd) && d.hook.quote() == cfg.pegQuote
                                && d.hook.treasury() == address(d.treasury) && address(d.hook.params()) == address(d.params)
                                && address(d.hook.poolManager()) == cfg.poolManager
                                && d.hook.quoteUsdFeed() == cfg.pegQuoteFeed && d.hook.quoteFeedMaxAge() == cfg.pegQuoteFeedMaxAge,
                            "PegHook"
                        )
                )
            ) {
                d.hook = _deployHook(cfg, d);
            }
            (address c0, address c1) =
                d.hook.stableIsToken0() ? (address(d.usd), cfg.pegQuote) : (cfg.pegQuote, address(d.usd));
            d.pegKey = PoolKey(
                Currency.wrap(c0), Currency.wrap(c1), d.hook.BASE_FEE(), d.hook.TICK_SPACING(), IHooks(address(d.hook))
            );
            if (!d.hook.initialized()) {
                g = gasleft();
                IPoolManager(cfg.poolManager).initialize(d.pegKey, d.hook.pegSqrtPriceX96());
                _rec("poolManager.initialize (peg)", g, CALL_DATA);
            }
            if (d.usd.keeper() == address(0)) {
                g = gasleft();
                d.params.setGenesisKeeper(address(d.hook));
                _rec("params.setGenesisKeeper", g, CALL_DATA);
            } else if (d.usd.keeper() != address(d.hook)) {
                revert Mismatch("ImdUSD keeper is another contract");
            }
        }
        // 5b. PegLPVault (in the beta from day 1): on the peg pool just opened. Deployed here, not in stage 5,
        // so the beta (stages 1-4, no DEX libraries linked) deploys it exactly as the full config does.
        if (cfg.lpVault.enabled) {
            if (address(d.hook) == address(0)) revert ModuleNeeds("lpVault", "peg hook");
            if (
                !(
                    _has(address(d.pegLP))
                        && _ok(
                            address(d.pegLP.hook()) == address(d.hook) && d.pegLP.treasury() == address(d.treasury)
                                && d.pegLP.tickUpper() - d.pegLP.tickLower() == 2 * cfg.lpVault.band,
                            "PegLPVault"
                        )
                )
            ) {
                g = gasleft();
                d.pegLP = new PegLPVault(
                    IPoolManager(cfg.poolManager), IPegHookView(address(d.hook)), address(d.treasury), cfg.lpVault.band
                );
                _rec("PegLPVault", g, type(PegLPVault).creationCode.length + 128);
            }
        }

        // 5c. Peg positions (a type on PegLPVault shares), before the seal.
        _stagePeg(cfg, d);

        // 6a. The measured IMD depth. ImdDepth + one DepthSampler per exit pool, listed before the seal. They
        // read 0 until 20 hours of samples and 6 days of daily lows exist, so the beta's sIMD line (opened on day 7) is
        // the first thing they gate; the keeper samples every pool and pokes ImdDepth hourly from genesis.
        if (cfg.depth.enabled) _stageDepth(cfg, d);

        // 6. D1: the sIMD line's depth rule (k, the posted depth CAP). Not checked at genesis.
        if (
            cfg.depthIlk != bytes32(0)
                && (
                    d.params.depthIlk() != cfg.depthIlk || d.params.depthK() != cfg.depthK || d.params.depthCap() != cfg.depthIMD
                        || d.params.otherImdLines() != cfg.otherImdLines || d.params.otherImdChop() != cfg.otherImdChop
                )
        ) {
            g = gasleft();
            d.params.setGenesisDepthRule(cfg.depthIlk, cfg.depthK, cfg.depthIMD, cfg.otherImdLines, cfg.otherImdChop);
            _rec("params.setGenesisDepthRule", g, CALL_DATA);
        }
        // 6b. The standing bid. PricerOracle (genesis tokens mapped, then sealed), the blue and edge Backstop
        // sleeves (wired to the Liquidator, Parameters and the Allocator as seller; genesis types listed; sealed), the
        // Allocator (its keeper, targets and limits come through its own 48h timelock after the deploy), and
        // Parameters pointed at both sleeves with the edge type flagged. All before the seal.
        if (cfg.backstop.enabled) _stageBackstop(cfg, d);

        if (!d.params.sealed_()) {
            g = gasleft();
            d.params.seal();
            _rec("params.seal", g, CALL_DATA);
        }
    }

    function _stageBackstop(DeployTypes.Config memory cfg, Deployed memory d) internal {
        uint256 g;
        DeployTypes.BackstopSpec memory b = cfg.backstop;
        if (!(_has(address(d.backstopOracle)) && _ok(address(d.backstopOracle.pricer()) == address(d.pricer)
                    && d.backstopOracle.params() == address(d.params), "PricerOracle"))) {
            g = gasleft();
            d.backstopOracle = new PricerOracle(d.pricer, address(d.params));
            _rec("PricerOracle", g, type(PricerOracle).creationCode.length + 64);
        }
        if (!(_has(address(d.allocator)) && _ok(d.allocator.treasury() == address(d.treasury) && d.allocator.governor() == cfg.governor,
                    "Allocator"))) {
            g = gasleft();
            d.allocator = new Allocator(cfg.governor, address(d.treasury), b.freezer, b.maxSlippageBps);
            _rec("Allocator", g, type(Allocator).creationCode.length + 128);
        }
        d.blue = _sleeve(d, d.blue, false, "imdUSD Backstop Blue", "bBLUE");
        d.edge = _sleeve(d, d.edge, true, "imdUSD Backstop Edge", "bEDGE");
        for (uint256 i; i < b.ilks.length; ++i) {
            DeployTypes.SleeveIlk memory si = b.ilks[i];
            address token = d.params.config(si.ilk).token;
            if (token == address(0)) revert Mismatch("backstop: type not registered");
            if (d.backstopOracle.ilkOf(token) == bytes32(0)) {
                g = gasleft();
                d.backstopOracle.setIlk(token, si.ilk);
                _rec("backstopOracle.setIlk", g, CALL_DATA);
            }
            Backstop s = si.edge ? d.edge : d.blue;
            (address listed,,,) = s.ilks(si.ilk);
            if (listed == address(0)) {
                g = gasleft();
                s.addIlk(si.ilk, token, si.genesisLine, si.saleMax, si.saleMax / 1 days);
                _rec("backstop.addIlk", g, CALL_DATA + 64);
            }
        }
        if (!d.backstopOracle.sealed_()) {
            g = gasleft();
            d.backstopOracle.seal();
            _rec("backstopOracle.seal", g, CALL_DATA);
        }
        if (!d.blue.isSealed()) {
            g = gasleft();
            d.blue.seal();
            _rec("blue.seal", g, CALL_DATA);
        }
        if (!d.edge.isSealed()) {
            g = gasleft();
            d.edge.seal();
            _rec("edge.seal", g, CALL_DATA);
        }
        if (d.params.blueBackstop() == address(0)) {
            uint64 premium = b.edgePremium;
            g = gasleft();
            d.params.setGenesisBackstops(address(d.blue), address(d.edge), premium);
            _rec("params.setGenesisBackstops", g, CALL_DATA);
        } else if (d.params.blueBackstop() != address(d.blue) || d.params.edgeBackstop() != address(d.edge)) {
            revert Mismatch("Parameters points at other sleeves");
        }
        for (uint256 i; i < b.ilks.length; ++i) {
            if (b.ilks[i].edge && !d.params.edgeIlk(b.ilks[i].ilk)) {
                g = gasleft();
                d.params.setGenesisEdgeIlk(b.ilks[i].ilk);
                _rec("params.setGenesisEdgeIlk", g, CALL_DATA);
            }
        }
    }

    /// @dev Deploy (or verify) one sleeve and wire it once: the Liquidator bids, Parameters lists after the seal, the
    /// Allocator sells.
    function _sleeve(Deployed memory d, Backstop s, bool edge, string memory name, string memory symbol)
        internal
        returns (Backstop)
    {
        uint256 g;
        if (!(_has(address(s)) && _ok(address(s.imdUSD()) == address(d.usd) && address(s.ledger()) == address(d.ledger)
                    && address(s.oracle()) == address(d.backstopOracle) && s.edge() == edge, edge ? "Backstop edge" : "Backstop blue"))) {
            g = gasleft();
            s = new Backstop(IERC20(address(d.usd)), ILedgerCover(address(d.ledger)), IBackstopOracle(address(d.backstopOracle)), edge, name, symbol);
            _rec(edge ? "Backstop edge" : "Backstop blue", g, type(Backstop).creationCode.length + 256);
        }
        if (s.liquidator() == address(0)) {
            g = gasleft();
            s.wire(address(d.liquidator), address(d.params), address(d.allocator));
            _rec("backstop.wire", g, CALL_DATA);
        } else if (s.liquidator() != address(d.liquidator) || s.params() != address(d.params) || s.seller() != address(d.allocator)) {
            revert Mismatch("Backstop wired to other contracts");
        }
        return s;
    }

    function _stageDepth(DeployTypes.Config memory cfg, Deployed memory d) internal {
        uint256 g;
        if (!(_has(address(d.imdDepth)) && _ok(d.imdDepth.params() == address(d.params), "ImdDepth"))) {
            g = gasleft();
            d.imdDepth = new ImdDepth(address(d.params));
            _rec("ImdDepth", g, type(ImdDepth).creationCode.length + 32);
        }
        uint256 n = cfg.depth.samplers.length;
        if (d.samplers.length != n) d.samplers = new DepthSampler[](n);
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            DeployTypes.SamplerSpec memory sp = cfg.depth.samplers[i];
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(sp.currency0),
                currency1: Currency.wrap(sp.currency1),
                fee: sp.fee,
                tickSpacing: sp.tickSpacing,
                hooks: IHooks(sp.hooks)
            });
            require(keccak256(abi.encode(key)) == sp.poolId, "depth sampler: key does not hash to its pool id");
            if (!(_has(address(d.samplers[i])) && _ok(PoolId.unwrap(d.samplers[i].poolId()) == sp.poolId, "DepthSampler"))) {
                IFeed f0 = sp.feed0 == DeployTypes.NO_FEED ? IFeed(address(0)) : d.feeds[sp.feed0];
                IFeed f1 = sp.feed1 == DeployTypes.NO_FEED ? IFeed(address(0)) : d.feeds[sp.feed1];
                g = gasleft();
                d.samplers[i] = new DepthSampler(
                    IPoolManager(cfg.poolManager), key, f0, f1, sp.bandBps, sp.maxDeviationTicks, sp.maxSteps, sp.soldIsToken0
                );
                _rec("DepthSampler", g, type(DepthSampler).creationCode.length + 448);
            }
            list[i] = address(d.samplers[i]);
        }
        if (address(d.params.imdDepth()) != address(d.imdDepth)) {
            g = gasleft();
            d.params.setGenesisImdDepth(address(d.imdDepth), list);
            _rec("params.setGenesisImdDepth", g, CALL_DATA + 32 * n);
        }
    }

    function _deployHook(DeployTypes.Config memory cfg, Deployed memory d) internal returns (PegHook) {
        bytes memory init = abi.encodePacked(
            type(PegHook).creationCode,
            abi.encode(
                IPoolManager(cfg.poolManager),
                address(d.usd),
                cfg.pegQuote,
                address(d.treasury),
                IKeeperCap(address(d.params)),
                cfg.pegQuoteFeed,
                cfg.pegQuoteFeedMaxAge
            )
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address a, bytes32 salt) = _create2Mined(init, flags, "PegHook");
        _pegHookSalt = salt;
        return PegHook(a);
    }
}
