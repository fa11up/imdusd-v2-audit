// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ImdBridge, IMintableBurnable} from "../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {MainnetConfig} from "./DeployConfig.sol";

/// @notice Ethereum's side of the 4663 path : one ImdBridge for the already-deployed v2 imdUSD,
/// governed by the mainnet Safe, its per-destination fee minted to the v2 Treasury. Not yet a minter: the Safe then proposes
/// SET_BRIDGE on Parameters (48h) and opens the path with RobinhoodConfig.launchBatchMainnet(robinhoodPathOnMainnet(...)) in
/// one BATCH (48h: path, both library pins, executor + DVN config). The deployer holds no power over it.
/// GUARDIAN: env GUARDIAN = the address of a dedicated operator key (the key itself is never used here).
/// It can only pause and nilify; the ops watcher pauses a path with it when `netMinted()` disagrees with the supply equation. The guardian is immutable (a change
/// is a redeploy), so the script REFUSES a zero guardian except on a local fork (FORK=1) or chain 31337.
///
///   GUARDIAN=<address> forge script script/DeployMainnetBridge.s.sol:DeployMainnetBridge --sig 'run(address,address)' \
///     <imdUSD v2> <v2 Treasury> --rpc-url $MAINNET_RPC_URL --sender <deployer> --broadcast --verify
contract DeployMainnetBridge is Script {
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c; // LayerZero EndpointV2, Ethereum

    error WrongChain(uint256 chainId);
    error NotAContract(address a);
    error TreasuryMismatch(address treasury);
    error NoGuardian();

    function run(address token, address treasury) external returns (ImdBridge bridge) {
        address guardian = guardianFromEnv();
        if (block.chainid != 1) revert WrongChain(block.chainid);
        if (token.code.length == 0) revert NotAContract(token);
        if (treasury.code.length == 0) revert NotAContract(treasury);
        // the v2 Treasury is governed by the same Safe as everything else
        (bool ok, bytes memory g) = treasury.staticcall(abi.encodeWithSignature("governor()"));
        if (!ok || abi.decode(g, (address)) != MainnetConfig.GOVERNANCE_SAFE) revert TreasuryMismatch(treasury);
        vm.startBroadcast();
        bridge = new ImdBridge(
            ILayerZeroEndpointV2(ENDPOINT), IMintableBurnable(token), MainnetConfig.GOVERNANCE_SAFE, guardian, treasury
        );
        vm.stopBroadcast();
    }

    /// @notice env GUARDIAN; zero only on a local fork (FORK=1) or chain 31337, where it is logged as a WARNING.
    function guardianFromEnv() public view returns (address guardian) {
        guardian = vm.envOr("GUARDIAN", address(0));
        if (guardian != address(0)) return guardian;
        if (vm.envOr("FORK", uint256(0)) != 1 && block.chainid != 31337) revert NoGuardian();
        console2.log("WARNING: guardian = 0x0 (local fork only). Only the Safe could pause this bridge or nilify.");
    }
}
