// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployTypes, MainnetConfig} from "./DeployConfig.sol";
import {ImdBridge} from "../src/bridge/ImdBridge.sol";
import {DeployBase} from "./deploy/DeployBase.sol";
import {StageCore} from "./deploy/StageCore.sol";
import {StageFeeds} from "./deploy/StageFeeds.sol";
import {StageTypes} from "./deploy/StageTypes.sol";
import {StageGenesis} from "./deploy/StageGenesis.sol";
import {StageModules} from "./deploy/StageModules.sol";

/// @notice Deploys and seals imdUSD v2 from a `DeployTypes.Config`, in test/utils/System.sol's order, in ONE run: the
/// five stages of script/deploy/ back to back. The mainnet launch runs the same stage functions one script per stage
/// (launch tooling not included in this snapshot), resuming from the deployment record; this single run is what every
/// fork and offline test deploys.
///
///   1 core      ImdUSD, Parameters, Pricer, Treasury, Ledger, Redeemer, Liquidator, Migrator + the four wire calls
///   2 feeds     every feed node
///   3 types     joins + wire + addGenesisIlk (+ seats, stocks, chain line where on) + the migrator line
///   4 genesis   SavingsVault, FeeNotes, PegHook + peg pool at $1, PegLPVault, the PEG type, ImdDepth + samplers,
///               the depth rule, PricerOracle + Backstop sleeves + Allocator, the genesis setters, `seal()`
///   (4b bridge  chain configs only: ImdBridge, after the seal)
///   5 modules   LoopVault, the Compound DEX (+ its linked libraries): the full config only
///
/// The numbers in the stage functions' comments (0-7, 5b, 6a, ...) count steps across the whole run, not stages.
///
/// AUTHORITY. The governance Safe is the `governor` of Parameters and Treasury from construction; the
/// deploying EOA is a `wirer`, and the `deployer` of PricerOracle and both Backstop sleeves until each one's own
/// `seal()`. Every such power is single-use: `wire` once per contract, genesis types/lines/savings until `seal`.
/// Stage 4 ends with `seal()`, after which the EOA can change nothing (test/fork/Deploy.t.sol proves each
/// wirer call reverts; PricerOracle.seal and Backstop.seal stay callable by it as no-ops). No contract has an owner.
///
///   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --sender <deployer> --broadcast --verify
contract Deploy is DeployBase, StageCore, StageFeeds, StageTypes, StageGenesis, StageModules {
    function run() external virtual returns (Deployed memory d) {
        DeployTypes.Config memory cfg = config();
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = _deploy(cfg, deployer);
        vm.stopBroadcast();
    }

    /// @notice What `run()` deploys: the full mainnet config. script/DeployBeta.s.sol overrides it with BetaConfig;
    /// the selection is the script entry named on the command line, never an environment variable.
    function config() public pure virtual returns (DeployTypes.Config memory) {
        return MainnetConfig.get();
    }

    /// @notice For the fork rehearsal: the same deployment, broadcast as `deployer`.
    function deployAs(DeployTypes.Config memory cfg, address deployer) external returns (Deployed memory d) {
        vm.startBroadcast(deployer);
        d = _deploy(cfg, deployer);
        vm.stopBroadcast();
    }

    function _deploy(DeployTypes.Config memory cfg, address me) internal returns (Deployed memory d) {
        delete _gasLog;
        _stageCore(cfg, d, me);
        _stageFeeds(cfg, d);
        _stageTypes(cfg, d, me);
        _stageGenesis(cfg, d);

        // 4b (stage). The LayerZero path. Not yet a minter: the Safe proposes SET_BRIDGE (48h) on Parameters, and opens each
        // path (peer, limits, enforced options, DVN config) on the bridge's own 48h timelock.
        if (cfg.bridge.enabled) {
            uint256 g = gasleft();
            d.bridge = _newBridge(cfg.bridge.endpoint, address(d.usd), cfg.governor, cfg.bridge.guardian, address(d.treasury));
            _rec("ImdBridge", g, type(ImdBridge).creationCode.length + 160);
        }

        _stageModules(cfg, d);
    }
}
