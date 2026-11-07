// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwoChains} from "../utils/TwoChains.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {MockLzEndpoint} from "../utils/MockLzEndpoint.sol";
import {Ledger} from "../../src/Ledger.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Pulse} from "../../src/Pulse.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {MessagingFee} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SendParam} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Positions on two chains, imdUSD crossing between them with messages left in flight, deliveries retried, Pulse
/// gaps (a silent sequencer) and liquidations. Reverts are tolerated; the state after each sequence is what is checked.
contract BridgeHandler is Test {
    bytes32 constant ETH = "ETH";
    struct Lane {
        Ledger ledger;
        Liquidator liquidator;
        ImdUSD usd;
        ImdBridge bridge;
        MockLzEndpoint ep;
        uint32 dstEid;
    }

    Lane[2] chains; // 0 = home, 1 = rh
    Pulse public pulse;
    MockERC20 weth;
    MockFeed ethFeed;
    address[] users;

    uint256 public start;
    uint256 public calls;
    uint256 public ok_open;
    uint256 public ok_repay;
    uint256 public ok_send;
    uint256 public ok_deliver;
    uint256 public ok_liquidate;
    uint256 public held; // liquidations held by the grace
    uint256 public silences; // passTime calls that left the chain silent past the gap
    uint256 public graceViolations; // a seizure while the grace (or a pending long gap) applied
    uint256 public lineViolations; // rh debt over its chain line right after a borrow
    uint256 public rhSentAt0;

    constructor(Lane memory home_, Lane memory rh_, Pulse pulse_, MockERC20 weth_, MockFeed ethFeed_, address[] memory users_) {
        chains[0] = home_;
        chains[1] = rh_;
        pulse = pulse_;
        weth = weth_;
        ethFeed = ethFeed_;
        users = users_;
        start = vm.getBlockTimestamp();
        vm.deal(address(this), 100 ether);
    }

    function _c(uint256 i) internal view returns (Lane storage) {
        return chains[i % 2];
    }

    function _u(uint256 s) internal view returns (address) {
        return users[s % users.length];
    }

    function open(uint256 ci, uint256 us, uint256 coll, uint256 debt) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        coll = bound(coll, 1e18, 20e18);
        uint256 max = coll * ethFeed.value() / 1e18 * 100 / 150;
        debt = bound(debt, 100e18, max);
        weth.mint(u, coll);
        vm.prank(u);
        try c.ledger.open(ETH, 0, Adjust(int256(coll), int256(debt), 0.05e18, 0, 0, false, type(uint256).max, address(0))) {
            ok_open++;
            if (ci % 2 == 1) {
                (uint128 d,,,, uint128 b) = c.ledger.ilkState(ETH);
                (uint128 d2,,,, uint128 b2) = c.ledger.ilkState("OTHER");
                if (uint256(d) + b + d2 + b2 > 30_000e18) lineViolations++;
            }
        } catch {}
    }

    function repay(uint256 ci, uint256 us, uint256 amount) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        uint256 debt = c.ledger.debtOf(_pid(ETH, u));
        amount = bound(amount, 0, debt < c.usd.balanceOf(u) ? debt : c.usd.balanceOf(u));
        if (amount == 0) return;
        if (debt - amount != 0 && debt - amount < 100e18) amount = debt;
        if (amount > c.usd.balanceOf(u)) return;
        vm.prank(u);
        try c.ledger.open(ETH, 0, Adjust(0, -int256(amount), 0, 0, 0, false, type(uint256).max, address(0))) {
            ok_repay++;
        } catch {}
    }

    function send(uint256 ci, uint256 us, uint256 to, uint256 amount) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        amount = bound(amount, 0, c.usd.balanceOf(u));
        if (amount < 1e12) return;
        SendParam memory p = SendParam(c.dstEid, bytes32(uint256(uint160(_u(to)))), amount, 0, "", "", "");
        MessagingFee memory fee = c.bridge.quoteSend(p, false);
        vm.deal(u, fee.nativeFee);
        vm.prank(u);
        try c.bridge.send{value: fee.nativeFee}(p, fee, u) {
            ok_send++;
        } catch {}
    }

    function deliver(uint256 ci, uint256 idx) external {
        calls++;
        MockLzEndpoint ep = _c(ci).ep;
        uint256 n = ep.packetCount();
        if (n == 0) return;
        if (ep.deliver(idx % n)) ok_deliver++;
    }

    /// Time passes; with `silent` the rh sequencer produces nothing (nobody can poke), up to 3 hours.
    function passTime(uint256 dt, bool silent) external {
        calls++;
        if (silent) {
            dt = bound(dt, 16 minutes, 3 hours);
            silences++;
            vm.warp(vm.getBlockTimestamp() + dt);
        } else {
            dt = bound(dt, 1 minutes, 12 hours);
            uint256 end = vm.getBlockTimestamp() + dt;
            while (vm.getBlockTimestamp() < end) {
                vm.warp(vm.getBlockTimestamp() + 10 minutes > end ? end : vm.getBlockTimestamp() + 10 minutes);
                pulse.poke();
            }
        }
        ethFeed.set(ethFeed.value());
    }

    function movePrice(uint256 p) external {
        calls++;
        ethFeed.set(bound(p, 1200e18, 2600e18));
    }

    function liquidate(uint256 ci, uint256 us) external {
        calls++;
        Lane storage c = _c(ci);
        address u = _u(us);
        uint256 debt = c.ledger.debtOf(_pid(ETH, u));
        if (debt == 0) return;
        // the liquidator's imdUSD comes out of circulation: borrow it from a user who holds enough (no unbacked mint)
        address payer;
        for (uint256 i; i < users.length; ++i) {
            if (users[i] != u && c.usd.balanceOf(users[i]) >= debt) payer = users[i];
        }
        if (payer == address(0)) return;
        vm.prank(payer);
        c.usd.transfer(address(this), debt);
        // seen from the rh Pulse before the call: a long gap pending, or a grace running
        bool mustHold = ci % 2 == 1 && (vm.getBlockTimestamp() - pulse.lastPulse() > pulse.gap() || vm.getBlockTimestamp() < pulse.graceUntil());
        try c.liquidator.liquidate(_pid(ETH, u)) returns (uint256 repaid, uint256 seized, uint256) {
            if (repaid + seized == 0) held++;
            else ok_liquidate++;
            if (mustHold && repaid + seized != 0) graceViolations++;
        } catch {}
        uint256 left = c.usd.balanceOf(address(this));
        if (left != 0) c.usd.transfer(payer, left);
    }

    function rhSent() external view returns (uint256) {
        return chains[1].bridge.sent();
    }
}

contract BridgeInvariantsTest is TwoChains {
    BridgeHandler handler;
    address[] users;

    function setUp() public {
        _setUpChains();
        _open();
        // the rh -> home path charges the highest fee, so every send exercises the fee mint
        vm.prank(safe);
        rh.bridge.propose(abi.encode(uint8(7), HOME_EID, uint256(25)));
        _warp(48 hours);
        rh.bridge.applyPending();
        for (uint256 i; i < 4; ++i) {
            address u = makeAddr(string(abi.encodePacked("user", i)));
            users.push(u);
            vm.startPrank(u);
            weth.approve(address(home.ledger), type(uint256).max);
            weth.approve(address(rh.ledger), type(uint256).max);
            vm.stopPrank();
        }
        BridgeHandler.Lane memory h = BridgeHandler.Lane(home.ledger, home.liquidator, home.usd, home.bridge, homeEp, RH_EID);
        BridgeHandler.Lane memory r = BridgeHandler.Lane(rh.ledger, rh.liquidator, rh.usd, rh.bridge, rhEp, HOME_EID);
        handler = new BridgeHandler(h, r, rh.pulse, weth, ethFeed, users);
        targetContract(address(handler));
    }

    function invariant_supplyPerChain() public {
        _assertChainSupply(home);
        _assertChainSupply(rh);
    }

    /// Σ supply + in flight == Σ ledger terms: imdUSD is never created or lost in transit.
    function invariant_supplyAcrossChains() public {
        _assertGlobalSupply();
    }

    function invariant_noSeizureDuringGrace() public view {
        assertEq(handler.graceViolations(), 0, "seized during a Pulse grace");
    }

    function invariant_chainLineHeld() public view {
        assertEq(handler.lineViolations(), 0, "rh debt over its chain line after a borrow");
    }

    /// A decaying limiter lets at most limit + limit x elapsed / window through in `elapsed`.
    function invariant_outboundLimit() public view {
        uint256 elapsed = vm.getBlockTimestamp() - handler.start();
        assertLe(handler.rhSent(), OUT_LIMIT + OUT_LIMIT * elapsed / 1 days, "rh exported more than its limit allows");
    }

    /// Non-hollow: the handler's actions do succeed (one deterministic sequence through every path).
    function test_handlerActionsSucceed() public {
        handler.open(1, 0, 10e18, 13_000e18);
        handler.open(0, 1, 10e18, 13_000e18);
        handler.send(1, 0, 2, 5_000e18);
        handler.send(0, 1, 3, 2_000e18);
        invariant_supplyAcrossChains();
        handler.deliver(1, 0);
        handler.deliver(0, 0);
        handler.repay(0, 1, 1_000e18);
        handler.passTime(1 hours, true); // a silent sequencer
        handler.movePrice(1300e18);
        handler.open(1, 2, 20e18, 15_000e18); // a second holder on rh, whose imdUSD pays the liquidator
        handler.liquidate(1, 0); // held by the grace its own poke starts
        handler.passTime(2 hours, false);
        handler.movePrice(1300e18);
        handler.liquidate(1, 0); // seized
        handler.open(0, 3, 20e18, 15_000e18);
        handler.liquidate(0, 1); // mainnet-shaped: seized at once
        assertGt(handler.ok_open(), 1);
        assertGt(handler.ok_send(), 1);
        assertGt(handler.ok_deliver(), 1);
        assertGt(handler.ok_repay(), 0);
        assertGt(handler.held(), 0);
        assertGt(handler.ok_liquidate(), 1);
        invariant_supplyPerChain();
        invariant_supplyAcrossChains();
        invariant_noSeizureDuringGrace();
        invariant_outboundLimit();
    }
}
