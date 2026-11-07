// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PegSystem} from "../utils/PegSystem.sol";
import {Join} from "../../src/Join.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {PegLPVault, IPegHookView} from "../../src/earn/PegLPVault.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {PegShareFeed, IPegVaultRead} from "../../src/earn/PegShareFeed.sol";
import {PegCollateral} from "../../src/earn/PegCollateral.sol";
import {PegPositionZap, IPegZapVault, IPegZapLedger} from "../../src/earn/PegPositionZap.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Peg positions against a local v4 PoolManager and the real PegHook + PegLPVault. Both token orders.
abstract contract PegPositionsTest is PegSystem {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 constant PEG = "PEG";
    uint64 constant RATE = 0.02e18;

    PegLPVault vault;
    PegCollateral coll;
    PegShareFeed feed;
    PegShareFeed spotLeg;
    PegPositionZap zap;
    PositionNFT nft;
    address alice = makeAddr("alice");
    address seed = makeAddr("seed");

    function _quoteAddr() internal pure virtual returns (address);

    /// @dev The peg type's risk (DeployConfig's values): solvent in imdUSD terms at every price, so a low mat.
    function pegRisk(uint128 line) internal pure returns (ParametersBase.Risk memory) {
        return ParametersBase.Risk({
            mat: 1.1e18,
            chop: 0.05e18,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: 0.005e18,
            yieldFee: 0,
            skew: 0.01e18,
            pegFloor: 0.98e18,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18,
            redeemDivisor: 1,
            redeemCap: 0
        });
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("USDC", uint8(6)), _quoteAddr());
        _deployPeg(IPoolManager(address(new PoolManager(address(this)))), IERC20(_quoteAddr()), 1e24);
        _hold(0, 31 minutes);
        vault = new PegLPVault(pm, IPegHookView(address(hook)), address(treasury), 100);
        feed = new PegShareFeed(IPegVaultRead(address(vault)), address(usd), address(quoteUsd), QUOTE_MAX_AGE, false);
        spotLeg = new PegShareFeed(IPegVaultRead(address(vault)), address(usd), address(quoteUsd), QUOTE_MAX_AGE, true);

        // The type, through the timelock (Parameters is sealed): shares as collateral, priced by the share feed.
        coll = new PegCollateral(IERC20(address(vault)), address(this));
        Join join = new Join(address(coll), address(this));
        join.wire(address(ledger));
        ParametersBase.Config memory c = ParametersBase.Config({
            token: address(coll),
            join: address(join),
            median: IFeed(address(feed)),
            spot: IFeed(address(spotLeg)), // the deployed spot leg, full value while two-sided, else 0
            nhi: IFeed(address(0)),
            yieldRate: address(0),
            pegAggregator: address(quoteUsd),
            liveSpot: IFeed(address(0)),
            redeemable: false,
            auction: false
        });
        bytes memory add = abi.encode(params.ADD_ILK(), PEG, c, pegRisk(1_000_000e18));
        vm.prank(governor);
        params.propose(add);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        _hold(0, 31 minutes);

        zap = new PegPositionZap(IERC20(address(usd)), IPegZapVault(address(vault)), coll, IPegZapLedger(address(ledger)), PEG);
        coll.setZap(address(zap));
        nft = ledger.nft();

        // A seed LP (the team at launch), so the vault prices deposits by its holdings.
        _fund(seed, 100_000e18, 100_000e6);
        vm.startPrank(seed);
        usd.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        if (hook.stableIsToken0()) vault.deposit(0, 100_000e18, 100_000e6, seed);
        else vault.deposit(0, 100_000e6, 100_000e18, seed);
        vm.stopPrank();

        _fund(alice, 0, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(zap), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers

    function _open(uint256 usdcIn) internal returns (uint256 id) {
        vm.prank(alice);
        id = zap.open(usdcIn, RATE, 0, type(uint256).max, 0, 0);
    }

    function _shareUsd(uint256 shares) internal view returns (uint256) {
        (uint256 v,) = feed.latestValue();
        return shares * v / 1e18;
    }

    function _assertSupply() internal {
        ledger.accrue(PEG);
        (uint128 d,,,, uint128 bad) = ledger.ilkState(PEG);
        assertEq(usd.totalSupply(), baseSupply + _keeperOutstanding() + d + bad, "supply == dealt + keeper + peg debt");
    }

    function _assertZapEmpty() internal view {
        assertEq(usd.balanceOf(address(zap)), 0, "zap holds no imdUSD");
        assertEq(usdc.balanceOf(address(zap)), 0, "zap holds no USDC");
        assertEq(vault.balanceOf(address(zap)), 0, "zap holds no shares");
        assertEq(usd.flashOutstanding(), 0, "flash repaid in the transaction");
    }

    // ------------------------------------------------------------ open

    function test_openAtPegDoublesDepth() public {
        uint256 l0 = vault.liquidity();
        uint256 id = _open(10_000e6);
        assertEq(nft.ownerOf(id), alice, "the user owns the position");
        LedgerBase.Position memory p = ledger.position(id);
        uint256 debt = ledger.debtOf(id);
        // About 10k imdUSD placed beside ~10k USDC (the vault's proportion at the peg), debt = placed + the upfront fee.
        assertApproxEqRel(debt, 10_000e18, 0.02e18, "debt ~ the imdUSD placed");
        assertApproxEqRel(_shareUsd(p.collateral), 2 * 10_000e18, 0.02e18, "collateral ~ 2x the debt at the peg");
        assertGt(vault.liquidity(), l0, "the vault's in-band liquidity grew");
        (bool ok, bool priced) = ledger.healthy(id);
        assertTrue(ok && priced);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6, 20e6, "unused USDC refunded");
        _assertZapEmpty();
        _assertSupply();
    }

    function test_upfrontFeeIsPaid() public {
        uint256 fee = ledger.upfrontFeeFor(PEG, 10_000e18, RATE);
        assertGt(fee, 0);
        vm.prank(alice);
        vm.expectRevert();
        zap.open(10_000e6, RATE, 0, fee / 2, 0, 0); // the fee bound holds through the zap
        uint256 supply0 = usd.totalSupply();
        uint256 id = _open(10_000e6);
        uint256 placed = usd.totalSupply() - supply0 - fee; // the borrow is minted; the fee is minted as interest
        assertApproxEqAbs(ledger.debtOf(id), placed + fee, 2, "debt = imdUSD placed + the upfront fee");
    }

    function test_notRedeemable() public {
        _open(10_000e6);
        _fund(address(this), 1_000e18, 0);
        vm.expectRevert();
        redeemer.redeem(PEG, 1_000e18, 1e18, 10, 0);
    }

    function test_rateFloorHolds() public {
        vm.prank(alice);
        vm.expectRevert();
        zap.open(10_000e6, 0.001e18, 0, type(uint256).max, 0, 0);
    }

    // ------------------------------------------------------------ the share price

    /// A push inside the band changes the mix, not the sum at $1: the share value moves by at most ~the band's half-width.
    function test_shareValueBarelyMovesUnderAPush() public {
        _open(10_000e6);
        (uint256 v0,) = feed.latestValue();
        _moveTo(-95); // near the band's lower edge (-1%)
        (uint256 vDown,) = feed.latestValue();
        _moveTo(95);
        (uint256 vUp,) = feed.latestValue();
        _moveTo(-500); // far past the band: the position is all imdUSD, nothing more to trade
        (uint256 vFarDown,) = feed.latestValue();
        _moveTo(500);
        (uint256 vFarUp,) = feed.latestValue();
        assertApproxEqRel(vDown, v0, 0.011e18, "inside the band: within ~1%");
        assertApproxEqRel(vUp, v0, 0.011e18, "inside the band: within ~1%");
        assertApproxEqRel(vFarDown, v0, 0.011e18, "past the band: no further change");
        assertApproxEqRel(vFarUp, v0, 0.011e18, "past the band: no further change");
    }

    function test_usdcDepegLowersTheValue() public {
        _open(10_000e6);
        (uint256 v0,) = feed.latestValue();
        quoteUsd.set(0.9e8);
        (uint256 v1,) = feed.latestValue();
        assertApproxEqRel(v1, v0 * 95 / 100, 0.01e18, "the USDC half counts at $0.90");
        quoteUsd.setBroken(true);
        (uint256 v2,) = feed.latestValue();
        assertEq(v2, 0, "unreadable quote price = unpriced");
    }

    // ------------------------------------------------------------ unwind

    function _grant(uint256 id) internal {
        vm.prank(alice);
        nft.approveOperator(id, address(zap), 32); // WITHDRAW_ANY
    }

    function test_unwindRoundTrip() public {
        uint256 id = _open(10_000e6);
        uint256 u0 = usdc.balanceOf(alice);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _grant(id);
        _fund(alice, 1_000e18, 0); // the upfront fee + a day of interest are covered by the owner
        vm.startPrank(alice);
        usd.approve(address(zap), type(uint256).max);
        zap.unwind(id, 0, type(uint256).max);
        vm.stopPrank();
        assertEq(ledger.debtOf(id), 0);
        assertEq(ledger.position(id).collateral, 0);
        assertApproxEqRel(usdc.balanceOf(alice) - u0, 10_000e6, 0.01e18, "USDC back");
        _assertZapEmpty();
        _assertSupply();
    }

    function test_unwindNeedsTheGrant() public {
        uint256 id = _open(10_000e6);
        vm.prank(alice);
        vm.expectRevert();
        zap.unwind(id, 0, type(uint256).max);
    }

    function test_onlyTheOwnerUnwinds() public {
        uint256 id = _open(10_000e6);
        _grant(id);
        vm.expectRevert(PegPositionZap.NotOwner.selector);
        zap.unwind(id, 0, type(uint256).max);
    }

    /// Below the band the shares are all imdUSD (bought back under $1): they repay the debt at par with imdUSD to spare.
    function test_solventFarBelowTheBand() public {
        uint256 id = _open(10_000e6);
        _moveTo(-500);
        (bool ok,) = ledger.healthy(id);
        assertTrue(ok, "healthy below the band");
        _grant(id);
        uint256 i0 = usd.balanceOf(alice);
        vm.prank(alice);
        zap.unwind(id, 0, type(uint256).max);
        assertGt(usd.balanceOf(alice), i0, "imdUSD to spare after repaying the debt in full");
        _assertZapEmpty();
    }

    /// Above the band the shares are all USDC (~2x the debt): the owner covers the imdUSD and keeps the USDC.
    function test_solventFarAboveTheBand() public {
        uint256 id = _open(10_000e6);
        _moveTo(500);
        (bool ok,) = ledger.healthy(id);
        assertTrue(ok, "healthy above the band");
        _grant(id);
        _fund(alice, 20_000e18, 0);
        uint256 u0 = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usd.approve(address(zap), type(uint256).max);
        zap.unwind(id, 0, type(uint256).max);
        vm.stopPrank();
        assertApproxEqRel(usdc.balanceOf(alice) - u0, 2 * 10_000e6, 0.02e18, "about 2x the USDC back");
        _assertZapEmpty();
    }

    function test_onlyTheLenderCallsBack() public {
        vm.expectRevert(PegPositionZap.NotLender.selector);
        zap.onFlashLoan(address(zap), address(usd), 1, 0, abi.encode(uint8(1)));
    }

    /// Below the band the vault is one-sided, the spot leg reads 0 and the Ledger refuses new PEG debt: neither
    /// the zap nor a holder of collateral can draw it there.
    function test_PEG01_noOneSidedBorrowBelowBand() public {
        address bob = makeAddr("bob");
        uint256 id = _bobCollateral(bob, 2_000e6);
        uint256 held = coll.balanceOf(bob);
        _hold(-500, 31 minutes);
        vm.prank(alice);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        zap.open(1_000e6, RATE, 0, type(uint256).max, 0, 0);
        vm.startPrank(bob);
        vm.expectRevert(LedgerBase.NotPriced.selector);
        ledger.open(PEG, 1, Adjust(int256(held), 500e18, RATE, 0, 0, false, type(uint256).max, bob));
        vm.stopPrank();
        id;
    }

    // ------------------------------------------------------------ the spot leg (re-check)

    /// The spot leg is the full share value while the USDC part of the vault's value is within 25%-75%, and 0 outside.
    function test_PEG_spotLegFullValueOrZero() public {
        int24[12] memory ts = [int24(-500), -150, -95, -75, -25, -1, 0, 1, 25, 75, 95, 500];
        for (uint256 i; i < ts.length; ++i) {
            _moveTo(ts[i]);
            (uint256 m,) = feed.latestValue();
            (uint256 s,) = spotLeg.latestValue();
            (uint256 t0, uint256 t1) = vault.positionAmounts();
            (uint256 st, uint256 q) = hook.stableIsToken0() ? (t0, t1 * 1e12) : (t1, t0 * 1e12);
            uint256 bps = q * 10_000 / (st + q);
            assertEq(s, bps >= 2_500 && bps <= 7_500 ? m : 0, "full value inside 25-75% USDC, 0 outside");
        }
    }

    /// The recheck's PoC turned round. New debt is open across the two-sided range (not only +-1 tick around the centre),
    /// and refused once the vault turns one-sided, either way.
    function test_RD_pegBorrowWindow() public {
        int24[9] memory open_ = [int24(-40), -25, -5, -2, 0, 2, 5, 25, 40];
        for (uint256 i; i < open_.length; ++i) {
            _hold(open_[i], 31 minutes); // the zap's deposit needs the spot at its TWAP (PegLPVault's own gate)
            assertTrue(pricer.quote(PEG).borrowable, "two-sided: PEG debt may be drawn");
            uint256 id = _open(1_000e6);
            assertGt(ledger.debtOf(id), 0, "the zap opens here");
        }
        int24[4] memory shut = [int24(-75), -150, 75, 150];
        for (uint256 i; i < shut.length; ++i) {
            _moveTo(shut[i]);
            Pricer.Quote memory q = pricer.quote(PEG);
            assertFalse(q.borrowable, "one-sided: no new PEG debt");
            assertTrue(q.priced, "still priced: liquidation and repayment carry on");
            (uint256 m,) = feed.latestValue();
            assertEq(q.low, m, "measured at the full-value median");
        }
    }

    /// The recheck's PoC turned round: a position healthy at the shares' full value stays healthy under any push, sub-tick
    /// or out of the band, either way: a mix change never lowers the liquidation price.
    function test_RD_pegFlashLiquidation() public {
        _moveTo(0);
        uint256 id = _open(10_000e6);
        uint256 debt = ledger.debtOf(id);
        (uint256 m,) = feed.latestValue();
        uint256 keep = Math.mulDiv(debt, 1.104e18, m); // levered down to ~110.4% at the full value (legal at the centre)
        uint256 held = ledger.position(id).collateral;
        vm.prank(alice);
        ledger.adjust(id, Adjust(-int256(held - keep), 0, 0, 0, 0, false, 0, alice));

        // 0.9 of one tick below the centre: the nudge that flipped it under the USDC-part leg.
        (uint160 sp0,,,) = pm.getSlot0(key.toId());
        uint160 sp1 = TickMath.getSqrtPriceAtTick(hook.stableIsToken0() ? hook.pegTick() - 1 : hook.pegTick() + 1);
        uint160 limit = uint160(sp1 > sp0 ? sp0 + uint256(sp1 - sp0) * 9 / 10 : sp0 - uint256(sp0 - sp1) * 9 / 10);
        router.swap(key, SwapParams(limit < sp0, -int256(1e30), limit));
        _assertUntouchable(id);

        int24[8] memory ts = [int24(-30), 30, -60, 60, -95, 95, -500, 500];
        for (uint256 i; i < ts.length; ++i) {
            _moveTo(ts[i]);
            _assertUntouchable(id);
        }
    }

    function _assertUntouchable(uint256 id) private {
        (bool ok, bool priced) = ledger.healthy(id);
        assertTrue(ok && priced, "healthy at the full value");
        vm.expectRevert(Liquidator.Healthy.selector);
        liquidator.liquidate(id);
    }

    /// A one-tx push from one-sided into the two-sided range only opens the door to debt, on collateral already held: it
    /// moves no value. The pusher (router + bob together, so nothing is hidden between them) ends poorer: the round trip's
    /// fees and toll, plus the upfront fee. New collateral cannot be made in the push (next test, and PegCollateral.t.sol).
    function test_PEG_pushIntoRangeDoesNotProfit() public {
        address bob = makeAddr("bob");
        _bobCollateral(bob, 2_000e6);
        uint256 held = coll.balanceOf(bob);
        assertGt(held, 0);
        _hold(-150, 31 minutes);
        assertFalse(pricer.quote(PEG).borrowable, "one-sided below the band");
        uint256 before = _worth(bob) + _shareUsd(held);

        _moveTo(-40); // the push: buys imdUSD from the band with USDC
        assertTrue(pricer.quote(PEG).borrowable, "the push opens the door for this transaction");
        vm.prank(bob);
        ledger.open(PEG, 1, Adjust(int256(held), 200e18, RATE, 0, 0, false, type(uint256).max, bob));
        _moveTo(-150); // and back

        uint256 id = ledger.positionId(bob, PEG, 1);
        uint256 afterW = _worth(bob) + _shareUsd(ledger.position(id).collateral) - ledger.debtOf(id);
        console2.log("pusher's loss, imdUSD at par", before - afterW);
        assertLt(afterW, before, "the push costs, and earns nothing");
    }

    /// PegLPVault's TWAP gate refuses a deposit made AFTER a push. It does not stop one made BEFORE it (spot == TWAP): what
    /// stops that route is that raw shares are not PEG collateral (PegCollateral.t.sol).
    function test_PEG_depositAfterAPushRefused() public {
        address bob = makeAddr("bob");
        _hold(-150, 31 minutes);
        _fund(bob, 1_000e18, 1_000e6);
        vm.startPrank(bob);
        usd.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        _moveTo(-40);
        (uint256 m0, uint256 m1) = hook.stableIsToken0() ? (uint256(1_000e18), uint256(1_000e6)) : (uint256(1_000e6), uint256(1_000e18));
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1e18, m0, m1, bob);
    }

    /// @dev Bob opens through the zap at the peg, then takes out what the position does not need (held as collateral tokens).
    function _bobCollateral(address bob, uint256 usdcIn) internal returns (uint256 id) {
        _fund(bob, 0, usdcIn);
        vm.startPrank(bob);
        usdc.approve(address(zap), type(uint256).max);
        coll.approve(address(ledger), type(uint256).max);
        id = zap.open(usdcIn, RATE, 0, type(uint256).max, 0, 0);
        uint256 held = ledger.position(id).collateral;
        ledger.adjust(id, Adjust(-int256(held / 4), 0, 0, 0, 0, false, 0, bob));
        vm.stopPrank();
    }

    /// @dev bob + the router, tokens at par.
    function _worth(address bob) internal view returns (uint256) {
        return usd.balanceOf(bob) + usd.balanceOf(address(router)) + (usdc.balanceOf(bob) + usdc.balanceOf(address(router))) * 1e12;
    }
}

contract PegPositionsStable0Test is PegPositionsTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }
}

contract PegPositionsStable1Test is PegPositionsTest {
    function _quoteAddr() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001001);
    }

}
