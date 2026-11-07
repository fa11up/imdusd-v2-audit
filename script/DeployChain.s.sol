// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "./Deploy.s.sol";
import {Pulse} from "../src/Pulse.sol";
import {ImdBridge, IMintableBurnable} from "../src/bridge/ImdBridge.sol";
import {ILayerZeroEndpointV2} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {IFeed} from "../src/interfaces/IFeed.sol";
import {SwarmPriceFeed, SwarmSpotFeed, SwarmNhiFeed} from "../src/feeds/SwarmFeeds.sol";
import {DeployTypes} from "./DeployConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ParametersBase} from "../src/ParametersBase.sol";
import {Parameters} from "../src/Parameters.sol";
import {RateFeed} from "../src/feeds/RateFeed.sol";
import {MarketCalendar} from "../src/feeds/MarketCalendar.sol";
import {MarketHoursFeed} from "../src/feeds/MarketHoursFeed.sol";
import {StockVault} from "../src/stocks/StockVault.sol";
import {StockJoin} from "../src/stocks/StockJoin.sol";

/// @notice script/Deploy.s.sol plus the chain parts: Pulse, ImdBridge and the swarm-attested feeds. Same `_deploy`, same
/// order; only the three constructors live here, so the mainnet entry stays lean (see Deploy's note). Any config that turns
/// on a chain part must be deployed through this contract (DeployRobinhood is one), or Deploy reverts `NeedsDeployChain`.
contract DeployChain is Deploy {
    function _newPulse(uint64 gap, uint64 grace) internal override returns (Pulse) {
        return new Pulse(gap, grace);
    }

    function _newBridge(address endpoint, address token, address governor, address guardian, address treasury)
        internal
        override
        returns (ImdBridge)
    {
        return new ImdBridge(ILayerZeroEndpointV2(endpoint), IMintableBurnable(token), governor, guardian, treasury);
    }

    /// @dev Stocks: one MarketCalendar (governed by the Safe), then per stock type a StockVault (custody), its MarketHoursFeed
    /// (holder = the vault), a RateFeed over the vault's share rate (the type's median AND spot: one feed, no skew), and a
    /// StockJoin (auction type, not redeemable), each type registered at genesis and put in the stock debt-cap group.
    function _deployStocks(DeployTypes.Config memory cfg, Deployed memory d, address me) internal override {
        DeployTypes.StocksSpec memory s = cfg.stocks;
        uint256 n = s.types.length;
        uint256 g = gasleft();
        d.calendar = new MarketCalendar(cfg.governor, s.closedDays, s.earlyDays);
        _rec("MarketCalendar", g, type(MarketCalendar).creationCode.length + 64 * (2 + s.closedDays.length + s.earlyDays.length));
        d.stockVaults = new StockVault[](n);
        d.stockJoins = new StockJoin[](n);
        d.stockFeeds = new MarketHoursFeed[](n);
        d.stockPrices = new RateFeed[](n);
        for (uint256 i; i < n; ++i) {
            DeployTypes.StockSpec memory t = s.types[i];
            g = gasleft();
            d.stockVaults[i] = new StockVault(IERC20Metadata(t.stock));
            _rec("StockVault", g, type(StockVault).creationCode.length + 32);
            g = gasleft();
            d.stockFeeds[i] = new MarketHoursFeed(t.aggregator, t.stock, address(d.stockVaults[i]), d.calendar, t.maxAge);
            _rec("MarketHoursFeed", g, type(MarketHoursFeed).creationCode.length + 160);
            g = gasleft();
            d.stockPrices[i] = new RateFeed(
                address(d.stockVaults[i]), bytes4(keccak256("convertToAssets(uint256)")), true, d.stockFeeds[i], s.rateCap
            );
            _rec("RateFeed (stock)", g, type(RateFeed).creationCode.length + 160);
            g = gasleft();
            d.stockJoins[i] =
                new StockJoin(t.ilk, address(d.stockVaults[i]), IERC20(s.usdg), me, t.auctionTime, t.auctionFloor);
            _rec("StockJoin", g, type(StockJoin).creationCode.length + 192);
            g = gasleft();
            d.stockJoins[i].wire(address(d.ledger));
            _rec("stockJoin.wire", g, CALL_DATA);
            g = gasleft();
            d.params.addGenesisIlk(t.ilk, _stockConfig(d, i), t.risk);
            _rec("params.addGenesisIlk (stock)", g, 1_000);
            g = gasleft();
            d.params.setGenesisGroup(t.ilk, s.group, s.groupLine);
            _rec("params.setGenesisGroup", g, CALL_DATA);
        }
    }

    function _stockConfig(Deployed memory d, uint256 i) internal pure returns (ParametersBase.Config memory) {
        IFeed price = IFeed(address(d.stockPrices[i]));
        return ParametersBase.Config({
            token: address(d.stockVaults[i]),
            join: address(d.stockJoins[i]),
            median: price,
            spot: price,
            nhi: IFeed(address(0)),
            yieldRate: address(0),
            pegAggregator: address(0),
            liveSpot: IFeed(address(0)),
            redeemable: false,
            auction: true
        });
    }
}
