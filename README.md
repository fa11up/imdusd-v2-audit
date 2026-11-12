# imdUSD v2: audit snapshot

imdUSD v2 is a modular, over-collateralised CDP stablecoin. One multi-collateral `Ledger` keeps every position. Each
borrower sets their own interest rate, and imdUSD is redeemable against the lowest-rate positions first, in the style of
Liquity v2, with a per-type decaying redemption fee. Collateral is priced by `Pricer` from two legs per type: Chainlink
aggregators (ETH, wstETH, cbBTC/WBTC, stablecoins, ERC-4626 share rates) or swarm-attested feeds (EIP-712 attestations
signed by the IdentityMD oracle network, for IMD/sIMD, the network-health index NHI and NFT seat prices).

What this core adds over a plain CDP:

- **Positions are ERC-721 ids.** `PositionNFT` holds ownership; the position's whole state lives in the `Ledger` under
  its id, so a transfer carries debt, rate, cooldown and premium rate. Ids are counterfactual (`positionId(owner, ilk,
  salt)`), an owner may hold any number per type, and operators hold separate rights (ADD, REPAY, SET_RATE,
  WITHDRAW/BORROW to the owner, WITHDRAW_ANY/BORROW_ANY to any address), granted per position or for all of an owner's
  positions and dropped on transfer. EIP-712 `permitOperator`, `openFor` and `borrowFor` (ERC-1271 accepted) let a key
  with no gas own and borrow; `bumpNonce(n)` cancels a whole pre-signed queue.
- **Size splits.** `Ledger` runs redemption, liquidation and write-off in `LedgerSettlement` by `delegatecall` on its own
  storage (shared layout in `LedgerBase`); `Parameters` runs per-kind validation and application in `ParametersRules` by
  `delegatecall` (shared layout in `ParametersBase`). Both splits keep the contracts under EIP-170/EIP-3860.
- **Versioned liquidation risk.** A type's `mat` and `chop` are kept per version. A position stays on the version it last
  took risk under until a newer version reaches its `bindAt`: a change that only lowers mat and chop binds at once, any
  other change binds `RISK_GRACE` (7 days) later. NHI-linked types keep a live `mat` and version only `chop`.
- **One pending proposal per kind** (`GovernedByKind`, used by `Parameters` and `Allocator`): every raise waits 48 hours
  and expires 14 days after its ETA; a proposal locks the kinds it would change; instant lowerings cancel pending
  proposals touching the same field.
- **Backstop sleeves.** Two `Backstop` instances per chain: `blue` (ETH, wstETH, BTC, staked stables) and `edge` (sIMD,
  later edge types). A sleeve is a STANDING BID: when a covered position is liquidated and the sleeve has room for the
  whole debt, it buys the collateral in the liquidation's own transaction at the liquidation price plus the penalty;
  its depositors keep the penalty less the Treasury's cut and the marker's chip. Seats are an auction type: no sleeve
  bids on them, they sell by Dutch auction. The edge sleeve also takes FIRST LOSS on edge types' bad debt before the Treasury, earns a premium (a share
  of edge interest, streamed over 7 days), and bounds the summed edge debt (`edgeCapacity` = max(3 x net vested imdUSD,
  a 60-day bootstrap allowance)). Deposits wait a day bucket, withdrawals queue 7 days and must be claimed within 2.
  `PricerOracle` gives the sleeves their prices from the Pricer's quotes.
- **Partial liquidation to a target.** A fungible type with a target buffer repays only what restores `mat + buffer`.
- **Allocator.** The only way protocol funds move, modelled on Spark's ALM controller: no recipient argument anywhere,
  allowlisted targets, a refilling rate limit per (action, target), slippage bounds from two feeds, and a freezer (the
  Safe) that can stop it. Its four discretionary jobs are RULE-DRIVEN: anyone may call them and the contract picks amount,
  price and route. Seized collateral sells by a descending auction per (sleeve, token) (103% of the sleeve's highest
  price, `max(low, high, redemption payout)`, falling to 98% of `low` over 2 hours, paid in imdUSD straight to the sleeve
  through `Backstop.sell` and never under its floor; collateral that arrives later stops the price until anyone restarts
  the run, so it is always offered from the top);
  `rebalanceVault` keeps a Safe-set amount of an asset liquid and deposits the rest in its one approved vault;
  `topUpBuffer` fills the peg buffer to its target; `rebalanceLp` moves protocol-owned `PegLPVault` shares toward a target
  behind a spot-versus-TWAP gate (no target set means no rule). A keeper role still exists for manual actions; the beta
  adds none. At genesis nothing is allowlisted: every Allocator action, collateral sales included, waits until the Safe's
  48-hour setup applies (targets, buckets, auto vault, LP target).
- **PEG positions.** A position type whose collateral is `PegLPVault` shares (the protocol's imdUSD/USDC peg-pool LP
  vault on the `PegHook` pool). `PegPositionZap` takes a user's USDC, flash-mints imdUSD, deposits both in the vault's
  proportion, wraps the shares 1:1 as `PegCollateral` (only the zap can mint it) and borrows exactly the imdUSD placed:
  debt that is peg liquidity. `PegShareFeed` prices a share from the vault's own holdings (imdUSD at $1, USDC at
  min($1, Chainlink)); its spot instance reads 0 while the vault is one-sided, which stops new PEG debt.
- **Measured IMD depth.** The sIMD line obeys `line x (1 + chop) + redeemCap (+ other chains' IMD lines) <= k x depth`.
  `DepthSampler` measures each IMD exit pool's depth to -15% on chain from the pool's own liquidity, in hourly buckets;
  `ImdDepth` sums the samplers and keeps a robust 7-day low, min'd with a swarm-attested depth leg once configured. A
  posted figure is only a ceiling.
- **RateManager.** Optional, outside the core: owners grant it SET_RATE only; a manager key re-rates members within fixed
  bounds, each member's own floor and ceiling, and only outside their 7-day rate cooldown.

Also in place from the earlier core: a Uniswap v4 hook (`PegHook`) on the imdUSD/USDC pool that charges a toll on swaps
that push the price away from $1 and runs a capped peg keeper; `SavingsVault` (sImdUSD), which streams a governed share
of borrower interest to savers; identity.md NFT seats as auction-liquidated collateral through per-seat accounts;
`FeeNotes`; the v1 -> v2 `Migrator`.

All governance goes through `Parameters` (a 2-of-3 Safe as governor). The repository also contains modules that are NOT
part of the first deployment: a LayerZero V2 bridge (`ImdBridge`, `Pulse`), a leveraged loop vault (`LoopVault`), an AMM
of two ERC-4626 tokens (`src/dex/`), `RateManager`, and stock-token collateral for Robinhood Chain (`src/stocks/`,
`MarketCalendar`, `MarketHoursFeed`). `script/` holds only the deploy scripts the tests import.

## Build and test

Requires Foundry 1.9 (solc 0.8.26, `via_ir`, `bytecode_hash = "none"`). Dependencies are vendored under `lib/`; no
network is needed for the offline suites.

```bash
forge build                                                    # solc via_ir: a clean build takes a long time
forge test --no-match-path 'test/fork/*'                       # offline: unit + invariant suites (1,267 tests)
forge build --use solar && forge test --use solar --no-match-path 'test/fork/*'   # fast dev loop (see below)

# Fork suites: one file at a time, single-threaded (in parallel, set-up calls hit RPC rate limits)
MAINNET_RPC_URL=<archive rpc> forge test --match-path test/fork/Deploy.t.sol --threads 1
MAINNET_RPC_URL=<archive rpc> forge test --match-path test/fork/DeployBeta.t.sol --threads 1
ROBINHOOD_RPC_URL=<rpc> forge test --match-path test/fork/Robinhood.t.sol --threads 1
```

`--use solar` builds in seconds and is fine for iterating, but Solar has accepted syntax that solc rejects; confirm
anything you rely on with solc. Fork suites without their RPC variable skip. The Robinhood suites
(`Robinhood*.t.sol`) need `ROBINHOOD_RPC_URL`; every other fork file needs `MAINNET_RPC_URL` (an archive node for the
files that pin a block).

## Audit scope

nSLOC per area: Solidity source lines left after removing `//` and `/* */` comments and blank lines, counted per file
with a small script (the same rule as `cloc`'s code lines; pragma and import lines count). This rule gives slightly
higher figures than the previous snapshot's table (for example 1,049 against 1,014 for the same old core files), so
compare areas within this table, not across snapshots.

**Round 1: what the beta deploys (7,537 nSLOC)**

The beta is `script/DeployBeta.s.sol`, which runs `script/Deploy.s.sol` with `BetaConfig` (`script/DeployConfig.sol`):
the full mainnet config with lower lines, a 300k chain-wide debt cap, seats on, and LoopVault and the DEX off. It
deploys every contract below.

| Area | Contracts | nSLOC |
|---|---|---|
| A. Core | `Ledger`, `LedgerBase`, `LedgerSettlement`, `PositionNFT`, `SortedPositions`, `Join`, `ImdUSD`, `Migrator`, `SavingsVault`, `TransientReentrancyGuard`, `IPositions` | 1,577 |
| B. Liquidation and redemption | `Liquidator`, `Redeemer`, `Pricer`, `Treasury` | 553 |
| C. Feeds | `ChainlinkFeed`, `ProductFeed`, `RateFeed`, `LivePoolPrice`, `SwarmFeed`, `SwarmFeeds`, `IFeed`, `IERC4626Min` | 609 |
| D. Peg | `PegHook`, `FeeNotes` | 596 |
| E. Governance | `Parameters`, `ParametersBase`, `ParametersRules`, `Governed`, `GovernedByKind` | 1,124 |
| F. Seats | `SeatAccount`, `SeatJoin`, `SeatFeed` | 829 |
| G. Peg LP vault and PEG positions | `PegLPVault`, `PegCollateral`, `PegShareFeed`, `PegPositionZap` | 599 |
| H. Backstop and Allocator | `Backstop`, `IBackstop`, `PricerOracle`, `Allocator` | 1,245 |
| I. Measured depth | `DepthSampler`, `ImdDepth` | 405 |

**Round 2: later modules (2,195 nSLOC)**

| Area | Contracts | nSLOC |
|---|---|---|
| Rate manager | `RateManager` | 148 |
| Bridge | `ImdBridge`, `Pulse` | 412 |
| Loop vault | `LoopVault` | 510 |
| DEX | `src/dex/` | 875 |
| Stock tokens | `src/stocks/`, `MarketCalendar`, `MarketHoursFeed` | 250 |

Out of scope: `test/`, `script/`, `lib/`, unless a finding in scope reaches through them. The deploy scripts are worth
reading for the wiring (`script/deploy/Stage*.sol`): what is set at genesis and sealed, and what is left to governance.

## Key invariants

1. **Supply equation.** At rest, `totalSupply == Σ debt + Σ badDebt + reserveBacked + migrator outstanding + peg keeper
   outstanding + bridge received − bridge sent` (see the `LedgerBase` header). Flash-minted amounts exist only inside a
   transaction (`circulating()` excludes them). The edge premium and interest are minted on both sides at once.
2. **Solvency and health.** No action that adds debt or removes collateral leaves a position below its type's liquidation
   ratio at the borrow price (`min(low, cap)`), and none is allowed unless the price is fresh and its two legs agree
   within `skew`. Repayments and deposits
   need no price. Liquidation health uses the position's BOUND risk version.
3. **Line.** For every type, `debt + badDebt <= line`; on a capped chain the chain-wide sum (and any group cap) holds too.
4. **Edge capacity.** The SUM of every edge type's debt plus bad debt stays within the edge sleeve's `edgeCapacity`, less
   the edge debt under a live liquidation mark. Checked wherever edge debt is created.
5. **Sleeve accounting.** A sleeve's shares are claims on vested imdUSD plus the collateral it holds, per token; exits
   are pro rata in kind; booked but uncovered bad debt on its types is netted out of the imdUSD used to price
   conversions, pay exits, bid and size edge lines; a bid or a cover never spends below `MIN_RESIDUE` (1 imdUSD); a
   deposit converts only after a full day bucket and never while the booked loss exceeds the cover room. Edge bad debt is
   covered by the edge sleeve first, then the Treasury (`Treasury.coverBadDebt`).
6. **Depth rule.** For the IMD-collateral type: `line x (1 + chop) + redeemCap (+ other chains' IMD lines) <= k x
   depthIMD`, with `depthIMD` the measured depth, capped by a posted ceiling.
7. **Timelock.** Every governed raise (lines, risk values, fees, minters, new types, the depth leg, depth ceiling, sleeves, Allocator limits)
   waits 48 hours; lowerings that reduce risk are instant and cancel pending proposals touching the same field; a queued
   proposal expires 14 days after its ETA; one pending slot per kind.
8. **Minters set once.** imdUSD has four minters, each fixed once: `ledger` and `migrator` (wired by the deployer),
   `keeper` (the peg hook, set by the deployer before the seal) and `bridge` (set once through the timelocked
   `Parameters`; empty in the beta). The imdUSD token has no owner, upgrade, pause or rescue.

## Trust model

- **Governor:** a 2-of-3 Safe, immutable in each contract. It acts only through the 48-hour timelocks of `Parameters`,
  `Treasury` and `Allocator`, except instant actions: the risk-reducing ones (lowering a line, a cap, a keeper cap, a
  depth ceiling, a bucket; disabling a sleeve listing; freezing the Allocator), unfreezing the Allocator, and
  `Allocator.returnToTreasury` (funds held there back to the Treasury, no bucket). It cannot move user collateral or
  mint imdUSD directly. It can name one bridge minter, once, through the 48-hour timelock (`SET_BRIDGE`): that minter
  can mint without limit and burn from any holder. The beta leaves the slot empty.
- **Swarm attester:** swarm-priced feeds (sIMD legs, NHI, seat median and spot, the depth leg) accept an EIP-712
  attestation only from one pinned signer, for one pinned question (bound by hash), with absolute floors (panel of at
  least 100, at least 51 agreeing); a value moves at most a fixed cap per epoch, widened at most 2x after an hour of
  staleness. Relaying is permissionless. A compromised attester can move those feeds within the cap per epoch, and nothing
  on chain checks the sIMD pair against the market (see Known issues).
- **Chainlink:** aggregators are trusted within staleness bounds; answers at the aggregator's min/max clamp or above a
  sanity cap read as unpriced.
- **Allocator callers:** the rule-driven actions are open to anyone; a caller picks only the MOMENT. Every action draws on
  the same Safe-set targets and refilling buckets, so a bucket is the most an action can move in its window. Rule-driven
  calls emit `Ruled` (and `AuctionStarted` / `Bought`); `Acted` is emitted only for a keeper's or the governor's action.
- **Keeper role:** a key the governor may add to the `Allocator` through its timelock (THE BETA ADDS NONE). It CAN move
  protocol funds held by the Allocator between the Allocator and allowlisted protocol targets only, each within its bucket
  and a two-feed slippage bound; it CANNOT name a recipient, raise a bucket or add a target, move user funds, mint imdUSD
  or change any parameter.
- **Freezer:** the Safe, from genesis (there is no separate freezer key). `freeze()` stops every keeper and rule-driven
  Allocator action; only the governor unfreezes. An operator watches the Allocator's logs and alerts; it holds no key that
  can move or stop protocol funds. Permissionless chores (relaying attestations, sampling `DepthSampler`, poking
  `ImdDepth`, marking and liquidating, starting auctions) anyone may run.
- **Issuers:** USDC/USDT can blacklist addresses; stock tokens (round 2) carry issuer pause, blocklist and `adminBurn`
  keys that the protocol cannot prevent, only cap by debt lines.
- **Relayers and samplers:** permissionless; liveness of swarm-priced types depends on someone buying and relaying
  attestations. Stale prices stop borrowing, not repayment.

## Known issues and accepted risks

Items below are known and do not need to be reported unless you find a materially worse consequence.

- The unbacked-supply brake stops new debt but not the peg keeper's mint, which is bounded only by `keeperCap`.
- Governed raises of lines, depth and `mat` have no per-step size bound beyond the timelock; the migrator line is not
  bounded by v1 supply; re-registering a token as a new type is not refused. (changed: the depth used by the rule is now
  measured on chain, and a raise of the posted figure only raises its ceiling.)
- Migrator: no instant way to lower the migrator line and no v1 redemption path; the first deployment opens with the
  migrator line at 0.
- The sIMD live (redemption payout) leg can be pushed down toward the attested `high` inside a transaction.
- Seat prices rely on the oracle recipe's distinct-seat rule against wash trading; stronger buyer filters are an
  oracle-side change. When the median's fall cap binds, a seat auction's decay does not continue down to the raw spot.
- `setGenesisKeeper` does not check the keeper's stable token.
- One wei of sIMD sent to the shared `Join` in a block makes that block's `viaAsset` unwraps revert (sIMD's one-block
  hold); matters mainly once `LoopVault` is on.
- While a price is stale, borrowing up to the line can use the last attested `low` (bounded by the per-epoch cap).
- An honest large sIMD redemption can hold the sIMD redemption fee at its 5% cap for hours (by design).
- The redemption fee is sized on the requested amount while the base-rate rise uses the filled amount.
- `PegHook`'s quote feed and max age are immutable; a v4 protocol fee at or above the keeper margin would make small
  keeper trades revert.
- `RateFeed`'s growth cap is measured from the last poke, so headroom accrues while nobody pokes.
- The sIMD price legs bound ETH/USD staleness differently, which can briefly read unpriced.
- Swarm feeds admit two attestations with equal `issuedAt` in either order (bounded by the cap).
- If Circle blacklists the Treasury, liquidations of USDC types with a non-zero Treasury cut revert (`treasury` is
  immutable).
- `PegLPVault` has no deposit hold, so just-in-time deposits around known fee or donation arrivals are possible.
- DEX (round 2): IMD outputs require `hookData` naming the recipient; price limits are checked by the hook only;
  deposits and compounding can be delayed at a cost.
- Stock types (round 2) are priced by a single leg.

### Known issues added 2026-11-07

- **An auction healed by the price alone stays open.** A repayment or deposit that heals a seat (or stock) position ends
  its auction in the same call. One healed by the price stays open until someone calls the permissionless `cancel`; if
  it dips again within the auction's life it sells at the auction's decayed price.
- **Value already in an empty sleeve is locked.** Premium that vested before anyone deposited, or what an exit left
  behind, belongs to the 1e6 offset shares minted to `0x…dEaD` at the first conversion. It stays in the pool and earns
  with it, and nobody can withdraw it.
- **A dead feed's edge mark stops counting after 7 days.** `Liquidator.releaseEdgeMark` drops a mark's debt from the
  edge capacity once its type has been unpriced 7 days (or the position has no debt). The debt itself still counts.
- **The Treasury covers edge bad debt only behind the sleeve.** `Treasury.coverBadDebt` falls through to its own balance
  only when the sleeve refuses with `UnknownIlk` (or covers nothing); any other sleeve revert reverts it, until the
  governor disables that sleeve listing.

### Known issues added in the 2026-11 internal review

Accepted after an internal adversarial review of this core. Dollar figures were measured on mainnet forks of the live
pools in early November 2026 (IMD/ETH v4 pool, sIMD line 24,333 imdUSD unless stated) and move with depth and prices.

**sIMD has no market check on its attested pair**

sIMD is priced by two attested legs (`low`, `high`) with the live pool in its `liveSpot` slot. The live leg sets the
redemption payout and `agree` only; `borrowable` and `low` do not read it.

- **A wrong pair is accepted.** A wrong attested pair, or a compromised attester key, moves sIMD up to 40% after a silence
  and 20% per epoch, and repeated pairs from a stolen key walk further until someone pauses. Measured at the 24,333 line:
  a -40% pair makes a book that is healthy at the market liquidatable, costing borrowers about $18k with about $15.7k to
  the caller; a +40% pair pays an attacker nothing. **Re-measure before any raise of the sIMD line.**
- **The guard.** `liquidate(id, minSeized)` and `bite(id, minSeized)` revert `SeizedTooLow` if a price update lands ahead of
  the caller. The standing bid path ignores it, and the unguarded forms remain.
- **Pushing the live pool inside a transaction.** The standing bid buys only while the live pool is not below `low` by more
  than `skew`. With a fresh pair stale-high, one transaction can push the pool up into `skew` of the pair and force the bid
  above the market. A push down past `skew` instead sends the liquidation to the caller, who takes the penalty's value;
  the sleeve loses only that bonus. A charged rate change is refused with the pair above the pool; borrowing is not.
- **NHI has no market check.** NHI is attested only; a wrong NHI on an NHI-linked type is bounded by its feed's
  per-epoch cap and lifetime, not by a pool.
- `LoopVault` (off in the beta) reads `low` and `high`; it must be re-reviewed against this risk before it is turned on.

**Backstop sleeves**

- **Exits inside the claim window before a loss.** Holders whose withdrawal requests have matured can leave pro rata,
  inside the 2-day claim window, before a loss is booked (measured: 5,002 of 6,000 left). Queue designs have this; an
  exit is net of anything already booked.
- **`MAX_RATE` stop after repeated wipes.** After about 5 wipes of 1M each, the 6th recapitalisation's conversion waits
  forever (the share price falls under 1/`MAX_RATE` per wei). Deposits stay cancellable and new money is never lost; the
  sleeve then needs a replacement.
- **Cover gas.** A liquidation that books bad debt reverts `CoverGasShort` with under 2M gas left, so a caller cannot
  starve its cover; such a liquidation needs a gas limit above 2M. The cover stays best effort for other failures
  (mid-bid, an empty Treasury); `netVested` still nets the booked debt, and anyone can call the cover afterwards.
- **Booked loss above the room holds every bucket.** While booked bad debt exceeds what the sleeve can cover, every
  bucket waits and edge room stays shut, even for a small residual. Anyone can end it (fund the Treasury and call
  `coverBadDebt`, or call `Ledger.cover`); deposits can be cancelled in full. A deposit that waits past maturity holds a
  free option: it can cancel or convert when the hole closes.
- **Retire residual.** A `RETIRE_SLEEVE_TOKEN` applied at a stale read values that token at 0 for the next conversion:
  the converting deposit A gains `A x T / (C + A)` from the other holders (T the retired token's true value, C the
  sleeve's other value; measured: 10,000 became 13,133 and another holder lost 3,133). The Safe cancels a refused retire
  once the token is priced again, and `realize` clears the flag at the first good read.
- **Global brake beyond sleeve plus Treasury.** A liquidation covers edge bad debt in its own transaction, the edge
  sleeve first and then Treasury imdUSD. Whatever is left beyond both counts in the unbacked-supply brake, which is
  global: an edge loss larger than the sleeve plus the Treasury stops new debt on every type, not only on edge types,
  until someone covers it.

**Measured depth**

- **Depth griefing (cost corrected after the first public audit).** A push, a sample and the push back fit in one
  transaction (between two PoolManager unlocks) or one bundle, so no capital is held: the cost is the pool fee both ways
  plus gas, about 2% of the pushed notional (~$200 per hour for a 25% push at this snapshot's depth, ~$450 for 50%; the
  earlier "$9,998" was the IMD sold, which the attacker buys back). Four such hours in one UTC day lower the measured
  depth for about 8 days (depth 61,954 to 45,251 and sIMD line 21,636 to 10,500 at 25%; depth 36,648 and line 4,765 at
  50%). It can only lower the sIMD line; positions are untouched. The samplers use the live pool price x ETH/USD as their
  band reference (an attested reference would need an IMD price at most 1 hour old at every sample). Sampler 0 references
  its own pool (0xb07d), so its `maxDeviationTicks` guard is inert; samplers 1 and 2 are measured against 0xb07d's price,
  so a large push of 0xb07d makes them refuse `PoolOffReference` rather than deflate. A public sample can also be sandwiched
  to INFLATE a bucket (+L / sample / -L); the operator samples through private relays, an operational defence, not the
  contract's. A fix needs a reference a push cannot move (an attested leg, or a proven end-of-previous-block pool price).
- **Keeper outage closes new sIMD borrowing.** If no sampler is sampled for about 6 hours of a 26-hour window, it reads 0
  depth and the 7-day low holds new sIMD borrowing at 0 for about 8 days. Existing positions are untouched. Fail-closed by
  design.

**PEG positions**

- **Own-USDC leverage.** Zero-USDC loops are gone (PEG collateral comes only through the zap, with real USDC), but real
  USDC equity levered through a USDC flash loan and a sale of the borrowed imdUSD still reaches about `mat`'s bound: at
  `mat` 125%, $1,000 of own USDC carries $3,901 of debt (3.9x debt over own USDC, 4.9x collateral over equity). It is
  solvent at par, a leveraged short of imdUSD, bounded by the PEG line and the two-sided range. Opening CRs inside the
  gate: 134.09% at the floor rate, 131.61% with the average rate at its maximum.
- **Idle imdUSD in the PEG gate.** Idle imdUSD in the vault counts in its value but not in the two-sided gate: in a vault
  one holder owns, 538 USDC backed 80.4k of debt at CR 126%. It needs 20% real equity and is solvent at par.
- **The PEG line can be filled cheaply:** anyone locking about 12.5k fills a 50k line. It uses only PEG's own line.
- **At-mat edge liquidation.** Levering to the limit at the gate's edge and the pool then returning to the centre reads
  124.93% at `mat` 125%: liquidatable at once (a liquidator nets about 268 on 10.7k). The same holds for an off-centre
  borrow at -49 ticks (CR 1.10009 reads 1.09943 at the centre). Both are a borrower's own choice of maximum debt.
- Zap opens are griefable for about $5 per block: a 12-tick push (toll-free) trips the vault's spot-versus-TWAP gate, and
  uncollected fees or donations above the 0.05% share margin make every open revert `Slippage` until someone compounds.

**Rates and governance**

- **Operator rate + 1 wei.** SET_RATE is the owner's grant of trust. An operator's rate change of any size (even 1 wei,
  or none) restarts the 7-day cooldown, and the owner's next change then pays the premium (9.6 imdUSD on 10k measured).
  Grant it only to a manager you trust.
- A hostile `RateManager` key can front-run a member's own `setRate`, `leave` or `setLimits` with a free re-rate, so the
  member's change pays the cooldown premium.
- `RateManager.maxStep` limits the target per call, not a member's move: calls with no ids can walk the target across the
  whole range, then one call moves members by the full range.
- A 3-word `RETIRE_SLEEVE_TOKEN` payload passes `propose` and fails at apply; its slot holds until the governor cancels.

### Known issues added after the first public audit (wave 1, 2875ffb)

- **Seat swap during an auction.** A holder's seats are fungible: a borrower whose position is in auction can swap the
  pledged seat for another seat in the same block, and `take` delivers whichever seats remain. Seats are priced by the
  collection median, so the buyer pays the median-based price for any seat; trait premiums are not priced.
- **Peg TWAP one-block push.** One block with a pushed peg-pool price holds the Allocator's LP actions (spot more than 10
  ticks off the TWAP, keeper and rule-driven alike) and can hold `LoopVault.lever` for about 30 minutes. Griefing only.
- **Peg toll pricing.** The toll is priced on the swap's end price: splitting a push into several swaps pays about a third
  of the toll; a swap that overshoots $1 is tolled on its whole amount; exact-output swaps pay about 4% less at the cap.
- **Backstop conversion moment.** A matured deposit bucket converts at the asset value of the first call after it matures
  (00:00 UTC of day + 2); anyone may call `realize` first.
- **Rate floor 0 + `borrowFor`.** `borrowFor` passes rate 0; on a type with `rateFloor` 0 a borrow on a position whose debt
  reached zero before inclusion would open at 0%. Unreachable in the beta (every floor >= 0.5%).
- **First swarm-feed value.** Nothing on chain checks a leaf's first relayed value; seeding and checking it is the
  operator's duty.
- **Edge bootstrap renewal.** The Safe can renew an edge type's 60-day bootstrap allowance by disabling it (instant) and
  re-listing it (48 h); while disabled, borrowing and the standing bid on it are off.
- **Redemptions ignore the Pulse.** A redemption can run inside a sequencer grace that holds liquidations (Robinhood chain
  only; mainnet has no Pulse).
- **Flash cap is per loan in flight, not per transaction.** Sequential flash loans in one transaction each get the full
  cap; `circulating()` stays correct.
- **`circulating()` and flash loans.** Inside a native flash loan it reads at least the supply when the outermost loan
  began, so real burns inside the loan (a redemption split in chunks) also read against that supply: second order. The
  fix covers imdUSD's own flash mint only: imdUSD borrowed elsewhere to repay one's own debt, redeem and re-borrow still
  deflates the supply for the redemption, bounded by outside imdUSD liquidity, the upfront fee and the 5% fee cap.
- **The seat figure cap counts attestations, not time.** Each new attestation moves the figure at most -20% / +25% + 1;
  back-to-back attestations (one block apart, each poked) walk it further within minutes, as the median's cap does.
- **The PEG type on a deploy resume.** A resumed stage adopts PEG's registered pieces without comparing its risk, spot leg
  or peg aggregator with the config (the other types are compared).
- **Rule-driven Allocator actions (new since 2875ffb).** A caller picks the moment of each, and where rules share a token
  (the buffer's quote token, the LP vault's tokens and an auto vault's asset can all be USDC) which rule spends it first;
  value only moves between protocol addresses. The collateral auction's top is 103% of the sleeve's highest price
  (`max(low, high, payout)`; the payout follows the type's live pool), its floor 98% of `low`: a type with no live pool
  leg tops at its attested `high`, so in a rally the pair has not caught up with a buyer can pay under market. Anyone may
  restart a run once it reaches its floor (griefing: up to 2 hours per restart before the floor again).
  `rebalanceVault` deposits at the vault's share price of that moment: only rate-based vaults (sUSDS-like) are meant for
  it; changing the auto vault leaves the old vault's shares to a keeper or the Safe. `rebalanceLp` exits with zero
  minimums behind the spot-versus-TWAP gate. Each is bounded by its bucket, and `freeze()` (the Safe) stops all of them.

### What changed since the first public audit (2875ffb)

For the re-check: the second commit of this repository is the whole delta. Fixes: health and liquidation on the
post-harvest state; `circulating()` held at the outermost flash loan's start; the seat auction clock counts from
max(signed, relayed); the seat figure capped per attestation and `SeatFeed` priced 0 until its first poke; deploy resume
compares every kept piece with the config; USDC/USDS feeds 25 h; malformed BATCH items refused at propose; seat-sale bad
debt covered in the same transaction; bounded way-back and remote clock in `SwarmFeed`; `RateFeed` high-water; instant
lowers that could raise refused; the way back after a silence bounded by 2x the cap from the last value as well as the
cap from the level (bounding it to values between the two instead locked out an honest fall for two hours); `Backstop.deposit` for others only into today's slot; `payNote` waits while bad debt is
booked and `retireReserve` keeps notes' face; ledger premium and risk-version lows; `SET_KEEPER`/`SET_BRIDGE` and a full
sleeve refused at propose; `SeatAccount.sync` refuses the seat and its join; two more approval selectors denied. New: the
rule-driven Allocator actions and the Safe as freezer from genesis. Each fix has a test named `AuditW1*` (the auditors'
proofs, adapted) or sits in the existing suites.

## Reporting findings

Report privately to **admin@imdusd.com**; do not open public issues. Include
the affected contract and function, the impact, and a Foundry test that reproduces it (the suites in `test/unit/` show
the set-up helpers in `test/utils/`).
