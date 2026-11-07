// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice IMD's ERC-8004 agent-registration adapter. The first argument is the token standard (0 = ERC-721);
/// the adapter checks `collection.ownerOf(tokenId) == msg.sender`. Live selector 0xb68ca002 (hive-seat-vault).
interface IImdAgentAdapter {
    function register(uint8 standard, address collection, uint256 tokenId, string calldata agentURI)
        external
        returns (uint256 agentId);
}

interface ISeatJoinForAccount {
    function holderOf(uint256 tokenId) external view returns (address);
    function claimAllowed(address target, bytes4 selector, address factory, uint256 hint) external view returns (bool);
    function onRewards(uint256 tokenId, address token, uint256 amount) external;
}

/// @notice One account per pledged seat: an EIP-1167 clone owned by `SeatJoin` that holds the NFT.
/// The plane keys claim trees by wallet, so a per-seat owner is what keeps each seat's rewards attributable.
///
/// SIGNING (pattern from ProjectHive-IMD/hive-seat-vault, MIT): the seat's holder (the borrower) stores the
/// EIP-712 pairing digest for their worker's device key with `authorizeWorker`; `isValidSignature` is VALID
/// for exactly those digests, while unexpired and while this account still owns the seat, and INVALID for
/// everything else, so the account can never sign a Permit, a Seaport order or any other message. Every
/// ownership change (withdrawal, liquidation, Treasury keep, Treasury transfer) bumps `custodyEpoch` and
/// retires every pairing made before it. The domain is bound to the NFT collection, as the plane's is.
///
/// The borrower keeps running their own worker; the protocol never holds a key or runs the seat.
contract SeatAccount {
    struct WorkerAuthorization {
        bytes32 deviceKey;
        address wallet;
        uint256 tokenId;
        bytes32 nonce;
        uint64 expiresAt;
        string relayOrigin;
    }

    struct Pairing {
        uint64 expiresAt;
        uint64 epoch;
        bool exists;
    }

    // EIP-712, identical to the plane's `workerAuthorizationTypedData` (packages/protocol/src/eip712.ts)
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant DOMAIN_NAME_HASH = keccak256("IdentityMD Worker");
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256("2");
    bytes32 private constant AUTHORIZATION_TYPEHASH = keccak256(
        "WorkerAuthorization(bytes32 deviceKey,address wallet,uint256 tokenId,bytes32 nonce,uint64 expiresAt,string relayOrigin)"
    );
    bytes4 private constant ERC1271_VALID = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    /// @dev Immutables live in the implementation's code, which every clone runs: shared by all seats.
    address public immutable join;
    IERC721 public immutable nft;
    IImdAgentAdapter public immutable adapter;

    uint256 public tokenId;
    bool public initialized;
    uint64 public custodyEpoch;
    uint256 public agentId;
    mapping(bytes32 digest => Pairing) private _pairing;
    /// @notice Token balance already reported to the join as rewards.
    mapping(address token => uint256) public reported;

    /// @notice Gas given to a reward token's `transfer` in `send`: a token that spends
    /// everything it is given (INVALID, an unbounded loop) fails inside this bound instead of taking the
    /// caller's whole budget. Any ERC-20 that behaves transfers in a fraction of it, and Glamsterdam prices a
    /// first-time recipient's balance slot at 110,020 alone. A token never runs inside anyone else's transaction: only `collect` reaches it.
    uint256 public constant SEND_GAS = 1_000_000;

    error Unauthorized();
    error AlreadyInitialized();
    error WrongWallet();
    error WrongToken();
    error AuthorizationExpired();
    error NotHeld();
    error AlreadyRegistered();
    error ClaimNotAllowed();
    error ClaimFailed(bytes reason);
    error SendFailed();
    error NotStray();

    event WorkerAuthorized(uint256 indexed tokenId, bytes32 deviceKey, bytes32 digest);
    event WorkerRevoked(bytes32 indexed digest);
    event AgentRegistered(uint256 indexed tokenId, uint256 agentId);
    event Released(uint256 indexed tokenId, address to, uint64 epoch);
    event RewardsReported(address indexed token, uint256 amount);

    constructor(address join_, IERC721 nft_, IImdAgentAdapter adapter_) {
        join = join_;
        nft = nft_;
        adapter = adapter_;
        initialized = true; // the implementation itself is never a seat
    }

    modifier onlyJoin() {
        if (msg.sender != join) revert Unauthorized();
        _;
    }

    modifier onlyHolder() {
        if (ISeatJoinForAccount(join).holderOf(tokenId) != msg.sender) revert Unauthorized();
        _;
    }

    function initialize(uint256 tokenId_) external onlyJoin {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        tokenId = tokenId_;
    }

    // ---------------------------------------------------------------- pairing (hive-seat-vault :188-:291)

    /// @notice Store the pairing digest for the holder's worker device. The holder cannot pass an arbitrary
    /// hash: the struct is checked and the digest computed here. Then POST /pair/complete to the plane with
    /// this message and any signature bytes.
    function authorizeWorker(WorkerAuthorization calldata auth) external onlyHolder returns (bytes32 digest) {
        if (auth.wallet != address(this)) revert WrongWallet();
        if (auth.tokenId != tokenId) revert WrongToken();
        if (auth.expiresAt <= block.timestamp) revert AuthorizationExpired();
        if (nft.ownerOf(tokenId) != address(this)) revert NotHeld();
        digest = workerAuthorizationDigest(auth);
        _pairing[digest] = Pairing({expiresAt: auth.expiresAt, epoch: custodyEpoch, exists: true});
        emit WorkerAuthorized(tokenId, auth.deviceKey, digest);
    }

    function revokeWorker(bytes32 digest) external onlyHolder {
        delete _pairing[digest];
        emit WorkerRevoked(digest);
    }

    /// @notice ERC-1271: VALID only for a stored pairing digest, unexpired, made in the current custody
    /// epoch, while this account still owns the seat.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        Pairing storage p = _pairing[hash];
        if (!p.exists) return ERC1271_INVALID;
        if (block.timestamp >= p.expiresAt) return ERC1271_INVALID;
        if (p.epoch != custodyEpoch) return ERC1271_INVALID;
        if (nft.ownerOf(tokenId) != address(this)) return ERC1271_INVALID;
        return ERC1271_VALID;
    }

    /// @notice The plane's EIP-712 digest: domain (IdentityMD Worker, 2, chainid, the collection).
    function workerAuthorizationDigest(WorkerAuthorization calldata auth) public view returns (bytes32) {
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(nft)));
        bytes32 structHash = keccak256(
            abi.encode(
                AUTHORIZATION_TYPEHASH,
                auth.deviceKey,
                auth.wallet,
                auth.tokenId,
                auth.nonce,
                auth.expiresAt,
                keccak256(bytes(auth.relayOrigin))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // ---------------------------------------------------------------- ERC-8004 (hive-seat-vault :216)

    /// @notice Register the seat's agent through the adapter, once; a seat registered before it was pledged
    /// needs nothing.
    function registerAgent(string calldata agentURI) external onlyHolder returns (uint256 id) {
        if (agentId != 0) revert AlreadyRegistered();
        if (nft.ownerOf(tokenId) != address(this)) revert NotHeld();
        id = adapter.register(0, address(nft), tokenId, agentURI);
        agentId = id;
        emit AgentRegistered(tokenId, id);
    }

    // ---------------------------------------------------------------- rewards

    /// @notice Call an allowlisted distributor (allowlisted target + selector, or a distributor the
    /// allowlisted `factory` deployed under `hint`), then report what arrived in `tokens` to the join.
    /// Permissionless: tokens only ever land here, and the join decides who they belong to.
    function claim(address target, bytes calldata data, address[] calldata tokens, address factory, uint256 hint)
        external
    {
        if (data.length < 4 || target == address(nft) || target == join) revert ClaimNotAllowed();
        if (!ISeatJoinForAccount(join).claimAllowed(target, bytes4(data[:4]), factory, hint)) revert ClaimNotAllowed();
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert ClaimFailed(ret);
        for (uint256 i; i < tokens.length; ++i) {
            sync(tokens[i]);
        }
    }

    /// @notice Report any balance of `token` not yet accounted for (an airdrop that simply arrived).
    /// Permissionless: the join credits what is reported to the seat's holder at this moment, and
    /// a seat's custody never walks the tokens reported, so reporting a worthless or hostile token costs
    /// its reporter gas and nobody else anything.
    function sync(address token) public {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 seen = reported[token];
        if (bal <= seen) return;
        reported[token] = bal;
        ISeatJoinForAccount(join).onRewards(tokenId, token, bal - seen);
        emit RewardsReported(token, bal - seen);
    }

    /// @notice Pay reported rewards out, as the join directs. The token gets `SEND_GAS` and must transfer
    /// (a `false` return, a revert or running out of its gas all revert here: the credit stays).
    function send(address token, address to, uint256 amount) external onlyJoin {
        uint256 seen = reported[token];
        reported[token] = amount > seen ? 0 : seen - amount;
        (bool ok, bytes memory ret) = token.call{gas: SEND_GAS}(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) revert SendFailed();
        if (ret.length == 0 ? token.code.length == 0 : (ret.length < 32 || !abi.decode(ret, (bool)))) revert SendFailed();
    }

    // ---------------------------------------------------------------- custody (join only)

    /// @notice Hand the seat to `to` and retire every pairing.
    function release(address to) external onlyJoin {
        unchecked {
            ++custodyEpoch;
        }
        nft.transferFrom(address(this), to, tokenId);
        emit Released(tokenId, to, custodyEpoch);
    }

    /// @notice The holder changed without the seat moving (the Treasury kept or passed it on): retire every pairing.
    function bump() external onlyJoin {
        unchecked {
            ++custodyEpoch;
        }
    }

    /// @notice Hand a STRAY token of the collection (one that reached this account by a plain `transferFrom`,
    /// never through `SeatJoin.deposit`, S5) to `to`. Never the seat this account holds: the join checks that
    /// and this account refuses it too. The custody epoch is untouched (the deposited seat's pairing stands).
    function rescue(uint256 strayId, address to) external onlyJoin {
        if (strayId == tokenId) revert NotStray();
        nft.transferFrom(address(this), to, strayId);
    }

    /// @dev Stray `safeTransferFrom`s are refused: a seat enters only through `SeatJoin.deposit`.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert Unauthorized();
    }
}
