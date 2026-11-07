// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice imdUSD (v2). Minted only by its Ledger, the v1 Migrator, one peg keeper and (where set) one bridge.
/// @dev No owner, upgrade, pause, blocklist or rescue. Four minters, each fixed once:
///  - `ledger` and `migrator` are wired once by the deployer, in the deploy transaction sequence, and the
///    wirer has no other power (v1's deferred `setVault` pattern).
///  - `bridge` is set once by `bridgeSetter` (the timelocked Parameters contract, so adding a bridge
///    minter is public for 48h first). It is meant for LayerZero's `MintBurnOFTAdapter`,
///    which calls `mint`/`burn` with the `IMintableBurnable` signatures below; rate limits and peers live
///    in the adapter, so this token stays the same on every chain.
///  - `keeper` is set once by the same timelocked setter: the v4 peg hook (src/peg/PegHook.sol), capped by
///    `Parameters.keeperCap`.
/// Payments: EIP-2612 permit, EIP-3009 transfer/receive-with-authorization (x402 facilitators settle
/// these gaslessly; the `bytes` overloads accept ERC-1271 signers), ERC-3156 flash mint at zero fee up
/// to `flashCap` PER TRANSACTION: loans in flight are counted in transient storage (`flashOutstanding`), so
/// nested or repeated loans inside one transaction share the cap, and `circulating()` is the supply
/// less what is only flash-minted, for every rule that must not be diluted by a flash mint.
contract ImdUSD is ERC20, ERC20Permit, ERC20FlashMint {
    /// @notice The address allowed to call `wire` exactly once.
    address public immutable wirer;
    /// @notice Most imdUSD flash-minted and not yet repaid at any moment of a transaction.
    uint256 public immutable flashCap;
    /// @dev Transient slot holding the flash loans in flight: keccak256("imdusd.flashOutstanding").
    uint256 private constant FLASH_SLOT = 0x43bba977711567fa248257e733d781f48e8e6b2665846d63f26d68e91b5ab029;

    address public ledger;
    address public migrator;
    address public bridge;
    /// @notice The peg keeper: mints only against USDC it receives above $1, burns what it buys back.
    address public keeper;
    /// @notice The address allowed to call `setBridge` and `setKeeper` exactly once each (wired: Parameters).
    address public bridgeSetter;

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    /// @notice EIP-3009: whether `nonce` of `authorizer` has been used or cancelled.
    mapping(address authorizer => mapping(bytes32 nonce => bool)) public authorizationState;

    error Unauthorized();
    error AlreadySet();
    error InvalidMinter();
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error InvalidSignature();

    event Wired(address ledger, address migrator);
    event BridgeSet(address bridge);
    event KeeperSet(address keeper);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    constructor(address wirer_, uint256 flashCap_) ERC20("imdUSD", "imdUSD") ERC20Permit("imdUSD") {
        if (wirer_ == address(0)) revert InvalidMinter();
        wirer = wirer_;
        flashCap = flashCap_;
    }

    // ---------------------------------------------------------------- minters

    function wire(address ledger_, address migrator_, address bridgeSetter_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (ledger != address(0)) revert AlreadySet();
        if (ledger_.code.length == 0 || migrator_.code.length == 0 || bridgeSetter_.code.length == 0) {
            revert InvalidMinter();
        }
        ledger = ledger_;
        migrator = migrator_;
        bridgeSetter = bridgeSetter_;
        emit Wired(ledger_, migrator_);
    }

    function setBridge(address bridge_) external {
        if (msg.sender != bridgeSetter) revert Unauthorized();
        if (bridge != address(0)) revert AlreadySet();
        if (bridge_.code.length == 0) revert InvalidMinter();
        bridge = bridge_;
        emit BridgeSet(bridge_);
    }

    /// @notice Set the peg keeper minter once, through the same timelocked setter as the bridge.
    function setKeeper(address keeper_) external {
        if (msg.sender != bridgeSetter) revert Unauthorized();
        if (keeper != address(0)) revert AlreadySet();
        if (keeper_.code.length == 0) revert InvalidMinter();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function isMinter(address account) public view returns (bool) {
        return account != address(0)
            && (account == ledger || account == migrator || account == bridge || account == keeper);
    }

    /// @notice Mint, by a minter. Returns true for LayerZero's `IMintableBurnable`.
    function mint(address to, uint256 amount) external returns (bool) {
        if (!isMinter(msg.sender)) revert Unauthorized();
        _mint(to, amount);
        return true;
    }

    /// @notice Burn from `from` without an allowance, by a minter (each minter only burns on an action
    /// `from` initiated through it, as v1's vault does). Returns true for `IMintableBurnable`.
    function burn(address from, uint256 amount) external returns (bool) {
        if (!isMinter(msg.sender)) revert Unauthorized();
        _burn(from, amount);
        return true;
    }

    // ---------------------------------------------------------------- flash mint

    /// @notice What may still be flash-minted in this transaction: the cap less the loans in flight.
    function maxFlashLoan(address token) public view override returns (uint256) {
        if (token != address(this)) return 0;
        uint256 inFlight = flashOutstanding();
        uint256 room = flashCap > inFlight ? flashCap - inFlight : 0;
        uint256 headroom = type(uint256).max - totalSupply();
        return room < headroom ? room : headroom;
    }

    /// @notice imdUSD flash-minted and not yet repaid in this transaction (zero between transactions).
    function flashOutstanding() public view returns (uint256 out) {
        assembly ("memory-safe") {
            out := tload(FLASH_SLOT)
        }
    }

    /// @notice The supply less the flash loans in flight: what the Redeemer's fee ramp and the savings uptake divide by,
    /// so a flash mint (any nesting) cannot dilute them. Equals `totalSupply()` outside a flash loan.
    function circulating() external view returns (uint256) {
        return totalSupply() - flashOutstanding();
    }

    /// @dev OpenZeppelin's `flashLoan` with the in-flight counter around the callback. `maxFlashLoan` already subtracts
    /// the loans in flight, so the cap bounds the transaction, not one call; the counter is restored (not zeroed) on the
    /// way out so nested loans unwind correctly, and the transaction's end clears the transient slot regardless.
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 value, bytes calldata data)
        public
        override
        returns (bool)
    {
        uint256 maxLoan = maxFlashLoan(token);
        if (value > maxLoan) revert ERC3156ExceededMaxLoan(maxLoan);
        uint256 before = flashOutstanding();
        _setFlashOutstanding(before + value);
        uint256 fee = flashFee(token, value);
        _mint(address(receiver), value);
        if (receiver.onFlashLoan(_msgSender(), token, value, fee, data) != keccak256("ERC3156FlashBorrower.onFlashLoan")) {
            revert ERC3156InvalidReceiver(address(receiver));
        }
        _spendAllowance(address(receiver), address(this), value + fee);
        _burn(address(receiver), value + fee); // fee is 0 and there is no fee receiver
        _setFlashOutstanding(before);
        return true;
    }

    function _setFlashOutstanding(uint256 out) private {
        assembly ("memory-safe") {
            tstore(FLASH_SLOT, out)
        }
    }

    function _flashFee(address, uint256) internal pure override returns (uint256) {
        return 0;
    }

    // ---------------------------------------------------------------- EIP-3009

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        transferWithAuthorization(from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) public {
        _useAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        receiveWithAuthorization(from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice Like transferWithAuthorization, but only the payee may submit it, so a watcher of the
    /// mempool cannot front-run the payee's own call with the same authorization.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) public {
        if (msg.sender != to) revert Unauthorized();
        _useAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
        _transfer(from, to, value);
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) public {
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)));
        if (!SignatureChecker.isValidSignatureNow(authorizer, digest, signature)) revert InvalidSignature();
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _useAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[from][nonce]) revert AuthorizationAlreadyUsed();
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce)));
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) revert InvalidSignature();
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
    }
}
