// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Treasury, ICoverable} from "../../src/Treasury.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {Ledger, IPulse} from "../../src/Ledger.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Migrator} from "../../src/Migrator.sol";
import {Join} from "../../src/Join.sol";
import {SortedPositions} from "../../src/SortedPositions.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";

interface IBridgeNet {
    function netMinted() external view returns (int256);
}

interface IKeeperOutstanding {
    function outstanding() external view returns (uint256);
}

/// @notice Deploys and wires the whole system in deploy-script order. Tests and the deploy script share it.
abstract contract System is Test {
    address internal governor = makeAddr("governor");

    ImdUSD internal usd;
    Parameters internal params;
    Pricer internal pricer;
    Treasury internal treasury;
    Ledger internal ledger;
    Redeemer internal redeemer;
    Liquidator internal liquidator;
    Migrator internal migrator;
    SortedPositions internal sorted;

    function _deploySystem(IERC20 v1) internal {
        usd = new ImdUSD(address(this), 10_000_000e18);
        params = new Parameters(governor, address(this));
        pricer = new Pricer(params);
        treasury = new Treasury(governor, IERC20(address(usd)), address(this));
        PositionNFT nft_ = new PositionNFT(address(this));
        ledger = new Ledger(usd, params, pricer, address(treasury), address(this), _pulse(), nft_);
        nft_.bind(address(ledger));
        sorted = ledger.sorted();
        redeemer = new Redeemer(ledger);
        liquidator = new Liquidator(ledger, pricer);
        ledger.wire(address(redeemer), address(liquidator));
        migrator = new Migrator(v1, usd, params);
        usd.wire(address(ledger), address(migrator), address(params));
        params.wire(address(ledger), address(usd));
        treasury.wire(ICoverable(address(ledger)));
    }

    /// @dev The Ledger's Pulse: none unless a suite overrides it (Robinhood suites do).
    function _pulse() internal virtual returns (IPulse) {
        return IPulse(address(0));
    }

    /// @dev The supply equation's bridge term: received − sent through the token's bridge minter (0 when unwired).
    function _bridgeNet() internal view returns (int256) {
        address b = usd.bridge();
        return b == address(0) ? int256(0) : IBridgeNet(b).netMinted();
    }

    function _addIlk(
        bytes32 ilk,
        address token,
        IFeed median,
        IFeed spot,
        IFeed nhi,
        address yieldRate,
        address peg,
        bool redeemable,
        ParametersBase.Risk memory risk
    ) internal returns (Join join) {
        return _addIlk(ilk, token, median, spot, nhi, yieldRate, peg, IFeed(address(0)), redeemable, risk);
    }

    function _addIlk(
        bytes32 ilk,
        address token,
        IFeed median,
        IFeed spot,
        IFeed nhi,
        address yieldRate,
        address peg,
        IFeed liveSpot,
        bool redeemable,
        ParametersBase.Risk memory risk
    ) internal returns (Join join) {
        join = new Join(token, address(this));
        join.wire(address(ledger));
        params.addGenesisIlk(
            ilk,
            ParametersBase.Config({
                token: token,
                join: address(join),
                median: median,
                spot: spot,
                nhi: nhi,
                yieldRate: yieldRate,
                pegAggregator: peg,
                liveSpot: liveSpot,
                redeemable: redeemable,
                auction: false
            }),
            risk
        );
    }

    /// @dev The supply equation's peg keeper term: what the keeper has minted and not bought back (0 when unwired).
    function _keeperOutstanding() internal view returns (uint256) {
        address k = usd.keeper();
        return k == address(0) ? 0 : IKeeperOutstanding(k).outstanding();
    }

    function _risk(uint64 mat, uint128 line) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: mat,
            chop: 0.1e18,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: 0.01e18,
            yieldFee: 0,
            skew: 0.05e18,
            pegFloor: 0,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 2,
            redeemCap: 0
        });
    }
}
