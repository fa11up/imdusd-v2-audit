// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MessagingParams, MessagingReceipt, MessagingFee, Origin} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {ILayerZeroReceiver} from "layerzero-v2/protocol/interfaces/ILayerZeroReceiver.sol";

/// @notice A LayerZero EndpointV2 stand-in for two chains in one EVM: `send` queues a packet (in flight), `deliver` hands it to
/// the destination endpoint, which calls the receiver's `lzReceive` AS that endpoint. A reverting delivery leaves the packet
/// in flight, retryable, as the real endpoint stores a verified payload until `lzReceive` succeeds. What is NOT modelled:
/// DVN verification, the executor, nonce ordering (ImdBridge is unordered), fees beyond a flat native fee.
contract MockLzEndpoint {
    struct Packet {
        uint32 dstEid;
        bytes32 receiver;
        bytes32 sender;
        uint64 nonce;
        bytes32 guid;
        bytes message;
        bytes options;
        bool delivered;
    }

    uint32 public immutable eid;
    uint256 public constant FEE = 0.0001 ether;

    mapping(uint32 eid => MockLzEndpoint) public remotes;
    Packet[] public packets;
    uint64 public nonce;

    // what the OApp configured through `setConfig` & co (recorded, not enforced)
    mapping(address oapp => uint256) public configCalls;
    mapping(address oapp => mapping(uint32 eid => address)) public sendLibrary;
    mapping(address oapp => mapping(uint32 eid => address)) public receiveLibrary;

    error InsufficientFee();
    error NotRemote();

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function link(MockLzEndpoint other) external {
        remotes[other.eid()] = other;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(FEE, 0);
    }

    function send(MessagingParams calldata p, address refund) external payable returns (MessagingReceipt memory r) {
        if (msg.value < FEE) revert InsufficientFee();
        uint64 n = ++nonce;
        bytes32 guid = keccak256(abi.encodePacked(n, eid, msg.sender, p.dstEid, p.receiver));
        packets.push(Packet(p.dstEid, p.receiver, bytes32(uint256(uint160(msg.sender))), n, guid, p.message, p.options, false));
        if (msg.value > FEE) {
            (bool ok,) = refund.call{value: msg.value - FEE}("");
            ok;
        }
        r = MessagingReceipt(guid, n, MessagingFee(FEE, 0));
    }

    /// @notice Hand packet `i` to its destination. Returns false (and keeps it in flight) if the receiver reverted.
    function deliver(uint256 i) external returns (bool ok) {
        Packet storage p = packets[i];
        if (p.delivered) return true;
        ok = remotes[p.dstEid].receivePacket(Origin(eid, p.sender, p.nonce), p.receiver, p.guid, p.message);
        if (ok) p.delivered = true;
    }

    function receivePacket(Origin calldata origin, bytes32 receiver, bytes32 guid, bytes calldata message)
        external
        returns (bool ok)
    {
        if (address(remotes[origin.srcEid]) != msg.sender) revert NotRemote();
        address to = address(uint160(uint256(receiver)));
        if (!ILayerZeroReceiver(to).allowInitializePath(origin)) return false;
        if (voided[to][origin.srcEid][origin.sender][origin.nonce] != 0) return false;
        try ILayerZeroReceiver(to).lzReceive(origin, guid, message, address(this), "") {
            ok = true;
        } catch {
            ok = false;
        }
    }

    // ---- channel acts: skip / nilify / burn an inbound nonce, by the receiving OApp only. A voided nonce is
    // refused on delivery; a nilified one can be re-verified (`reverify`), a burned or skipped one never.

    /// @notice 1 skipped, 2 nilified, 3 burned; keyed by (receiver, srcEid, sender, nonce) on the RECEIVING endpoint.
    mapping(address oapp => mapping(uint32 srcEid => mapping(bytes32 sender => mapping(uint64 nonce => uint8)))) public voided;

    function skip(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce_) external {
        if (msg.sender != oapp) revert NotRemote();
        voided[oapp][srcEid][sender][nonce_] = 1;
    }

    function nilify(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce_, bytes32) external {
        if (msg.sender != oapp) revert NotRemote();
        voided[oapp][srcEid][sender][nonce_] = 2;
    }

    function burn(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce_, bytes32) external {
        if (msg.sender != oapp) revert NotRemote();
        voided[oapp][srcEid][sender][nonce_] = 3;
    }

    /// @notice The DVNs verify a nilified nonce again (test stand-in).
    function reverify(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce_) external {
        if (voided[oapp][srcEid][sender][nonce_] == 2) voided[oapp][srcEid][sender][nonce_] = 0;
    }

    /// @notice A packet a compromised DVN set verified: claims to come from `sender` on this endpoint's chain (test stand-in).
    function forge(uint32 dstEid, bytes32 receiver, bytes32 sender, bytes calldata message) external returns (uint256 i) {
        uint64 n = ++nonce;
        bytes32 guid = keccak256(abi.encodePacked("forged", n));
        packets.push(Packet(dstEid, receiver, sender, n, guid, message, "", false));
        i = packets.length - 1;
    }

    function packetCount() external view returns (uint256) {
        return packets.length;
    }

    /// @notice Amount (18 decimals) in packet `i`, from the OFT message (`bytes32 to ‖ uint64 amountSD`).
    function amountOf(uint256 i) external view returns (uint256) {
        bytes memory m = packets[i].message;
        uint64 sd;
        assembly {
            sd := shr(192, mload(add(m, 64)))
        }
        return uint256(sd) * 1e12;
    }

    function isDelivered(uint256 i) external view returns (bool) {
        return packets[i].delivered;
    }

    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external {
        if (msg.sender != oapp) revert NotRemote();
        configCalls[oapp]++;
        for (uint256 i; i < params.length; ++i) {
            configs[oapp][lib][params[i].eid][params[i].configType] = params[i].config;
        }
    }

    // ---- default libraries: an OApp with no pinned library follows the endpoint owner's default, and config
    // is stored PER LIBRARY, so a default move leaves such an OApp on a library where it has no config of its own.

    mapping(uint32 eid => address) public defaultSendLibrary;
    mapping(uint32 eid => address) public defaultReceiveLibrary;
    mapping(address oapp => mapping(address lib => mapping(uint32 eid => mapping(uint32 configType => bytes)))) internal configs;

    /// @notice Test stand-in for LayerZero's owner-only `setDefaultSendLibrary`/`setDefaultReceiveLibrary`.
    function setDefaultLibraries(uint32 eid_, address sendLib, address receiveLib) external {
        defaultSendLibrary[eid_] = sendLib;
        defaultReceiveLibrary[eid_] = receiveLib;
    }

    function getSendLibrary(address oapp, uint32 eid_) external view returns (address lib) {
        lib = sendLibrary[oapp][eid_];
        if (lib == address(0)) lib = defaultSendLibrary[eid_];
    }

    function getReceiveLibrary(address oapp, uint32 eid_) public view returns (address lib, bool isDefault) {
        lib = receiveLibrary[oapp][eid_];
        if (lib == address(0)) (lib, isDefault) = (defaultReceiveLibrary[eid_], true);
    }

    function getConfig(address oapp, address lib, uint32 eid_, uint32 configType) external view returns (bytes memory) {
        return configs[oapp][lib][eid_][configType];
    }

    /// @notice The ULN config that verifies `oapp`'s inbound packets from `eid_` right now (empty = the library's defaults).
    function effectiveReceiveConfig(address oapp, uint32 eid_) external view returns (bytes memory) {
        (address lib,) = getReceiveLibrary(oapp, eid_);
        return configs[oapp][lib][eid_][2];
    }

    function setSendLibrary(address oapp, uint32 eid_, address lib) external {
        if (msg.sender != oapp) revert NotRemote();
        sendLibrary[oapp][eid_] = lib;
    }

    function setReceiveLibrary(address oapp, uint32 eid_, address lib, uint256) external {
        if (msg.sender != oapp) revert NotRemote();
        receiveLibrary[oapp][eid_] = lib;
    }
}

/// @notice A stand-in message library (only its code matters: ImdBridge refuses a library address with no code).
contract MockMessageLib {
    function messageLibType() external pure returns (uint8) {
        return 2;
    }
}
