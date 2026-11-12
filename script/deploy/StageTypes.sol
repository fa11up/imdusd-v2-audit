// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Join} from "../../src/Join.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";
import {SeatFeed, SeatSpotLeg} from "../../src/feeds/SeatFeed.sol";
import {DeployTypes} from "../DeployConfig.sol";
import {DeployBase} from "./DeployBase.sol";

/// @notice Stage 3, the collateral types: one join per type, wired, registered at genesis; the seat and stock modules
/// where a config turns them on; the chain's debt cap where capped; and the migrator line (0 in the beta).
abstract contract StageTypes is DeployBase {
    /// @notice The migrator line set at genesis: 0 when the config keeps migration closed, else the
    /// config's floor, or twice v1's supply at the deploy block if that is higher, so v1 growth between now and
    /// deployment can never leave holders unable to migrate.
    function migratorLineFor(DeployTypes.Config memory cfg) public view returns (uint256) {
        if (cfg.migratorClosed) return 0;
        uint256 twice = 2 * IERC20(cfg.v1).totalSupply();
        return twice > cfg.migratorLine ? twice : cfg.migratorLine;
    }

    function _stageTypes(DeployTypes.Config memory cfg, Deployed memory d, address me) internal {
        uint256 g;
        // 3. Collateral types: one join each, wired, then registered at genesis.
        Join[] memory recorded = d.joins;
        d.joins = new Join[](cfg.ilks.length);
        for (uint256 i; i < cfg.ilks.length; ++i) {
            DeployTypes.IlkSpec memory s = cfg.ilks[i];
            Join join = i < recorded.length ? recorded[i] : Join(address(0));
            if (!(_has(address(join)) && _ok(join.token() == s.token && join.wirer() == me, "Join"))) {
                g = gasleft();
                join = new Join(s.token, me);
                _rec("Join", g, type(Join).creationCode.length + 64);
            }
            if (join.ledger() == address(0)) {
                g = gasleft();
                join.wire(address(d.ledger));
                _rec("join.wire", g, CALL_DATA);
            } else if (join.ledger() != address(d.ledger)) {
                revert Mismatch("Join wired to another Ledger");
            }
            d.joins[i] = join;
            ParametersBase.Config memory want = _ilkConfig(s, address(join), d.feeds);
            if (!d.params.exists(s.ilk)) {
                g = gasleft();
                d.params.addGenesisIlk(s.ilk, want, s.risk);
                _rec("params.addGenesisIlk", g, 1_000);
            } else {
                _sameIlk(d.params, s.ilk, want, s.risk);
            }
        }

        // 3b. The seat type: its join is its own collateral token. Its legs may be empty here (the beta): the
        // type then prices at 0 until the first median + spot are relayed.
        if (cfg.seats.enabled) _deploySeats(cfg, d, me);
        // 3b'. Stock tokens (Robinhood): vault + market-hours feed + capped rate + USDG auction join per type.
        if (cfg.stocks.types.length != 0) _deployStocks(cfg, d, me);

        // 3c. The chain's global debt cap, where the chain is capped. Never uncapped afterwards.
        if (cfg.chain.capped && d.params.chainCapped() && d.params.chainLine() != cfg.chain.chainLine) {
            revert Mismatch("chain line set by another config");
        }
        if (cfg.chain.capped && !d.params.chainCapped()) {
            g = gasleft();
            d.params.setGenesisChainLine(cfg.chain.chainLine);
            _rec("params.setGenesisChainLine", g, CALL_DATA);
        }

        // 3d. The NHI-linked liquidation grace cap, where the config turns the grace off (the beta).
        if (cfg.graceOff && d.params.maxLull() != 0) {
            g = gasleft();
            d.params.setGenesisMaxLull(0);
            _rec("params.setGenesisMaxLull", g, CALL_DATA);
        }

        // 4. Migrator line (always sent while open: a resumed beta re-sends its 0, which is harmless).
        uint256 line = migratorLineFor(cfg);
        if (!d.params.sealed_() && (line == 0 || d.params.migratorLine() != line)) {
            g = gasleft();
            d.params.setGenesisMigratorLine(line);
            _rec("params.setGenesisMigratorLine", g, CALL_DATA);
        }
    }

    /// @dev Resumable like the joins above: a recorded contract with code and the right wiring is kept, one with the
    /// wrong wiring stops the run, a missing one is deployed.
    function _deploySeats(DeployTypes.Config memory cfg, Deployed memory d, address me) internal {
        DeployTypes.SeatSpec memory s = cfg.seats;
        uint256 g;
        if (
            !(
                _has(address(d.seatJoin))
                    && _ok(
                        address(d.seatJoin.nft()) == s.nft && d.seatJoin.wirer() == me && d.seatJoin.ilk() == s.ilk
                            && d.seatJoin.maxSeats() == s.maxSeats && d.seatJoin.perBorrower() == s.perBorrower,
                        "SeatJoin"
                    )
            )
        ) {
            g = gasleft();
            d.seatJoin = new SeatJoin(s.ilk, IERC721(s.nft), IImdAgentAdapter(s.adapter), me, s.maxSeats, s.perBorrower);
            _rec("SeatJoin (+SeatAccount impl)", g, type(SeatJoin).creationCode.length + 192);
        }
        if (address(d.seatJoin.ledger()) == address(0)) {
            g = gasleft();
            d.seatJoin.wire(address(d.ledger));
            _rec("seatJoin.wire", g, CALL_DATA);
        } else if (address(d.seatJoin.ledger()) != address(d.ledger)) {
            revert Mismatch("SeatJoin wired to another Ledger");
        }
        bool feedOk = _has(address(d.seatFeed))
            && _ok(
                address(d.seatFeed.median()) == address(d.feeds[s.median]) && address(d.seatFeed.spot()) == address(d.feeds[s.spot])
                    && address(d.seatFeed.ethUsd()) == address(d.feeds[s.ethUsd]),
                "SeatFeed"
            );
        if (!feedOk) {
            g = gasleft();
            d.seatFeed = new SeatFeed(d.feeds[s.median], d.feeds[s.spot], d.feeds[s.ethUsd]);
            _rec("SeatFeed", g, type(SeatFeed).creationCode.length + 96);
        }
        if (!(_has(address(d.seatSpot)) && _ok(address(d.seatSpot.feed()) == address(d.seatFeed), "SeatSpotLeg"))) {
            g = gasleft();
            d.seatSpot = new SeatSpotLeg(d.seatFeed);
            _rec("SeatSpotLeg", g, type(SeatSpotLeg).creationCode.length + 32);
        }
        ParametersBase.Config memory want = ParametersBase.Config({
            token: address(d.seatJoin),
            join: address(d.seatJoin),
            median: IFeed(address(d.seatFeed)),
            spot: IFeed(address(d.seatSpot)),
            nhi: IFeed(address(0)),
            yieldRate: address(0),
            pegAggregator: address(0),
            liveSpot: IFeed(address(0)),
            redeemable: false,
            auction: true
        });
        if (d.params.exists(s.ilk)) return _sameIlk(d.params, s.ilk, want, s.risk);
        g = gasleft();
        d.params.addGenesisIlk(s.ilk, want, s.risk);
        _rec("params.addGenesisIlk (SEAT)", g, 1_000);
    }

    /// @dev A type already registered (a resumed run) must be exactly the one this config registers: join, feeds, flags
    /// and risk (audit wave 1, panel 7: only the join was compared, and a type's feeds cannot change after the seal).
    function _sameIlk(Parameters params, bytes32 ilk, ParametersBase.Config memory c, ParametersBase.Risk memory r)
        internal
        view
    {
        if (keccak256(abi.encode(params.config(ilk))) != keccak256(abi.encode(c))) {
            revert Mismatch("type registered with another config");
        }
        if (keccak256(abi.encode(params.storedRisk(ilk))) != keccak256(abi.encode(r))) {
            revert Mismatch("type registered with other risk");
        }
    }
}
