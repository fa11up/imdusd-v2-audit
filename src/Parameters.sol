// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ParametersBase.sol";
import {ParametersRules} from "./ParametersRules.sol";

/// @notice Collateral types ("ilks") and every economic knob, each bounded in source, behind a 48h timelock.
/// @dev What governance can and cannot do, which is the point of this contract:
///  - CAN: tune a type's risk values inside the bounds below; add a new type; set the v1 Migrator's cap;
///    set the bridge minter once; set the peg keeper minter once and its cap; set the savers' share of interest
///    within 0-50% (MAX_SAVINGS_SHARE), at most 10 points per change (MAX_SAVINGS_STEP); open a fee-note series
///    (tenor 30/90/180 days, discount <= 10%, a size cap); move a capped chain's `chainLine` within MAX_CHAIN_LINE
///    (never uncap it). Freezing a type is `line = 0`. The risk-reducing direction is INSTANT by the governor, also
///    after the seal (the `lower*` acts, `postLowerDepth`, `removeDepthSampler`, `disableSleeveIlk`); raising waits 48h.
///  - CANNOT: change a type's token, custody (join) or price feeds once registered (v1's rule: a feed
///    that breaks is wound down, never re-pointed), seize collateral, or mint.
/// Genesis types are registered by the deployer (`wirer`) before `seal()`, so a launch does not wait
/// 48h per type; after sealing only the timelock can add one.
contract Parameters is ParametersBase {
    /// @notice The per-kind validate/apply module this contract delegate-calls (deployed here; fixed).
    ParametersRules public immutable rules;

    constructor(address governor_, address wirer_) ParametersBase(governor_, wirer_) {
        rules = new ParametersRules(governor_);
    }

    function wire(address ledger_, address token_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (ledger != address(0)) revert AlreadyWired();
        if (ledger_.code.length == 0 || token_.code.length == 0) revert BadConfig();
        ledger = ledger_;
        token = token_;
    }

    /// @notice Register a type at genesis, without the timelock. Only before `seal`.
    function addGenesisIlk(bytes32 ilk, Config calldata config, Risk calldata risk) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        _checkIlk(ilk, config, risk);
        _addIlk(ilk, config, risk);
    }

    function setGenesisMigratorLine(uint256 line) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        migratorLine = line;
        emit MigratorLineSet(line);
    }

    /// @notice Name the sImdUSD vault and its starting share. Only before `seal`; the vault is then fixed
    /// and only its share moves, through the timelock (0 switches the savings rate off).
    function setGenesisSavings(address vault, uint64 share) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (token == address(0) || vault.code.length == 0 || IAssetView(vault).asset() != token) revert BadConfig();
        if (share > MAX_SAVINGS_SHARE) revert OutOfBounds();
        savings = vault;
        savingsShare = share;
        emit SavingsSet(vault, share);
    }

    /// @notice Name the peg keeper minter at genesis (the v4 peg hook), without the timelock. Only before `seal`;
    /// its cap stays 0 until governance raises it through the timelock, so it can mint nothing at launch.
    function setGenesisKeeper(address keeper_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (token == address(0)) revert BadConfig();
        IBridgeSettable(token).setKeeper(keeper_);
    }

    /// @notice Name the fee-notes contract at genesis. Only before `seal`; fixed afterwards. Opening a series is
    /// always a timelocked proposal (OPEN_NOTE_SERIES), never a genesis act.
    function setGenesisNotes(address notes_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (
            token == address(0) || notes_.code.length == 0 || INoteSeries(notes_).token() != token
                || INoteSeries(notes_).params() != address(this)
        ) revert BadConfig();
        notes = notes_;
        emit NotesSet(notes_);
    }

    /// @notice Cap the NHI-linked liquidation grace at genesis (the beta: 0). Only before `seal`; afterwards SET_MAX_LULL.
    function setGenesisMaxLull(uint256 lull) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (lull > MAX_LULL) revert OutOfBounds();
        maxLull = uint64(lull);
        emit MaxLullSet(lull);
    }

    /// @notice Cap this chain's total debt at genesis. Only before `seal`; afterwards only SET_CHAIN_LINE moves it.
    function setGenesisChainLine(uint256 line) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (line > MAX_CHAIN_LINE) revert OutOfBounds();
        chainCapped = true;
        chainLine = uint128(line);
        emit ChainLineSet(line);
    }

    /// @notice D1 at genesis: the depth-gated type, k and the first posted depth. Only before `seal`; the rule is not
    /// checked here (the beta's sIMD line is 0 at genesis and opens through the day-7 batch, which must satisfy it).
    function setGenesisDepthRule(bytes32 ilk, uint64 k, uint256 depth, uint256 otherLines, uint64 otherChop) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (!exists(ilk)) revert UnknownIlk();
        if (k > MAX_DEPTH_K || otherChop > 1e18) revert OutOfBounds();
        (depthIlk, depthK, depthCap, otherImdLines, otherImdChop) = (ilk, k, depth, otherLines, otherChop);
        emit DepthRuleSet(ilk, k, depth);
        emit OtherImdSet(otherLines, otherChop);
    }

    /// @notice The measured IMD depth at genesis. Only before `seal`; once set the posted figure is only a cap.
    function setGenesisImdDepth(address imdDepth_, address[] calldata samplers) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (imdDepth_.code.length == 0 || IImdDepth(imdDepth_).params() != address(this)) revert BadConfig();
        imdDepth = IImdDepth(imdDepth_);
        for (uint256 i; i < samplers.length; ++i) IImdDepth(imdDepth_).addSampler(samplers[i]);
        emit ImdDepthSet(imdDepth_);
    }

    /// @notice Unlist an IMD exit-pool sampler at once (its pool was drained or is suspect). Lowers depth only.
    function removeDepthSampler(address sampler) external onlyGovernor {
        if (address(imdDepth) == address(0)) revert OutOfBounds();
        _cancelPending(ADD_DEPTH_SAMPLER, 0);
        imdDepth.removeSampler(sampler);
        _flagDepth();
    }

    /// @notice A type's borrow price ceiling at genesis (0 = none). Only before `seal`; afterwards `lowerCap` / SET_CAP.
    function setGenesisCap(bytes32 ilk, uint256 cap_) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (!exists(ilk)) revert UnknownIlk();
        _setCap(ilk, cap_);
    }

    /// @notice The Backstop sleeves and the edge premium, once, before the seal.
    function setGenesisBackstops(address blue, address edge, uint64 premium) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (blueBackstop != address(0) || edgeBackstop != address(0)) revert BadConfig();
        if (premium > MAX_EDGE_PREMIUM || (edge == address(0) && premium != 0)) revert OutOfBounds();
        (blueBackstop, edgeBackstop, edgePremium) = (blue, edge, premium);
        emit BackstopsSet(blue, edge, premium);
    }

    /// @notice Make `ilk` an edge type (its bid and first loss are the edge sleeve's), before the seal.
    function setGenesisEdgeIlk(bytes32 ilk) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (!exists(ilk)) revert UnknownIlk();
        if (edgeBackstop == address(0) || edgeIlk[ilk]) revert BadConfig();
        edgeIlk[ilk] = true;
        edgeIlks.push(ilk);
        emit EdgeIlkSet(ilk);
    }

    /// @notice A type's liquidation target buffer at genesis (0 = close in full). Afterwards SET_TARGET.
    function setGenesisTarget(bytes32 ilk, uint64 buffer) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        if (!exists(ilk)) revert UnknownIlk();
        if (buffer > MAX_TARGET_BUFFER) revert OutOfBounds();
        targetBuffer[ilk] = buffer;
        emit TargetSet(ilk, buffer);
    }

    /// @notice Lower the edge premium at once.
    function lowerEdgePremium(uint64 premium) external onlyGovernor {
        if (premium >= edgePremium) revert OutOfBounds();
        _cancelPending(SET_EDGE_PREMIUM, 0);
        edgePremium = premium;
        emit EdgePremiumSet(premium);
    }

    /// @notice Stop a sleeve's standing bid on a type at once (the safe direction; liquidations fall back to the
    /// caller/auction path). ADD_SLEEVE_ILK (48h) lists it again. On an EDGE type it also ends the type's first-loss cover
    /// and its edge capacity reads 0, so while any edge debt exists every borrow and charged rate change on that type
    /// reverts (`EdgeCapacityExceeded`) until the re-listing. A re-listing restarts the type's bootstrap allowance
    /// (`listedAt`, `genesisLine`): edge capacity is bounded by vested imdUSD only as far as the Safe does not re-list.
    function disableSleeveIlk(bytes32 ilk, bool edge) external onlyGovernor {
        address sleeve = edge ? edgeBackstop : blueBackstop;
        if (sleeve == address(0)) revert BadConfig();
        _cancelPending(ADD_SLEEVE_ILK, ilk); // or anyone's applyPending would undo the stop
        ISleeve(sleeve).disableIlk(ilk);
        emit SleeveIlkDisabled(ilk, edge);
    }

    function edgeIlkCount() external view returns (uint256) {
        return edgeIlks.length;
    }

    /// @notice Set a ceiling on a type with none, or lower one, at once. Every adjust that is not a de-risking
    /// repay-and-withdraw is measured at the borrow price min(low, cap), so a low cap also refuses plain collateral
    /// withdrawals from an indebted position (repay first) until SET_CAP lifts it; repay, deposit, redemption and
    /// liquidation are unaffected.
    /// Refused below 1/100 of the live low (a unit error, e.g. a per-token figure for an 8-decimal token).
    function lowerCap(bytes32 ilk, uint256 cap_) external onlyGovernor {
        if (!exists(ilk)) revert UnknownIlk();
        uint256 cur = cap[ilk];
        if (cap_ == 0 || (cur != 0 && cap_ >= cur) || cap_ < _liveLow(ilk) / 100) revert OutOfBounds();
        _cancelPending(SET_CAP, ilk);
        _setCap(ilk, cap_);
    }


    /// @notice Lower the other chains' IMD lines at once (after the other chain lowered its line). Refused while the depth
    /// line binds this chain's depth-gated type (audit wave 1): less exposure counted elsewhere is more room here, so then it
    /// would RAISE the enforced line without the timelock; SET_OTHER_IMD (48h) does that.
    function lowerOtherImdLines(uint256 lines) external onlyGovernor {
        if (depthIlk == bytes32(0) || lines >= otherImdLines) revert OutOfBounds();
        if (depthLine() < _risk[depthIlk].line) revert OutOfBounds();
        _cancelPending(SET_OTHER_IMD, 0);
        otherImdLines = lines;
        emit OtherImdSet(lines, otherImdChop);
        _flagDepth();
    }

    // ---------------------------------------------------------------- D1: instant lowering (governor, no delay)

    /// @notice Lower the depth-gated type's line at once. It stops new draws and, because the line binds the cooldown
    /// premium too, an in-cooldown rate change; repay, deposit, redemption and liquidation carry on.
    function lowerDepthLine(uint128 line) external onlyGovernor {
        if (depthIlk == bytes32(0)) revert OutOfBounds();
        _lowerLine(depthIlk, line);
    }

    /// @notice Lower ANY type's line at once (a type that has just booked bad debt must be stoppable without a
    /// 48h wait). Strictly lowering; raising stays a SET_RISK proposal. It stops new draws and, because the line binds the
    /// cooldown premium too, an in-cooldown rate change; repay, deposit, redemption and liquidation carry on.
    function lowerLine(bytes32 ilk, uint128 line) external onlyGovernor {
        if (!exists(ilk)) revert UnknownIlk();
        _lowerLine(ilk, line);
    }

    function _lowerLine(bytes32 ilk, uint128 line) private {
        if (line >= _risk[ilk].line) revert OutOfBounds();
        _cancelPending(SET_RISK, ilk);
        _risk[ilk].line = line;
        emit RiskSet(ilk, _risk[ilk]);
        if (ilk == depthIlk) _flagDepth();
    }

    /// @notice Tighten the unbacked-supply brake at once (loosening is SET_UNBACKED_BRAKE, 48h).
    function lowerUnbackedBrake(uint64 brake) external onlyGovernor {
        if (brake >= unbackedBrake) revert OutOfBounds();
        _cancelPending(SET_UNBACKED_BRAKE, 0);
        unbackedBrake = brake;
        emit UnbackedBrakeSet(brake);
    }

    /// @notice Lower the peg keeper's cap at once (raising is SET_KEEPER_CAP, 48h). Only new mints stop.
    function lowerKeeperCap(uint256 cap) external onlyGovernor {
        if (cap >= keeperCap) revert OutOfBounds();
        _cancelPending(SET_KEEPER_CAP, 0);
        keeperCap = cap;
        emit KeeperCapSet(cap);
    }

    /// @notice Lower k at once.
    function lowerDepthK(uint64 k) external onlyGovernor {
        if (depthIlk == bytes32(0) || k >= depthK) revert OutOfBounds();
        _cancelPending(SET_DEPTH_K, 0);
        depthK = k;
        emit DepthKSet(k);
        _flagDepth();
    }

    /// @notice Post a LOWER depth ceiling at once (a higher one, or none, goes through SET_DEPTH and the timelock). With no
    /// ImdDepth the posted figure IS the depth, so 0 means zero, not "no ceiling" (audit wave 1).
    function postLowerDepth(uint256 depth) external onlyGovernor {
        if (
            depthIlk == bytes32(0) || depth == 0
                || ((depthCap != 0 || address(imdDepth) == address(0)) && depth >= depthCap)
        ) revert OutOfBounds();
        _cancelPending(SET_DEPTH, 0);
        depthCap = depth;
        emit DepthPosted(depth);
        _flagDepth();
    }







    /// @dev An instant lower wins over every older proposal that would change the same field. It cancels the
    /// pending slot carrying `kind` (its own slot, or the BATCH carrying it), and for a per-type field (`ilk` != 0: SET_RISK's
    /// line, SET_CAP) only when that proposal touches this type. The Safe re-proposes whatever else the batch carried.
    function _cancelPending(uint8 kind, bytes32 ilk) private {
        if (locked & (uint256(1) << kind) == 0) return;
        uint8 slot = pendingKinds & (uint256(1) << kind) != 0 ? kind : BATCH;
        if (ilk != bytes32(0) && !_touches(_slots[slot].payload, kind, ilk)) return;
        cancel(slot); // the caller is the governor (every lower is onlyGovernor)
    }

    function _touches(bytes memory p, uint8 kind, bytes32 ilk) private pure returns (bool) {
        // Every per-type payload has a kind word and an ilk word; a shorter item names no type, and must never make an
        // instant lower revert (audit wave 1: one malformed batch item blocked every type's brakes).
        if (p.length < 64) return false;
        (uint8 k, bytes32 i) = abi.decode(p, (uint8, bytes32));
        if (k == BATCH) {
            (, bytes[] memory items) = abi.decode(p, (uint8, bytes[]));
            for (uint256 j; j < items.length; ++j) {
                if (_touches(items[j], kind, ilk)) return true;
            }
            return false;
        }
        return k == kind && i == ilk;
    }

    /// @notice Put a type in a debt-cap group, and set a group's line, at genesis. Only before `seal`; afterwards only
    /// SET_GROUP / SET_GROUP_LINE (48h) move them.
    function setGenesisGroup(bytes32 ilk, uint8 group, uint256 line) external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed();
        _checkGroup(ilk, group, line);
        _setGroup(ilk, group, line);
    }

    /// @notice End genesis. From here on the wirer has no power; every change is the timelock's, except the governor's
    /// instant risk-reducing acts (the `lower*` functions, `postLowerDepth`, `removeDepthSampler`, `disableSleeveIlk`).
    function seal() external {
        if (msg.sender != wirer) revert Unauthorized();
        if (sealed_) revert Sealed(); // one-shot: a second seal would restart every type's redemption fee at the cap
        if (ledger == address(0)) revert BadConfig();
        sealed_ = true;
        sealedAt = uint64(block.timestamp);
    }

    /// @notice When a type went live: the seal for a genesis type, its addition for a later one; 0 before the seal.
    /// The Redeemer starts each type's redemption base rate at its cap from this moment (launch at the cap).
    function listedAt(bytes32 ilk) external view returns (uint256) {
        if (!sealed_) return 0;
        uint256 a = _addedAt[ilk];
        return a > sealedAt ? a : sealedAt;
    }

    // ---------------------------------------------------------------- views

    function config(bytes32 ilk) external view returns (Config memory) {
        return _config[ilk];
    }

    /// @notice A type's risk. For the depth-gated type `line` is min(stored line, `depthLine()`): the rule binds live.
    /// Governance reads the STORED line through `storedRisk`.
    function risk(bytes32 ilk) external view returns (Risk memory r) {
        r = _risk[ilk];
        if (ilk == depthIlk && ilk != bytes32(0)) {
            uint256 dl = depthLine();
            if (dl < r.line) r.line = uint128(dl);
        }
    }

    /// @notice The newest liquidation-risk version of a type: what a position binds to when it takes on risk.
    function riskVersion(bytes32 ilk) external view returns (uint256) {
        return _versions[ilk].length - 1;
    }

    /// @notice The mat and chop that bind a position on version `v` now: its own version, or the newest version whose
    /// `bindAt` has passed if that is later. `mat` is 0 on an NHI-linked type (the caller uses the live NHI mat).
    function liqRisk(bytes32 ilk, uint256 v) external view returns (uint256 mat, uint256 chop) {
        LiqRisk[] storage vs = _versions[ilk];
        uint256 n = vs.length;
        uint256 e = v < n ? v : n - 1;
        for (uint256 i = n - 1; i > e; --i) {
            if (vs[i].bindAt <= block.timestamp) {
                e = i;
                break;
            }
        }
        LiqRisk storage x = vs[e];
        return (address(_config[ilk].nhi) != address(0) ? 0 : x.mat, x.chop);
    }

    function storedRisk(bytes32 ilk) external view returns (Risk memory) {
        return _risk[ilk];
    }


    /// @notice Where the Ledger sends savers' interest, and what share of it.
    function savingsSplit() external view returns (address, uint256) {
        return (savings, savingsShare);
    }

    function chainCap() external view returns (bool, uint256) {
        return (chainCapped, chainLine);
    }

    /// @notice The type's debt-cap group (0 = none) and that group's line.
    function groupCap(bytes32 ilk) external view returns (uint8 group, uint256 line) {
        group = groupOf[ilk];
        line = groupLine[group];
    }

    function ilkCount() external view returns (uint256) {
        return ilks.length;
    }

    // ---------------------------------------------------------------- governance







    // ---------------------------------------------------------------- checks

    // ---------------------------------------------------------------- governance (in ParametersRules)

    function _validate(bytes memory payload) internal override {
        _delegate(abi.encodeCall(ParametersRules.validateKind, (payload)));
    }

    function _apply(bytes memory payload) internal override {
        _delegate(abi.encodeCall(ParametersRules.applyKind, (payload)));
    }

    /// @dev Run `data` in ParametersRules on this contract's storage; bubble any revert unchanged.
    function _delegate(bytes memory data) private {
        address m = address(rules);
        assembly ("memory-safe") {
            let ok := delegatecall(gas(), m, add(data, 0x20), mload(data), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
        }
    }
}
