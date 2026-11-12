// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ImdUSD} from "src/ImdUSD.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {Parameters} from "src/Parameters.sol";
import {Pricer} from "src/Pricer.sol";
import {Treasury, ICoverable} from "src/Treasury.sol";
import {PositionNFT} from "src/PositionNFT.sol";
import {Ledger, IPulse} from "src/Ledger.sol";
import {Redeemer} from "src/Redeemer.sol";
import {Liquidator} from "src/Liquidator.sol";
import {Migrator} from "src/Migrator.sol";
import {Join} from "src/Join.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {Adjust} from "src/interfaces/IPositions.sol";

contract W1RvRVToken is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract W1RvRVFeed is IFeed {
    uint256 public value;
    uint64 public updatedAt;
    constructor(uint256 v) { value = v; updatedAt = uint64(block.timestamp); }
    function set(uint256 v) external { value = v; updatedAt = uint64(block.timestamp); }
    function latestValue() external view returns (uint256, uint64) { return (value, updatedAt); }
    function isStale() external view returns (bool) { return block.timestamp - updatedAt > 365 days; }
    function maxAge() external pure returns (uint256) { return 365 days; }
}

/// @dev Q4: `Parameters.riskVersion` is the NEWEST version, pending or not, and `liqRisk(ilk, newest)` returns it with no
/// bindAt check. Ledger._adjust / setRate write it into `p.version` on any borrow or withdrawal, so a position touched
/// during the 7-day grace is liquidated at the pending (harsher) mat and chop at once, while an untouched twin keeps the
/// old version until `bindAt`.
/// Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 1): the auditors' proof; a de-risking adjust keeps its risk version.
contract W1RvProofRiskVersionRebind is Test {
    bytes32 constant ETH = "ETH";
    address governor = makeAddr("governor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    ImdUSD usd;
    Parameters params;
    Pricer pricer;
    Treasury treasury;
    Ledger ledger;
    Liquidator liquidator;
    W1RvRVToken weth;
    W1RvRVFeed feed;

    function _risk(uint64 mat, uint64 chop) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: mat, chop: chop, cut: 0.5e18, chip: 0.1e18, rateFloor: 0.01e18, yieldFee: 0, skew: 0.05e18,
            pegFloor: 0, line: 1_000_000e18, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 2, redeemCap: 0
        });
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new W1RvRVToken();
        feed = new W1RvRVFeed(2000e18);
        usd = new ImdUSD(address(this), 10_000_000e18);
        params = new Parameters(governor, address(this));
        pricer = new Pricer(params);
        treasury = new Treasury(governor, IERC20(address(usd)), address(this));
        PositionNFT nft_ = new PositionNFT(address(this));
        ledger = new Ledger(usd, params, pricer, address(treasury), address(this), IPulse(address(0)), nft_);
        nft_.bind(address(ledger));
        Redeemer redeemer = new Redeemer(ledger);
        liquidator = new Liquidator(ledger, pricer);
        ledger.wire(address(redeemer), address(liquidator));
        Migrator migrator = new Migrator(IERC20(address(new W1RvRVToken())), usd, params);
        usd.wire(address(ledger), address(migrator), address(params));
        params.wire(address(ledger), address(usd));
        treasury.wire(ICoverable(address(ledger)));
        Join join = new Join(address(weth), address(this));
        join.wire(address(ledger));
        params.addGenesisIlk(
            ETH,
            ParametersBase.Config({
                token: address(weth), join: address(join), median: feed, spot: feed, nhi: IFeed(address(0)),
                yieldRate: address(0), pegAggregator: address(0), liveSpot: IFeed(address(0)), redeemable: true, auction: false
            }),
            _risk(1.4e18, 0.1e18)
        );
        params.seal();
        address[2] memory us = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            weth.mint(us[i], 1000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            usd.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
        deal(address(usd), keeper, 100_000e18);
        vm.prank(keeper);
        usd.approve(address(ledger), type(uint256).max);
    }

    function _open(address u, uint256 coll, uint256 debt) internal returns (uint256 id) {
        vm.prank(u);
        id = ledger.open(ETH, 0, Adjust(int256(coll), int256(debt), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function test_deRiskingAdjustKeepsItsVersionThroughTheGrace() public {
        uint256 a = _open(alice, 10e18, 13_000e18); // CR 153.8% under version 0 (mat 140%)
        uint256 b = _open(bob, 10e18, 13_000e18); // identical twin, never touched

        // Governance raises mat 140% -> 160%: version 1 pushed with bindAt = now + 7 days.
        uint8 kind = params.SET_RISK();
        vm.prank(governor);
        params.propose(abi.encode(kind, ETH, _risk(1.6e18, 0.1e18)));
        vm.warp(block.timestamp + 48 hours);
        params.applyPending();
        feed.set(2000e18);
        assertEq(params.riskVersion(ETH), 1);

        // Alice repays half and withdraws 40% of her collateral: ratio UP (153.8% -> 184.6%), passes the health check.
        vm.prank(alice);
        ledger.adjust(a, Adjust(-4e18, -6_500e18, 0, 0, 0, false, 0, address(0)));

        // Price falls 15%. Alice: 6 x 1700 = 10,200 / ~6,501 = 156.9%: healthy at 140%, unhealthy at 160%.
        feed.set(1700e18);
        (bool okB,) = ledger.healthy(b); // Bob: 17,000 / 13,000 = 130.8%: unhealthy either way (control: version 0 works)
        assertFalse(okB);
        (bool okA,) = ledger.healthy(a);
        (uint256 matA,) = params.liqRisk(ETH, ledger.position(a).version);
        emit log_named_uint("alice.version", ledger.position(a).version);
        emit log_named_uint("mat binding alice now", matA);
        // EXPECTED (ParametersBase.sol:300-303, README): version 1 binds nobody before its bindAt, so Alice is healthy
        // at 140% for the rest of the week. ACTUAL: she is on version 1 already and reads unhealthy at 160%.
        assertEq(ledger.position(a).version, 0, "bound to a version whose bindAt has not passed");
        assertTrue(okA, "healthy at the version in force (140%)");
        vm.prank(keeper);
        vm.expectRevert(Liquidator.Healthy.selector);
        liquidator.liquidate(a);
    }
}