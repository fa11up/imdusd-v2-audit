// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatAccount, IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";

/// @notice The pairing digest against a vector computed by the PLANE's own TypeScript:
/// `hashTypedData(workerAuthorizationTypedData({chainId: 1, verifyingContract: IDMD}, message))` from
/// Identity-md/protocol packages/protocol/src/eip712.ts, run with viem (2026-10-21), message:
///   deviceKey = keccak256("device-key"), wallet = 0x1111…1111, tokenId = "1343",
///   nonce = keccak256("nonce"), expiresAt = 1800003600, relayOrigin = "https://api.imd.fun".
contract SeatDigestTest is Test {
    address constant IDMD = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    bytes32 constant PLANE_DIGEST = 0xb4e5e0f756c1533aa83f20c580898b17d9604c32bc0d15a98651daa93753e7a7;

    function test_digestMatchesPlaneTypeScript() public {
        vm.chainId(1);
        SeatAccount impl = new SeatAccount(address(this), IERC721(IDMD), IImdAgentAdapter(address(0)));
        SeatAccount.WorkerAuthorization memory a = SeatAccount.WorkerAuthorization({
            deviceKey: keccak256("device-key"),
            wallet: 0x1111111111111111111111111111111111111111,
            tokenId: 1343,
            nonce: keccak256("nonce"),
            expiresAt: 1800003600,
            relayOrigin: "https://api.imd.fun"
        });
        assertEq(a.deviceKey, 0x5c68d51e58ccaf6d7617128f40ba211f8933b0c1ed83fccbf9500aaa5355110d);
        assertEq(impl.workerAuthorizationDigest(a), PLANE_DIGEST);
    }
}
