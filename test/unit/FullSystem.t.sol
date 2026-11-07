// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullSystem} from "../utils/FullSystem.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Parameters} from "../../src/Parameters.sol";

/// @notice The offline full system is the real script's output: every module wired, every authority the Safe, and
/// every transaction (seats included) under the EIP-7825 cap with forge's 1.3x margin.
contract FullSystemTest is FullSystem {
    function setUp() public {
        _deployFull();
    }

    function test_everyModuleDeployedAndWired() public view {
        assertEq(d.params.ilkCount(), 4, "ETH, S-USDC, SIMD, SEAT");
        assertTrue(d.params.config(SEAT).auction);
        assertEq(address(d.loop.ledger()), address(d.ledger));
        assertEq(address(d.pegLP.hook()), address(d.hook));
        assertEq(d.dexHook.treasury(), address(d.treasury));
        assertEq(address(d.dexHook.vault0()), address(sinfer), "INFER sorts first, as on mainnet");
        assertEq(address(d.seatJoin.ledger()), address(d.ledger));
        assertEq(d.params.governor(), safe);
        assertEq(d.treasury.governor(), safe);
        assertTrue(d.params.sealed_());
        address[8] memory all = [
            address(d.usd), address(d.ledger), address(d.treasury), address(d.pegLP), address(d.loop),
            address(d.dexHook), address(d.seatJoin), address(d.hook)
        ];
        for (uint256 i; i < all.length; ++i) {
            (bool ok,) = all[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "owner() exists");
        }
    }

    function test_seatsOnDeployFitsTheEip7825Cap() public {
        Deploy.GasRow[] memory rows = script.gasLog();
        uint256 total;
        uint256 largest;
        for (uint256 i; i < rows.length; ++i) {
            total += rows[i].gas;
            if (rows[i].gas > largest) largest = rows[i].gas;
            assertLe(rows[i].gas * 13 / 10, 16_777_216, rows[i].label);
        }
        emit log_named_uint("transactions", rows.length);
        emit log_named_uint("total gas", total);
        emit log_named_uint("largest gas", largest);
    }

    function test_supplyEquationAtGenesis() public {
        _assertSupply();
        assertEq(d.usd.totalSupply(), 0);
    }
}
