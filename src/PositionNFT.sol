// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Adjust} from "./interfaces/IPositions.sol";

interface IPositionLedger {
    function onTransfer(uint256 id, address from, address to) external;
}

interface ILedgerExecute {
    function execute(address owner, bytes32 ilk, uint256 salt, uint256 id, Adjust calldata a, address actor)
        external
        returns (uint256);
}

/// @notice Ownership of Ledger positions: one ERC-721 per position, minted only by the Ledger, never burned.
/// A position's whole state lives in the Ledger under its id, so a transfer carries its debt, rate, cooldown and premium rate
/// (a transfer is never a way around the upfront fee or the rate cooldown).
///
/// RIGHTS. Besides the owner, an operator can hold any of seven rights over a position, split by risk (Aave v4 position
/// managers, Liquity add/remove managers): ADD collateral, REPAY, SET_RATE, WITHDRAW and BORROW to the OWNER only, and
/// WITHDRAW_ANY / BORROW_ANY to any address. Rights are granted per position or for every position of the owner, and are
/// keyed by the owner who granted them, so a transfer leaves the new owner with no operators. Per-position grants are
/// also keyed by the position's transfer EPOCH, bumped on every transfer, so a grant never comes back when a position
/// returns to an earlier owner. An all-positions grant (`id == 0`) follows its owner: it covers every
/// position the owner holds, including positions somebody else later sends them. ERC-721 approval is a separate thing:
/// it allows a transfer, which is full control, exactly as for any NFT.
///
/// SIGNATURES (EIP-712; ERC-1271 accepted, so Safes and 7702 accounts sign too). `permitOperator` grants rights;
/// `openFor` and `borrowFor` (here; they call the Ledger's `execute`) let a fresh key own a position and borrow to any
/// address without ever holding gas. One sequential nonce per owner across all three; `bumpNonce(n)` jumps
/// the nonce to `n`, which cancels every outstanding signature with a nonce below `n` (the whole pre-signed
/// queue).
interface IPositionLedgerNft {
    function nft() external view returns (address);
}

contract PositionNFT is ERC721, EIP712 {
    uint8 public constant ADD = 1;
    uint8 public constant REPAY = 2;
    /// @dev An owner's grant of trust: any change by the operator restarts the 7-day cooldown, so the owner's next change pays
    /// the premium.
    uint8 public constant SET_RATE = 4;
    uint8 public constant WITHDRAW = 8;
    uint8 public constant BORROW = 16;
    uint8 public constant WITHDRAW_ANY = 32;
    uint8 public constant BORROW_ANY = 64;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("PermitOperator(address owner,uint256 id,address operator,uint8 mask,uint256 nonce,uint256 deadline)");
    bytes32 public constant OPEN_TYPEHASH = keccak256(
        "OpenFor(address owner,bytes32 ilk,uint256 salt,int256 dCollateral,int256 dDebt,uint64 rate,bool viaAsset,uint256 maxUpfrontFee,address to,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant BORROW_TYPEHASH = keccak256(
        "BorrowFor(address owner,uint256 id,uint256 amount,address to,uint256 maxUpfrontFee,uint256 nonce,uint256 deadline)"
    );

    /// @notice The Ledger that mints, burns and acts for these positions. Bound once by `binder` (the deployer), after the
    /// Ledger exists: the NFT is deployed first so the Ledger's creation code stays under EIP-3860. The Ledger
    /// refuses to be wired until this points at it.
    address public ledger;
    address public immutable binder;

    /// @notice The most one `bumpNonce` may move the nonce (keeps a typo from exhausting the owner's nonce space).
    uint256 public constant MAX_NONCE_JUMP = type(uint64).max;

    /// @notice A position's transfer epoch: bumped on every transfer, so per-position grants of an earlier holding lapse.
    mapping(uint256 id => uint256) public epochOf;
    /// @dev Rights an owner granted an operator over one position, per transfer epoch.
    mapping(uint256 id => mapping(uint256 epoch => mapping(address owner => mapping(address operator => uint8)))) internal
        _idRights;
    /// @notice Rights an owner granted an operator over every position they own.
    mapping(address owner => mapping(address operator => uint8)) public allRights;
    mapping(address owner => uint256) public nonces;

    error Unauthorized();
    error Expired();
    error BadSignature();
    error NoRight(uint8 missing);
    error BadNonce();

    event OperatorSet(address indexed owner, uint256 indexed id, address indexed operator, uint8 mask);
    event NonceBumped(address indexed owner, uint256 nonce);

    constructor(address binder_) ERC721("imdUSD position", "imdPOS") EIP712("imdUSD positions", "1") {
        binder = binder_;
    }

    /// @notice Bind the Ledger, once, by the deployer. The Ledger checks the binding in its own `wire`.
    function bind(address ledger_) external {
        if (msg.sender != binder || ledger != address(0) || ledger_.code.length == 0) revert Unauthorized();
        if (address(IPositionLedgerNft(ledger_).nft()) != address(this)) revert Unauthorized();
        ledger = ledger_;
    }

    modifier onlyLedger() {
        if (msg.sender != ledger) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------- Ledger

    /// @notice Ledger only. Not a safe mint: a position can be opened for any address (a contract that cannot receive
    /// NFTs only loses the ability to move it, never the position).
    function mint(address to, uint256 id) external onlyLedger {
        _mint(to, id);
    }

    // ---------------------------------------------------------------- signed actions

    /// @notice Open (or change) `owner`'s position `positionId(owner, ilk, salt)` by `owner`'s `OpenFor` signature. The
    /// caller pays any collateral (approve the Ledger) and any repayment; borrowed imdUSD and withdrawn collateral go to the
    /// signed `to`. The hints are not signed: they only move gas. A fresh key can own a position without ever holding gas.
    function openFor(address owner, bytes32 ilk, uint256 salt, Adjust calldata a, uint256 deadline, bytes calldata sig)
        external
        returns (uint256 id)
    {
        bytes32 h = keccak256(
            abi.encode(
                OPEN_TYPEHASH,
                owner,
                ilk,
                salt,
                a.dCollateral,
                a.dDebt,
                a.rate,
                a.viaAsset,
                a.maxUpfrontFee,
                a.to,
                _useNonce(owner),
                deadline
            )
        );
        _verify(owner, h, deadline, sig);
        return ILedgerExecute(ledger).execute(owner, ilk, salt, 0, a, msg.sender);
    }

    /// @notice Borrow `amount` on position `id` to `to` (zero: its owner), by its owner's `BorrowFor` signature. Meant for a
    /// position that has debt: the borrow keeps the position's rate (it passes rate 0). Nothing here checks that: on a
    /// position whose debt reached zero before inclusion the Ledger takes rate 0 as the opening rate, which reverts
    /// (RateOutOfRange) on every type whose `rateFloor` is above 0 (all beta types).
    function borrowFor(uint256 id, uint256 amount, address to, uint256 maxUpfrontFee, uint256 deadline, bytes calldata sig)
        external
    {
        address owner = ownerOf(id);
        bytes32 h = keccak256(abi.encode(BORROW_TYPEHASH, owner, id, amount, to, maxUpfrontFee, _useNonce(owner), deadline));
        _verify(owner, h, deadline, sig);
        Adjust memory a;
        a.dDebt = int256(amount);
        if (a.dDebt < 0) revert BadSignature();
        a.maxUpfrontFee = maxUpfrontFee;
        a.to = to;
        ILedgerExecute(ledger).execute(owner, bytes32(0), 0, id, a, msg.sender);
    }

    // ---------------------------------------------------------------- rights

    /// @notice Grant `operator` `mask` over position `id` (yours), or over every position you own with `id == 0`.
    /// A mask of 0 revokes.
    function approveOperator(uint256 id, address operator, uint8 mask) external {
        _setRights(msg.sender, id, operator, mask);
    }

    /// @notice `approveOperator` by the owner's signature.
    function permitOperator(address owner, uint256 id, address operator, uint8 mask, uint256 deadline, bytes calldata sig)
        external
    {
        bytes32 h = keccak256(abi.encode(PERMIT_TYPEHASH, owner, id, operator, mask, _useNonce(owner), deadline));
        _verify(owner, h, deadline, sig);
        _setRights(owner, id, operator, mask);
    }

    /// @notice Cancel every signature you have given with a nonce below `newNonce`: the nonce jumps to `newNonce`, so the
    /// whole queue of pre-signed messages dies at once (pass `nonces(you) + k` to cancel the next k). It must move forward,
    /// by at most `MAX_NONCE_JUMP`.
    function bumpNonce(uint256 newNonce) external {
        uint256 cur = nonces[msg.sender];
        if (newNonce <= cur || newNonce - cur > MAX_NONCE_JUMP) revert BadNonce();
        nonces[msg.sender] = newNonce;
        emit NonceBumped(msg.sender, newNonce);
    }

    /// @notice Rights `owner` granted `operator` over position `id` in its current transfer epoch.
    function idRights(uint256 id, address owner, address operator) public view returns (uint8) {
        return _idRights[id][epochOf[id]][owner][operator];
    }

    /// @notice The rights `who` holds over position `id`: every right for its owner, else what the owner granted (an _ANY
    /// right includes its to-the-owner form).
    function rightsOf(uint256 id, address who) public view returns (uint8) {
        address owner = _ownerOf(id);
        if (who == owner) return type(uint8).max;
        uint8 r = _idRights[id][epochOf[id]][owner][who] | allRights[owner][who];
        // WITHDRAW_ANY and BORROW_ANY include their to-the-owner forms.
        return r | ((r & (WITHDRAW_ANY | BORROW_ANY)) >> 2);
    }

    /// @notice Reverts unless `who` holds every right in `need` over `id`.
    function checkRights(uint256 id, address who, uint8 need) external view {
        uint8 missing = need & ~rightsOf(id, who);
        if (missing != 0) revert NoRight(missing);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------- internals

    function _setRights(address owner, uint256 id, address operator, uint8 mask) private {
        if (id == 0) {
            allRights[owner][operator] = mask;
        } else {
            if (_ownerOf(id) != owner) revert Unauthorized();
            _idRights[id][epochOf[id]][owner][operator] = mask;
        }
        emit OperatorSet(owner, id, operator, mask);
    }

    function _useNonce(address owner) private returns (uint256) {
        unchecked {
            return nonces[owner]++;
        }
    }

    function _verify(address owner, bytes32 structHash, uint256 deadline, bytes calldata sig) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!SignatureChecker.isValidSignatureNow(owner, _hashTypedDataV4(structHash), sig)) revert BadSignature();
    }

    /// @dev A real transfer (not a mint) tells the Ledger, which moves holder-bound custody (seats) with it and refuses a
    /// transfer in the middle of one of its own calls.
    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from != address(0) && to != address(0)) {
            unchecked {
                ++epochOf[id];
            }
            IPositionLedger(ledger).onTransfer(id, from, to);
        }
    }
}
