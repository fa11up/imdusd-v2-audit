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
import {LedgerBase} from "src/LedgerBase.sol";
import {Redeemer} from "src/Redeemer.sol";
import {Liquidator} from "src/Liquidator.sol";
import {Migrator} from "src/Migrator.sol";
import {Join} from "src/Join.sol";
import {IFeed} from "src/interfaces/IFeed.sol";
import {Adjust} from "src/interfaces/IPositions.sol";

contract W1PlPLToken is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract W1PlPLFeed is IFeed {
    uint256 public value;
    uint64 public updatedAt;
    constructor(uint256 v) { value = v; updatedAt = uint64(block.timestamp); }
    function set(uint256 v) external { value = v; updatedAt = uint64(block.timestamp); }
    function latestValue() external view returns (uint256, uint64) { return (value, updatedAt); }
    function isStale() external view returns (bool) { return block.timestamp - updatedAt > 365 days; }
    function maxAge() external pure returns (uint256) { return 365 days; }
}

/// @dev Q3: the C2 rule says debt added inside the cooldown of a charged rate change pays RATE_COOLDOWN of interest at the
/// rate BEFORE that change ("a dust reopen followed by a top-up costs what one reopen does"). Two in-cooldown setRate
/// calls on a dust-sized debt overwrite `premiumRate` with the freely chosen intermediate rate, so the top-up pays the
/// premium at that rate (here 2%) instead of the original 10%.
/// Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 1): the auditors' proof; the top-up premium stays at the rate before the first change.
contract W1PlProofPremiumLaunder is Test {
    bytes32 constant ETH = "ETH";
    address governor = makeAddr("governor");
    address alice = makeAddr("alice");

    ImdUSD usd;
    Parameters params;
    Pricer pricer;
    Treasury treasury;
    Ledger ledger;
    W1PlPLToken weth;
    W1PlPLFeed feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new W1PlPLToken();
        feed = new W1PlPLFeed(2000e18);
        W1PlPLToken v1 = new W1PlPLToken();

        usd = new ImdUSD(address(this), 10_000_000e18);
        params = new Parameters(governor, address(this));
        pricer = new Pricer(params);
        treasury = new Treasury(governor, IERC20(address(usd)), address(this));
        PositionNFT nft_ = new PositionNFT(address(this));
        ledger = new Ledger(usd, params, pricer, address(treasury), address(this), IPulse(address(0)), nft_);
        nft_.bind(address(ledger));
        Redeemer redeemer = new Redeemer(ledger);
        Liquidator liquidator = new Liquidator(ledger, pricer);
        ledger.wire(address(redeemer), address(liquidator));
        Migrator migrator = new Migrator(IERC20(address(v1)), usd, params);
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
            ParametersBase.Risk({
                mat: 1.4e18, chop: 0.1e18, cut: 0.5e18, chip: 0.1e18, rateFloor: 0.01e18, yieldFee: 0, skew: 0.05e18,
                pegFloor: 0, line: 1_000_000e18, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 2, redeemCap: 0
            })
        );
        params.seal();

        weth.mint(alice, 100e18);
        vm.startPrank(alice);
        weth.approve(address(ledger), type(uint256).max);
        vm.stopPrank();
    }

    function _premium(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * rate * 7 days + 365 days * 1e18 - 1) / (365 days * 1e18);
    }

    function test_twoInCooldownRateChangesDoNotLaunderThePremiumRate() public {
        uint256 id = ledger.positionId(alice, ETH, 0);
        // Alice borrows 10,000 at 10%: lastRateChange = now, so a change inside 7 days is charged at 10%.
        vm.prank(alice);
        ledger.open(ETH, 0, Adjust(int256(100e18), int256(10_000e18), 0.10e18, 0, 0, false, type(uint256).max, address(0)));
        vm.warp(block.timestamp + 1 days);

        // The honest price of dropping 10,000 of debt from 10% to 1% inside the cooldown: 7 days at 10%.
        uint256 honest = _premium(10_000e18, 0.10e18);

        // 1. Repay down to dust (free, no price needed).
        uint256 debt = ledger.debtOf(id);
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, -int256(debt - 101e18), 0, 0, 0, false, type(uint256).max, address(0)));
        assertApproxEqAbs(ledger.debtOf(id), 101e18, 1);

        // 2. Two rate changes on the dust: 10% -> 2% (charged at 10% on 101) then 2% -> 1% (charged at 2% on ~101).
        vm.startPrank(alice);
        ledger.setRate(id, 0.02e18, 0, 0);
        ledger.setRate(id, 0.01e18, 0, 0);
        vm.stopPrank();
        LedgerBase.Position memory p = ledger.position(id);
        assertEq(p.rate, 0.01e18);
        uint256 dust = p.debt;
        uint256 paidSoFar = dust - 101e18; // the two tiny premiums (about 0.19 + 0.04 imdUSD)

        // 3. Top up the 9,900 back inside the cooldown.
        ledger.accrue(ETH);
        uint256 upfront = ledger.upfrontFeeFor(ETH, 9_899e18, 0.01e18);
        vm.prank(alice);
        ledger.adjust(id, Adjust(0, int256(9_899e18), 0, 0, 0, false, type(uint256).max, address(0)));
        uint256 topUpPremium = ledger.debtOf(id) - dust - 9_899e18 - upfront;

        emit log_named_uint("honest premium (7d at 10% on 10,000)", honest);
        emit log_named_uint("premiumRate after the two changes   ", p.premiumRate);
        emit log_named_uint("premium charged on the 9,899 top-up ", topUpPremium);
        emit log_named_uint("total premium paid over the sequence", topUpPremium + paidSoFar);

        // Documented rule (LedgerBase 125-127, Ledger 281-283): the top-up pays at the rate BEFORE the charged change (10%).
        // Actual: `premiumRate` is the freely chosen intermediate rate (2%), and the top-up pays about a fifth.
        assertEq(p.premiumRate, 0.10e18, "premiumRate should still be the rate the cooldown was entered at");
        assertGe(topUpPremium + paidSoFar, honest, "the sequence must cost at least one honest rate change");
    }
}