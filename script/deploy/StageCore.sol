// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Pricer} from "../../src/Pricer.sol";
import {Pulse} from "../../src/Pulse.sol";
import {Treasury, ICoverable} from "../../src/Treasury.sol";
import {Ledger, IPulse} from "../../src/Ledger.sol";
import {PositionNFT} from "../../src/PositionNFT.sol";
import {Redeemer} from "../../src/Redeemer.sol";
import {Liquidator} from "../../src/Liquidator.sol";
import {Migrator} from "../../src/Migrator.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";

/// @notice Stage 1, the core: (Pulse where the chain needs one,) ImdUSD, Parameters, Pricer, Treasury, Ledger (+ its
/// SortedPositions), Redeemer, Liquidator, Migrator and the four wire calls, in test/utils/System.sol's order.
abstract contract StageCore is DeployBase {
    function _stageCore(DeployTypes.Config memory cfg, Deployed memory d, address me) internal {
        if (cfg.chain.chainId != 0 && block.chainid != cfg.chain.chainId) revert WrongChain(cfg.chain.chainId, block.chainid);
        uint256 g;
        // 0. The sequencer-outage grace, where the chain needs one: the Ledger pokes it on every accrual.
        if (cfg.chain.pulse && !_has(address(d.pulse))) {
            g = gasleft();
            d.pulse = _newPulse(cfg.chain.pulseGap, cfg.chain.pulseGrace);
            _rec("Pulse", g, type(Pulse).creationCode.length + 64);
        }
        // 1. Core, in System.sol order.
        if (!(_has(address(d.usd)) && _ok(d.usd.wirer() == me && d.usd.flashCap() == cfg.flashCap, "ImdUSD"))) {
            g = gasleft();
            d.usd = new ImdUSD(me, cfg.flashCap);
            _rec("ImdUSD", g, type(ImdUSD).creationCode.length + 64);
        }
        if (!(_has(address(d.params)) && _ok(d.params.wirer() == me && d.params.governor() == cfg.governor, "Parameters"))) {
            g = gasleft();
            d.params = new Parameters(cfg.governor, me);
            _rec("Parameters", g, type(Parameters).creationCode.length + 64);
        }
        if (!(_has(address(d.pricer)) && _ok(d.pricer.params() == d.params, "Pricer"))) {
            g = gasleft();
            d.pricer = new Pricer(d.params);
            _rec("Pricer", g, type(Pricer).creationCode.length + 32);
        }
        if (
            !(_has(address(d.treasury)) && _ok(d.treasury.wirer() == me && d.treasury.governor() == cfg.governor
                    && address(d.treasury.token()) == address(d.usd),
                "Treasury"))
        ) {
            g = gasleft();
            d.treasury = new Treasury(cfg.governor, IERC20(address(d.usd)), me);
            _rec("Treasury", g, type(Treasury).creationCode.length + 96);
        }
        if (
            !(_has(address(d.ledger)) && _ok(d.ledger.token() == d.usd && d.ledger.params() == d.params && d.ledger.pricer() == d.pricer
                    && d.ledger.treasury() == address(d.treasury) && d.ledger.wirer() == me
                    && address(d.ledger.pulse()) == address(d.pulse),
                "Ledger"))
        ) {
            g = gasleft();
            PositionNFT nft_ = new PositionNFT(me); // first, so the Ledger's creation code stays under EIP-3860
            _rec("PositionNFT", g, type(PositionNFT).creationCode.length + 32);
            g = gasleft();
            d.ledger = new Ledger(d.usd, d.params, d.pricer, address(d.treasury), me, IPulse(address(d.pulse)), nft_);
            _rec("Ledger (+SortedPositions, LedgerSettlement)", g, type(Ledger).creationCode.length + 192);
        }
        if (d.ledger.nft().ledger() == address(0)) {
            g = gasleft();
            d.ledger.nft().bind(address(d.ledger));
            _rec("positionNFT.bind", g, CALL_DATA); // in the gas log like every other broadcast (audit wave 1)
        }
        if (!(_has(address(d.redeemer)) && _ok(d.redeemer.ledger() == d.ledger, "Redeemer"))) {
            g = gasleft();
            d.redeemer = new Redeemer(d.ledger);
            _rec("Redeemer", g, type(Redeemer).creationCode.length + 32);
        }
        if (!(_has(address(d.liquidator)) && _ok(d.liquidator.ledger() == d.ledger && d.liquidator.pricer() == d.pricer, "Liquidator")))
        {
            g = gasleft();
            d.liquidator = new Liquidator(d.ledger, d.pricer);
            _rec("Liquidator", g, type(Liquidator).creationCode.length + 64);
        }
        if (d.ledger.redeemer() == address(0)) {
            g = gasleft();
            d.ledger.wire(address(d.redeemer), address(d.liquidator));
            _rec("ledger.wire", g, CALL_DATA);
        } else if (d.ledger.redeemer() != address(d.redeemer) || d.ledger.liquidator() != address(d.liquidator)) {
            revert Mismatch("Ledger wired to another Redeemer/Liquidator");
        }
        if (
            !(_has(address(d.migrator)) && _ok(address(d.migrator.v1()) == cfg.v1 && d.migrator.v2() == d.usd && d.migrator.params() == d.params,
                "Migrator"))
        ) {
            g = gasleft();
            d.migrator = new Migrator(IERC20(cfg.v1), d.usd, d.params);
            _rec("Migrator", g, type(Migrator).creationCode.length + 96);
        }
        if (d.usd.ledger() == address(0)) {
            g = gasleft();
            d.usd.wire(address(d.ledger), address(d.migrator), address(d.params));
            _rec("usd.wire", g, CALL_DATA);
        } else if (
            d.usd.ledger() != address(d.ledger) || d.usd.migrator() != address(d.migrator)
                || d.usd.bridgeSetter() != address(d.params)
        ) {
            revert Mismatch("ImdUSD wired to other contracts");
        }
        if (d.params.ledger() == address(0)) {
            g = gasleft();
            d.params.wire(address(d.ledger), address(d.usd));
            _rec("params.wire", g, CALL_DATA);
        } else if (d.params.ledger() != address(d.ledger) || d.params.token() != address(d.usd)) {
            revert Mismatch("Parameters wired to other contracts");
        }
        if (address(d.treasury.ledger()) == address(0)) {
            g = gasleft();
            d.treasury.wire(ICoverable(address(d.ledger)));
            _rec("treasury.wire", g, CALL_DATA);
        } else if (address(d.treasury.ledger()) != address(d.ledger)) {
            revert Mismatch("Treasury wired to another Ledger");
        }
    }
}
