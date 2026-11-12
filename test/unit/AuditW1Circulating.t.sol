// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
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

contract CiTok is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract CiFeed is IFeed {
    uint256 public value;
    uint64 public at;
    constructor(uint256 v) { value = v; at = uint64(block.timestamp); }
    function latestValue() external view returns (uint256, uint64) { return (value, at); }
    function isStale() external pure returns (bool) { return false; }
    function maxAge() external pure returns (uint256) { return 1 hours; }
}

/// @dev Stands in for a minter (the Ledger slot) so ImdUSD's burn path can be driven directly.
contract CiMinter {
    function burn(ImdUSD usd, address from, uint256 a) external { usd.burn(from, a); }
    function mint(ImdUSD usd, address to, uint256 a) external { usd.mint(to, a); }
}

/// @dev Inside a loan: the minter burns `burnAmt` of the loan, `circulating()` is recorded, the minter mints it back, and
/// an optional inner loan nests the same.
contract CiReceiver is IERC3156FlashBorrower {
    ImdUSD immutable usd;
    CiMinter immutable minter;
    uint256 public seen;
    uint256 public seenInner;
    constructor(ImdUSD u, CiMinter m) { usd = u; minter = m; }

    function run(uint256 outer, uint256 inner, uint256 burnAmt) external {
        usd.flashLoan(this, address(usd), outer, abi.encode(inner, burnAmt, true));
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata data) external returns (bytes32) {
        (uint256 inner, uint256 burnAmt, bool top) = abi.decode(data, (uint256, uint256, bool));
        if (top && inner != 0) {
            usd.flashLoan(this, address(usd), inner, abi.encode(uint256(0), burnAmt, false));
            seen = usd.circulating();
        } else {
            minter.burn(usd, address(this), burnAmt);
            if (top) seen = usd.circulating();
            else seenInner = usd.circulating();
            minter.mint(usd, address(this), burnAmt);
        }
        usd.approve(address(usd), amount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev The panel-2 attack shape: flash-borrow the debt, repay it on the Ledger, read circulating(), re-borrow, return.
contract CiBorrower is IERC3156FlashBorrower {
    ImdUSD immutable usd;
    Ledger immutable ledger;
    uint256 public id;
    uint256 public seen;
    constructor(ImdUSD u, Ledger l) { usd = u; ledger = l; }

    function openPosition(bytes32 ilk, uint256 coll, uint256 debt, IERC20 tok) external {
        tok.approve(address(ledger), type(uint256).max);
        usd.approve(address(ledger), type(uint256).max);
        id = ledger.open(ilk, 0, Adjust(int256(coll), int256(debt), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
    }

    function run(uint256 amount) external {
        usd.flashLoan(this, address(usd), amount, "");
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata) external returns (bytes32) {
        ledger.adjust(id, Adjust(0, -int256(amount), 0, 0, 0, false, type(uint256).max, address(0)));
        seen = usd.circulating();
        ledger.adjust(id, Adjust(0, int256(amount), 0, 0, 0, false, type(uint256).max, address(0)));
        usd.approve(address(usd), amount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 2): a minter burn inside a flash loan retires
/// flash-minted imdUSD first, so `circulating()` never under-reads the real supply.
contract AuditW1CirculatingTest is Test {
    ImdUSD usd;
    CiMinter minter;
    CiReceiver recv;

    function setUp() public {
        usd = new ImdUSD(address(this), 100_000e18);
        minter = new CiMinter();
        usd.wire(address(minter), address(new CiMinter()), address(new CiMinter()));
        minter.mint(usd, address(this), 1_000_000e18);
        recv = new CiReceiver(usd, minter);
    }

    function test_burnInsideALoanKeepsCirculatingAtTheRealSupply() public {
        recv.run(90_000e18, 0, 90_000e18);
        assertEq(recv.seen(), 1_000_000e18, "circulating() = the supply before the transaction");
        assertEq(usd.flashOutstanding(), 0);
        assertEq(usd.totalSupply(), 1_000_000e18);
    }

    function test_partialBurnInsideALoan() public {
        recv.run(90_000e18, 0, 30_000e18);
        assertEq(recv.seen(), 1_000_000e18);
    }

    function test_nestedLoansUnwind() public {
        // No burn: inner sees the supply less both loans = the real supply; the outer sees it after the inner returns.
        recv.run(60_000e18, 40_000e18, 0);
        assertEq(recv.seenInner(), 1_000_000e18);
        assertEq(recv.seen(), 1_000_000e18);
        // A burn inside the inner loan larger than the inner loan, then the same amount minted back (repay + re-borrow):
        // neither the burn deflates it nor the re-mint dilutes it.
        recv.run(60_000e18, 40_000e18, 70_000e18);
        assertEq(recv.seenInner(), 1_000_000e18);
        assertEq(recv.seen(), 1_000_000e18);
        assertEq(usd.flashOutstanding(), 0);
        assertEq(usd.circulating(), usd.totalSupply());
    }

    function test_capStillBindsAtAnyMoment() public {
        vm.expectRevert(abi.encodeWithSignature("ERC3156ExceededMaxLoan(uint256)", uint256(40_000e18)));
        recv.run(60_000e18, 40_001e18, 0);
    }

    /// End to end on the Ledger: the borrower repays its debt with a flash loan; circulating() inside is the real supply.
    function test_ledgerRepayInsideALoanDoesNotDeflateCirculating() public {
        vm.warp(1_800_000_000);
        ImdUSD u = new ImdUSD(address(this), 100_000e18);
        Parameters params = new Parameters(makeAddr("gov"), address(this));
        Pricer pricer = new Pricer(params);
        Treasury treasury = new Treasury(makeAddr("gov"), IERC20(address(u)), address(this));
        PositionNFT nft = new PositionNFT(address(this));
        Ledger ledger = new Ledger(u, params, pricer, address(treasury), address(this), IPulse(address(0)), nft);
        nft.bind(address(ledger));
        ledger.wire(address(new Redeemer(ledger)), address(new Liquidator(ledger, pricer)));
        u.wire(address(ledger), address(new Migrator(IERC20(address(new CiTok())), u, params)), address(params));
        params.wire(address(ledger), address(u));
        treasury.wire(ICoverable(address(ledger)));
        CiTok weth = new CiTok();
        Join join = new Join(address(weth), address(this));
        join.wire(address(ledger));
        CiFeed feed = new CiFeed(2000e18);
        params.addGenesisIlk(
            "ETH",
            ParametersBase.Config({
                token: address(weth), join: address(join), median: feed, spot: feed, nhi: IFeed(address(0)),
                yieldRate: address(0), pegAggregator: address(0), liveSpot: IFeed(address(0)), redeemable: true,
                auction: false
            }),
            ParametersBase.Risk({
                mat: 1.5e18, chop: 0.1e18, cut: 0.5e18, chip: 0.1e18, rateFloor: 0.01e18, yieldFee: 0, skew: 0.05e18,
                pegFloor: 0, line: 1_000_000e18, dust: 100e18, redeemFloor: 0.005e18, redeemDivisor: 16, redeemCap: 0
            })
        );
        params.seal();

        CiBorrower b = new CiBorrower(u, ledger);
        weth.mint(address(b), 100e18);
        b.openPosition("ETH", 100e18, 90_000e18, IERC20(address(weth)));
        deal(address(u), address(b), u.balanceOf(address(b)) + 1_000e18); // covers the re-borrow's upfront fee
        uint256 supply = u.totalSupply();

        b.run(80_000e18);
        // Before the fix it read supply - 80,000 (the repay burned flash-minted tokens the counter still held).
        assertApproxEqAbs(b.seen(), supply, 1e18, "circulating() inside the loan is the real supply");
        assertEq(u.flashOutstanding(), 0);
    }
}
