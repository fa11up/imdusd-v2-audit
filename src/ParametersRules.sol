// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ParametersBase.sol";

/// @notice Parameters' per-kind validation and application (EIP-170 split; the LedgerSettlement pattern). Deployed
/// by Parameters' constructor and run ONLY by delegatecall from it, on Parameters' storage; a direct call is refused.
contract ParametersRules is ParametersBase {
    address private immutable self;

    error NotDelegated();

    constructor(address governor_) ParametersBase(governor_, address(1)) {
        self = address(this);
    }

    function validateKind(bytes memory payload) external {
        if (address(this) == self) revert NotDelegated();
        _validate(payload);
    }

    function applyKind(bytes memory payload) external {
        if (address(this) == self) revert NotDelegated();
        _apply(payload);
    }

    function _validate(bytes memory payload) internal override {
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == SET_RISK) {
            (, bytes32 ilk, Risk memory r) = abi.decode(payload, (uint8, bytes32, Risk));
            if (!exists(ilk)) revert UnknownIlk();
            _checkRisk(_config[ilk], r);
            // A dust raise at most doubles the dust in force (or reaches DUST_STEP); re-checked at apply.
            uint256 od = _risk[ilk].dust;
            if (r.dust > od && r.dust > 2 * od && r.dust > DUST_STEP) revert OutOfBounds();
        } else if (kind == ADD_ILK) {
            (, bytes32 ilk, Config memory c, Risk memory r) = abi.decode(payload, (uint8, bytes32, Config, Risk));
            _checkIlk(ilk, c, r);
        } else if (kind == SET_MIGRATOR_LINE) {
            // Any value: zero closes conversion into v2; reverse conversion is never blocked by the line.
        } else if (kind == SET_BRIDGE || kind == SET_KEEPER) {
            (, address minter) = abi.decode(payload, (uint8, address));
            if (minter.code.length == 0) revert BadConfig();
        } else if (kind == SET_SAVINGS_SHARE) {
            (, uint64 share) = abi.decode(payload, (uint8, uint64));
            if (savings == address(0) || share > MAX_SAVINGS_SHARE) revert OutOfBounds();
            // Re-checked at apply (Governed validates again), against the share then in force.
            uint256 cur = savingsShare;
            if (share > cur + MAX_SAVINGS_STEP || share + MAX_SAVINGS_STEP < cur) revert OutOfBounds();
        } else if (kind == SET_KEEPER_CAP) {
            // Lowering it below the outstanding amount only stops new mints; buy-backs are never blocked.
            (, uint256 cap) = abi.decode(payload, (uint8, uint256));
            if (cap > MAX_KEEPER_CAP) revert OutOfBounds();
        } else if (kind == SET_BUFFER_TARGET) {
            (, uint256 target) = abi.decode(payload, (uint8, uint256));
            if (target > MAX_BUFFER_TARGET) revert OutOfBounds();
        } else if (kind == SET_UNBACKED_BRAKE) {
            (, uint64 brake) = abi.decode(payload, (uint8, uint64));
            if (brake > MAX_UNBACKED_BRAKE) revert OutOfBounds();
        } else if (kind == SET_MAX_LULL) {
            (, uint64 lull) = abi.decode(payload, (uint8, uint64));
            if (lull > MAX_LULL) revert OutOfBounds();
        } else if (kind == SET_DEPTH_K) {
            (, uint64 k) = abi.decode(payload, (uint8, uint64));
            if (depthIlk == bytes32(0) || k > MAX_DEPTH_K) revert OutOfBounds();
        } else if (kind == SET_DEPTH) {
            if (depthIlk == bytes32(0)) revert OutOfBounds();
        } else if (kind == ADD_DEPTH_SAMPLER) {
            (, address sampler) = abi.decode(payload, (uint8, address));
            if (address(imdDepth) == address(0) || sampler.code.length == 0) revert OutOfBounds();
        } else if (kind == SET_DEPTH_LEG) {
            (, address leg, address price) = abi.decode(payload, (uint8, address, address));
            if (address(imdDepth) == address(0) || (leg == address(0)) != (price == address(0))) revert OutOfBounds();
        } else if (kind == SET_OTHER_IMD) {
            (, , uint64 chop) = abi.decode(payload, (uint8, uint256, uint64));
            if (depthIlk == bytes32(0) || chop > 1e18) revert OutOfBounds();
        } else if (kind == SET_TARGET) {
            (, bytes32 ilk, uint64 buffer) = abi.decode(payload, (uint8, bytes32, uint64));
            if (!exists(ilk)) revert UnknownIlk();
            if (buffer > MAX_TARGET_BUFFER) revert OutOfBounds();
        } else if (kind == SET_EDGE_PREMIUM) {
            (, uint64 premium) = abi.decode(payload, (uint8, uint64));
            if (edgeBackstop == address(0) || premium > MAX_EDGE_PREMIUM) revert OutOfBounds();
        } else if (kind == ADD_SLEEVE_ILK) {
            (, bytes32 ilk, bool edge, uint128 genesisLine,,) =
                abi.decode(payload, (uint8, bytes32, bool, uint128, uint128, uint128));
            if (!exists(ilk)) revert UnknownIlk();
            Config memory c = _config[ilk];
            // Only fungible custody is bid on: seat (auction) types keep their Dutch auctions.
            if (c.auction) revert BadConfig();
            address sleeve = edge ? edgeBackstop : blueBackstop;
            if (sleeve == address(0)) revert BadConfig();
            (address listed,,, bool on) = ISleeve(sleeve).ilks(ilk);
            if (listed != address(0) && (on || listed != c.token)) revert BadConfig(); // a disabled type may be re-listed
            // A type may sit in one sleeve only (the other sleeve must not list it either).
            address other = edge ? blueBackstop : edgeBackstop;
            if (other != address(0)) {
                (address o,,,) = ISleeve(other).ilks(ilk);
                if (o != address(0)) revert BadConfig();
            }
            // Refuse at propose (and again at apply) what the apply would fail on or harm with: a NEW token in a
            // sleeve already holding MAX_TOKENS, a token the sleeve's oracle maps to another type, and an edge listing
            // whose existing debt would push the summed edge debt past what the edge sleeve stands behind (that would
            // stop borrowing on every edge type at once).
            if (!ISleeve(sleeve).isToken(c.token) && ISleeve(sleeve).tokenCount() >= ISleeve(sleeve).MAX_TOKENS()) {
                revert OutOfBounds();
            }
            bytes32 mapped = ISleeveOracle(ISleeve(sleeve).oracle()).ilkOf(c.token);
            if (mapped != bytes32(0) && mapped != ilk) revert BadConfig();
            if (edge) _checkEdgeListing(sleeve, ilk, genesisLine);
        } else if (kind == RETIRE_SLEEVE_TOKEN) {
            (, bool edge, address t) = abi.decode(payload, (uint8, bool, address));
            address sleeve = edge ? edgeBackstop : blueBackstop;
            if (sleeve == address(0) || !ISleeve(sleeve).isToken(t)) revert BadConfig();
        } else if (kind == SET_CAP) {
            // A raise of an existing ceiling, at most to max(2 x the one in force, the live low), re-checked at
            // apply against the cap and the low then. Setting a first ceiling or lowering one is `lowerCap`.
            (, bytes32 ilk, uint256 cap_) = abi.decode(payload, (uint8, bytes32, uint256));
            uint256 cur = cap[ilk];
            if (!exists(ilk)) revert UnknownIlk();
            if (cur == 0 || cap_ <= cur || (cap_ > 2 * cur && cap_ > _liveLow(ilk))) revert OutOfBounds();
        } else if (kind == BATCH) {
            (, bytes[] memory items) = abi.decode(payload, (uint8, bytes[]));
            if (items.length == 0 || items.length > MAX_BATCH) revert OutOfBounds();
            for (uint256 i; i < items.length; ++i) {
                if (abi.decode(items[i], (uint8)) == BATCH) revert UnknownKind();
                _validate(items[i]);
            }
        } else if (kind == OPEN_NOTE_SERIES) {
            (, uint64 tenor, uint32 discountBps, uint128 cap) = abi.decode(payload, (uint8, uint64, uint32, uint128));
            if (notes == address(0)) revert BadConfig();
            if (tenor != 30 days && tenor != 90 days && tenor != 180 days) revert OutOfBounds();
            if (discountBps == 0 || discountBps > MAX_NOTE_DISCOUNT_BPS || cap == 0) revert OutOfBounds();
        } else if (kind == SET_CHAIN_LINE) {
            (, uint256 line) = abi.decode(payload, (uint8, uint256));
            if (!chainCapped || line > MAX_CHAIN_LINE) revert OutOfBounds();
        } else if (kind == SET_GROUP || kind == SET_GROUP_LINE) {
            (, bytes32 ilk, uint8 group, uint256 line) = abi.decode(payload, (uint8, bytes32, uint8, uint256));
            _checkGroup(kind == SET_GROUP ? ilk : bytes32(0), group, line);
        } else if (kind == SET_SEAT_LIMITS) {
            (, address join, uint256 maxSeats, uint256 perBorrower) = abi.decode(payload, (uint8, address, uint256, uint256));
            _checkSeatJoin(join);
            if (maxSeats > MAX_SEATS || perBorrower == 0 || perBorrower > MAX_SEATS_PER_BORROWER) revert OutOfBounds();
        } else if (kind == SET_SEAT_CLAIM) {
            (, address join, address target, bytes4 sel, uint8 rule) =
                abi.decode(payload, (uint8, address, address, bytes4, uint8));
            _checkSeatJoin(join);
            if (rule > MAX_CLAIM_RULE) revert OutOfBounds();
            if (rule != 0 && (target.code.length == 0 || _movesTokens(sel))) revert BadConfig();
        } else {
            revert UnknownKind();
        }
    }
    /// @dev When a new liquidation-risk version binds. It binds NOW only if, per field (chop; and mat
    /// unless the type is NHI-linked, whose mat is live), it is no harsher than the version in force (the newest whose
    /// bindAt has passed) AND every pending version after it. Otherwise it binds at max(now + RISK_GRACE, the latest
    /// pending bindAt), so bindAt never decreases and a softening cannot jump ahead of a pending raise. Each pending version
    /// the new one is no harsher than is postponed to the same bindAt (old positions then go straight from the version in
    /// force to the new one, never through the superseded harsher one; a postponement only delays a stricter rule).
    function _bindAt(bytes32 ilk, Risk memory r) private returns (uint256 at) {
        LiqRisk[] storage vs = _versions[ilk];
        bool nhi = address(_config[ilk].nhi) != address(0);
        uint256 i = vs.length;
        uint256 first = i; // the oldest pending version
        bool harsher;
        at = block.timestamp;
        while (i > 0) {
            LiqRisk storage v = vs[--i];
            if (r.chop > v.chop || (!nhi && r.mat > v.mat)) harsher = true;
            if (v.bindAt <= block.timestamp) break; // the version in force: compared, then stop
            first = i;
            if (v.bindAt > at) at = v.bindAt;
        }
        if (!harsher) return block.timestamp;
        if (at < block.timestamp + RISK_GRACE) at = block.timestamp + RISK_GRACE;
        for (i = first; i < vs.length; ++i) {
            LiqRisk storage v = vs[i];
            if (r.chop <= v.chop && (nhi || r.mat <= v.mat)) {
                v.bindAt = uint64(at);
                emit RiskVersioned(ilk, i, v.mat, v.chop, at);
            }
        }
    }

    /// @dev An edge listing of a type that already carries debt (or bad debt) adds it to the edge SUM bound of
    /// every edge type. Refused unless the new sum fits the capacity of every live listed edge type and of the new one (whose
    /// capacity at listing is max(EDGE_MULTIPLE x netVested, genesisLine), less the edge debt in auction). A re-listed type's
    /// debt counts once. A disabled type's debt counts (the Ledger's `_checkEdge` sums every edge type), its capacity of 0
    /// bounds nothing (it only stops that type's own borrowing).
    function _checkEdgeListing(address sleeve, bytes32 ilk, uint256 genesisLine) private view {
        uint256 sum = _edgeDebt(ilk);
        if (sum == 0) return;
        uint256 inAuction = IEdgeInAuction(ILedgerEdgeView(ledger).liquidator()).edgeInAuction();
        uint256 room = ISleeve(sleeve).EDGE_MULTIPLE() * ISleeve(sleeve).netVested();
        if (genesisLine > room) room = genesisLine;
        room = room > inAuction ? room - inAuction : 0;
        uint256 n = edgeIlks.length;
        for (uint256 i; i < n; ++i) {
            bytes32 e = edgeIlks[i];
            if (e == ilk) continue;
            sum += _edgeDebt(e);
            (,,, bool on) = ISleeve(sleeve).ilks(e);
            if (!on) continue;
            uint256 c = ISleeve(sleeve).edgeCapacity(e, inAuction);
            if (c < room) room = c;
        }
        if (sum > room) revert OutOfBounds();
    }

    function _edgeDebt(bytes32 ilk) private view returns (uint256) {
        (uint256 d,,,, uint256 b) = ILedgerEdgeView(ledger).ilkState(ilk);
        return d + b;
    }

    /// @dev A SeatAccount forwards any calldata after an allowlisted (target, selector), so a claim rule may never
    /// name a selector that moves or approves the account's tokens (ERC-20 / 721 / 1155 / 777 / 1363 transfers, approvals,
    /// permits, and multicall, which reaches any of them): allowlisting one would let anyone move every account's unpaid rewards. Removing a rule (rule 0) is always allowed.
    function _movesTokens(bytes4 s) private pure returns (bool) {
        return s == 0x095ea7b3 // approve(address,uint256)
            || s == 0xa9059cbb // transfer(address,uint256)
            || s == 0x23b872dd // transferFrom(address,address,uint256)
            || s == 0xd505accf // permit(address,address,uint256,uint256,uint8,bytes32,bytes32) (EIP-2612)
            || s == 0x8fcbaf0c // permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32) (DAI)
            || s == 0x39509351 // increaseAllowance(address,uint256)
            || s == 0xa22cb465 // setApprovalForAll(address,bool)
            || s == 0x42842e0e // safeTransferFrom(address,address,uint256)
            || s == 0xb88d4fde // safeTransferFrom(address,address,uint256,bytes)
            || s == 0xf242432a // safeTransferFrom(address,address,uint256,uint256,bytes) (ERC-1155)
            || s == 0x2eb2c2d6 // safeBatchTransferFrom(address,address,uint256[],uint256[],bytes) (ERC-1155)
            || s == 0x1296ee62 // transferAndCall(address,uint256) (ERC-1363)
            || s == 0x4000aea0 // transferAndCall(address,uint256,bytes) (ERC-677, ERC-1363)
            || s == 0xd8fbe994 // transferFromAndCall(address,address,uint256) (ERC-1363)
            || s == 0xc1d34b89 // transferFromAndCall(address,address,uint256,bytes) (ERC-1363)
            || s == 0x3177029f // approveAndCall(address,uint256)
            || s == 0xcae9ca51 // approveAndCall(address,uint256,bytes)
            || s == 0x9bd9bbc6 // send(address,uint256,bytes) (ERC-777)
            || s == 0x62ad1b83 // operatorSend(address,address,uint256,bytes,bytes) (ERC-777)
            || s == 0x959b8c3f // authorizeOperator(address) (ERC-777)
            || s == 0xac9650d8 // multicall(bytes[])
            || s == 0x5ae401dc; // multicall(uint256,bytes[])
    }

    function _apply(bytes memory payload) internal override {
        uint8 kind = abi.decode(payload, (uint8));
        if (kind == SET_RISK) {
            (, bytes32 ilk, Risk memory r) = abi.decode(payload, (uint8, bytes32, Risk));
            bool raises = ilk == depthIlk && ilk != bytes32(0) && _depthNeed(r) > _depthNeed(_risk[ilk]);
            Risk memory o = _risk[ilk];
            if (r.mat != o.mat || r.chop != o.chop) _pushVersion(ilk, r.mat, r.chop, _bindAt(ilk, r));
            _risk[ilk] = r;
            emit RiskSet(ilk, r);
            if (raises) _requireDepth();
        } else if (kind == ADD_ILK) {
            (, bytes32 ilk, Config memory c, Risk memory r) = abi.decode(payload, (uint8, bytes32, Config, Risk));
            _addIlk(ilk, c, r);
        } else if (kind == SET_MIGRATOR_LINE) {
            (, uint256 line) = abi.decode(payload, (uint8, uint256));
            migratorLine = line;
            emit MigratorLineSet(line);
        } else if (kind == SET_SAVINGS_SHARE) {
            (, uint64 share) = abi.decode(payload, (uint8, uint64));
            savingsShare = share;
            emit SavingsSet(savings, share);
        } else if (kind == SET_BRIDGE) {
            (, address bridge) = abi.decode(payload, (uint8, address));
            IBridgeSettable(token).setBridge(bridge);
        } else if (kind == SET_KEEPER) {
            (, address keeper) = abi.decode(payload, (uint8, address));
            IBridgeSettable(token).setKeeper(keeper);
        } else if (kind == SET_KEEPER_CAP) {
            (, uint256 cap) = abi.decode(payload, (uint8, uint256));
            keeperCap = cap;
            emit KeeperCapSet(cap);
        } else if (kind == SET_BUFFER_TARGET) {
            (, uint256 target) = abi.decode(payload, (uint8, uint256));
            bufferTarget = target;
            emit BufferTargetSet(target);
        } else if (kind == SET_UNBACKED_BRAKE) {
            (, uint64 brake) = abi.decode(payload, (uint8, uint64));
            unbackedBrake = brake;
            emit UnbackedBrakeSet(brake);
        } else if (kind == SET_MAX_LULL) {
            (, uint64 lull) = abi.decode(payload, (uint8, uint64));
            maxLull = lull;
            emit MaxLullSet(lull);
        } else if (kind == SET_DEPTH_K) {
            (, uint64 k) = abi.decode(payload, (uint8, uint64));
            bool up = k > depthK;
            depthK = k;
            emit DepthKSet(k);
            if (up) _requireDepth();
            else _flagDepth();
        } else if (kind == SET_DEPTH) {
            // The posted ceiling, any value (0 clears it where an ImdDepth measures depth): a raise only lifts the cap.
            (, uint256 depth) = abi.decode(payload, (uint8, uint256));
            depthCap = depth;
            emit DepthPosted(depth);
            _flagDepth();
        } else if (kind == ADD_DEPTH_SAMPLER) {
            (, address sampler) = abi.decode(payload, (uint8, address));
            imdDepth.addSampler(sampler);
            _flagDepth();
        } else if (kind == SET_DEPTH_LEG) {
            (, address leg, address price) = abi.decode(payload, (uint8, address, address));
            imdDepth.setLeg(leg, price);
            _flagDepth();
        } else if (kind == SET_OTHER_IMD) {
            (, uint256 lines, uint64 chop) = abi.decode(payload, (uint8, uint256, uint64));
            uint256 before = otherImdLines * (1e18 + otherImdChop);
            (otherImdLines, otherImdChop) = (lines, chop);
            emit OtherImdSet(lines, chop);
            if (lines * (1e18 + chop) > before) _requireDepth();
            else _flagDepth();
        } else if (kind == SET_CAP) {
            (, bytes32 ilk, uint256 cap_) = abi.decode(payload, (uint8, bytes32, uint256));
            _setCap(ilk, cap_);
        } else if (kind == SET_TARGET) {
            (, bytes32 ilk, uint64 buffer) = abi.decode(payload, (uint8, bytes32, uint64));
            targetBuffer[ilk] = buffer;
            emit TargetSet(ilk, buffer);
        } else if (kind == SET_EDGE_PREMIUM) {
            (, uint64 premium) = abi.decode(payload, (uint8, uint64));
            edgePremium = premium;
            emit EdgePremiumSet(premium);
        } else if (kind == ADD_SLEEVE_ILK) {
            (, bytes32 ilk, bool edge, uint128 genesisLine, uint128 saleMax, uint128 saleSlope) =
                abi.decode(payload, (uint8, bytes32, bool, uint128, uint128, uint128));
            address sleeve = edge ? edgeBackstop : blueBackstop;
            address token = _config[ilk].token;
            ISleeveOracle o = ISleeveOracle(ISleeve(sleeve).oracle());
            // A token already mapped to this type stays mapped (a mapping to another type is refused in _validate).
            if (o.ilkOf(token) == bytes32(0)) o.setIlk(token, ilk);
            ISleeve(sleeve).addIlk(ilk, token, genesisLine, saleMax, saleSlope);
            if (edge && !edgeIlk[ilk]) {
                edgeIlk[ilk] = true;
                edgeIlks.push(ilk);
                emit EdgeIlkSet(ilk);
            }
            emit SleeveIlkAdded(ilk, edge, genesisLine);
        } else if (kind == RETIRE_SLEEVE_TOKEN) {
            (, bool edge, address t, bool on) = abi.decode(payload, (uint8, bool, address, bool));
            ISleeve(edge ? edgeBackstop : blueBackstop).retire(t, on);
        } else if (kind == BATCH) {
            (, bytes[] memory items) = abi.decode(payload, (uint8, bytes[]));
            for (uint256 i; i < items.length; ++i) {
                _validate(items[i]);
                _apply(items[i]);
            }
        } else if (kind == OPEN_NOTE_SERIES) {
            (, uint64 tenor, uint32 discountBps, uint128 cap) = abi.decode(payload, (uint8, uint64, uint32, uint128));
            uint256 id = INoteSeries(notes).open(tenor, discountBps, cap);
            emit NoteSeriesOpened(id, tenor, discountBps, cap);
        } else if (kind == SET_CHAIN_LINE) {
            (, uint256 line) = abi.decode(payload, (uint8, uint256));
            chainLine = uint128(line);
            emit ChainLineSet(line);
        } else if (kind == SET_GROUP || kind == SET_GROUP_LINE) {
            (, bytes32 ilk, uint8 group, uint256 line) = abi.decode(payload, (uint8, bytes32, uint8, uint256));
            _setGroup(kind == SET_GROUP ? ilk : bytes32(0), group, line);
        } else if (kind == SET_SEAT_LIMITS) {
            (, address join, uint256 maxSeats, uint256 perBorrower) = abi.decode(payload, (uint8, address, uint256, uint256));
            ISeatGoverned(join).setLimits(maxSeats, perBorrower);
            emit SeatLimitsSet(join, maxSeats, perBorrower);
        } else {
            (, address join, address target, bytes4 selector, uint8 rule) =
                abi.decode(payload, (uint8, address, address, bytes4, uint8));
            ISeatGoverned(join).setClaimRule(target, selector, rule);
            emit SeatClaimRuleSet(join, target, selector, rule);
        }
    }
}
