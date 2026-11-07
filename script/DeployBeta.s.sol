// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "./Deploy.s.sol";
import {DeployTypes, BetaConfig} from "./DeployConfig.sol";

/// @notice The capped live beta: script/Deploy.s.sol, unchanged, with BetaConfig in place of the
/// full mainnet config. Rehearsed by test/fork/DeployBeta.t.sol.
///
///   forge script script/DeployBeta.s.sol:DeployBeta --rpc-url $MAINNET_RPC_URL --sender <deployer> --broadcast --verify
contract DeployBeta is Deploy {
    function config() public pure override returns (DeployTypes.Config memory) {
        return BetaConfig.get();
    }
}
