// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Governed} from "../Governed.sol";
import {TransientReentrancyGuard} from "../TransientReentrancyGuard.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingReceipt,
    MessagingFee,
    Origin
} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {SendParam, OFTReceipt} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {OFTMsgCodec} from "layerzero-v2/oft/libs/OFTMsgCodec.sol";

/// @dev LayerZero ULN302's `UlnConfig` (configType 2), decoded to enforce the floors below.
struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

interface IMintableBurnable {
    function mint(address to, uint256 amount) external returns (bool);
    function burn(address from, uint256 amount) external returns (bool);
}

/// @notice imdUSD's LayerZero V2 path: LayerZero's MintBurnOFTAdapter pattern (burn on send, mint on receive, through
/// the token's one bridge minter), with every Ownable power of the OApp moved behind a 48h `Governed` timelock. No `owner()`.
/// @dev Wire format = OFT's (OFTMsgCodec: `bytes32 to ‖ uint64 amountSD`, 6 shared decimals), and the OApp receiver surface the
/// endpoint calls (`allowInitializePath`, `nextNonce`, `lzReceive`) is OApp v1/v2's, so a standard OFT peer interoperates.
///
/// AUTHORITY.
///  - The governor (the chain's Safe) proposes; anyone applies after 48h. Through it: peers, rate limits and enforced options
///    per path (`SET_PATH`), the endpoint's message-library config for this OApp (`SET_CONFIG`: DVNs, confirmations, executor),
///    send/receive libraries, and unpausing a path. `BATCH` applies several in one proposal (one pending slot).
///  - No endpoint delegate is ever set: only this contract configures itself at the endpoint, and only from `_apply`, so DVN
///  config is as slow as a peer change.
///  - LIBRARIES ARE PINNED. Each path's send and receive library is set explicitly (`SET_SEND_LIBRARY`,
///    `SET_RECEIVE_LIBRARY`) in the launch BATCH, so a LayerZero default-library move cannot put this OApp on a library
///    where it has no DVN config (the endpoint's defaults would then verify our packets). `SET_CONFIG` refuses a library
///    that is not the pinned one for each param's eid (pins set earlier in the same BATCH count). A LayerZero library
///    deprecation becomes one 48h BATCH: SET_RECEIVE_LIBRARY (new lib, grace) + SET_SEND_LIBRARY + SET_CONFIG on the new lib.
///  - DVN FLOORS IN SOURCE. `SET_CONFIG` decodes every ULN config and refuses fewer than MIN_REQUIRED_DVNS
///    required DVNs (or NIL), a DVN list that does not match its count, is unsorted, repeats or holds zero, and fewer block
///    confirmations than the source chain's floor; only executor (on a send library) and ULN config types pass. A compromised
///    or careless Safe cannot propose a Kelp-style 1-of-1 downgrade at all.
///  - VERIFIED PAYLOADS CAN BE VOIDED. A forged packet that a compromised DVN set verified stays executable at the
///    endpoint until it is executed, nilified or burned; with no delegate only this contract can do that. The timelock may
///    `ENDPOINT_SKIP`/`ENDPOINT_NILIFY`/`ENDPOINT_BURN` an inbound nonce of a PAUSED path (validated paused at proposal and
///    at application), and the guardian or governor may `nilify` instantly: like `pause`, it only closes (a nilified nonce
///    can be re-verified by the DVNs, so an honest message is delayed, never lost). Kelp sequence: pause, nilify, fix the
///    DVN config, then unpause, without changing the peer.
///  - `guardian` (and the governor) may PAUSE a path instantly; only the timelock unpauses it (closable fast, reopened
///    slowly). A paused path refuses sends and leaves inbound messages at the endpoint, retryable once reopened.
///
/// LIMITS. Per path, an outbound and an inbound limit in LayerZero RateLimiter's form: at most `limit` in any
/// `window`, with the amount in flight decaying linearly. Outbound bounds how much a failure on this chain can export; inbound
/// is the mint limit under a forged message. A path with no limit set refuses everything. An inbound message over the limit
/// reverts and stays at the endpoint (retry later); nothing is lost. Bounds are in source.
///
/// FEE. Per destination, `feeBps[eid]` of each send (0 until the timelock sets it, at most MAX_FEE_BPS).
/// The sender is burned the whole amount; the destination receives the amount less the fee (and less the dust below 1e-6
/// the fee leaves); the fee is minted here to the Treasury. `sent` counts only what is delivered, so the fee never leaves
/// the chain and the supply equation below is unchanged.
///
/// SUPPLY. `received` (minted here) and `sent` (burned here, net of the fee re-minted to the Treasury) are cumulative, so
/// on each chain
///   token.totalSupply() == Σ debt + Σ bad debt + reserveBacked + migrated + keeper + received − sent.
contract ImdBridge is Governed, TransientReentrancyGuard {
    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;

    struct Limit {
        uint128 limit; // most in any window; 0 = closed
        uint32 window; // seconds
        uint128 inFlight; // at `lastUpdated`, decays at limit/window per second
        uint64 lastUpdated;
    }

    uint8 public constant SET_PATH = 1; // (eid, peer, outLimit, outWindow, inLimit, inWindow, enforcedOptions)
    uint8 public constant SET_CONFIG = 2; // (lib, SetConfigParam[])
    uint8 public constant SET_SEND_LIBRARY = 3; // (eid, lib)
    uint8 public constant SET_RECEIVE_LIBRARY = 4; // (eid, lib, gracePeriod)
    uint8 public constant UNPAUSE = 5; // (eid)
    uint8 public constant BATCH = 6; // (bytes[] payloads), none of them a BATCH
    uint8 public constant SET_FEE = 7; // (eid, bps)
    /// @notice Endpoint channel acts for a PAUSED path: drop a verified inbound payload so it can never execute.
    uint8 public constant ENDPOINT_SKIP = 8; // (srcEid, sender, nonce): skip a nonce that was never verified
    uint8 public constant ENDPOINT_NILIFY = 9; // (srcEid, sender, nonce, payloadHash): void a verified payload (re-verifiable)
    uint8 public constant ENDPOINT_BURN = 10; // (srcEid, sender, nonce, payloadHash): void it for good

    uint256 public constant MAX_LIMIT = 10_000_000e18;
    uint256 public constant MIN_WINDOW = 1 hours;
    uint256 public constant MAX_WINDOW = 7 days;
    uint8 public constant SHARED_DECIMALS = 6;
    uint256 public constant CONVERSION = 1e12; // 18 local decimals -> 6 shared
    /// @notice Highest per-destination fee: 0.25%, the peg pools' no-surcharge band. A larger fee would let one chain's
    /// price sit outside the band before moving imdUSD between chains pays, so the bridge would stop tying the pegs together.
    uint256 public constant MAX_FEE_BPS = 25;
    /// @notice Least required DVNs on any ULN config (3, following LayerZero's post-Kelp
    /// guidance): the launch set is LayerZero Labs + Twinstake + P2P, so no single operator (LayerZero's own included) is
    /// one of only two. Raising it is a redeploy of the bridge.
    uint8 public constant MIN_REQUIRED_DVNS = 3;
    /// @notice Least block confirmations by SOURCE chain. Ethereum: 15 = LayerZero's default for Ethereum and
    /// the IMD OFT's mainnet -> 4663 value (~3 min; a deeper reorg is bounded by the 4663 inbound limit). Any other source
    /// (4663, an Arbitrum Orbit chain with one sequencer): 20 = LayerZero's default for Arbitrum-family sources; the IMD OFT's
    /// 5 is ~1-2 s of soft confirmations.
    uint64 public constant MIN_CONFIRMATIONS_FROM_ETHEREUM = 15;
    uint64 public constant MIN_CONFIRMATIONS_FROM_OTHER = 20;
    uint32 public constant ETHEREUM_EID = 30101;
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 internal constant CONFIG_TYPE_ULN = 2;
    uint8 internal constant NIL_DVN_COUNT = 255;

    ILayerZeroEndpointV2 public immutable endpoint;
    IMintableBurnable public immutable minterBurner;
    address public immutable guardian;
    /// @notice Where the per-destination fee is minted (this chain's Treasury).
    address public immutable treasury;

    mapping(uint32 eid => bytes32) public peers;
    mapping(uint32 eid => bytes) public enforcedOptions;
    mapping(uint32 eid => bool) public paused;
    mapping(uint32 eid => Limit) public outbound;
    mapping(uint32 eid => Limit) public inbound;
    mapping(uint32 eid => uint16) public feeBps;
    /// @notice The library pinned for each path; zero until the launch BATCH pins it.
    mapping(uint32 eid => address) public sendLibrary;
    mapping(uint32 eid => address) public receiveLibrary;

    /// @notice Cumulative imdUSD minted by inbound messages / burned by sends, here.
    uint256 public received;
    uint256 public sent;
    /// @notice Cumulative fee minted to the Treasury.
    uint256 public fees;

    error OnlyEndpoint();
    error OnlyPeer(uint32 eid, bytes32 sender);
    error NoPeer(uint32 eid);
    error PathPaused(uint32 eid);
    error RateLimited(uint32 eid, uint256 amount, uint256 available);
    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD);
    error ComposeUnsupported();
    error LzTokenUnsupported();
    error BadPayload();
    error OutOfBounds();
    error Unauthorized();
    error UnpinnedLibrary(uint32 eid, address lib);
    /// @notice A SET_CONFIG param below the floors. reason: 1 config type (unknown, or executor on a receive library),
    /// 2 zero executor, 3 required DVN count < MIN_REQUIRED_DVNS or NIL, 4 DVN list length != count, 5 a DVN list not strictly
    /// ascending (zero, repeated or unsorted), 6 confirmations below the source's floor (or NIL), 7 optional DVN count/threshold.
    error WeakConfig(uint8 reason);
    error PathOpen(uint32 eid);
    error NotEnoughNative(uint256 msgValue);
    error ZeroAmount();

    event Sent(bytes32 indexed guid, uint32 indexed dstEid, address indexed from, bytes32 to, uint256 amount);
    event Received(bytes32 indexed guid, uint32 indexed srcEid, address indexed to, uint256 amount);
    event PathSet(uint32 indexed eid, bytes32 peer, uint256 outLimit, uint256 outWindow, uint256 inLimit, uint256 inWindow);
    event Paused(uint32 indexed eid, address by);
    event Unpaused(uint32 indexed eid);
    event FeeSet(uint32 indexed eid, uint256 bps);
    event Voided(uint8 indexed kind, uint32 indexed srcEid, bytes32 sender, uint64 nonce, bytes32 payloadHash);

    constructor(
        ILayerZeroEndpointV2 endpoint_,
        IMintableBurnable token_,
        address governor_,
        address guardian_,
        address treasury_
    ) Governed(governor_) {
        if (address(endpoint_).code.length == 0 || address(token_).code.length == 0 || treasury_ == address(0)) {
            revert BadPayload();
        }
        endpoint = endpoint_;
        minterBurner = token_;
        guardian = guardian_;
        treasury = treasury_;
    }

    // ================================================================ OFT surface

    function token() external view returns (address) {
        return address(minterBurner);
    }

    function approvalRequired() external pure returns (bool) {
        return false;
    }

    function sharedDecimals() external pure returns (uint8) {
        return SHARED_DECIMALS;
    }

    /// @notice OFT's interface id and version (MintBurnOFTAdapter reports the same).
    function oftVersion() external pure returns (bytes4, uint64) {
        return (0x02e49c2c, 1);
    }

    function oAppVersion() external pure returns (uint64 senderVersion, uint64 receiverVersion) {
        return (1, 2);
    }

    /// @notice The endpoint fee for a send of `p`.
    function quoteSend(SendParam calldata p, bool payInLzToken) external view returns (MessagingFee memory) {
        if (payInLzToken) revert LzTokenUnsupported();
        (, uint256 delivered) = _split(p.dstEid, p.amountLD);
        (bytes memory message, bytes memory options) = _build(p, delivered);
        return endpoint.quote(MessagingParams(p.dstEid, _peer(p.dstEid), message, options, false), address(this));
    }

    /// @notice What a send of `amountLD` to `dstEid` burns from the sender and delivers (OFT's `quoteOFT` receipt).
    function quoteOFT(SendParam calldata p) external view returns (OFTReceipt memory) {
        (uint256 burned, uint256 delivered) = _split(p.dstEid, p.amountLD);
        return OFTReceipt(burned, delivered);
    }

    /// @notice Burn `amountLD` (less dust below 1e-6) from the caller and send it, less the destination's fee, to `p.to` on
    /// `p.dstEid`. `minAmountLD` bounds what is delivered.
    function send(SendParam calldata p, MessagingFee calldata fee, address refundAddress)
        external
        payable
        nonReentrant
        returns (MessagingReceipt memory receipt, OFTReceipt memory oft)
    {
        if (fee.lzTokenFee != 0) revert LzTokenUnsupported();
        // exactly the declared fee (OAppSender's rule), so nothing is stranded here for the next sender to spend
        if (msg.value != fee.nativeFee) revert NotEnoughNative(msg.value);
        if (paused[p.dstEid]) revert PathPaused(p.dstEid);
        (uint256 amount, uint256 delivered) = _split(p.dstEid, p.amountLD);
        if (delivered == 0) revert ZeroAmount(); // a zero send is log spam and used to snap the window
        if (delivered < p.minAmountLD) revert SlippageExceeded(delivered, p.minAmountLD);
        _consume(outbound[p.dstEid], p.dstEid, delivered);
        sent += delivered;
        minterBurner.burn(msg.sender, amount);
        if (amount != delivered) {
            fees += amount - delivered;
            minterBurner.mint(treasury, amount - delivered);
        }
        (bytes memory message, bytes memory options) = _build(p, delivered);
        receipt = endpoint.send{value: fee.nativeFee}(
            MessagingParams(p.dstEid, _peer(p.dstEid), message, options, false), refundAddress
        );
        oft = OFTReceipt(amount, delivered);
        emit Sent(receipt.guid, p.dstEid, msg.sender, p.to, delivered);
    }

    // ================================================================ OApp receiver surface

    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return peers[origin.srcEid] == origin.sender && origin.sender != bytes32(0);
    }

    /// @notice Unordered delivery (OApp default).
    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    /// @notice The endpoint delivers a verified packet. Reverting leaves it stored at the endpoint, retryable.
    function lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint();
        bytes32 peer = peers[origin.srcEid];
        if (peer == bytes32(0) || peer != origin.sender) revert OnlyPeer(origin.srcEid, origin.sender);
        if (paused[origin.srcEid]) revert PathPaused(origin.srcEid);
        uint256 amount = uint256(message.amountSD()) * CONVERSION;
        _consume(inbound[origin.srcEid], origin.srcEid, amount);
        address to = message.sendTo().bytes32ToAddress();
        if (to == address(0)) to = address(0xdead); // OFT's rule: _mint(0) is not allowed
        received += amount;
        // A compose payload (our peers never send one) is ignored: the tokens are credited, nothing is called.
        minterBurner.mint(to, amount);
        emit Received(guid, origin.srcEid, to, amount);
    }

    // ================================================================ limits, pause

    /// @notice What may be sent to (or received from) `eid` right now.
    function availableOut(uint32 eid) external view returns (uint256) {
        return _available(outbound[eid]);
    }

    function availableIn(uint32 eid) external view returns (uint256) {
        return _available(inbound[eid]);
    }

    /// @notice Net imdUSD this bridge has put into circulation on this chain: received − sent (the supply equation's term).
    function netMinted() external view returns (int256) {
        return int256(received) - int256(sent);
    }

    function pause(uint32 eid) external {
        if (msg.sender != guardian && msg.sender != governor) revert Unauthorized();
        paused[eid] = true;
        emit Paused(eid, msg.sender);
    }

    /// @notice Void a verified inbound payload now: guardian or governor, like `pause`. Re-verifiable by the DVNs,
    /// so it delays an honest message and kills a forged one; burning for good and skipping go through the timelock.
    function nilify(uint32 srcEid, bytes32 sender, uint64 nonce, bytes32 payloadHash) external {
        if (msg.sender != guardian && msg.sender != governor) revert Unauthorized();
        endpoint.nilify(address(this), srcEid, sender, nonce, payloadHash);
        emit Voided(ENDPOINT_NILIFY, srcEid, sender, nonce, payloadHash);
    }

    // ================================================================ internals

    function _peer(uint32 eid) private view returns (bytes32 peer) {
        peer = peers[eid];
        if (peer == bytes32(0)) revert NoPeer(eid);
    }

    /// @dev (burned, delivered): the dust-free amount and what is left after the fee, itself dust-free (the fee takes the dust).
    function _split(uint32 eid, uint256 amountLD) private view returns (uint256 amount, uint256 delivered) {
        amount = _removeDust(amountLD);
        delivered = _removeDust(amount - amount * feeBps[eid] / 10_000);
    }

    function _removeDust(uint256 amountLD) private pure returns (uint256) {
        uint256 sd = amountLD / CONVERSION;
        if (sd > type(uint64).max) revert OutOfBounds();
        return sd * CONVERSION;
    }

    function _build(SendParam calldata p, uint256 amount) private view returns (bytes memory message, bytes memory options) {
        if (p.composeMsg.length != 0 || p.oftCmd.length != 0) revert ComposeUnsupported();
        (message,) = OFTMsgCodec.encode(p.to, uint64(amount / CONVERSION), "");
        options = _combine(enforcedOptions[p.dstEid], p.extraOptions);
    }

    /// @dev OAppOptionsType3.combineOptions: enforced options first, then the caller's type-3 options without their 2-byte header.
    function _combine(bytes memory enforced, bytes calldata extra) private pure returns (bytes memory) {
        if (enforced.length == 0) return extra;
        if (extra.length == 0) return enforced;
        if (extra.length < 2 || uint16(bytes2(extra[:2])) != 3) revert BadPayload();
        return bytes.concat(enforced, extra[2:]);
    }

    function _available(Limit storage l) private view returns (uint256) {
        uint256 decayed = l.window == 0 ? 0 : uint256(l.limit) * (block.timestamp - l.lastUpdated) / l.window;
        uint256 inFlight = l.inFlight > decayed ? l.inFlight - decayed : 0;
        return l.limit > inFlight ? l.limit - inFlight : 0;
    }

    function _consume(Limit storage l, uint32 eid, uint256 amount) private {
        if (amount == 0) return; // a zero-amount message (inbound) moves no window
        uint256 available = _available(l);
        if (amount > available) revert RateLimited(eid, amount, available);
        l.inFlight = uint128(l.limit - available + amount);
        l.lastUpdated = uint64(block.timestamp);
    }

    // ================================================================ governance (48h)

    function _validate(bytes memory payload) internal view override {
        if (abi.decode(payload, (uint8)) == BATCH) {
            (, bytes[] memory items) = abi.decode(payload, (uint8, bytes[]));
            if (items.length == 0) revert BadPayload();
            for (uint256 i; i < items.length; ++i) {
                if (abi.decode(items[i], (uint8)) == BATCH) revert BadPayload();
                _check(items[i], items);
            }
        } else {
            _check(payload, new bytes[](0));
        }
    }

    /// @dev One item; `batch` = the whole BATCH it belongs to (empty alone), whose library pins count for SET_CONFIG.
    function _check(bytes memory payload, bytes[] memory batch) private view {
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == SET_PATH) {
            (, uint32 eid, bytes32 peer, uint256 outLimit, uint256 outWindow, uint256 inLimit, uint256 inWindow, bytes memory opts) =
                abi.decode(payload, (uint8, uint32, bytes32, uint256, uint256, uint256, uint256, bytes));
            if (eid == 0 || eid == endpoint.eid() || peer == bytes32(0)) revert BadPayload();
            if (outLimit > MAX_LIMIT || inLimit > MAX_LIMIT) revert OutOfBounds();
            if (outWindow < MIN_WINDOW || outWindow > MAX_WINDOW || inWindow < MIN_WINDOW || inWindow > MAX_WINDOW) {
                revert OutOfBounds();
            }
            if (opts.length != 0 && (opts.length < 2 || uint16(bytes2(opts)) != 3)) revert BadPayload();
        } else if (kind == SET_CONFIG) {
            (, address lib, SetConfigParam[] memory params) = abi.decode(payload, (uint8, address, SetConfigParam[]));
            if (lib.code.length == 0) revert BadPayload();
            for (uint256 i; i < params.length; ++i) {
                uint32 eid = params[i].eid;
                bool isSend = lib == _pinned(SET_SEND_LIBRARY, eid, batch);
                if (!isSend && lib != _pinned(SET_RECEIVE_LIBRARY, eid, batch)) revert UnpinnedLibrary(eid, lib);
                uint32 t = params[i].configType;
                if (t == CONFIG_TYPE_ULN) {
                    // confirmations are counted on the SOURCE chain: this one for a send library, `eid` for a receive one
                    _checkUln(params[i].config, (isSend ? endpoint.eid() : eid) == ETHEREUM_EID);
                } else if (t == CONFIG_TYPE_EXECUTOR && isSend) {
                    (, address executor) = abi.decode(params[i].config, (uint32, address));
                    if (executor == address(0)) revert WeakConfig(2);
                } else {
                    revert WeakConfig(1);
                }
            }
        } else if (kind == SET_SEND_LIBRARY || kind == SET_RECEIVE_LIBRARY) {
            (, uint32 eid, address lib) = abi.decode(payload, (uint8, uint32, address));
            if (lib.code.length == 0 || eid == 0 || eid == endpoint.eid()) revert BadPayload();
        } else if (kind == SET_FEE) {
            (, uint32 eid, uint256 bps) = abi.decode(payload, (uint8, uint32, uint256));
            if (eid == 0 || eid == endpoint.eid()) revert BadPayload();
            if (bps > MAX_FEE_BPS) revert OutOfBounds();
        } else if (kind == ENDPOINT_SKIP || kind == ENDPOINT_NILIFY || kind == ENDPOINT_BURN) {
            (, uint32 eid) = abi.decode(payload, (uint8, uint32));
            if (eid == 0 || eid == endpoint.eid()) revert BadPayload();
            if (!paused[eid]) revert PathOpen(eid);
        } else if (kind != UNPAUSE) {
            revert BadPayload();
        }
    }

    function _checkUln(bytes memory config, bool fromEthereum) private pure {
        UlnConfig memory u = abi.decode(config, (UlnConfig));
        if (u.requiredDVNCount < MIN_REQUIRED_DVNS || u.requiredDVNCount == NIL_DVN_COUNT) revert WeakConfig(3);
        if (u.requiredDVNs.length != u.requiredDVNCount) revert WeakConfig(4);
        _ascending(u.requiredDVNs);
        uint64 floor_ = fromEthereum ? MIN_CONFIRMATIONS_FROM_ETHEREUM : MIN_CONFIRMATIONS_FROM_OTHER;
        if (u.confirmations < floor_ || u.confirmations == type(uint64).max) revert WeakConfig(6);
        if (
            u.optionalDVNs.length != u.optionalDVNCount || u.optionalDVNThreshold > u.optionalDVNCount
                || (u.optionalDVNCount != 0 && u.optionalDVNThreshold == 0)
        ) revert WeakConfig(7);
        _ascending(u.optionalDVNs);
    }

    /// @dev Strictly ascending from above zero: no zero address, no repeat (a repeat would count one DVN twice).
    function _ascending(address[] memory dvns) private pure {
        address prev;
        for (uint256 i; i < dvns.length; ++i) {
            if (dvns[i] <= prev) revert WeakConfig(5);
            prev = dvns[i];
        }
    }

    /// @dev The library `kind` (SET_SEND_LIBRARY / SET_RECEIVE_LIBRARY) pins for `eid` once `batch` is applied: the last such
    /// item in the batch, else what is pinned now.
    function _pinned(uint8 kind, uint32 eid, bytes[] memory batch) private view returns (address lib) {
        lib = kind == SET_SEND_LIBRARY ? sendLibrary[eid] : receiveLibrary[eid];
        for (uint256 i; i < batch.length; ++i) {
            if (abi.decode(batch[i], (uint8)) != kind) continue;
            (, uint32 e, address l) = abi.decode(batch[i], (uint8, uint32, address));
            if (e == eid) lib = l;
        }
    }

    function _apply(bytes memory payload) internal override {
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == BATCH) {
            (, bytes[] memory items) = abi.decode(payload, (uint8, bytes[]));
            for (uint256 i; i < items.length; ++i) {
                _apply(items[i]);
            }
        } else if (kind == SET_PATH) {
            (, uint32 eid, bytes32 peer, uint256 outLimit, uint256 outWindow, uint256 inLimit, uint256 inWindow, bytes memory opts) =
                abi.decode(payload, (uint8, uint32, bytes32, uint256, uint256, uint256, uint256, bytes));
            peers[eid] = peer;
            enforcedOptions[eid] = opts;
            _setLimit(outbound[eid], outLimit, outWindow);
            _setLimit(inbound[eid], inLimit, inWindow);
            emit PathSet(eid, peer, outLimit, outWindow, inLimit, inWindow);
        } else if (kind == SET_CONFIG) {
            (, address lib, SetConfigParam[] memory params) = abi.decode(payload, (uint8, address, SetConfigParam[]));
            endpoint.setConfig(address(this), lib, params);
        } else if (kind == SET_SEND_LIBRARY) {
            (, uint32 eid, address lib) = abi.decode(payload, (uint8, uint32, address));
            sendLibrary[eid] = lib;
            endpoint.setSendLibrary(address(this), eid, lib);
        } else if (kind == SET_RECEIVE_LIBRARY) {
            (, uint32 eid, address lib, uint256 grace) = abi.decode(payload, (uint8, uint32, address, uint256));
            receiveLibrary[eid] = lib;
            endpoint.setReceiveLibrary(address(this), eid, lib, grace);
        } else if (kind == SET_FEE) {
            (, uint32 eid, uint256 bps) = abi.decode(payload, (uint8, uint32, uint256));
            feeBps[eid] = uint16(bps);
            emit FeeSet(eid, bps);
        } else if (kind == ENDPOINT_SKIP) {
            (, uint32 eid, bytes32 sender, uint64 nonce) = abi.decode(payload, (uint8, uint32, bytes32, uint64));
            endpoint.skip(address(this), eid, sender, nonce);
            emit Voided(kind, eid, sender, nonce, bytes32(0));
        } else if (kind == ENDPOINT_NILIFY || kind == ENDPOINT_BURN) {
            (, uint32 eid, bytes32 sender, uint64 nonce, bytes32 h) =
                abi.decode(payload, (uint8, uint32, bytes32, uint64, bytes32));
            if (kind == ENDPOINT_NILIFY) endpoint.nilify(address(this), eid, sender, nonce, h);
            else endpoint.burn(address(this), eid, sender, nonce, h);
            emit Voided(kind, eid, sender, nonce, h);
        } else {
            (, uint32 eid) = abi.decode(payload, (uint8, uint32));
            paused[eid] = false;
            emit Unpaused(eid);
        }
    }

    /// @dev A new limit keeps what is in flight (decayed to now), so changing a limit cannot reset the window. LOWERING it
    /// scales what is in flight by new/old: the FRACTION of the window used is kept, so a full window stays full
    /// for one window at the new rate instead of old/new windows (a 50x cut used to shut the path for 50 days). Raising keeps
    /// the absolute amount (the extra room is the point of a raise).
    function _setLimit(Limit storage l, uint256 limit, uint256 window) private {
        uint256 decayed = l.window == 0 ? 0 : uint256(l.limit) * (block.timestamp - l.lastUpdated) / l.window;
        uint256 inFlight = l.inFlight > decayed ? l.inFlight - decayed : 0;
        if (limit < l.limit) inFlight = inFlight * limit / l.limit;
        l.inFlight = uint128(inFlight);
        l.lastUpdated = uint64(block.timestamp);
        l.limit = uint128(limit);
        l.window = uint32(window);
    }
}
