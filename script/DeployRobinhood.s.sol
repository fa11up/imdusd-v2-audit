// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployChain} from "./DeployChain.s.sol";
import {console2} from "forge-std/console2.sol";
import {DeployTypes, RobinhoodConfig} from "./DeployConfig.sol";

/// @notice Robinhood Chain (4663): script/Deploy.s.sol, unchanged, with RobinhoodConfig. The base script
/// refuses any chain but 4663 (`ChainSpec.chainId`); this entry also refuses a governor with no code, so the placeholder
/// (no Safe on 4663 yet) and any EOA are rejected before anything is broadcast. Rehearsed by test/fork/RobinhoodDeploy.t.sol.
///
///   GUARDIAN=<guardian address> forge script script/DeployRobinhood.s.sol:DeployRobinhood --rpc-url $ROBINHOOD_RPC_URL --sender <deployer> --broadcast
///
/// After it (the Safe): SET_BRIDGE on Parameters (48h) here and on mainnet; ImdBridge SET_PATH on
/// both = RobinhoodConfig.launchBatch4663 / launchBatchMainnet (peer + limits, both library pins, executor + DVN config; 48h); buy the first IMD price, spot and NHI
/// attestations for the three swarm feeds (consumer chain 4663) and check them against mainnet before any IMD deposit.
contract DeployRobinhood is DeployChain {
    error GovernorNotAContract(address governor);
    error NoGuardian();

    function config() public pure override returns (DeployTypes.Config memory) {
        return RobinhoodConfig.get();
    }

    function run() external override returns (Deployed memory d) {
        DeployTypes.Config memory cfg = config();
        if (cfg.governor.code.length == 0) revert GovernorNotAContract(cfg.governor);
        if (cfg.bridge.enabled) cfg.bridge.guardian = guardianFromEnv();
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d = _deploy(cfg, deployer);
        vm.stopBroadcast();
    }

    /// @notice The bridge guardian: env GUARDIAN = the address of a dedicated operator key.
    /// Pause + nilify only; the ops watcher pauses a path
    /// with it when `netMinted()` disagrees with the supply equation. Immutable, so zero is REFUSED except on a local fork
    /// (FORK=1) or chain 31337.
    function guardianFromEnv() public view returns (address guardian) {
        guardian = vm.envOr("GUARDIAN", address(0));
        if (guardian != address(0)) return guardian;
        if (vm.envOr("FORK", uint256(0)) != 1 && block.chainid != 31337) revert NoGuardian();
        console2.log("WARNING: bridge guardian = 0x0 (local fork only). Only the Safe could pause the bridge or nilify.");
    }
}
