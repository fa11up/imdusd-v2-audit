// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";
import {Allocator, ISwapRoute, IBackstopSale, IBackstopPriceAlloc} from "../../src/peg/Allocator.sol";
import {GovernedByKind as Governed} from "../../src/GovernedByKind.sol";

contract MockVault4626 is ERC4626 {
    constructor(IERC20 a) ERC20("vault", "v") ERC4626(a) {}
}

/// @dev PegHook's buffer surface: pulls the quote stablecoin on fundBuffer.
contract MockPegBuffer {
    address public quote;
    uint256 public buffer;
    uint256 public target = 1_000_000e6;

    function setTarget(uint256 t) external {
        target = t;
    }

    function bufferRoom() external view returns (uint256) {
        return target > buffer ? target - buffer : 0;
    }

    constructor(address q) {
        quote = q;
    }

    function fundBuffer(uint256 amount) external {
        IERC20(quote).transferFrom(msg.sender, address(this), amount);
        buffer += amount;
    }
}

/// @dev PegLPVault's surface: proportional deposit of both tokens at 1 share = 1 of each (scaled), withdraw pays back.
contract MockLPVault is ERC20 {
    IERC20 public token0;
    IERC20 public token1;

    int24 public spotTicks;
    int24 public twapTicks;

    constructor(IERC20 t0, IERC20 t1) ERC20("lp", "lp") {
        (token0, token1) = (t0, t1);
    }

    /// @dev The vault's hook view (spot and 30-minute TWAP ticks): the mock is its own hook.
    function hook() external view returns (address) {
        return address(this);
    }

    function setTicks(int24 spot, int24 twap) external {
        (spotTicks, twapTicks) = (spot, twap);
    }

    function previewDeposit(uint256 shares) external view returns (uint256, uint256) {
        if (totalSupply() == 0) return (0, 0);
        return (shares, shares / 1e12);
    }

    function deposit(uint256 shares, uint256 max0, uint256 max1, address to) external returns (uint256, uint256, uint256) {
        uint256 a0 = shares;
        uint256 a1 = shares / 1e12;
        require(a0 <= max0 && a1 <= max1, "max");
        token0.transferFrom(msg.sender, address(this), a0);
        token1.transferFrom(msg.sender, address(this), a1);
        _mint(to, shares);
        return (shares, a0, a1);
    }

    function withdraw(uint256 shares, uint256, uint256, address to) external returns (uint256 a0, uint256 a1) {
        _burn(msg.sender, shares);
        a0 = shares;
        a1 = shares / 1e12;
        token0.transfer(to, a0);
        token1.transfer(to, a1);
    }
}

/// @dev A route paying `rateBps` of fair value (feeds are $1 for both tokens here, so fair = scaled amount).
/// Modes: 0 honest, 1 pays to `thief` instead, 2 tries to pull amountIn+1, 3 pays the given minOut minus 1.
contract MockRoute is ISwapRoute {
    uint256 public rateBps = 10_000;
    uint8 public mode;
    address public thief;

    function set(uint256 r, uint8 m, address t) external {
        (rateBps, mode, thief) = (r, m, t);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        uint256 pull = mode == 2 ? amountIn + 1 : amountIn;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), pull);
        uint8 dIn = ERC20(tokenIn).decimals();
        uint8 dOut = ERC20(tokenOut).decimals();
        out = Math.mulDiv(amountIn, 10 ** dOut, 10 ** dIn) * rateBps / 10_000;
        if (mode == 3) out = minOut - 1;
        MockERC20(tokenOut).mint(mode == 1 ? thief : recipient, out);
    }
}

/// @dev The Backstop's price source: (low, high, ok) per token, USD per 1e18 raw.
contract MockBackstopOracle is IBackstopPriceAlloc {
    mapping(address => uint256) public low;
    mapping(address => uint256) public high;
    mapping(address => bool) public bad;
    mapping(address => uint256) public payoutOf;

    function set(address t, uint256 l, uint256 h, bool isBad) external {
        (low[t], high[t], bad[t]) = (l, h, isBad);
    }

    function setPayout(address t, uint256 p) external {
        payoutOf[t] = p;
    }

    function priceOf(address t) external view returns (uint256, uint256, bool) {
        return (low[t], high[t], !bad[t] && low[t] != 0);
    }
}

contract MockBackstop is IBackstopSale {
    address public allocator;
    IERC20 public imdUSD;
    MockBackstopOracle public prices = new MockBackstopOracle();
    uint256 public sold;
    uint256 public proceedsBooked;

    function setAllocator(address a) external {
        allocator = a;
    }

    function oracle() external view returns (IBackstopPriceAlloc) {
        return prices;
    }

    /// @dev Backstop.coll: what the sleeve holds of `t` (the mock holds its collateral as a plain balance).
    function coll(address t) external view returns (uint256) {
        return IERC20(t).balanceOf(address(this));
    }

    function setImdUSD(IERC20 t) external {
        imdUSD = t;
    }

    /// @dev Backstop.sell's shape: hand the collateral to the seller, call it back, measure the imdUSD that came in.
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata data) external returns (uint256 got) {
        require(msg.sender == allocator, "only allocator");
        uint256 before = imdUSD.balanceOf(address(this));
        IERC20(token).transfer(msg.sender, amount);
        Allocator(msg.sender).onBackstopSell(token, amount, data);
        got = imdUSD.balanceOf(address(this)) - before;
        require(got >= minOut, "short");
        (uint256 low,,) = prices.priceOf(token);
        require(got >= amount * low / 1e18 * 9_800 / 10_000, "floor"); // Backstop.MAX_SALE_SLIPPAGE_BPS
        sold += amount;
        proceedsBooked += got;
    }
}

contract AllocatorTest is Test {
    Allocator al;
    MockERC20 usdc;
    MockERC20 usd; // imdUSD stand-in (18 dec)
    MockERC20 weth;
    MockVault4626 vault;
    MockPegBuffer hook;
    MockLPVault lp;
    MockRoute route;
    MockBackstop backstop;
    MockFeed fUsdc;
    MockFeed fUsd;
    MockFeed fWeth;
    address governor = makeAddr("governor");
    address treasury = makeAddr("treasury");
    address freezer = makeAddr("freezer");
    address keeper = makeAddr("keeper");
    address eve = makeAddr("eve");
    bytes32 VD;
    bytes32 SW;
    uint8 K_LIMIT;
    uint8 K_SLIP;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usdc = new MockERC20("USDC", 6);
        usd = new MockERC20("imdUSD", 18);
        weth = new MockERC20("WETH", 18);
        vault = new MockVault4626(IERC20(address(usdc)));
        hook = new MockPegBuffer(address(usdc));
        lp = new MockLPVault(IERC20(address(usd)), IERC20(address(usdc)));
        route = new MockRoute();
        backstop = new MockBackstop();
        fUsdc = new MockFeed(1e30); // $1 per 1e6 raw
        fUsd = new MockFeed(1e18);
        fWeth = new MockFeed(2000e18);
        al = new Allocator(governor, treasury, freezer, 100); // 1% max slippage
        backstop.setAllocator(address(al));
        backstop.setImdUSD(IERC20(address(usd)));
        backstop.prices().set(address(weth), 2000e18, 0, false);
        (VD, SW, K_LIMIT, K_SLIP) = (al.VAULT_DEPOSIT(), al.SWAP(), al.SET_LIMIT(), al.SET_SLIPPAGE());

        _gov(abi.encode(al.ADD_KEEPER(), keeper));
        _allow(al.VAULT_DEPOSIT(), address(vault), 1_000e6, 1e6); // 1,000 USDC, refills 1 USDC/s
        _allow(al.VAULT_REDEEM(), address(vault), 1_000e6, 1e6);
        _allow(al.BUFFER_FUND(), address(hook), 500e6, 1e5);
        _allow(al.LP_DEPOSIT(), address(lp), 1_000e18, 1e18);
        _allow(al.LP_WITHDRAW(), address(lp), 1_000e18, 1e18);
        _allow(al.SWAP(), address(route), 1_000e18, 1e18); // USD: $1,000, refills $1/s
        _allow(al.BACKSTOP_SALE(), address(backstop), 20_000e18, 2e18); // USD: 10 WETH at $2,000
        _allow(al.TO_TREASURY(), address(usdc), 100e6, 1e4);
        _gov(abi.encode(al.SET_FEED(), address(usdc), address(fUsdc)));
        _gov(abi.encode(al.SET_FEED(), address(usd), address(fUsd)));
        _gov(abi.encode(al.SET_FEED(), address(weth), address(fWeth)));

        usdc.mint(address(al), 100_000e6);
        usd.mint(address(al), 100_000e18);
        weth.mint(address(backstop), 100e18);
        fUsdc.setMaxAge(365 days);
        fUsd.setMaxAge(365 days);
        fWeth.setMaxAge(365 days);
    }

    function _gov(bytes memory payload) internal {
        vm.prank(governor);
        al.propose(payload);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        al.applyPending();
    }

    function _allow(bytes32 action, address target, uint128 max, uint128 slope) internal {
        _gov(abi.encode(al.ADD_TARGET(), action, target));
        _gov(abi.encode(al.SET_LIMIT(), action, target, max, slope));
    }

    // ---------------------------------------------------------------- buckets

    function test_bucketCapsAndRefills() public {
        vm.prank(keeper);
        al.vaultDeposit(address(vault), 600e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.RateLimited.selector, VD, address(vault), 600e6, 400e6));
        al.vaultDeposit(address(vault), 600e6);
        vm.warp(vm.getBlockTimestamp() + 200); // +200 USDC
        assertEq(al.available(al.VAULT_DEPOSIT(), address(vault)), 600e6);
        vm.warp(vm.getBlockTimestamp() + 1 days); // capped at max
        assertEq(al.available(al.VAULT_DEPOSIT(), address(vault)), 1_000e6);
        assertEq(vault.balanceOf(address(al)), vault.convertToShares(600e6));
        assertEq(usdc.allowance(address(al), address(vault)), 0, "no standing allowance");
    }

    function test_redeemReturnsHere() public {
        vm.prank(keeper);
        uint256 sh = al.vaultDeposit(address(vault), 500e6);
        uint256 before = usdc.balanceOf(address(al));
        vm.prank(keeper);
        al.vaultRedeem(address(vault), sh);
        assertEq(usdc.balanceOf(address(al)) - before, 500e6);
    }

    function test_fundBufferAndLp() public {
        vm.prank(keeper);
        al.fundBuffer(address(hook), 300e6);
        assertEq(hook.buffer(), 300e6);
        vm.prank(keeper);
        al.lpDeposit(address(lp), 500e18, 500e18, 500e6);
        assertEq(lp.balanceOf(address(al)), 500e18);
        vm.prank(keeper);
        al.lpWithdraw(address(lp), 200e18, 0, 0);
        assertEq(lp.balanceOf(address(al)), 300e18);
        assertEq(usd.allowance(address(al), address(lp)), 0);
    }

    function test_unknownTargetRefused() public {
        MockVault4626 other = new MockVault4626(IERC20(address(usdc)));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.NotAllowed.selector, VD, address(other)));
        al.vaultDeposit(address(other), 1e6);
    }

    function test_onlyKeeper() public {
        vm.prank(eve);
        vm.expectRevert(Allocator.NotKeeper.selector);
        al.vaultDeposit(address(vault), 1e6);
        vm.prank(eve);
        vm.expectRevert(Allocator.NotKeeper.selector);
        al.returnToTreasury(address(usdc), 1e6);
    }

    // ---------------------------------------------------------------- freezer

    function test_freezerStopsEverything() public {
        vm.prank(freezer);
        al.freeze();
        vm.startPrank(keeper);
        vm.expectRevert(Allocator.Frozen.selector);
        al.vaultDeposit(address(vault), 1e6);
        vm.expectRevert(Allocator.Frozen.selector);
        al.swap(address(route), address(usdc), address(usd), 1e6, 0);
        vm.expectRevert(Allocator.Frozen.selector);
        al.returnToTreasury(address(usdc), 1e6);
        vm.stopPrank();
        vm.prank(freezer);
        vm.expectRevert(Governed.NotGovernor.selector);
        al.unfreeze();
        vm.prank(governor);
        al.unfreeze();
        vm.prank(keeper);
        al.vaultDeposit(address(vault), 1e6);
    }

    function test_freezerRemovesKeeperOnly() public {
        vm.prank(freezer);
        al.removeKeeper(keeper);
        assertFalse(al.isKeeper(keeper));
        vm.prank(freezer);
        vm.expectRevert(Governed.NotGovernor.selector);
        al.lowerLimit(SW, address(route), 0, 0);
        vm.prank(eve);
        vm.expectRevert(Allocator.NotFreezer.selector);
        al.freeze();
    }

    // ---------------------------------------------------------------- governance bounds

    function test_lowerInstantRaiseTimelocked() public {
        vm.startPrank(governor);
        al.lowerLimit(SW, address(route), 100e6, 1e5);
        vm.expectRevert(Allocator.BadPayload.selector);
        al.lowerLimit(SW, address(route), 200e6, 1e5); // a raise is not a lower
        bytes memory raise = abi.encode(K_LIMIT, SW, address(route), uint128(2_000e6), uint128(1e6));
        al.propose(raise);
        vm.stopPrank();
        assertEq(al.available(SW, address(route)), 100e6);
        vm.expectRevert();
        al.applyPending();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        al.applyPending();
        (uint128 max,,,) = al.limits(al.key(al.SWAP(), address(route)));
        assertEq(max, 2_000e6);
    }

    function test_removeTargetInstant() public {
        vm.prank(governor);
        al.removeTarget(SW, address(route));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.NotAllowed.selector, SW, address(route)));
        al.swap(address(route), address(usdc), address(usd), 1e6, 0);
    }

    function test_slippageBound() public {
        assertEq(al.oracleMinOut(address(usdc), address(usd), 100e6), 99e18);
        vm.prank(governor);
        vm.expectRevert(Allocator.BadPayload.selector);
        al.propose(abi.encode(K_SLIP, uint16(600)));
        vm.prank(governor);
        al.lowerSlippage(50);
        assertEq(al.oracleMinOut(address(usdc), address(usd), 100e6), 99.5e18);
    }

    // ---------------------------------------------------------------- swaps and sales

    function test_swapHonest() public {
        vm.prank(keeper);
        uint256 got = al.swap(address(route), address(usdc), address(usd), 100e6, 0);
        assertEq(got, 100e18);
        assertEq(usdc.allowance(address(al), address(route)), 0);
    }

    /// A route paying below the oracle bound reverts even when the keeper asks for less.
    function test_swapBelowOracleBoundReverts() public {
        route.set(9_800, 0, address(0)); // pays 98% of fair, bound is 99%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.Slippage.selector, 98e18, 99e18));
        al.swap(address(route), address(usdc), address(usd), 100e6, 0);
    }

    function test_swapToSomeoneElseReverts() public {
        route.set(10_000, 1, eve);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.Slippage.selector, 0, 99e18));
        al.swap(address(route), address(usdc), address(usd), 100e6, 0);
        assertEq(usd.balanceOf(eve), 0);
    }

    function test_routeCannotPullMoreThanAmountIn() public {
        route.set(10_000, 2, address(0));
        vm.prank(keeper);
        vm.expectRevert();
        al.swap(address(route), address(usdc), address(usd), 100e6, 0);
    }

    function test_staleFeedBlocksSwap() public {
        fUsd.setStale(true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.StaleFeed.selector, address(usd)));
        al.swap(address(route), address(usdc), address(usd), 100e6, 0);
    }

    function test_backstopSaleProceedsGoToBackstop() public {
        route.set(2_000 * 10_000, 0, address(0)); // pays $2,000 per WETH, the feed price
        vm.prank(keeper);
        uint256 proceeds = al.sellForBackstop(address(backstop), address(route), address(weth), 1e18, 0);
        assertEq(proceeds, 2_000e18);
        assertEq(usd.balanceOf(address(backstop)), 2_000e18, "proceeds land in the backstop");
        assertEq(backstop.sold(), 1e18);
        assertEq(backstop.proceedsBooked(), 2_000e18);
        assertEq(weth.balanceOf(address(al)), 0, "nothing left here");
    }

    function test_backstopSaleBelowBoundReverts() public {
        route.set(1_900 * 10_000, 0, address(0)); // 5% under the feed, bound is 1%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Allocator.Slippage.selector, 1_900e18, 1_980e18));
        al.sellForBackstop(address(backstop), address(route), address(weth), 1e18, 0);
    }

    function test_backstopCallbackOutsideASaleRefused() public {
        vm.expectRevert(abi.encodeWithSelector(Allocator.NotAllowed.selector, al.BACKSTOP_SALE(), address(this)));
        al.onBackstopSell(address(weth), 1e18, abi.encode(address(route), uint256(0)));
    }

    function test_returnToTreasuryOnlyThere() public {
        vm.prank(keeper);
        al.returnToTreasury(address(usdc), 50e6);
        assertEq(usdc.balanceOf(treasury), 50e6);
        vm.prank(governor);
        al.returnToTreasury(address(usd), 1_000e18); // governor: no bucket
        assertEq(usd.balanceOf(treasury), 1_000e18);
    }

    // ---------------------------------------------------------------- no path to an outside recipient

    /// Any call any keeper can make, with any arguments: no address other than the protocol's ends up holding more.
    function testFuzz_noExternalRecipient(uint8 which, address target, uint256 amount, uint256 min) public {
        vm.assume(target != address(al) && target != address(vault) && target != address(hook));
        amount = bound(amount, 0, 2_000e18);
        uint256 e0 = usdc.balanceOf(eve) + usd.balanceOf(eve) + weth.balanceOf(eve) + vault.balanceOf(eve)
            + lp.balanceOf(eve);
        uint256 t0 = usdc.balanceOf(target) + usd.balanceOf(target) + weth.balanceOf(target);
        vm.startPrank(keeper);
        which = which % 8;
        if (which == 0) try al.vaultDeposit(target, amount) {} catch {}
        else if (which == 1) try al.vaultRedeem(target, amount) {} catch {}
        else if (which == 2) try al.fundBuffer(target, amount) {} catch {}
        else if (which == 3) try al.lpDeposit(target, amount, amount, amount) {} catch {}
        else if (which == 4) try al.lpWithdraw(target, amount, min, min) {} catch {}
        else if (which == 5) try al.swap(target, address(usdc), address(usd), amount, min) {} catch {}
        else if (which == 6) try al.sellForBackstop(target, address(route), address(weth), amount, min) {} catch {}
        else try al.returnToTreasury(target, amount) {} catch {}
        vm.stopPrank();
        assertEq(
            usdc.balanceOf(eve) + usd.balanceOf(eve) + weth.balanceOf(eve) + vault.balanceOf(eve) + lp.balanceOf(eve), e0
        );
        if (target != treasury && target != address(route) && target != address(backstop) && target != address(lp)) {
            assertEq(usdc.balanceOf(target) + usd.balanceOf(target) + weth.balanceOf(target), t0, "unlisted target paid");
        }
    }
}
