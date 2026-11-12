// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {Pricer} from "src/Pricer.sol";
import {Treasury, ICoverable} from "src/Treasury.sol";
import {PositionNFT} from "src/PositionNFT.sol";
import {Ledger} from "src/Ledger.sol";
import {IPulse} from "src/LedgerBase.sol";
import {Redeemer} from "src/Redeemer.sol";
import {Liquidator} from "src/Liquidator.sol";
import {Migrator} from "src/Migrator.sol";
import {Join} from "src/Join.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {Adjust} from "src/interfaces/IPositions.sol";

contract HvTok is ERC20 {
    constructor(string memory s) ERC20(s, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract HvFeed is IFeed {
    uint256 public value;
    uint64 public at;
    constructor(uint256 v) { set(v); }
    function set(uint256 v) public { value = v; at = uint64(block.timestamp); }
    function latestValue() external view returns (uint256, uint64) { return (value, at); }
    function isStale() external view returns (bool) { return value == 0 || block.timestamp - at > 1 hours; }
    function maxAge() external pure returns (uint256) { return 1 hours; }
}

contract HvRate {
    uint256 public rate = 1e18;
    function set(uint256 r) external { rate = r; }
}

/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 1): liquidation health is measured on the state after
/// the pending yield harvest, and the liquidation lands that harvest first. Before the fix a third party's harvest could
/// make a healthy S-USDC position liquidatable at an unchanged price, and a wstETH position its own harvest heals was
/// liquidated with the 10% penalty.
contract AuditW1HarvestTest is Test {
    bytes32 constant WSTETH = "WSTETH";
    bytes32 constant SUSDC = "S-USDC";
    address governor = makeAddr("governor");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    ImdUSD usd;
    Parameters params;
    Treasury treasury;
    Ledger ledger;
    Liquidator liquidator;
    HvTok wsteth;
    HvTok susdc;
    HvFeed ethFeed;
    HvFeed usdcFeed;
    HvRate ethRate;
    HvRate usdcRate;

    function setUp() public {
        vm.warp(1_800_000_000);
        usd = new ImdUSD(address(this), 10_000_000e18);
        params = new Parameters(governor, address(this));
        Pricer pricer = new Pricer(params);
        treasury = new Treasury(governor, IERC20(address(usd)), address(this));
        PositionNFT nft = new PositionNFT(address(this));
        ledger = new Ledger(usd, params, pricer, address(treasury), address(this), IPulse(address(0)), nft);
        nft.bind(address(ledger));
        Redeemer redeemer = new Redeemer(ledger);
        liquidator = new Liquidator(ledger, pricer);
        ledger.wire(address(redeemer), address(liquidator));
        Migrator migrator = new Migrator(IERC20(address(new HvTok("v1"))), usd, params);
        usd.wire(address(ledger), address(migrator), address(params));
        params.wire(address(ledger), address(usd));
        treasury.wire(ICoverable(address(ledger)));

        (wsteth, ethFeed, ethRate) = _add(WSTETH, 2000e18, 1.45e18, 0.1e18, 0.01e18, 50_000e18);
        (susdc, usdcFeed, usdcRate) = _add(SUSDC, 1e18, 1.08e18, 0.05e18, 0.005e18, 12_500e18);
        params.seal();

        wsteth.mint(alice, 10e18);
        susdc.mint(alice, 10_000e18);
        vm.startPrank(alice);
        wsteth.approve(address(ledger), type(uint256).max);
        susdc.approve(address(ledger), type(uint256).max);
        vm.stopPrank();
        deal(address(usd), keeper, 50_000e18);
        vm.prank(keeper);
        usd.approve(address(ledger), type(uint256).max);
    }

    function _add(bytes32 ilk, uint256 price, uint64 mat, uint64 chop, uint64 floor, uint128 line)
        private
        returns (HvTok tok, HvFeed feed, HvRate rate)
    {
        tok = new HvTok(string(abi.encodePacked(ilk)));
        feed = new HvFeed(price);
        rate = new HvRate();
        Join join = new Join(address(tok), address(this));
        join.wire(address(ledger));
        params.addGenesisIlk(
            ilk,
            ParametersBase.Config({
                token: address(tok),
                join: address(join),
                median: feed,
                spot: feed,
                nhi: IFeed(address(0)),
                yieldRate: address(rate),
                pegAggregator: address(0),
                liveSpot: IFeed(address(0)),
                redeemable: true,
                auction: false
            }),
            ParametersBase.Risk({
                mat: mat, chop: chop, cut: 0.5e18, chip: 0.1e18, rateFloor: floor, yieldFee: 0.1e18,
                skew: 0.05e18, pegFloor: 0, line: line, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 2,
                redeemCap: 0
            })
        );
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    /// wstETH (0.9 x mat > 1: the harvest RAISES the ratio): healthy once its own yield lands, so not liquidatable.
    function test_wsteth_healthyAfterPendingHarvestIsNotLiquidated() public {
        vm.prank(alice);
        uint256 id = ledger.open(WSTETH, 0, Adjust(10e18, 13_700e18, 0.01e18, 0, 0, false, type(uint256).max, address(0)));
        vm.warp(block.timestamp + 365 days);
        ethRate.set(1.03e18);
        ethFeed.set(1995e18);
        (bool ok,) = ledger.healthy(id);
        assertTrue(ok, "healthy on the harvested state");
        vm.expectRevert(Liquidator.Healthy.selector);
        liquidator.liquidate(id);
    }

    /// S-USDC (CR < 1/(1 - fee) = 111%: the harvest LOWERS the ratio): a third party's harvest no longer changes the verdict.
    function test_susdc_thirdPartyHarvestDoesNotChangeHealth() public {
        vm.prank(alice);
        uint256 id = ledger.open(SUSDC, 0, Adjust(10_000e18, 9_112e18, 0.06e18, 0, 0, false, type(uint256).max, address(0)));
        vm.warp(block.timestamp + 365 days);
        usdcRate.set(1.045e18);
        usdcFeed.set(1.045e18);
        (bool before,) = ledger.healthy(id);
        uint256 needBefore = ledger.liquidationNeed(id, 1.045e18);
        ledger.harvest(SUSDC, _ids(id));
        (bool afterHarvest,) = ledger.healthy(id);
        assertEq(afterHarvest, before, "a harvest does not move liquidation health");
        assertEq(ledger.liquidationNeed(id, 1.045e18), needBefore, "nor the liquidation need");
        assertFalse(before, "on the harvested state this position is under mat");
    }

    /// The liquidation lands the harvest: the yield shares go to the Treasury, the mark moves, the type's books balance.
    function test_liquidationRunsThePendingHarvestFirst() public {
        vm.prank(alice);
        uint256 id = ledger.open(WSTETH, 0, Adjust(10e18, 13_700e18, 0.01e18, 0, 0, false, type(uint256).max, address(0)));
        vm.warp(block.timestamp + 365 days);
        ethRate.set(1.03e18);
        ethFeed.set(1900e18); // unhealthy even after the harvest
        (bool ok,) = ledger.healthy(id);
        assertFalse(ok);
        uint256 treasuryBefore = wsteth.balanceOf(address(treasury));
        vm.prank(keeper);
        liquidator.liquidate(id);
        assertEq(ledger.position(id).yieldMark, 1.03e18, "mark moved: the harvest ran");
        // The Treasury receives the yield shares (and its cut of the penalty): more than the cut alone.
        uint256 yieldShares = uint256(10e18) * 0.03e18 / 1.03e18;
        assertGe(wsteth.balanceOf(address(treasury)) - treasuryBefore, yieldShares - 1, "yield shares reached the Treasury");
        (uint128 sDebt, uint128 sColl,,,) = ledger.ilkState(WSTETH);
        assertEq(sColl, ledger.position(id).collateral, "type collateral = the only position's");
        assertApproxEqAbs(sDebt, ledger.debtOf(id), 1e6, "type debt = the only position's");
    }
}
