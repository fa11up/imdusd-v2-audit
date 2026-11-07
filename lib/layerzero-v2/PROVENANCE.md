LayerZero V2 interfaces and the OFT message codec, the minimum imdUSD v2's bridge (src/bridge/ImdBridge.sol) needs to speak
the OFT wire format to a real `EndpointV2`. Copied 2026-10-21 from the npm tarballs (every file below is `SPDX-License-Identifier: MIT`):

| File | Package | Notes |
|---|---|---|
| protocol/interfaces/ILayerZeroEndpointV2.sol, IMessageLibManager.sol, IMessagingChannel.sol, IMessagingComposer.sol, IMessagingContext.sol, ILayerZeroReceiver.sol | `@layerzerolabs/lz-evm-protocol-v2@3.0.168` (`contracts/interfaces/`) | verbatim. The package's `license` field is LZBL-1.2 for the protocol IMPLEMENTATION; these interface files carry MIT headers. No implementation (EndpointV2, ULN, DVN) is vendored. |
| oft/libs/OFTMsgCodec.sol | `@layerzerolabs/oft-evm@4.0.1` (MIT) | verbatim |
| oft/interfaces/IOFT.sol | `@layerzerolabs/oft-evm@4.0.1` (MIT) | ONE line changed: its import of `MessagingReceipt, MessagingFee` points at `ILayerZeroEndpointV2.sol` (where they are defined) instead of `oapp-evm`'s `OAppSender.sol`, which only re-exports them and would pull in `Ownable` |

Not vendored on purpose: `OAppCore`/`OApp`/`OFTCore`/`MintBurnOFTAdapter`. They are `Ownable` (peers, delegate, enforced options,
msg inspector are `onlyOwner`), and imdUSD v2 has no `owner()`: every such power goes through a 48h `Governed` timelock. ImdBridge
re-implements the same receive/send path (OApp version 1/2, `allowInitializePath`, `nextNonce`, OFT `send`/`quoteSend`, 6 shared
decimals, dust removal) on top of these files, so a standard OFT peer and the real endpoint see the same messages.

sha256 (vendored copies):
9544e8b7296bd5aee79e3f2241189b22f6402ff781b38329d2a0a31c90e454e0  ./oft/interfaces/IOFT.sol
3e6dfff6595f8af1c1618a80e30efd16f117652e1fd73ffb1f6795dcc443d658  ./oft/libs/OFTMsgCodec.sol
a88fb702b371527c3791d7e5c168c1157d39021ed29b51e627e02973e6a740e0  ./protocol/interfaces/ILayerZeroEndpointV2.sol
24e4add7dd95a72dad23e26c4fadfc1b6ce63148e0c7f4d6ad5dfaeda79db3e7  ./protocol/interfaces/ILayerZeroReceiver.sol
ffc33e319ab5e9d1392d16f8716625bcfb1dc34b744551f87dad1c0eb3ad11f1  ./protocol/interfaces/IMessageLibManager.sol
9d0100f7cede83d5a4f6c9e03d6bfd24f861e9331b298ca4c73f99b161c718d5  ./protocol/interfaces/IMessagingChannel.sol
5e7e5a47a477dcf05c034d5135bf6516119af881ea78d586805eee0ad5ab6b12  ./protocol/interfaces/IMessagingComposer.sol
b7f081828b8d0d206833953ebd73101bb28ac62541e7e8365fddc38eb440a92a  ./protocol/interfaces/IMessagingContext.sol
