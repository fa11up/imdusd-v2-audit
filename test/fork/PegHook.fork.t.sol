// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PegSystem} from "../utils/PegSystem.sol";
import {Mainnet} from "./MainnetAddresses.sol";

/// @notice Exit criterion: against the REAL mainnet v4 PoolManager and REAL USDC, a peg excursion is
/// closed both ways by strangers' calls, with no keeper key.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/PegHook.fork.t.sol
contract PegHookForkTest is PegSystem {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    // Morpho Blue holds hundreds of millions of USDC: the LP's and traders' USDC comes from it (USDC's packed
    // balance slot defeats `deal`).
    address constant USDC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        _deployPeg(PM, IERC20(Mainnet.USDC), 500_000e18);
        _hold(0, 31 minutes);
    }

    function _fund(address to, uint256 stableAmt, uint256 quoteAmt) internal override {
        deal(address(usd), to, usd.balanceOf(to) + stableAmt, true);
        baseSupply += stableAmt;
        if (quoteAmt > 10_000_000e6) quoteAmt = 10_000_000e6;
        vm.prank(USDC_WHALE);
        usdc.transfer(to, quoteAmt);
    }

    function test_fork_excursionClosedBothWays() public {
        address stranger1 = makeAddr("stranger1");
        address stranger2 = makeAddr("stranger2");
        uint256 t0 = usdc.balanceOf(address(treasury));

        // Above: imdUSD trades at +0.6% for half an hour. A stranger's call sells it back to the peg.
        _hold(60, 31 minutes);
        assertGt(_spotPrice(), 1.005e18);
        vm.prank(stranger1);
        uint256 minted = hook.provide();
        assertGt(minted, 0);
        assertGe(_spotPrice(), 1e18);
        assertLe(_spotPrice(), 1.0006e18, "closed from above");
        assertGt(usdc.balanceOf(stranger1), 0, "caller paid from profit");
        _assertKeeperSolvent();

        // Below: imdUSD trades at -0.6%. Another stranger's call buys it back and burns it.
        _hold(-60, 31 minutes);
        assertLt(_spotPrice(), 0.995e18);
        vm.prank(stranger2);
        (uint256 burned,) = hook.withdraw();
        assertGt(burned, 0);
        assertLe(burned, minted);
        assertLe(_spotPrice(), 1e18);
        assertGe(_spotPrice(), 0.9994e18, "closed from below");
        assertGt(usdc.balanceOf(stranger2), 0);
        assertGt(usdc.balanceOf(address(treasury)), t0, "profit to the Treasury");
        _assertKeeperSolvent();
        emit log_named_uint("minted", minted);
        emit log_named_uint("burned", burned);
        emit log_named_uint("treasury USDC", usdc.balanceOf(address(treasury)) - t0);
        emit log_named_uint("callers USDC", usdc.balanceOf(stranger1) + usdc.balanceOf(stranger2));
    }

    function test_fork_surchargeOnRealPoolManager() public {
        _moveTo(-150);
        uint256 t = usdc.balanceOf(address(treasury)) + usd.balanceOf(address(treasury));
        hook.sweep(key.currency0);
        hook.sweep(key.currency1);
        assertGt(usdc.balanceOf(address(treasury)) + usd.balanceOf(address(treasury)), t);
    }
}
