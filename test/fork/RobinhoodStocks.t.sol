// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RobinhoodStocksFork, PoolSeller} from "./RobinhoodStocksBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DeployTypes, RobinhoodConfig} from "../../script/DeployConfig.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IStockToken {
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
    function pauseOracle() external;
    function unpauseOracle() external;
    function adminBurn(address from, uint256 amount) external;
}

interface IStockRegistry {
    function pause() external;
    function unpause() external;
    function blockAccounts(address[] calldata accounts) external;
    function unblockAccounts(address[] calldata accounts) external;
}

/// @notice Exit criterion on a Robinhood Chain fork: a Friday position survives a Monday gap; a paused
/// token freezes its type; a market-closed liquidation waits for the open. Plus a round trip and a USDG-settled auction whose
/// stock is sold on the real v4 pool. ONE SUITE AT A TIME on the public RPC:
///   ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/fork/RobinhoodStocks.t.sol
/// REAL: RobinhoodConfig through DeployChain; the SPY token (beacon proxy), its registry, the SPY Chainlink feed, USDG, the v4
/// PoolManager and the SPY/USDG pool; every issuer action is the real function called by its real role holder (pranked).
/// MOCKED: the Safe (a stand-in); time (warps, with the keeper's 10-minute Pulse pokes); the SPY answer after a warp (the
/// real answer re-stamped, or moved by the scenario: the measured p99.9 weekend gap).
contract RobinhoodStocksTest is RobinhoodStocksFork {
    uint256 constant SPY_P999_GAP_BPS = 790; // weekend-gap study: SPY, 2000-2026, weekend + holiday closures

    function setUp() public {
        _setUpFork();
    }

    function _join() internal view returns (StockJoin) {
        return d.stockJoins[spyIndex];
    }

    /// @dev alice pledges `amount` SPY at the current answer and borrows `debt`.
    function _position(uint256 amount, uint256 debt) internal {
        _give(RobinhoodConfig.SPY, alice, amount);
        _approveAll(alice);
        vm.prank(alice);
        d.ledger.open(SPY, 0, Adjust(int256(amount), int256(debt), 0.05e18, 0, 0, true, type(uint256).max, address(0)));
    }

    /// @dev An hour into a session that still has at least an hour to run (the fork block may sit late in one).
    function _inSession() internal {
        uint256 t = _nextOpen(vm.getBlockTimestamp() + 1);
        while (!d.calendar.isOpen(t + 2 hours)) t = _nextOpen(t + 8 hours);
        _walk(t + 1 hours);
        _spy(spyAnswer);
    }

    function test_stockTypesDeployedAsConfigured() public view {
        DeployTypes.StocksSpec memory s = RobinhoodConfig.stocks();
        assertEq(d.stockJoins.length, s.types.length);
        for (uint256 i; i < s.types.length; ++i) {
            ParametersBase.Config memory c = d.params.config(s.types[i].ilk);
            assertTrue(c.auction && !c.redeemable);
            assertEq(c.token, address(d.stockVaults[i]));
            assertEq(c.join, address(d.stockJoins[i]));
            assertEq(address(c.median), address(d.stockPrices[i]));
            assertEq(d.stockVaults[i].asset(), s.types[i].stock);
            assertEq(d.stockFeeds[i].aggregator(), s.types[i].aggregator);
            assertEq(d.stockFeeds[i].registry(), RobinhoodConfig.STOCK_REGISTRY);
            assertEq(d.stockFeeds[i].holder(), address(d.stockVaults[i]));
            assertFalse(d.stockFeeds[i].frozen(), "no issuer action on any allowlisted token at the fork block");
            assertEq(d.params.risk(s.types[i].ilk).mat, s.types[i].risk.mat);
            assertEq(d.params.groupOf(s.types[i].ilk), RobinhoodConfig.STOCK_GROUP);
        }
        (, uint256 line) = d.params.groupCap(SPY);
        assertEq(line, RobinhoodConfig.CHAIN_LINE / 4, "stock + SGOV within 25% of the chain line");
        // 9 types since AAPL: the per-type lines sum past the group line, so the group line binds
        uint256 sum;
        for (uint256 i; i < s.types.length; ++i) sum += d.params.risk(s.types[i].ilk).line;
        assertEq(s.types.length, 9);
        assertEq(sum, 8_250e18);
        assertGt(sum, line);
        assertEq(s.types[7].ilk, bytes32("STOCK-AAPL"));
        assertEq(d.params.risk("STOCK-AAPL").mat, 1.45e18);
        assertEq(d.calendar.governor(), safe);
    }

    function test_roundTripSpyInTheSession() public {
        _inSession();
        _position(3e18, 1_000e18);
        assertEq(IERC20(RobinhoodConfig.SPY).balanceOf(address(d.stockVaults[spyIndex])), 3e18, "staked into the vault");
        // Repay all: the amount + its upfront fee, whose imdUSD the Treasury received.
        uint256 owed = d.ledger.debtOf(_pid(SPY, alice));
        vm.prank(address(d.treasury));
        d.usd.transfer(alice, owed - 1_000e18);
        vm.prank(alice);
        // shares carry 6 more decimals than the stock (StockVault._decimalsOffset): 3 tokens = 3e24 shares
        d.ledger.open(SPY, 0, Adjust(-3e24, -int256(owed), 0, 0, 0, true, type(uint256).max, address(0)));
        assertEq(IERC20(RobinhoodConfig.SPY).balanceOf(alice), 3e18, "the real token back");
        assertEq(d.ledger.debtOf(_pid(SPY, alice)), 0);
    }

    /// @notice EXIT CRITERION 1. Borrowed to the limit (collateral = mat x debt) at Friday's close; the weekend gaps SPY down by
    /// its measured p99.9 (7.9%); liquidated at Monday's open and sold only at the auction floor (90%, an hour later): the sale
    /// still covers debt and penalty, so the type takes no bad debt.
    function test_fridayPositionSurvivesMondayGap() public {
        uint256 close = _nextFridayClose();
        _walk(close - 10 minutes);
        _spy(spyAnswer);
        uint256 value = 4 * uint256(spyAnswer) * 1e10; // 4 SPY, USD 1e18
        uint256 debt = value * 1e18 / d.params.risk(SPY).mat - 1e15;
        // To the limit INCLUDING the upfront fee (7 days at the type's 5%, an empty type: the opener's rate).
        debt = debt * 365 days / (365 days + 0.05e18 * 7 days / 1e18);
        _position(4e18, debt);
        assertLe(d.ledger.debtOf(_pid(SPY, alice)), value * 1e18 / d.params.risk(SPY).mat, "at the limit");
        _walk(close);
        assertTrue(d.stockPrices[spyIndex].isStale(), "Friday 16:00: closed");
        int256 gapped = spyAnswer * int256(10_000 - SPY_P999_GAP_BPS) / 10_000;
        uint256 open = _nextOpen(close);
        _walk(open - 13.5 hours);
        _spy(gapped); // the Sunday-night print: published, not priced
        vm.expectRevert(Liquidator.NotPriced.selector);
        d.liquidator.bark(_pid(SPY, alice));
        _walk(open);
        _spy(gapped);
        d.liquidator.liquidate(_pid(SPY, alice));
        _walk(open + 1 hours);
        _spy(gapped);
        // per 1e18 vault shares = 1e-6 SPY (StockVault offset)
        assertEq(_join().price(_pid(SPY, alice)), uint256(gapped) * 1e10 * 0.9e18 / 1e18 / 1e6, "the floor");
        _give(RobinhoodConfig.USDG, taker, 10_000e6);
        _approveAll(taker);
        vm.prank(taker);
        _join().take(_pid(SPY, alice), type(uint256).max);
        (,,,, uint128 bad) = d.ledger.ilkState(SPY);
        assertEq(bad, 0, "no bad debt after the p99.9 weekend gap");
        assertEq(d.ledger.debtOf(_pid(SPY, alice)), 0);
        assertGe(IERC20(RobinhoodConfig.USDG).balanceOf(address(d.treasury)) * 1e12, debt, "the Treasury holds the debt in USDG");
    }

    /// @notice EXIT CRITERION 2, on the real token through its real role holders: a token pause, an oracle pause, the global
    /// pause and a blocklisted custody each freeze the type (no new debt, no liquidation); repayment never waits.
    function test_pausedTokenFreezesItsType() public {
        _inSession();
        _position(3e18, 1_000e18);
        IStockToken spy = IStockToken(RobinhoodConfig.SPY);
        IStockRegistry reg = IStockRegistry(RobinhoodConfig.STOCK_REGISTRY);

        vm.prank(PAUSER);
        spy.pause();
        _assertFrozen();
        vm.prank(PAUSER);
        spy.unpause();

        vm.prank(ORACLE_PAUSER);
        spy.pauseOracle();
        _assertFrozen();
        vm.prank(ORACLE_PAUSER);
        spy.unpauseOracle();

        vm.prank(GLOBAL_PAUSER);
        reg.pause();
        assertTrue(spy.paused(), "the registry's pause reaches the token");
        _assertFrozen();
        vm.prank(GLOBAL_PAUSER);
        reg.unpause();

        address[] memory who = new address[](1);
        who[0] = address(d.stockVaults[spyIndex]);
        vm.prank(BLOCKER);
        reg.blockAccounts(who);
        _assertFrozen();
        vm.prank(BLOCKER);
        reg.unblockAccounts(who);

        assertFalse(d.stockFeeds[spyIndex].frozen());
        vm.prank(alice);
        d.ledger.open(SPY, 0, Adjust(0, 100e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function _assertFrozen() internal {
        assertTrue(d.stockFeeds[spyIndex].frozen(), "frozen");
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        d.ledger.open(SPY, 0, Adjust(0, 100e18, 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        _spy(spyAnswer / 2); // unhealthy at this price, yet nothing may be seized
        vm.expectRevert(Liquidator.NotPriced.selector);
        d.liquidator.bark(_pid(SPY, alice));
        _spy(spyAnswer);
        vm.prank(alice);
        d.ledger.open(SPY, 0, Adjust(0, -10e18, 0, 0, 0, false, type(uint256).max, address(0))); // repaying always works
    }

    /// @notice EXIT CRITERION 3: unhealthy after the close, the position cannot be marked until the session opens.
    function test_marketClosedLiquidationWaitsForTheOpen() public {
        uint256 close = _nextFridayClose();
        _walk(close - 30 minutes);
        _spy(spyAnswer);
        _position(3e18, 1_000e18);
        _walk(close + 1 hours);
        _spy(spyAnswer * 60 / 100); // an after-hours collapse
        vm.expectRevert(Liquidator.NotPriced.selector);
        d.liquidator.bark(_pid(SPY, alice));
        _walk(close + 20 hours); // Saturday
        vm.expectRevert(Liquidator.NotPriced.selector);
        d.liquidator.bark(_pid(SPY, alice));
        uint256 open = _nextOpen(close);
        _walk(open);
        _spy(spyAnswer * 60 / 100);
        d.liquidator.liquidate(_pid(SPY, alice));
        (uint64 at,) = _join().auctions(_pid(SPY, alice));
        assertEq(at, open, "the auction opens with the session");
    }

    /// @notice The auction settled in USDG, its SPY sold on the real SPY/USDG v4 pool: the liquidator's whole round trip.
    function test_auctionSettledInUsdgAndSoldOnTheRealPool() public {
        _inSession();
        _position(3e18, 1_500e18);
        _spy(spyAnswer * 80 / 100);
        d.liquidator.liquidate(_pid(SPY, alice));
        _walk(vm.getBlockTimestamp() + 30 minutes);
        _spy(spyAnswer * 80 / 100);
        _give(RobinhoodConfig.USDG, taker, 10_000e6);
        _approveAll(taker);
        uint256 usdgBefore = IERC20(RobinhoodConfig.USDG).balanceOf(taker);
        vm.prank(taker);
        (uint256 units, uint256 paid) = _join().take(_pid(SPY, alice), type(uint256).max);
        uint256 got = IERC20(RobinhoodConfig.SPY).balanceOf(taker);
        assertApproxEqAbs(got, units / 1e6, 1, "1e6 shares = 1 SPY unit (StockVault offset)");
        PoolSeller seller = new PoolSeller(IPoolManager(PM));
        vm.prank(taker);
        IERC20(RobinhoodConfig.SPY).transfer(address(seller), got);
        vm.prank(taker);
        seller.sell(_spyPoolKey(), true, got);
        uint256 usdgAfter = IERC20(RobinhoodConfig.USDG).balanceOf(taker);
        assertGt(usdgAfter, usdgBefore, "bought at the auction, sold on the pool at a profit");
        emit log_named_uint("USDG paid to the auction", paid);
        emit log_named_uint("USDG from the pool", usdgAfter - (usdgBefore - paid));
    }

    /// @notice The issuer burns the whole custody (its real `adminBurn`, by its real burner): the type reads unpriced and the
    /// debt is written off as the type's bad debt, permissionlessly.
    function test_adminBurnOfTheCustodyIsWrittenOff() public {
        _inSession();
        _position(3e18, 1_000e18);
        vm.prank(BURNER);
        IStockToken(RobinhoodConfig.SPY).adminBurn(address(d.stockVaults[spyIndex]), 3e18);
        assertTrue(d.stockPrices[spyIndex].isStale());
        d.ledger.writeOff(_pid(SPY, alice)); // the first worthless reading only arms
        vm.warp(vm.getBlockTimestamp() + d.ledger.WRITEOFF_DELAY());
        uint256 debt = d.ledger.debtOf(_pid(SPY, alice));
        d.ledger.writeOff(_pid(SPY, alice));
        assertEq(d.stockVaults[spyIndex].balanceOf(address(d.treasury)), 3e24, "seized shares to the Treasury");
        (,,,, uint128 bad) = d.ledger.ilkState(SPY);
        assertEq(bad, debt);
    }
}
