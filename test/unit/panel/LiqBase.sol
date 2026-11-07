// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {System} from "../../utils/System.sol";
import {MockERC20, MockFeed} from "../../utils/Mocks.sol";
import {ParametersBase} from "../../../src/ParametersBase.sol";
import {Backstop} from "../../../src/backstop/Backstop.sol";
import {ILedgerCover, IBackstopOracle} from "../../../src/backstop/IBackstop.sol";
import {PricerOracle} from "../../../src/backstop/PricerOracle.sol";
import {IFeed} from "../../../src/interfaces/IFeed.sol";
import {Adjust} from "../../../src/interfaces/IPositions.sol";
import {_pid} from "../../utils/Pid.sol";

/// @notice StandingBid.t.sol's setup, with SEPARATE median and spot feeds per type (the real wiring: two oracle legs).
abstract contract LiqBase is System {
    bytes32 constant ETH = "ETH";
    bytes32 constant SIMD = "SIMD";

    MockERC20 weth;
    MockERC20 simd;
    MockFeed ethMedian;
    MockFeed ethSpot;
    MockFeed simdMedian;
    MockFeed simdSpot;
    PricerOracle oracle;
    Backstop blue;
    Backstop edge;

    address alice = makeAddr("alice"); // borrower
    address bob = makeAddr("bob"); // sleeve depositor
    address carol = makeAddr("carol"); // kicker / other borrower
    address dave = makeAddr("dave");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        simd = new MockERC20("sIMD", 18);
        ethMedian = new MockFeed(2000e18);
        ethSpot = new MockFeed(2000e18);
        simdMedian = new MockFeed(5e18);
        simdSpot = new MockFeed(5e18);
        _deploySystem(IERC20(address(new MockERC20("imdUSDv1", 18))));
        _addIlk(ETH, address(weth), ethMedian, ethSpot, IFeed(address(0)), address(0), address(0), true, _risk(1.4e18, 10_000_000e18));
        ParametersBase.Risk memory ir = _risk(1.7e18, 10_000_000e18);
        ir.chop = 0.2e18;
        IFeed live = _simdLive();
        if (address(live) != address(0)) ir.redeemCap = 1_000_000e18; // a type with a live leg must have a window cap
        _addIlk(SIMD, address(simd), simdMedian, simdSpot, IFeed(address(0)), address(0), address(0), live, true, ir);

        oracle = new PricerOracle(pricer, address(params));
        oracle.setIlk(address(weth), ETH);
        oracle.setIlk(address(simd), SIMD);
        oracle.seal();
        blue = new Backstop(IERC20(address(usd)), ILedgerCover(address(ledger)), IBackstopOracle(address(oracle)), false, "blue", "bB");
        edge = new Backstop(IERC20(address(usd)), ILedgerCover(address(ledger)), IBackstopOracle(address(oracle)), true, "edge", "eB");
        blue.wire(address(liquidator), address(params), address(0));
        edge.wire(address(liquidator), address(params), address(0));
        blue.addIlk(ETH, address(weth), 0, type(uint128).max, 0);
        edge.addIlk(SIMD, address(simd), 20_000e18, type(uint128).max, 0);
        blue.seal();
        edge.seal();

        params.setGenesisBackstops(address(blue), address(edge), 0.2e18);
        params.setGenesisEdgeIlk(SIMD);
        params.setGenesisMigratorLine(10_000_000e18);
        params.seal();

        address[4] memory us = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            weth.mint(us[i], 10_000e18);
            simd.mint(us[i], 1_000_000e18);
            vm.startPrank(us[i]);
            weth.approve(address(ledger), type(uint256).max);
            simd.approve(address(ledger), type(uint256).max);
            usd.approve(address(blue), type(uint256).max);
            usd.approve(address(edge), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev The sIMD type's live pool leg (none by default); a test of the deployed sIMD shape overrides it.
    function _simdLive() internal virtual returns (IFeed) {
        return IFeed(address(0));
    }

    function _open(address u, bytes32 ilk, uint256 coll, uint256 debt, uint64 rate) internal {
        (uint256 p, uint256 n) = sorted.findInsertPosition(ilk, rate);
        vm.prank(u);
        ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), rate, p, n, false, type(uint256).max, address(0)));
    }

    function _refresh() internal {
        ethMedian.set(ethMedian.value());
        ethSpot.set(ethSpot.value());
        simdMedian.set(simdMedian.value());
        simdSpot.set(simdSpot.value());
    }

    /// @dev `who` borrows `amount` against ETH and deposits it into `sleeve`; optionally waits until it is bid room.
    function _fund(address who, Backstop sleeve, uint256 amount, bool mature) internal {
        _open(who, ETH, 2 * amount / 1000e18 * 1e18 + 10e18, amount, 0.05e18);
        vm.prank(who);
        sleeve.deposit(amount, who);
        if (mature) {
            vm.warp(vm.getBlockTimestamp() + 2 days);
            _refresh();
            sleeve.realize(who);
        }
    }

    function _pidOf(bytes32 ilk, address u) internal pure returns (uint256) {
        return _pid(ilk, u);
    }
}
