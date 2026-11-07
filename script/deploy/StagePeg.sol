// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Join} from "../../src/Join.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {PegShareFeed, IPegVaultRead} from "../../src/earn/PegShareFeed.sol";
import {PegPositionZap, IPegZapVault, IPegZapLedger} from "../../src/earn/PegPositionZap.sol";
import {PegCollateral} from "../../src/earn/PegCollateral.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";

/// @notice Stage 5c: peg positions. On the PegLPVault deployed in 5b, before the seal: the collateral wrapper,
/// the share feed, a Join for the wrapper, the type (genesis, no timelock) and the zap. Re-run safe: each piece is skipped once it exists.
abstract contract StagePeg is DeployBase {
    function _stagePeg(DeployTypes.Config memory cfg, Deployed memory d) internal {
        if (!cfg.pegPositions.enabled) return;
        if (address(d.pegLP) == address(0)) revert ModuleNeeds("pegPositions", "lpVault");
        bytes32 ilk = cfg.pegPositions.ilk;
        uint256 g;
        // A type already registered names its feed and join: a resume adopts those, never orphan copies.
        if (d.params.exists(ilk)) {
            ParametersBase.Config memory c = d.params.config(ilk);
            if (!_has(address(d.pegCollateral))) d.pegCollateral = PegCollateral(c.token);
            if (!_has(address(d.pegFeed))) d.pegFeed = PegShareFeed(address(c.median));
            if (!_has(address(d.pegJoin))) d.pegJoin = Join(c.join);
        }
        if (!(_has(address(d.pegCollateral)) && _ok(address(d.pegCollateral.shares()) == address(d.pegLP) && d.pegCollateral.wirer() == d.params.wirer(), "PegCollateral"))) {
            g = gasleft();
            d.pegCollateral = new PegCollateral(IERC20(address(d.pegLP)), d.params.wirer());
            _rec("PegCollateral", g, type(PegCollateral).creationCode.length + 64);
        }
        if (!(_has(address(d.pegFeed)) && _ok(address(d.pegFeed.vault()) == address(d.pegLP), "PegShareFeed"))) {
            g = gasleft();
            d.pegFeed = new PegShareFeed(
                IPegVaultRead(address(d.pegLP)), address(d.usd), cfg.pegQuoteFeed, cfg.pegQuoteFeedMaxAge, false
            );
            _rec("PegShareFeed", g, type(PegShareFeed).creationCode.length + 128);
        }
        if (!(_has(address(d.pegJoin)) && _ok(d.pegJoin.token() == address(d.pegCollateral) && d.pegJoin.wirer() == d.params.wirer(), "peg Join"))) {
            g = gasleft();
            d.pegJoin = new Join(address(d.pegCollateral), d.params.wirer());
            _rec("Join (PEG)", g, type(Join).creationCode.length + 64);
        }
        if (d.pegJoin.ledger() == address(0)) {
            g = gasleft();
            d.pegJoin.wire(address(d.ledger));
            _rec("pegJoin.wire", g, CALL_DATA);
        }
        if (!d.params.exists(ilk)) {
            g = gasleft();
            // The spot leg, the full value while the vault is two-sided, else 0; found again on resume as
            // config(PEG).spot.
            PegShareFeed spotLeg = new PegShareFeed(
                IPegVaultRead(address(d.pegLP)), address(d.usd), cfg.pegQuoteFeed, cfg.pegQuoteFeedMaxAge, true
            );
            _rec("PegShareFeed (spot leg)", g, type(PegShareFeed).creationCode.length + 160);
            g = gasleft();
            d.params.addGenesisIlk(
                ilk,
                ParametersBase.Config({
                    token: address(d.pegCollateral),
                    join: address(d.pegJoin),
                    median: IFeed(address(d.pegFeed)),
                    spot: IFeed(address(spotLeg)),
                    nhi: IFeed(address(0)),
                    yieldRate: address(0),
                    pegAggregator: cfg.pegQuoteFeed,
                    liveSpot: IFeed(address(0)),
                    redeemable: false,
                    auction: false
                }),
                cfg.pegPositions.risk
            );
            _rec("params.addGenesisIlk(PEG)", g, CALL_DATA + 800);
        }
        // Round 3 L4: setZap landed and the record lost the zap: the wrapper names it, once and for good. Adopt it, no orphan.
        if (!_has(address(d.pegZap)) && d.pegCollateral.zap() != address(0)) d.pegZap = PegPositionZap(d.pegCollateral.zap());
        if (!(_has(address(d.pegZap)) && _ok(d.pegZap.ilk() == ilk && address(d.pegZap.collateral()) == address(d.pegCollateral), "PegPositionZap"))) {
            g = gasleft();
            d.pegZap = new PegPositionZap(
                IERC20(address(d.usd)), IPegZapVault(address(d.pegLP)), d.pegCollateral, IPegZapLedger(address(d.ledger)), ilk
            );
            _rec("PegPositionZap", g, type(PegPositionZap).creationCode.length + 160);
        }
        if (d.pegCollateral.zap() == address(0)) {
            g = gasleft();
            d.pegCollateral.setZap(address(d.pegZap));
            _rec("pegCollateral.setZap", g, CALL_DATA);
        }
    }
}
