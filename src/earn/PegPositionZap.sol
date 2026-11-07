// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Adjust} from "../interfaces/IPositions.sol";
import {LedgerBase} from "../LedgerBase.sol";
import {PegCollateral} from "./PegCollateral.sol";

interface IPegZapVault {
    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);
    function totals() external view returns (uint256, uint256);
    function totalSupply() external view returns (uint256);
    function DEAD_SHARES() external view returns (uint256);
    function compound() external;
    function deposit(uint256 shares, uint256 max0, uint256 max1, address to) external returns (uint256, uint256, uint256);
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address to) external returns (uint256, uint256);
}

interface IPegZapLedger {
    function open(bytes32 ilk, uint256 salt, Adjust calldata a) external returns (uint256 id);
    function adjust(uint256 id, Adjust calldata a) external;
    function repayFor(uint256 id, uint256 amount) external;
    function debtOf(uint256 id) external view returns (uint256);
    function position(uint256 id) external view returns (LedgerBase.Position memory);
    function nft() external view returns (address);
}

interface IPegZapNft {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

/// @notice Peg positions: debt that IS peg liquidity. A USDC holder brings `y` USDC; the zap flash-mints
/// imdUSD, deposits both into PegLPVault IN THE VAULT'S PROPORTION (two-sided, in band), opens a Ledger position whose
/// collateral is those shares wrapped 1:1 as `PegCollateral` (only this zap can mint it), borrows exactly the imdUSD the vault took to repay the flash mint, and hands the
/// position NFT to the user. So every dollar of USDC becomes about two dollars of in-band depth.
/// @dev No custody between transactions: the zap owns a position only inside `open` (then transfers it) and never holds
/// funds after a call. Unwinding needs the owner's grant of WITHDRAW_ANY on the position to this zap (the collateral must
/// come here to be redeemed): `PositionNFT.approveOperator(id, zap, 32)`.
///
/// Two-sided by construction: the vault takes both tokens in its current proportion, and the Ledger's health check
/// (collateral = shares worth imdUSD + USDC at $1, debt = the imdUSD placed) refuses an imdUSD-heavy deposit below the
/// type's `mat`. A vault that holds only USDC (imdUSD above the band) takes no imdUSD, so an open there reverts `DustDebt`.
contract PegPositionZap is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    bytes32 private constant FLASH_OK = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint8 private constant OPEN = 1;
    uint8 private constant UNWIND = 2;
    /// @notice Shares asked for are this fraction (1e4) of what the inputs buy: the vault collects fees before pricing, so
    /// an exact ask could exceed the inputs. The unspent inputs go back to the user.
    uint256 public constant SHARE_MARGIN_BPS = 9995;

    IERC20 public immutable imdUSD;
    IERC20 public immutable usdc;
    IPegZapVault public immutable vault;
    PegCollateral public immutable collateral;
    IPegZapLedger public immutable ledger;
    IPegZapNft public immutable nft;
    bytes32 public immutable ilk;
    bool private immutable stableIs0;

    uint256 public opened; // salt counter: each zap position gets a fresh id
    /// @dev Transient slot carrying the opened id out of the flash callback (solc 0.8.26 has no `transient` variables).
    bytes32 private constant ID_SLOT = 0x2d5e0e5af6c460dcd64e34dfe6c69769d6386b7cd6df373d401dfd2cef030ef9; // keccak256("imdusd.pegzap.id")

    error BadConfig();
    error NotLender();
    error NotOwner();
    error TooFewShares(uint256 got);
    error TooLittleUsdc(uint256 got);
    error ShortfallTooHigh(uint256 needed, uint256 maxImdIn);

    event PegOpened(address indexed user, uint256 indexed id, uint256 shares, uint256 imdUSDPlaced, uint256 usdcPlaced);
    event PegUnwound(address indexed user, uint256 indexed id, uint256 imdUSDOut, uint256 usdcOut);

    constructor(IERC20 imdUSD_, IPegZapVault vault_, PegCollateral collateral_, IPegZapLedger ledger_, bytes32 ilk_) {
        address t0 = address(vault_.token0());
        address t1 = address(vault_.token1());
        if ((address(imdUSD_) != t0 && address(imdUSD_) != t1) || address(collateral_.shares()) != address(vault_)) revert BadConfig();
        collateral = collateral_;
        imdUSD = imdUSD_;
        stableIs0 = address(imdUSD_) == t0;
        usdc = IERC20(stableIs0 ? t1 : t0);
        vault = vault_;
        ledger = ledger_;
        nft = IPegZapNft(ledger_.nft());
        ilk = ilk_;
    }

    // ================================================================ open

    /// @notice Bring `usdcIn` USDC, receive a peg position NFT. `rate` is the borrower-set rate (>= the type's floor).
    /// Refused outside the two-sided gate (Pricer). Above the band the vault holds only USDC and takes no imdUSD, so the position
    /// would have no debt: that open reverts `DustDebt`; open again once the pool is back in the band.
    function open(uint256 usdcIn, uint64 rate, uint256 minShares, uint256 maxUpfrontFee, uint256 prevHint, uint256 nextHint)
        external
        returns (uint256 id)
    {
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        uint256 imdIn = usdcIn * _quoteScale();
        bytes memory data = abi.encode(OPEN, msg.sender, usdcIn, rate, minShares, maxUpfrontFee, prevHint, nextHint);
        IERC3156FlashLender(address(imdUSD)).flashLoan(this, address(imdUSD), imdIn, data);
        assembly ("memory-safe") {
            id := tload(ID_SLOT)
            tstore(ID_SLOT, 0)
        }
    }

    // ================================================================ unwind

    /// @notice Close your peg position: repay its whole debt, redeem its shares, receive the USDC and any imdUSD left.
    /// When the shares hold less imdUSD than the debt, the shortfall is pulled from you in imdUSD (approve this zap
    /// first). The debt is the imdUSD placed PLUS the upfront fee and interest, so there is a shortfall even at the
    /// opening price, and a push of the pool just before the unwind can raise it to nearly the whole debt: `maxImdIn`
    /// bounds what may be pulled. Needs WITHDRAW_ANY on `id` granted to this zap.
    function unwind(uint256 id, uint256 minUsdcOut, uint256 maxImdIn) external {
        if (nft.ownerOf(id) != msg.sender) revert NotOwner();
        uint256 debt = ledger.debtOf(id);
        bytes memory data = abi.encode(UNWIND, msg.sender, id, minUsdcOut, debt, maxImdIn);
        if (debt == 0) {
            _unwindBody(msg.sender, id, minUsdcOut, 0, 0);
        } else {
            IERC3156FlashLender(address(imdUSD)).flashLoan(this, address(imdUSD), debt, data);
        }
    }

    // ================================================================ flash callback

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        if (msg.sender != address(imdUSD) || initiator != address(this) || token != address(imdUSD)) revert NotLender();
        uint8 kind = abi.decode(data, (uint8));
        if (kind == OPEN) {
            (, address user, uint256 usdcIn, uint64 rate, uint256 minShares, uint256 maxFee, uint256 p, uint256 n) =
                abi.decode(data, (uint8, address, uint256, uint64, uint256, uint256, uint256, uint256));
            _openBody(user, amount, usdcIn, rate, minShares, maxFee, p, n);
        } else {
            (, address user, uint256 id, uint256 minUsdcOut, uint256 debt, uint256 maxImdIn) =
                abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256));
            _unwindBody(user, id, minUsdcOut, debt, maxImdIn);
        }
        imdUSD.forceApprove(address(imdUSD), amount + fee);
        return FLASH_OK;
    }

    function _openBody(
        address user,
        uint256 imdIn,
        uint256 usdcIn,
        uint64 rate,
        uint256 minShares,
        uint256 maxFee,
        uint256 prevHint,
        uint256 nextHint
    ) private {
        // Collect the fees first, so shares are sized on what the deposit will price them at (fees above the margin
        // reverted every open). Same TWAP gate as the deposit that follows, and the same first step it would run itself.
        vault.compound();
        (uint256 max0, uint256 max1) = stableIs0 ? (imdIn, usdcIn) : (usdcIn, imdIn);
        imdUSD.forceApprove(address(vault), imdIn);
        usdc.forceApprove(address(vault), usdcIn);
        (uint256 shares, uint256 a0, uint256 a1) = vault.deposit(_sharesFor(max0, max1), max0, max1, address(this));
        if (shares < minShares) revert TooFewShares(shares);
        (uint256 imdPlaced, uint256 usdcPlaced) = stableIs0 ? (a0, a1) : (a1, a0);
        imdUSD.forceApprove(address(vault), 0);
        usdc.forceApprove(address(vault), 0);

        IERC20(address(vault)).forceApprove(address(collateral), shares);
        collateral.wrap(shares, address(this));
        IERC20(address(collateral)).forceApprove(address(ledger), shares);
        uint256 id = ledger.open(
            ilk,
            ++opened,
            Adjust(int256(shares), int256(imdPlaced), rate, prevHint, nextHint, false, maxFee, address(this))
        );
        nft.transferFrom(address(this), user, id);
        assembly ("memory-safe") {
            tstore(ID_SLOT, id)
        }
        // The flash mint (imdIn) is now covered: imdIn - imdPlaced never left, imdPlaced came back as the borrow.
        uint256 usdcBack = usdcIn - usdcPlaced;
        if (usdcBack != 0) usdc.safeTransfer(user, usdcBack);
        emit PegOpened(user, id, shares, imdPlaced, usdcPlaced);
    }

    function _unwindBody(address user, uint256 id, uint256 minUsdcOut, uint256 debt, uint256 maxImdIn) private {
        if (debt != 0) ledger.repayFor(id, debt);
        uint256 shares = ledger.position(id).collateral;
        ledger.adjust(id, Adjust(-int256(shares), 0, 0, 0, 0, false, 0, address(this)));
        collateral.redeem(shares, address(this));
        (uint256 a0, uint256 a1) = vault.withdraw(shares, 0, 0, address(this));
        (uint256 imdGot, uint256 usdcGot) = stableIs0 ? (a0, a1) : (a1, a0);
        if (usdcGot < minUsdcOut) revert TooLittleUsdc(usdcGot);
        uint256 imdOut;
        if (imdGot < debt) {
            uint256 shortfall = debt - imdGot; // fee + interest, more if the pool sits above the opening price
            if (shortfall > maxImdIn) revert ShortfallTooHigh(shortfall, maxImdIn);
            imdUSD.safeTransferFrom(user, address(this), shortfall);
        } else {
            imdOut = imdGot - debt;
        }
        if (imdOut != 0) imdUSD.safeTransfer(user, imdOut);
        if (usdcGot != 0) usdc.safeTransfer(user, usdcGot);
        emit PegUnwound(user, id, imdOut, usdcGot);
    }

    // ================================================================ helpers

    /// @dev Shares the inputs buy at the vault's current proportion, less SHARE_MARGIN_BPS; 0 on a first deposit (the
    /// vault then takes the liquidity max0/max1 buy).
    function _sharesFor(uint256 max0, uint256 max1) private view returns (uint256) {
        uint256 supply = vault.totalSupply();
        if (supply == 0 || supply == vault.DEAD_SHARES()) return 0;
        (uint256 t0, uint256 t1) = vault.totals();
        uint256 s0 = t0 == 0 ? type(uint256).max : Math.mulDiv(max0, supply, t0);
        uint256 s1 = t1 == 0 ? type(uint256).max : Math.mulDiv(max1, supply, t1);
        return Math.min(s0, s1) * SHARE_MARGIN_BPS / 10_000;
    }

    function _quoteScale() private view returns (uint256) {
        return 10 ** (IDec(address(imdUSD)).decimals() - IDec(address(usdc)).decimals());
    }
}

interface IDec {
    function decimals() external view returns (uint8);
}
