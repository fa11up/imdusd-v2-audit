// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PegSystem} from "../utils/PegSystem.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {Join} from "../../src/Join.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {PegLPVault, IPegHookView} from "../../src/earn/PegLPVault.sol";
import {PegShareFeed, IPegVaultRead} from "../../src/earn/PegShareFeed.sol";
import {PegCollateral} from "../../src/earn/PegCollateral.sol";
import {PegPositionZap, IPegZapVault, IPegZapLedger} from "../../src/earn/PegPositionZap.sol";
import {MainnetConfig} from "../../script/DeployConfig.sol";

interface IApprove {
    function approveOperator(uint256 id, address operator, uint8 mask) external;
}

/// @notice Peg positions on the live v4 PoolManager with real USDC: open, earn, unwind.
contract PegPositionsForkTest is PegSystem {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant USDC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    bytes32 constant PEG = "PEG";

    PegLPVault vault;
    PegShareFeed feed;
    PegPositionZap zap;
    address alice = makeAddr("alice");
    address seed = makeAddr("seed");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        _deployPeg(PM, IERC20(Mainnet.USDC), 500_000e18);
        _hold(0, 31 minutes);
        vault = new PegLPVault(PM, IPegHookView(address(hook)), address(treasury), 100);
        feed = new PegShareFeed(IPegVaultRead(address(vault)), address(usd), address(quoteUsd), QUOTE_MAX_AGE, false);
        PegCollateral coll = new PegCollateral(IERC20(address(vault)), address(this));
        Join join = new Join(address(coll), address(this));
        join.wire(address(ledger));
        ParametersBase.Config memory c = ParametersBase.Config({
            token: address(coll),
            join: address(join),
            median: IFeed(address(feed)),
            spot: IFeed(address(new PegShareFeed(IPegVaultRead(address(vault)), address(usd), address(quoteUsd), QUOTE_MAX_AGE, true))),
            nhi: IFeed(address(0)),
            yieldRate: address(0),
            pegAggregator: address(quoteUsd),
            liveSpot: IFeed(address(0)),
            redeemable: false,
            auction: false
        });
        bytes memory add = abi.encode(params.ADD_ILK(), PEG, c, MainnetConfig.pegRisk(50_000e18));
        vm.prank(governor);
        params.propose(add);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        _hold(0, 31 minutes);
        zap = new PegPositionZap(IERC20(address(usd)), IPegZapVault(address(vault)), coll, IPegZapLedger(address(ledger)), PEG);
        coll.setZap(address(zap));

        _fund(seed, 50_000e18, 50_000e6);
        vm.startPrank(seed);
        usd.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        if (hook.stableIsToken0()) vault.deposit(0, 50_000e18, 50_000e6, seed);
        else vault.deposit(0, 50_000e6, 50_000e18, seed);
        vm.stopPrank();
        _fund(alice, 0, 20_000e6);
    }

    function _fund(address to, uint256 stableAmt, uint256 quoteAmt) internal override {
        deal(address(usd), to, usd.balanceOf(to) + stableAmt, true);
        baseSupply += stableAmt;
        if (quoteAmt == 0) return;
        vm.prank(USDC_WHALE);
        usdc.transfer(to, quoteAmt);
    }

    function test_fork_openEarnUnwind() public {
        vm.startPrank(alice);
        usdc.approve(address(zap), type(uint256).max);
        uint256 id = zap.open(10_000e6, 0.02e18, 0, type(uint256).max, 0, 0);
        vm.stopPrank();
        assertEq(ledger.nft().ownerOf(id), alice);
        (bool ok, bool priced) = ledger.healthy(id);
        assertTrue(ok && priced);
        assertApproxEqRel(ledger.debtOf(id), 10_000e18, 0.02e18);

        for (uint256 i; i < 10; ++i) {
            _moveTo(20);
            _moveTo(-20);
        }
        _hold(0, 31 minutes);
        vault.compound();

        address nft = address(ledger.nft());
        vm.prank(alice);
        IApprove(nft).approveOperator(id, address(zap), 32);
        _fund(alice, 500e18, 0); // the upfront fee + interest
        uint256 u0 = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usd.approve(address(zap), type(uint256).max);
        zap.unwind(id, 0, type(uint256).max);
        vm.stopPrank();
        assertEq(ledger.debtOf(id), 0);
        assertApproxEqRel(usdc.balanceOf(alice) - u0, 10_000e6, 0.02e18, "real USDC back");
        assertEq(usd.balanceOf(address(zap)) + usdc.balanceOf(address(zap)) + vault.balanceOf(address(zap)), 0);
    }
}
