// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PegSystem} from "../utils/PegSystem.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {PegLPVault, IPegHookView} from "../../src/earn/PegLPVault.sol";

/// @notice The peg-LP vault on the REAL mainnet PoolManager with REAL USDC (USDC's blacklist and
/// packed balances, the real settle/take path): deposit, earn fees, compound, ride a fall out of the band, exit whole.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/PegLPVault.fork.t.sol
contract PegLPVaultForkTest is PegSystem {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    PegLPVault vault;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        _deployPeg(PM, IERC20(Mainnet.USDC), 500_000e18);
        _hold(0, 31 minutes);
        vault = new PegLPVault(PM, IPegHookView(address(hook)), address(treasury), 100);
        _fund(alice, 200_000e18, 200_000e6);
        vm.startPrank(alice);
        usd.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _fund(address to, uint256 stableAmt, uint256 quoteAmt) internal override {
        deal(address(usd), to, usd.balanceOf(to) + stableAmt, true);
        baseSupply += stableAmt;
        if (quoteAmt > 10_000_000e6) quoteAmt = 10_000_000e6;
        vm.prank(USDC_WHALE);
        usdc.transfer(to, quoteAmt);
    }

    function _usdOf(address a) internal view returns (uint256) {
        return usd.balanceOf(a) + usdc.balanceOf(a) * 1e12;
    }

    function test_fork_depositEarnFallExit() public {
        uint256 start = _usdOf(alice);
        vm.prank(alice);
        (uint256 shares,,) = vault.deposit(0, 100_000e18, 100_000e6, alice);
        assertGt(vault.liquidity(), 0);

        for (uint256 i; i < 10; ++i) {
            _moveTo(20);
            _moveTo(-20);
        }
        _moveTo(0);
        uint256 tr = _usdOf(address(treasury));
        vault.compound();
        assertGt(_usdOf(address(treasury)), tr, "performance fee in real USDC/imdUSD");

        // A fall to $0.985 for the window: out of the band, the vault holds imdUSD, the exit still works.
        _hold(-150, 31 minutes);
        vm.prank(alice);
        vault.withdraw(shares, 0, 0, alice);
        assertEq(vault.balanceOf(alice), 0);
        // Valued at $1 each, alice lost only what an LP loses to a 1.5% fall inside a ±1% band, minus fees earned.
        uint256 end = _usdOf(alice);
        assertGt(end, start - 2_000e18);
        emit log_named_decimal_int("alice change ($, at par)", int256(end) - int256(start), 18);
    }
}
