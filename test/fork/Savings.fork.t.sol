// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployTypes, MainnetConfig} from "../../script/DeployConfig.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

interface IAgg {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice sImdUSD on a mainnet fork of the real deploy script (savings share 35%): a saver deposits, an ETH
/// borrower accrues 30 days of interest, the vault receives exactly its share, vests it over 7 days, the saver
/// leaves with more than they put in, and the Treasury got the rest.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/Savings.fork.t.sol
contract SavingsForkTest is Test {
    using SafeERC20 for IERC20;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice"); // borrower
    address bob = makeAddr("bob"); // saver (borrows a little to have imdUSD to save)

    Deploy.Deployed d;
    bytes32 ilk;
    uint64 share;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.deal(deployer, 10 ether);
        DeployTypes.Config memory c = MainnetConfig.get();
        ilk = c.ilks[0].ilk;
        share = c.savingsShare;
        d = new Deploy().deployAs(c, deployer);
        // The fork's Chainlink round may be minutes old: read it as if updated now.
        (uint80 id, int256 answer,,, uint80 ans) = IAgg(Mainnet.CL_ETH_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer, block.timestamp, block.timestamp, ans)
        );
    }

    function _borrow(address who, uint256 weth, uint256 debt, uint64 rate) internal {
        deal(Mainnet.WETH, who, weth);
        vm.startPrank(who);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), weth);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition(ilk, rate);
        d.ledger.open(ilk, 0, Adjust(int256(weth), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
        vm.stopPrank();
    }

    function test_fork_saverEarnsItsShareOfThirtyDaysOfInterest() public {
        assertEq(share, 0.35e18, "launch share");
        // Bob borrows 10,000 at the floor and saves it all; Alice borrows 100,000 at 5%.
        _borrow(bob, 20e18, 10_000e18, 0.01e18);
        vm.startPrank(bob);
        d.usd.approve(address(d.savings), 10_000e18);
        uint256 shares = d.savings.deposit(10_000e18, bob);
        vm.stopPrank();
        assertGt(shares, 0);
        vm.warp(vm.getBlockTimestamp() + 1); // a deposit is uptake from the next block
        _borrow(alice, 100e18, 100_000e18, 0.05e18);

        (uint128 debt0,,,,) = d.ledger.ilkState(ilk);
        uint256 t0 = d.usd.balanceOf(address(d.treasury));
        uint256 s0 = d.usd.balanceOf(address(d.savings));
        // Alice's upfront fee was split too: the savers' part sits in the vault, streaming from arrival.
        uint256 extra = s0 - 10_000e18;
        assertGt(extra, 0);
        assertLt(extra, 10e18);
        assertApproxEqAbs(d.savings.totalAssets(), 10_000e18, 1, "nothing of it counts at once");
        uint256 m0 = d.treasury.trailingRevenue();

        // 30 days: nobody touches the type, then anyone settles it.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        // C6: the share paid scales with uptake: saved ~10,000 (the fee's part has vested by now) of ~110,000 circulating
        // supply = ~9.1% (between the 5% floor and 35%).
        uint256 base = d.savings.totalAssets();
        assertApproxEqAbs(base, 10_000e18 + extra, 1, "the fee's part vested in its 7 days");
        uint256 eff = Math.mulDiv(base, 1e18, d.usd.circulating());
        assertGt(eff, 0.05e18);
        assertLt(eff, share);
        d.ledger.accrue(ilk);
        (uint128 debt1,,,,) = d.ledger.ilkState(ilk);
        uint256 interest = uint256(debt1) - debt0;
        // 100,000 x 5% + 10,000 x 1% over 30/365 of a year = 419.18
        assertApproxEqRel(interest, 419.178e18, 0.002e18, "30 days of interest (+ on the upfront fees)");
        uint256 toSavings = Math.mulDiv(interest, eff, 1e18);
        assertEq(d.usd.balanceOf(address(d.savings)) - s0, toSavings, "vault received exactly its share");
        assertEq(d.usd.balanceOf(address(d.treasury)) - t0, interest - toSavings, "the Treasury got the rest");
        assertEq(d.treasury.trailingRevenue() - m0, interest - toSavings, "and metered it");
        emit log_named_decimal_uint("interest", interest, 18);
        emit log_named_decimal_uint("to savers", toSavings, 18);

        // Vesting: nothing at once, half after 3.5 days, all after 7.
        d.savings.sync();
        assertApproxEqAbs(d.savings.totalAssets(), base, 1, "nothing counts at once (synced on arrival already, T3)");
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        assertApproxEqAbs(d.savings.totalAssets(), base + toSavings / 2, 1e9, "half vested");
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        assertApproxEqAbs(d.savings.totalAssets(), 10_000e18 + toSavings + extra, 1, "fully vested");

        // The saver leaves with more than they deposited.
        vm.prank(bob);
        uint256 got = d.savings.redeem(shares, bob, bob);
        assertGt(got, 10_000e18, "more than deposited");
        assertApproxEqAbs(got, 10_000e18 + toSavings + extra, 1e9, "the whole share (+ its part of the upfront fee), less share rounding");
        assertEq(d.usd.balanceOf(bob), got);
        assertLe(d.savings.totalAssets(), 1e9, "vault emptied (rounding dust at most)");

        // Supply equation on the deployed system: debt + reserve + migrated + keeper.
        (uint128 debt2,,,, uint128 bad) = d.ledger.ilkState(ilk);
        assertEq(
            d.usd.totalSupply(),
            uint256(debt2) + bad + d.ledger.reserveBacked() + d.migrator.outstanding() + d.hook.outstanding(),
            "supply"
        );
    }
}
