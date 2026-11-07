// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {System} from "./System.sol";
import {MockERC20, MockFeed, MockAggregator} from "./Mocks.sol";
import {MockStockRegistry, MockStockToken} from "./StockMocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {MarketCalendar} from "../../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../../src/feeds/MarketHoursFeed.sol";
import {StockVault} from "../../src/stocks/StockVault.sol";
import {StockJoin} from "../../src/stocks/StockJoin.sol";
import {Join} from "../../src/Join.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "./Pid.sol";

/// @notice The core plus one stock type wired the way DeployChain._deployStocks wires it (vault, market-hours feed, capped
/// rate, USDG auction join, debt-cap group 1), and an ETH type outside the group, on mocks.
abstract contract StockSystem is System {
    // 2026: Mon 10-19 is in EDT (session 13:30-20:00 UTC); Mon 11-02 is in EST (14:30-21:00 UTC).
    uint256 internal constant MON_OPEN = 1792416600; // Mon 2026-10-19 13:30 UTC = 09:30 New York
    uint256 internal constant MON_1400 = 1792418400;
    uint256 internal constant FRI_CLOSE = 1792785600; // Fri 2026-10-23 20:00 UTC = 16:00 New York
    uint256 internal constant SAT_1500 = 1792854000;
    uint256 internal constant NEXT_MON_OPEN = 1793021400; // Mon 2026-10-26 13:30 UTC
    uint256 internal constant EST_MON_OPEN = 1793629800; // Mon 2026-11-02 14:30 UTC = 09:30 New York (EST)
    uint256 internal constant THANKSGIVING_1500 = 1795705200; // Thu 2026-11-26 15:00 UTC
    uint256 internal constant EARLY_CLOSE = 1795802400; // Fri 2026-11-27 18:00 UTC = 13:00 New York
    uint32 internal constant THANKSGIVING = 20783;
    uint32 internal constant DAY_AFTER = 20784;

    bytes32 internal constant STK = "STOCK-SPY";
    bytes32 internal constant ETH = "ETH";
    uint8 internal constant GROUP = 1;

    MockERC20 internal usdg;
    MockERC20 internal weth;
    MockFeed internal ethFeed;
    MockStockRegistry internal reg;
    MockStockToken internal stock;
    MockAggregator internal agg;
    MarketCalendar internal cal;
    StockVault internal vault;
    MarketHoursFeed internal mhf;
    RateFeed internal price;
    StockJoin internal sjoin;
    Join internal ethJoin;

    function _deployStocks(uint128 stockLine, uint256 groupLine) internal {
        vm.warp(MON_1400);
        _deploySystem(IERC20(address(new MockERC20("v1", 18))));
        usdg = new MockERC20("USDG", 6);
        weth = new MockERC20("WETH", 18);
        ethFeed = new MockFeed(2_000e18);
        reg = new MockStockRegistry();
        stock = new MockStockToken("SPY", reg);
        agg = new MockAggregator(8, 100e8); // $100 per token
        uint32[] memory closed = new uint32[](1);
        closed[0] = THANKSGIVING;
        uint32[] memory early = new uint32[](1);
        early[0] = DAY_AFTER;
        cal = new MarketCalendar(governor, closed, early);
        vault = new StockVault(IERC20Metadata(address(stock)));
        mhf = new MarketHoursFeed(address(agg), address(stock), address(vault), cal, 25 hours);
        price = new RateFeed(address(vault), bytes4(keccak256("convertToAssets(uint256)")), true, mhf, uint256(0.001e18) / 1 days);
        sjoin = new StockJoin(STK, address(vault), IERC20(address(usdg)), address(this), 1 hours, 0.9e18);
        sjoin.wire(address(ledger));
        params.addGenesisIlk(STK, _stockConfig(), _stockRisk(stockLine));
        params.setGenesisGroup(STK, GROUP, groupLine);
        ethJoin = _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, _risk(1.5e18, 1_000_000e18));
        params.seal();
    }

    function _stockConfig() internal view returns (ParametersBase.Config memory) {
        return ParametersBase.Config({
            token: address(vault),
            join: address(sjoin),
            median: IFeed(address(price)),
            spot: IFeed(address(price)),
            nhi: IFeed(address(0)),
            yieldRate: address(0),
            pegAggregator: address(0),
            liveSpot: IFeed(address(0)),
            redeemable: false,
            auction: true
        });
    }

    function _stockRisk(uint128 line) internal pure returns (ParametersBase.Risk memory r) {
        r = _risk(1.5e18, line);
        r.rateFloor = 0.05e18;
    }

    /// @dev Give `who` `amount` stock tokens and let the Ledger pull them.
    function _fund(address who, uint256 amount) internal {
        stock.mint(who, amount);
        vm.prank(who);
        stock.approve(address(ledger), type(uint256).max);
    }

    /// @dev Deposit `amount` stock (staked into the vault on entry) and borrow `debt`.
    function _open(address who, uint256 amount, uint256 debt) internal {
        _fund(who, amount);
        vm.prank(who);
        ledger.open(STK, 0, Adjust(int256(amount), int256(debt), 0.05e18, 0, 0, true, type(uint256).max, address(0)));
    }

    /// @dev The feed publishes `usd8` now (a Chainlink round).
    function _price(int256 usd8) internal {
        agg.set(usd8);
    }

    function _supplyHolds() internal view {
        bytes32[2] memory ks = [STK, ETH];
        uint256 sum = ledger.reserveBacked() + migrator.outstanding();
        for (uint256 i; i < 2; ++i) {
            (uint128 debt,,,, uint128 bad) = ledger.ilkState(ks[i]);
            sum += uint256(debt) + bad;
        }
        assertGe(sum, usd.totalSupply(), "supply <= liabilities");
        assertApproxEqAbs(sum, usd.totalSupply(), 2, "supply equation");
    }
}
