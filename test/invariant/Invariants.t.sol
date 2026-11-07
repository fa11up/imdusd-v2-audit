// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PegSystem, PegRouter} from "../utils/PegSystem.sol";
import {MockERC20, MockFeed, MockVault} from "../utils/Mocks.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Ledger} from "../../src/Ledger.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {SortedPositions} from "../../src/SortedPositions.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {Migrator} from "../../src/Migrator.sol";
import {RateFeed} from "../../src/feeds/RateFeed.sol";
import {Join} from "../../src/Join.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {SavingsVault} from "../../src/SavingsVault.sol";
import {PegHook} from "../../src/peg/PegHook.sol";
import {FeeNotes, ITreasuryNotes} from "../../src/peg/FeeNotes.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";

/// @notice Drives the system with bounded, mostly-valid random actions. Reverts are tolerated (the
/// invariant config has fail_on_revert = false); what matters is the state after every sequence.
/// Besides positions, savings and migration it trades the v2 imdUSD/USDC peg pool (a real local v4
/// PoolManager with the PegHook), holds prices so the hook's TWAP moves, and calls the peg keeper, so the
/// supply equation's `keeper.outstanding` term is exercised with positions present; and it buys and redeems
/// fee notes.
contract Handler is Test {
    bytes32 constant ETH = "ETH";
    bytes32 constant SUSDC = "S-USDC";
    int24 constant TRADE_LIMIT_TICKS = 400; // a trade never pushes the pool past ±4%

    Ledger ledger;
    Redeemer redeemer;
    Liquidator liquidator;
    SortedPositions sorted;
    ImdUSD usd;
    Migrator migrator;
    MockFeed ethFeed;
    MockFeed usdcFeed;
    MockVault vault;
    MockERC20 v1;
    address[] public users;

    uint256 public calls;
    uint256 public ok_open;
    uint256 public ok_rate;
    uint256 public ok_redeem;
    uint256 public ok_liquidate;
    uint256 public ok_harvest;
    uint256 public ok_save;
    uint256 public ok_unsave;
    uint256 public ok_trade;
    uint256 public ok_provide;
    uint256 public ok_withdraw;
    uint256 public ok_buffer;
    uint256 public ok_note;
    uint256 public ok_redeemNote;
    uint256 public minted; // by the keeper, in total
    uint256 public burned; // by the keeper, in total

    SavingsVault public savings;
    PegHook public hook;
    PegRouter public router;
    MockERC20 public usdc;
    FeeNotes public notes;
    PoolKey key;

    function setSavings(SavingsVault savings_) external {
        savings = savings_;
    }

    /// @dev setUp's one call. The fuzzer targets this contract, so a second call (random addresses) must revert, or every
    /// keeper call after it runs against a junk hook and the ghost totals read nonsense.
    function setPeg(PegHook hook_, PegRouter router_, PoolKey memory key_, MockERC20 usdc_, FeeNotes notes_) external {
        require(address(hook) == address(0), "setPeg: set once in setUp");
        hook = hook_;
        router = router_;
        key = key_;
        usdc = usdc_;
        notes = notes_;
    }

    constructor(
        Ledger ledger_,
        Redeemer redeemer_,
        Liquidator liquidator_,
        Migrator migrator_,
        MockFeed ethFeed_,
        MockFeed usdcFeed_,
        MockVault vault_,
        MockERC20 v1_,
        address[] memory users_
    ) {
        ledger = ledger_;
        redeemer = redeemer_;
        liquidator = liquidator_;
        sorted = ledger_.sorted();
        usd = ledger_.token();
        migrator = migrator_;
        ethFeed = ethFeed_;
        usdcFeed = usdcFeed_;
        vault = vault_;
        v1 = v1_;
        users = users_;
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function _ilk(uint256 seed) internal pure returns (bytes32) {
        return seed % 2 == 0 ? ETH : SUSDC;
    }

    function _hints(bytes32 ilk, uint64 rate) internal view returns (uint256 p, uint256 n) {
        return sorted.findInsertPosition(ilk, rate);
    }

    function _refreshFeeds() internal {
        ethFeed.set(ethFeed.value());
        usdcFeed.set(usdcFeed.value());
    }

    /// Opens or adds to a position with collateral and debt the position can carry (~70% of its limit).
    function open(uint256 u, uint256 i, uint256 coll, uint256 debt, uint256 rate) external {
        calls++;
        address user = _user(u);
        bytes32 ilk = _ilk(i);
        uint64 r = uint64(bound(rate, 0.01e18, 0.3e18));
        (uint256 p, uint256 n) = _hints(ilk, r);
        uint256 value;
        if (ilk == ETH) {
            coll = bound(coll, 1e18, 50e18);
            value = coll * ethFeed.value() / 1e18;
        } else {
            coll = bound(coll, 1_000e6, 100_000e6);
            value = coll * 1e12;
        }
        uint256 room = value * 70 / 100 * 1e18 / (ilk == ETH ? 1.4e18 : 1.08e18);
        debt = bound(debt, 100e18, room > 100e18 ? room : 100e18);
        vm.prank(user);
        try ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), r, p, n, ilk == SUSDC, type(uint256).max, address(0))) {
            ok_open++;
        } catch {}
    }

    function repay(uint256 u, uint256 i, uint256 amount) external {
        calls++;
        address user = _user(u);
        bytes32 ilk = _ilk(i);
        uint256 debt = ledger.debtOf(_pid(ilk, user));
        amount = bound(amount, 0, debt);
        if (amount > usd.balanceOf(user)) amount = usd.balanceOf(user);
        vm.prank(user);
        ledger.open(ilk, 0, Adjust(0, -int256(amount), 0, 0, 0, false, type(uint256).max, address(0)));
    }

    function withdraw(uint256 u, uint256 i, uint256 amount) external {
        calls++;
        address user = _user(u);
        bytes32 ilk = _ilk(i);
        amount = bound(amount, 0, ledger.position(_pid(ilk, user)).collateral);
        vm.prank(user);
        ledger.open(ilk, 0, Adjust(-int256(amount), 0, 0, 0, 0, false, type(uint256).max, address(0)));
    }

    function setRate(uint256 u, uint256 i, uint256 rate) external {
        calls++;
        bytes32 ilk = _ilk(i);
        address user = _withDebt(ilk, u);
        if (user == address(0)) return;
        uint64 r = uint64(bound(rate, 0.01e18, 0.3e18));
        (uint256 p, uint256 n) = _hints(ilk, r);
        vm.prank(user);
        try ledger.setRate(_pid(ilk, user), r, p, n) {
            ok_rate++;
        } catch {}
    }

    function _withDebt(bytes32 ilk, uint256 seed) internal view returns (address) {
        for (uint256 k; k < users.length; ++k) {
            address cand = users[(seed + k) % users.length];
            if (ledger.position(_pid(ilk, cand)).debt != 0) return cand;
        }
        return address(0);
    }

    function movePrice(uint256 price) external {
        calls++;
        ethFeed.set(bound(price, 800e18, 4000e18));
    }

    function passTime(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 10 days));
        _refreshFeeds();
    }

    function accrue(uint256 i) external {
        calls++;
        ledger.accrue(_ilk(i));
    }

    function vaultYield(uint256 amount) external {
        calls++;
        vault.accrue(bound(amount, 0, 2_000e6));
    }

    function redeem(uint256 u, uint256 i, uint256 amount) external {
        calls++;
        bytes32 ilk = _ilk(i);
        address user = _user(u);
        uint256 bal = usd.balanceOf(user);
        if (bal < 1e18 || sorted.size(ilk) == 0) return;
        amount = bound(amount, 1e18, bal);
        vm.prank(user);
        try redeemer.redeem(ilk, amount, 0.05e18, 20, 0) {
            ok_redeem++;
        } catch {}
    }

    /// Crashes the price far enough that someone is unhealthy, then liquidates them.
    function liquidate(uint256 liq, uint256 seed, uint256 crash) external {
        calls++;
        address target = _withDebt(ETH, seed);
        if (target == address(0)) return;
        ethFeed.set(bound(crash, 500e18, 1500e18));
        (bool ok,) = ledger.healthy(_pid(ETH, target));
        if (ok) return;
        address l = _user(liq);
        if (l == target) l = _user(liq + 1);
        uint256 need = ledger.debtOf(_pid(ETH, target));
        if (usd.balanceOf(l) < need) {
            uint64 r = 0.05e18;
            (uint256 p, uint256 n) = _hints(SUSDC, r);
            vm.prank(l);
            try ledger.open(SUSDC, 0, Adjust(int256(need * 2 / 1e12 + 1_000e6), int256(need), r, p, n, true, type(uint256).max, address(0))) {} catch {}
        }
        vm.prank(l);
        try liquidator.liquidate(_pid(ETH, target)) {
            ok_liquidate++;
        } catch {}
    }

    function harvest(uint256 i) external {
        calls++;
        uint256[] memory ids = new uint256[](users.length);
        for (uint256 k; k < ids.length; ++k) ids[k] = _pid(SUSDC, users[k]);
        try ledger.harvest(SUSDC, ids) {
            ok_harvest++;
        } catch {}
        i;
    }

    function migrate(uint256 u, uint256 amount, bool back) external {
        calls++;
        address user = _user(u);
        amount = bound(amount, 0, 10_000e18);
        vm.startPrank(user);
        if (back) migrator.toV1(amount);
        else migrator.toV2(amount);
        vm.stopPrank();
    }

    /// sImdUSD: deposit, redeem, and donate (a donation must only stream, never jump the price).
    function save(uint256 u, uint256 amount) external {
        calls++;
        address user = _user(u);
        amount = bound(amount, 0, usd.balanceOf(user));
        vm.startPrank(user);
        usd.approve(address(savings), amount);
        try savings.deposit(amount, user) {
            ok_save++;
        } catch {}
        vm.stopPrank();
    }

    function unsave(uint256 u, uint256 shares) external {
        calls++;
        address user = _user(u);
        shares = bound(shares, 0, savings.balanceOf(user));
        vm.prank(user);
        try savings.redeem(shares, user, user) {
            ok_unsave++;
        } catch {}
    }

    function donate(uint256 u, uint256 amount) external {
        calls++;
        address user = _user(u);
        amount = bound(amount, 0, usd.balanceOf(user));
        vm.prank(user);
        usd.transfer(address(savings), amount);
    }

    function cover(uint256 u, uint256 i, uint256 amount) external {
        calls++;
        vm.prank(_user(u));
        ledger.cover(_ilk(i), bound(amount, 0, 100_000e18));
    }

    // ------------------------------------------------------------ the peg pool

    function _limit(int24 stableTicks) internal view returns (uint160) {
        int24 t = hook.pegTick();
        return TickMath.getSqrtPriceAtTick(hook.stableIsToken0() ? t + stableTicks : t - stableTicks);
    }

    /// The market buys imdUSD with fresh USDC (mock-minted: USDC is not in the supply equation), up to +4%.
    function tradeUp(uint256 amount) external {
        calls++;
        amount = bound(amount, 1e6, 300_000e6);
        usdc.mint(address(router), amount);
        try router.swap(key, SwapParams(!hook.stableIsToken0(), -int256(amount), _limit(TRADE_LIMIT_TICKS))) {
            ok_trade++;
        } catch {}
    }

    /// A user sells borrowed imdUSD into the pool (through the router), down to −4%.
    function tradeDown(uint256 u, uint256 amount) external {
        calls++;
        address user = _user(u);
        amount = bound(amount, 0, usd.balanceOf(user));
        if (amount < 1e18) return;
        vm.prank(user);
        usd.transfer(address(router), amount);
        try router.swap(key, SwapParams(hook.stableIsToken0(), -int256(amount), _limit(-TRADE_LIMIT_TICKS))) {
            ok_trade++;
        } catch {}
    }

    /// The pool is poked (1 unit of USDC) so the hook checkpoints the current tick, then time passes with the
    /// price held. With `isolate = true` a warp inside one call does not reach that call's own nested swaps, so the
    /// poke comes first and the elapsed time is seen by the next call (the keeper's TWAP then covers the hold).
    function hold(uint256 secs) external {
        calls++;
        secs = bound(secs, 60, 40 minutes);
        usdc.mint(address(router), 1);
        bool z = !hook.stableIsToken0();
        try router.swap(key, SwapParams(z, -1, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)) {} catch {}
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12);
        _refreshFeeds();
    }

    function keeperProvide() external {
        calls++;
        try hook.provide() returns (uint256 m) {
            ok_provide++;
            minted += m;
        } catch {}
    }

    function keeperWithdraw() external {
        calls++;
        try hook.withdraw() returns (uint256 b, uint256 bought) {
            ok_withdraw++;
            burned += b;
            if (bought != 0) ok_buffer++;
        } catch {}
    }

    // ------------------------------------------------------------ fee notes (series 1)

    function buyNote(uint256 u, uint256 face) external {
        calls++;
        address user = _user(u);
        face = bound(face, 1e18, 100_000e18);
        vm.startPrank(user);
        usdc.approve(address(notes), type(uint256).max);
        try notes.buy(1, face) {
            ok_note++;
        } catch {}
        vm.stopPrank();
    }

    function redeemNote(uint256 u) external {
        calls++;
        address user = _user(u);
        uint256 bal = notes.balanceOf(user, 1);
        if (bal == 0) return;
        vm.prank(user);
        try notes.redeem(1, bal) {
            ok_redeemNote++;
        } catch {}
    }
}

contract InvariantsTest is PegSystem {
    bytes32 constant ETH = "ETH";
    bytes32 constant SUSDC = "S-USDC";
    uint256 constant KEEPER_CAP = 500_000e18;

    Handler handler;
    MockERC20 weth;
    MockERC20 usdcMock;
    MockERC20 v1;
    MockVault vault;
    Join ethJoin;
    Join vaultJoin;
    SavingsVault savings;
    FeeNotes notes;
    address[] users;

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockERC20("WETH", 18);
        usdcMock = new MockERC20("USDC", 6);
        v1 = new MockERC20("v1", 18);
        vault = new MockVault(IERC20(address(usdcMock)));
        MockFeed ethFeed = new MockFeed(2000e18);
        MockFeed usdcFeed = new MockFeed(1e30);
        usdcMock.mint(address(this), 1e6);
        usdcMock.approve(address(vault), 1e6);
        vault.deposit(1e6, address(0xbeef));
        RateFeed vr = new RateFeed(address(vault), bytes4(keccak256("convertToAssets(uint256)")), true, usdcFeed, uint256(0.01e18) / 1 days);

        pm = IPoolManager(address(new PoolManager(address(this))));
        usdc = IERC20(address(usdcMock));
        _deploySystem(IERC20(address(v1)));
        ParametersBase.Risk memory er = _risk(1.4e18, 2_000_000e18);
        ethJoin = _addIlk(ETH, address(weth), ethFeed, ethFeed, IFeed(address(0)), address(0), address(0), true, er);
        ParametersBase.Risk memory sr = _risk(1.08e18, 5_000_000e18);
        sr.chop = 0.05e18;
        sr.yieldFee = 0.1e18;
        vaultJoin = _addIlk(SUSDC, address(vault), IFeed(address(vr)), IFeed(address(vr)), IFeed(address(0)), address(vr), address(0), true, sr);
        params.setGenesisMigratorLine(50_000e18);
        savings = new SavingsVault(IERC20(address(usd)));
        params.setGenesisSavings(address(savings), 0.5e18);
        notes = new FeeNotes(IERC20(address(usd)), usdc, ITreasuryNotes(address(treasury)), address(params));
        treasury.wireNotes(address(notes));
        params.setGenesisNotes(address(notes));
        params.seal();
        // The peg pool: hook mined, keeper minter + cap through the timelock, pool open at $1.
        _openPeg(KEEPER_CAP);
        _setBufferTarget(5_000e6); // keeper profit kept as the below-peg buyer
        // One note series, through the timelock: 30 days, 3% off, no practical size cap.
        bytes memory open = abi.encode(params.OPEN_NOTE_SERIES(), uint64(30 days), uint32(300), type(uint128).max);
        vm.prank(governor);
        params.propose(open);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        params.applyPending();
        ethFeed.set(ethFeed.value());
        usdcFeed.set(usdcFeed.value());

        for (uint256 i; i < 5; ++i) {
            address u = makeAddr(string(abi.encodePacked("user", i)));
            users.push(u);
            weth.mint(u, 10_000e18);
            usdcMock.mint(u, 10_000_000e6);
            v1.mint(u, 100_000e18);
            vm.startPrank(u);
            weth.approve(address(ledger), type(uint256).max);
            usdcMock.approve(address(ledger), type(uint256).max);
            v1.approve(address(migrator), type(uint256).max);
            vm.stopPrank();
        }
        // users[0] is the pool's LP: borrows real imdUSD against the stable vault (so the supply equation
        // holds: no dealt imdUSD anywhere) and seeds ~1M of each side over ±10% around the peg.
        address lp = users[0];
        (uint256 p, uint256 n) = sorted.findInsertPosition(SUSDC, 0.05e18);
        vm.startPrank(lp);
        ledger.open(SUSDC, 0, Adjust(int256(2_500_000e6), int256(1_500_000e18), 0.05e18, p, n, true, type(uint256).max, address(0)));
        usd.transfer(address(router), 1_200_000e18);
        vm.stopPrank();
        usdcMock.mint(address(router), 1_200_000e6);
        int24 t = hook.pegTick();
        router.addLiquidity(key, ModifyLiquidityParams(t - 1000, t + 1000, 2e19, 0));

        handler = new Handler(ledger, redeemer, liquidator, migrator, ethFeed, usdcFeed, vault, v1, users);
        handler.setSavings(savings);
        handler.setPeg(hook, router, key, usdcMock, notes);
        handler.hold(31 minutes); // a TWAP history at the peg
        targetContract(address(handler));
    }

    /// supply == Σ type debt + Σ bad debt + reserve-backed + migrated + peg keeper outstanding + bridged in − out
    function invariant_supplyEquation() public {
        ledger.accrue(ETH);
        ledger.accrue(SUSDC);
        (uint128 d1,,,, uint128 b1) = ledger.ilkState(ETH);
        (uint128 d2,,,, uint128 b2) = ledger.ilkState(SUSDC);
        assertEq(
            int256(usd.totalSupply()),
            int256(uint256(d1) + b1 + d2 + b2 + ledger.reserveBacked() + migrator.outstanding() + _keeperOutstanding())
                + _bridgeNet(),
            "supply"
        );
    }

    /// The type's recorded debt is never below the sum of its positions' debts.
    function invariant_typeDebtCoversPositions() public {
        _checkIlkDebt(ETH);
        _checkIlkDebt(SUSDC);
    }

    function _checkIlkDebt(bytes32 ilk) internal {
        ledger.accrue(ilk);
        (uint128 d,,,,) = ledger.ilkState(ilk);
        uint256 sum;
        for (uint256 i; i < users.length; ++i) sum += ledger.debtOf(_pid(ilk, users[i]));
        assertGe(uint256(d), sum, "type debt >= positions");
        // and only by rounding: at most one wei per position per touch is plenty of slack here
        assertLe(uint256(d) - sum, 1e12, "drift");
    }

    /// Custody matches accounting: every collateral unit the ledger records is in its join.
    function invariant_custody() public view {
        (, uint128 c1,,,) = ledger.ilkState(ETH);
        (, uint128 c2,,,) = ledger.ilkState(SUSDC);
        assertEq(weth.balanceOf(address(ethJoin)), c1, "eth custody");
        assertEq(vault.balanceOf(address(vaultJoin)), c2, "vault custody");
        uint256 s1;
        uint256 s2;
        for (uint256 i; i < users.length; ++i) {
            s1 += ledger.position(_pid(ETH, users[i])).collateral;
            s2 += ledger.position(_pid(SUSDC, users[i])).collateral;
        }
        assertEq(s1, c1, "eth positions");
        assertEq(s2, c2, "vault positions");
    }

    /// The redemption list holds exactly the positions with debt, in ascending rate order.
    function invariant_sortedList() public view {
        _checkList(ETH);
        _checkList(SUSDC);
    }

    function _checkList(bytes32 ilk) internal view {
        uint256 withDebt;
        for (uint256 i; i < users.length; ++i) {
            bool has = ledger.position(_pid(ilk, users[i])).debt != 0;
            if (has) withDebt++;
            assertEq(sorted.contains(ilk, _pid(ilk, users[i])), has, "listed iff in debt");
        }
        assertEq(sorted.size(ilk), withDebt, "size");
        uint256 cur = sorted.first(ilk);
        uint64 last;
        while (cur != 0) {
            uint64 r = ledger.position(cur).rate;
            assertGe(r, last, "ascending");
            last = r;
            cur = sorted.next(ilk, cur);
        }
    }

    /// sImdUSD can always pay every saver: its imdUSD covers what it accounts for, which covers what its
    /// shares are worth. (Interest it receives is in the supply equation already, as type debt.)
    function invariant_savingsSolvent() public view {
        uint256 bal = usd.balanceOf(address(savings));
        assertGe(bal, savings.tracked(), "balance >= tracked");
        assertGe(savings.tracked(), savings.totalAssets(), "tracked >= counted");
        uint256 owed;
        for (uint256 i; i < users.length; ++i) owed += savings.previewRedeem(savings.balanceOf(users[i]));
        assertLe(owed, savings.totalAssets(), "shares <= counted");
    }

    /// The peg keeper's USDC always covers its outstanding imdUSD at $1 plus the buffer, and it never holds
    /// more imdUSD outstanding than the cap.
    function invariant_keeperSolvent() public view {
        assertGe(usdc.balanceOf(address(hook)), hook.principal() + hook.buffer(), "keeper USDC >= principal + buffer");
        assertLe(hook.outstanding(), KEEPER_CAP, "cap");
        assertLe(hook.buffer(), params.bufferTarget(), "the buffer never exceeds its target");
        assertEq(hook.outstanding(), handler.minted() - handler.burned(), "outstanding == minted - burned");
    }

    /// Every note sold and not redeemed is held by its buyer: outstanding face == Σ holders' balances.
    function invariant_notesAccounted() public view {
        uint256 held;
        for (uint256 i; i < users.length; ++i) held += notes.balanceOf(users[i], 1);
        assertEq(notes.outstanding(), held, "notes outstanding == held");
    }

    /// Not hollow: driven with ordinary inputs, every money-moving action in the handler succeeds, including
    /// both keeper legs with positions present (so the supply equation is checked with a non-zero keeper term)
    /// and a note bought under the revenue cap and redeemed at maturity.
    /// (The fuzzer swallows reverts, so without this a handler that always reverts would pass.)
    function test_handlerActionsSucceed() public {
        for (uint256 k; k < 5; ++k) {
            handler.open(k, 0, 10e18, 8_000e18, 0.02e18 + k * 0.01e18);
            handler.open(k, 1, 20_000e6, 9_000e18, 0.02e18 + k * 0.01e18);
        }
        handler.setRate(1, 0, 0.2e18);
        handler.vaultYield(1_500e6);
        handler.passTime(3 days);
        handler.harvest(0);
        handler.redeem(4, 0, 2_000e18);
        handler.redeem(4, 1, 2_000e18);
        handler.liquidate(0, 2, 900e18);
        handler.save(1, 1_000e18);
        handler.save(2, 2_000e18);
        handler.passTime(1 days);
        handler.donate(3, 500e18);
        handler.passTime(1 days);
        handler.unsave(1, type(uint256).max);
        assertEq(handler.ok_save(), 2, "save");
        assertEq(handler.ok_unsave(), 1, "unsave");
        assertGt(usd.balanceOf(address(savings)), 2_000e18, "savers received interest");
        assertEq(handler.ok_open(), 10, "opens");
        assertEq(handler.ok_rate(), 1, "rate");
        assertEq(handler.ok_harvest(), 1, "harvest");
        assertEq(handler.ok_redeem(), 2, "redeem");
        assertEq(handler.ok_liquidate(), 1, "liquidate");

        // A note, inside the series' sale window, under the cap the metered interest allows.
        handler.accrue(0);
        handler.accrue(1);
        assertGt(treasury.trailingRevenue(), 0, "revenue metered");
        handler.buyNote(2, 20e18);
        assertEq(handler.ok_note(), 1, "note bought");
        assertEq(notes.outstanding(), 20e18);

        // The peg: the market pushes imdUSD to ~+0.6%, holds it half an hour, and a keeper call sells minted
        // imdUSD back to the peg; then a user dumps imdUSD to ~−0.6%, and the keeper buys back and burns.
        handler.tradeUp(60_000e6);
        assertGt(hook.spotTicks(), hook.TRIGGER_TICKS(), "pushed above the trigger");
        handler.hold(31 minutes);
        handler.keeperProvide();
        assertEq(handler.ok_provide(), 1, "provide");
        assertGt(_keeperOutstanding(), 0, "keeper term non-zero");
        invariant_supplyEquation(); // positions + savings + keeper outstanding together
        invariant_keeperSolvent();
        handler.tradeDown(0, 65_000e18);
        assertLt(hook.spotTicks(), -hook.TRIGGER_TICKS(), "pushed below the trigger");
        handler.hold(31 minutes);
        handler.keeperWithdraw();
        assertEq(handler.ok_withdraw(), 1, "withdraw");
        assertEq(handler.ok_trade(), 2, "trades");
        assertGt(handler.burned(), 0);
        assertLe(handler.burned(), handler.minted());

        // The note matures; interest settled since funds the Treasury; the holder is paid.
        handler.passTime(10 days);
        handler.passTime(10 days);
        handler.passTime(10 days);
        handler.passTime(8 days);
        handler.accrue(0);
        handler.accrue(1);
        handler.redeemNote(2);
        assertEq(handler.ok_redeemNote(), 1, "note redeemed");
        assertEq(notes.outstanding(), 0);

        invariant_supplyEquation();
        invariant_typeDebtCoversPositions();
        invariant_custody();
        invariant_sortedList();
        invariant_savingsSolvent();
        invariant_keeperSolvent();
        invariant_notesAccounted();
    }
}
