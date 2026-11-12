// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";
import {Allocator} from "../../src/peg/Allocator.sol";
import {MockFeed} from "../utils/Mocks.sol";
import {BackstopBase, BUSD, BToken, BOracle, BLedger, BLiquidator, BSeller} from "./Backstop.t.sol";

/// @notice The rule-driven collateral auction against the REAL Backstop: the sleeve's own `sell` (seller check, sale limit,
/// 98%-of-low floor, proceeds booked) with the real Allocator as its seller.
contract AllocatorAuctionBackstopTest is BackstopBase {
    Allocator al;
    address governor = makeAddr("governor");

    function setUp() public override {
        vm.warp(1_800_000_000);
        usd = new BUSD();
        weth = new BToken("WETH");
        oracle = new BOracle();
        oracle.set(address(weth), 2000e18, 2010e18);
        ledger = new BLedger(usd);
        liq = new BLiquidator(ledger);
        al = new Allocator(governor, makeAddr("treasury"), makeAddr("freezer"), 100);
        blue = new Backstop(IERC20(address(usd)), ledger, oracle, false, "Backstop blue", "sBACK-B");
        blue.wire(address(liq), address(this), address(al));
        blue.addIlk(ETH, address(weth), 0, 100e18, uint128(100e18) / 1 days);
        blue.seal();
        _gov(abi.encode(al.ADD_TARGET(), al.BACKSTOP_SALE(), address(blue)));
        _gov(abi.encode(al.SET_LIMIT(), al.BACKSTOP_SALE(), address(blue), uint128(50_000e18), uint128(1e18)));
        address[2] memory us = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            usd.mint(us[i], 1_000_000e18);
            vm.startPrank(us[i]);
            usd.approve(address(blue), type(uint256).max);
            usd.approve(address(al), type(uint256).max);
            vm.stopPrank();
        }
        _join(blue, alice, 100_000e18);
        _bid(blue, ETH, weth, 18_000e18, 10e18); // the standing bid bought 10 WETH for 18,000 imdUSD
        skip(1 days); // the sleeve's sale limit refills
    }

    function _gov(bytes memory payload) internal {
        vm.prank(governor);
        al.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        al.applyPending();
    }

    function test_realSleeveSellsThroughTheAuction() public {
        assertEq(blue.coll(address(weth)), 10e18);
        al.startAuction(address(blue), address(weth));
        assertEq(al.auctionPrice(address(blue), address(weth)), 2070.3e18, "103% of high (2,010)");
        skip(1 hours);
        uint256 price = al.auctionPrice(address(blue), address(weth));
        assertEq(price, (2070.3e18 + 1960e18) / 2, "half way to 98% of low");
        uint256 usdBefore = usd.balanceOf(address(blue));
        vm.prank(bob);
        uint256 pay = al.buyCollateral(address(blue), address(weth), 4e18, type(uint256).max);
        assertEq(pay, 4 * price);
        assertEq(weth.balanceOf(bob), 4e18, "collateral to the buyer");
        assertEq(blue.coll(address(weth)), 6e18, "the sleeve debited it");
        assertEq(usd.balanceOf(address(blue)) - usdBefore, pay, "imdUSD to the sleeve");
        assertEq(weth.balanceOf(address(al)), 0);
        assertEq(usd.balanceOf(address(al)), 0);
    }

    function test_floorSaleClearsTheSleevesOwnFloor() public {
        al.startAuction(address(blue), address(weth));
        skip(2 hours);
        vm.prank(bob);
        uint256 pay = al.buyCollateral(address(blue), address(weth), 10e18, type(uint256).max);
        assertEq(pay, 19_600e18, "exactly 98% of low: Backstop.sell accepts it");
        assertEq(blue.coll(address(weth)), 0);
    }

    /// Audit-suite review (wave-2 snapshot): the floor price rounded down before the multiply, Backstop.sell after it, so a
    /// 10-unit buy at the floor reverted SaleShort at any price that is not a multiple of 50 wei.
    function test_floorBuyClearsAtAnUnevenPrice() public {
        oracle.set(address(weth), 3127.123456789012345678e18, 3130e18);
        al.startAuction(address(blue), address(weth));
        skip(2 hours);
        vm.prank(bob);
        uint256 pay = al.buyCollateral(address(blue), address(weth), 10e18, type(uint256).max);
        assertEq(pay, uint256(31_271.23456789012345678e18) * 9_800 / 10_000, "exactly the sleeve's floor");
        assertEq(blue.coll(address(weth)), 0);
    }

    function test_sleevesSaleLimitStillBinds() public {
        _join(blue, bob, 200_000e18);
        _bid(blue, ETH, weth, 180_000e18, 100e18); // 110 WETH held, sale limit 100 WETH
        _gov(abi.encode(al.SET_LIMIT(), al.BACKSTOP_SALE(), address(blue), uint128(1_000_000e18), uint128(1_000_000e18)));
        skip(1); // a raised bucket refills at its slope; the Allocator's bound is not the one under test
        al.startAuction(address(blue), address(weth));
        skip(2 hours);
        vm.prank(bob);
        vm.expectRevert(Backstop.SaleLimit.selector);
        al.buyCollateral(address(blue), address(weth), 101e18, type(uint256).max);
    }

    function test_onlyTheAllocatorSells() public {
        vm.prank(bob);
        vm.expectRevert(Backstop.Unauthorized.selector);
        blue.sell(address(weth), 1e18, 0, abi.encode(uint8(2), bob, uint256(0)));
    }
}
