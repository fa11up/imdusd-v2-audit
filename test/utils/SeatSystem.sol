// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {System} from "./System.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {IFeed} from "../../src/interfaces/IFeed.sol";
import {SeatFeed, SeatSpotLeg} from "../../src/feeds/SeatFeed.sol";
import {SeatJoin} from "../../src/seats/SeatJoin.sol";
import {IImdAgentAdapter} from "../../src/seats/SeatAccount.sol";

/// @notice Registers the SEAT type (launch limits) on a deployed System.
abstract contract SeatSystem is System {
    bytes32 internal constant SEAT = "SEAT";

    SeatJoin internal seatJoin;
    SeatFeed internal seatFeed;
    SeatSpotLeg internal seatSpot;

    /// @dev LtvBase 40% (mat 250%), rateFloor 8%, not redeemable, 25 seats, 3 per borrower.
    function _seatRisk(uint128 line) internal pure returns (ParametersBase.Risk memory r) {
        r = ParametersBase.Risk({
            mat: 2.5e18,
            chop: 0.1e18,
            cut: 0.5e18,
            chip: 0.1e18,
            rateFloor: 0.08e18,
            yieldFee: 0.1e18, // the 10% fee on rewards, in kind (yieldFee 10% on all types)
            skew: 0.25e18, // freeze past 25% median/spot divergence
            pegFloor: 0,
            line: line,
            dust: 100e18,
            redeemFloor: 0.005e18, // unused (not redeemable), but must be in bounds
            redeemDivisor: 4,
            redeemCap: 0
        });
    }

    function _addSeatIlk(IERC721 nft, IImdAgentAdapter adapter, IFeed median, IFeed spot, IFeed ethUsd, uint128 line)
        internal
    {
        seatFeed = new SeatFeed(median, spot, ethUsd);
        seatSpot = new SeatSpotLeg(seatFeed);
        seatJoin = new SeatJoin(SEAT, nft, adapter, address(this), 25, 3);
        seatJoin.wire(address(ledger));
        params.addGenesisIlk(
            SEAT,
            ParametersBase.Config({
                token: address(seatJoin),
                join: address(seatJoin),
                median: IFeed(address(seatFeed)),
                spot: IFeed(address(seatSpot)),
                nhi: IFeed(address(0)),
                yieldRate: address(0),
                pegAggregator: address(0),
                liveSpot: IFeed(address(0)),
                redeemable: false,
                auction: true
            }),
            _seatRisk(line)
        );
    }
}
