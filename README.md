# Hindsight

[![tests](https://github.com/OoJae/hindsight-hook/actions/workflows/ci.yml/badge.svg)](https://github.com/OoJae/hindsight-hook/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Ex-post markout-settled fees for Uniswap v4 — the fee is decided *after* your trade.**

> Every deployed MEV defense prices flow **before** it knows anything — volatility guesses, priority-fee taxes, auctions for rights. Hindsight prices flow from the one signal that cannot be faked, spoofed, or revert-spammed: **what the price actually did after your trade landed.** Benign flow is refunded to ~0. Informed flow pays its realized adverse-selection cost — streamed back to LPs.

Built for the **UHI10 Hookathon** (theme: *Sustainable Liquidity & MEV Protection*).

**🔗 Live app (Unichain Sepolia): https://oojae.github.io/hindsight-hook/**
**🔬 Interactive evidence: https://oojae.github.io/hindsight-hook/explorer/** — re-prices all
55,822 real mainnet swaps *in your browser* under any parameters you choose. Try to break it.
**Hook:** `0x4475d1A77cb15f7867A37877B3f59E9a847990C4` · all addresses in [`DEPLOYMENTS.md`](DEPLOYMENTS.md) — watch the real
flashblock counter tick, get a bond quote, and see live settlements incl. an actual toxic
forfeit. Connect any wallet on Unichain Sepolia to swap ("Mint demo tokens" gives you balance).

---

## The problem

LPs on volatile pairs bleed value to informed flow: CEX-DEX arbitrageurs extract loss-versus-rebalancing (LVR) every block ($233.8M measured over 19 months on mainnet, 75% of it captured by just 3 searchers). Static fees can't fix this — a 30bps fee throttles the benign flow you want while barely denting the informed flow you don't. And dynamic fees can't either: as the UHI10 organizers put it, *"a dynamic fee can't tell the difference between a retail trader and a bot — it ends up punishing everyone equally."*

The newest generation of defenses (priority-fee MEV taxes à la Angstrom L2 / Balancer v3) price the *intent* to be first. But on fast rollups searchers no longer bid for priority — they **spam cheap reverting probes** (documented on Unichain in Aug 2025; >50% of Base gas is now MEV spam paying <10% of fees). A reverted probe pays zero MEV tax. Ex-ante pricing is structurally gameable.

## The mechanism

**You can't revert-spam a measurement of what already happened.**

```
 swap ──► bond escrowed (ERC-6909 claims, afterSwapReturnDelta)
             │
             ▼   N flashblocks (~3s on Unichain, via Uniswap's official
             │   FlashblockNumber contract — 200ms granularity)
             ▼
      settlement window [F0+N, F0+N+W] finalizes ── TWAP recorded
             │
             ▼
      settle(swapId)   ← permissionless, keeper-tipped
        │
        ├─ markout ≤ θ  (price reverted / stayed)  → FULL BOND REFUND
        │                                            effective fee ≈ 5bps headline
        └─ markout > θ  (trade predicted the move) → bond forfeited pro-rata
                                                     → dripped to in-range LPs
```

- **Markout** — signed post-trade drift in tick space (1 tick ≈ 1bp), measured against a **finalized** window: the verdict is a pure read; there is nothing to sandwich at settlement.
- **θ = θ_min + k·σ** — the toxicity threshold breathes with realized volatility, so trending markets don't confiscate benign momentum flow. *We tax information, not volatility.*
- **Bond** = 25bps of notional × reputation multiplier. New addresses pay full freight (discounts are **earned** through settled benign history — Sybil-proof); addresses caught extracting pay up to 3×; whales get no discount above a size tier (no reputation laundering).
- **Forfeits drip** to LPs via `donate()` on an epoch schedule, which *bounds* the atomic
  snipe rather than hand-waving it away: a JIT LP that adds, triggers one flush and exits can
  take at most **one epoch's release — 50% of the pot** (15% at the specific liquidity ratios
  in `test/integration/LPSet.t.sol`, and it scales with the JIT's share), where a lump
  donation would have handed it 100%. The drip does not *penalise* a JIT that keeps coming
  back — payout is proportional to liquidity-weighted presence at flush instants, so a JIT
  that attends every flush earns what a durable LP earns. That is the honest characterisation:
  the drip converts a single snipeable event into a stream you must keep showing up for.
- **Missing data ⇒ refund** (withholding observations can never punish a trader), but **unsettled bonds auto-forfeit after a grace period** (waiting out the observation buffer is not an escape hatch).
- Reverted transactions never land, never post bonds, never enter the measurement — the revert-spam attack that defeats ex-ante taxes simply does not apply.

## vs. the state of the art

| | prices | infrastructure | revert-spam | who pays |
|---|---|---|---|---|
| Angstrom L2 tax | ex-ante (priority tip) | off-chain validator net (L1) / tip semantics (L2) | ❌ gameable | everyone who bids |
| Balancer v3 MEV hook | ex-ante (priority tip) | none | ❌ gameable | everyone who bids |
| am-AMM (Bunni v2 †) | ex-ante (manager lease) | Harberger auction + manager | — | uniform fee |
| Dynamic/volatility fees | ex-ante (proxy guess) | oracle | — | everyone equally |
| **Hindsight** | **ex-post (realized markout)** | **none — fully on-chain, permissionless keeper** | ✅ **immune** | **only flow that measurably extracted** |

† the only am-AMM production deployment was exploited and shut down in 2025.

## Sustainable liquidity, quantified — on real mainnet flow

`backtest/` re-prices **7 days of real Unichain mainnet ETH/USDC swaps** (55,822 of them)
under each mechanism. Every number is a *re-pricing of identical realized trades* — no
simulated agents, no behavioural assumptions. Reproduce in one command:
`cd backtest && .venv/bin/python compare.py`.

### 0. We publish the null

Before any headline: does the trade-direction signal actually carry information, or would
*random* labels collect just as much? Flipping a swap's direction negates its markout, so we
shuffle directions and re-run — everything else untouched.

| horizon (N+W) | true clawback | random-label mean | z | beats |
|---|---|---|---|---|
| 1+1s | $654 | $960 | **−4.53** | 0/30 |
| 3+2s | $1,071 | $1,187 | **−1.68** | 3/30 |
| 5+2s | $1,576 | $1,503 | +0.92 | 25/30 |
| **10+5s (shipped)** | **$2,338** | $1,980 | **+4.52** | **30/30** |
| 30+10s | $4,028 | $3,171 | +9.45 | 30/30 |

**At short horizons the mechanism does not beat chance** — the dominant post-swap signal
there is a trade's own price impact, not information (large trades see price revert against
them, so random labels can collect *more*). Informational drift only separates from impact
at ~10s. We ship the horizon where the signal is real, and publish the null beside it. An
earlier draft of this README quoted the 3+2s numbers; our own second-round audit caught it.

### 1. How much of the bleeding does it stop?

| | |
|---|---|
| LP fee income (status quo, 5 bps) | $6,690.77 |
| Post-swap drift in the trade's direction (gross positive) | $5,001.53 |
| Net LP markout P&L, ex-fees (the 15s LVR bleed) | −$2,186.54 |
| **Hindsight clawback** | **$2,337.72** (net of keeper tips: **$2,220.83** to LPs) |
| **ρ = clawback ÷ gross positive markout** | **46.7%** |

ρ is deliberately measured against *gross* adverse selection, not net: the mechanism prices
each trade's own informational cost and does not credit an informed trader for the
favourable markout that uninformed flow happened to hand back. Netting the two is exactly
the pooling this hook exists to undo — but the gross/net split is in the table so you can
judge that choice yourself.

### 2. Same LP revenue — who pays it?

Calibrate a volatility-scaled dynamic fee to raise *exactly* the revenue Hindsight raises on
the same flow, then ask who hands over the incremental money:

| mechanism | benign pays | toxic pays | separation | incremental revenue from **benign** flow |
|---|---|---|---|---|
| Flat fee (6.75 bps) | 6.75 bps | 6.75 bps | 1.0× | **75.7%** |
| Volatility-scaled dynamic fee (5 + 4.22·σ) | 6.66 bps | 7.02 bps | 1.05× | **71.9%** |
| **Hindsight** | **5.00 bps** | **12.18 bps** | **2.44×** | **0.0%** |

All fees are volume-weighted — what a dollar of flow actually pays, and the same definition
the [browser explorer](https://oojae.github.io/hindsight-hook/explorer/) and `replay.py` use,
so all three agree. Given the *same* LP revenue, the best ex-ante signal available in
`beforeSwap` separates toxic from benign flow by **5%**; Hindsight separates them by **144%**,
and every benign bond comes back in full. ![who pays](backtest/chart_who_pays.png)

### 3. Two obvious objections, answered with data

**"Circular — you define 'toxic', then grade competitors against your own labels."** The
obvious rebuttal — correlate each mechanism's *charge* against realized markout — is a
**tautology, and we'll say so first**: our charge is a monotone function of the settlement
markout, so that test scores ~0.80 on pure Gaussian noise (higher than it scores on the real
data). It proves nothing. So we score the charge against harm it **never observed**: set the
charge on the settlement window `[t+10s, t+15s)`, then measure harm on a **disjoint later
window** `[t+20s, t+60s)`, with a shuffled-harm control. The competitor is steelmanned with a
**trailing** 120s volatility signal — what a hook can actually read in `beforeSwap`.

| mechanism | Pearson | Spearman |
|---|---|---|
| **Hindsight** | **0.424** | **0.420** |
| dynamic fee (trailing vol — fair ex-ante signal) | 0.036 | 0.007 |
| flat fee | 0.000 | 0.000 |
| *control: Hindsight vs shuffled harm* | *−0.001* | *0.002* |

Hindsight's charge predicts *future* adverse selection an order of magnitude better than a
volatility-scaled fee, and the control lands at zero exactly as it must.

**"Just one bot on a thin tape?"** The top address is half the dataset, so we removed it —
the result strengthens:

| sample | ρ | dynamic fee's take from benign |
|---|---|---|
| all 55,822 swaps | 46.7% | 71.9% |
| excluding top sender (n=27,920) | **48.3%** | 71.7% |
| excluding top-3 (n=12,128) | **53.5%** | 78.6% |

### 4. We tax information, not volatility

**First, a limitation we found by auditing our own live demo.** The 8-swap arb burst on
Unichain Sepolia settles with θ = 31 for swaps #1–#5 (all refunded, markout 20–27) and θ = 3
for #6–#7 (both forfeited, markout 20 and 10). The largest markout is acquitted and smaller
ones convicted, because θ and the markout are measured over *the same window*: the burst's
own companion prints land inside the early swaps' windows and lift their threshold. On a
9-print demo tape that is a timing artifact, not classification — and we would rather say so
than let it read as the mechanism working.

On the real 55,822-swap tape it does not behave that way. θ sits at its floor (3 ticks) for
**68.2%** of swaps and never exceeds **32.4**, and conviction is monotone in markout: every
swap with markout ≥ 20 ticks is convicted at every θ level. The pathology needs a window
dense with other prints, which is a thin-tape condition. It is still a real edge — an
adversary who can pad their own window raises their own threshold — so it is capped in the
mechanism (θ can no longer be driven past 31, where it previously reached 171) and listed in
Future Work: *decouple the θ volatility
window from the markout window, so the drift being scored cannot raise its own threshold.*

With that said, here is the property measured at scale:

The threshold θ scales with short-horizon realized volatility, so a violent-but-uninformed
tape does not get confiscated. To show that term is doing real work, we calibrate a *static*
θ (4.0 ticks) to flag the same total number of swaps (12,010 vs 12,071) and compare what each
flags, by realized-volatility decile:

| vol decile | static θ flags | vol-scaled θ flags |
|---|---|---|
| 1 (quietest) | 13.0% | 18.7% |
| 5 | 11.1% | 16.6% |
| 9 | 31.5% | 18.9% |
| **10 (most volatile)** | **44.3%** | **24.2%** |

Same total flow flagged — but in the most volatile decile the static threshold confiscates
**1.8× more**, while the vol-scaled one *shifts* its attention toward quiet-tape flow, where
a large directional move is far more likely to be information than noise. That is the
mechanism refusing to charge traders for being unlucky.
![vol decile](backtest/chart_vol_decile.png)

### 5. Not tuned to a lucky window

ρ moves 42.5% → 58.6% across a 60× horizon range and the k × θ_min sensitivity grid is
smooth and monotone with no cliffs. Honest note: θ_min dominates k on this tape (θ_min 3→12
cuts the clawback ~70%; k 1.5→6.0 cuts it ~23%) — §4 above is where the k term earns its
keep. ![horizon](backtest/chart_horizon.png)

## Partner integrations

- **Unichain** — the mechanism is flashblock-native: settlement windows are measured on **Uniswap's official FlashblockNumber contract** (live builder-maintained proxies: mainnet [`0x3c3a…1ec3→proxy 0x3c3a8a41e095c76b03f79f70955fff3b03cf753e`], Sepolia [`0x056466f1a50a6B5e4DCCF106074ee0083D721a42`] — verified ticking at 200ms cadence). To our knowledge this is the **first v4 hook to consume it**. Graceful `block.number` fallback + owner emergency switch if builder infra ever halts; `src/OperatedFlashblockNumber.sol` mirrors the official V1 allowlist pattern as a contingency. Fork tests run the full cycle against the **real Unichain Sepolia PoolManager**.

- **Reactive Network** — **live and verified end-to-end.** An RSC on Reactive Lasna (`src/integrations/reactive/HindsightReactive.sol`, deployed `0x163C7077F4480EB3315479bdf5831051DD91160a`) subscribes to the hook's `SwapRecorded` events on Unichain Sepolia plus Cron sweep/flush topics, and drives settlement through the official callback proxy into `HindsightCallback` (`0xD6e1F8D864D177ad55449aa4C4776e6709B8d8d3`). The current v4 deployment settles autonomously ~60s after the swap (10s maturity + 5s window + RSC latency); the first such settlement we captured a tx hash for was on the v1 bytecode, when the horizon was shorter: `0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4` (29s). Settlement liveness without any operated infrastructure.

- **Chainlink Automation** — `src/integrations/chainlink/HindsightUpkeep.sol` deployed on Base Sepolia (`0xc8d20Aaa0436B7F0370Eda41c4Aa4064bDec7E9a`) against a second, chain-identical hook deployment (`0x1f4BdB8C84613aB9533bB473Cdef51182BB750c4`, running the hook's `block.number` fallback clock): three-mode conditional upkeep (settle/flush/poke), forwarder-gated, **three upkeeps registered programmatically against the live v2.3 registrar** (the web UI is deprecated to withdraw-only; we encoded the v2.3 `RegistrationParams` incl. `billingToken` by hand), auto-approved, LINK-funded, forwarders wired on-chain. This leg also proves the **fallback clock end-to-end on a chain with no flashblocks**: a live retail swap stamped at `461731830` (a `block.number × 10` stamp), `checkUpkeep(settle)` flipping false→true on-chain as the window closed, and `settle(0)` returning the full bond — tx `0x9984206868526b036a5e8bd6932063a2d3cbde1047fb01eef43cbd21b521796c`. Full transparency: Chainlink sunset classic-Automation testnet execution in mid-2026 and the Base Sepolia DON currently performs nothing for anyone (30h registry scan: zero `UpkeepPerformed` events) — so the perform path is proven by the fork suite executing the complete check→perform→refund cycle against the real Base Sepolia PoolManager (reproduce: `BASE_SEPOLIA_RPC_URL=<rpc> forge test --mc BaseSepoliaFork -vv`, ~13s; without an RPC the fork tests SKIP loudly rather than passing silently).

See `DEPLOYMENTS.md` for all addresses and proof transactions.

## Repository tour

```
src/
  HindsightHook.sol            the hook: bond escrow, observations, settlement, drip, reputation
  libraries/MarkoutLib.sol     markout + forfeit curve (pure)
  libraries/BondMathLib.sol    bond sizing: base bps × reputation, size tier, caps (pure)
  libraries/ToxicityLib.sol    per-address EMA + multiplier curve (pure)
  libraries/ObservationLib.sol flashblock-stamped ring buffer + jump-clamped TWAP
  OperatedFlashblockNumber.sol testnet counter mirroring the official V1 pattern
  mocks/MockFlashblockNumber.sol
script/                        00 counter → 01 hook (HookMiner) → 02 pool+liquidity → 03 demo flows
tools/verify_deployment.py     byte-for-byte: this source == the live hooks on both chains
bot/keeper.mjs                 poke() open windows, settle() matured swaps, flushDonations()
backtest/
  swaps_eth_usdc_5bp.csv.gz    7 days of REAL Unichain mainnet swaps (55,822), committed
  fetch.py                     rebuilds that tape from RPC (not needed to reproduce)
  replay.py                    headline stats + charts
  compare.py                   the 8-section evidence suite: null, LVR decomposition,
                               revenue-matched head-to-head, horizons, vol deciles,
                               sensitivity, out-of-sample, concentration, permutation
test/
  spike/DeltaSigns.t.sol       bond delta math across ALL FOUR swap configs
  unit/                        fuzzed library tests
  integration/                 settlement, donation drip + LP accrual, reputation
  integration/AuditRepro.t.sol      round-1 findings: one regression test each
  integration/AuditRepro2.t.sol     round-2 findings M4-M7, plus M10 found live on-chain
  integration/EvictionExploit.t.sol the round-2 critical: exploit, then closure
  invariant/                   claims exactly back pending bonds; custody == pot
  fork/UnichainSepolia.t.sol   full cycle vs the REAL PoolManager + REAL flashblock counter
```

## Run it

Measured steady-state gas (`forge test --mt test_gas_numbers -vv`): swap incl. hook + test
router ≈ 224k, settle refund ≈ 41k, settle forfeit incl. the donation drip ≈ 219k, poke ≈ 29k
— cents on an L2. (Measured after warm-up, so one-time funding/cold-storage costs are not
billed to them.)

```bash
git clone https://github.com/OoJae/hindsight-hook && cd hindsight-hook
# fast dep init (the full --recursive pulls ~1GB of unrelated nested submodules):
git submodule update --init lib/reactive-lib lib/v4-hooks-public
git -C lib/v4-hooks-public submodule update --init --recursive lib/v4-core lib/v4-periphery
git -C lib/v4-hooks-public submodule update --init lib/openzeppelin-contracts lib/solady lib/forge-std
forge test                                   # 118 tests: unit, integration, invariant
forge test --match-path 'test/fork/*'        # +5 fork tests (needs an RPC; SKIPs loudly without one)
forge test --mc UnichainSepoliaFork -vv      # fork suite vs real Unichain Sepolia state
forge test --gas-report
python3 tools/verify_deployment.py          # proves this source IS the live bytecode

# backtest on real mainnet swaps — the tape is COMMITTED (swaps_*.csv.gz), so this
# reproduces every published number offline, with no RPC and no fetch step
cd backtest && python3 -m venv .venv && .venv/bin/pip install matplotlib
.venv/bin/python compare.py                  # every number in "Sustainable liquidity, quantified"
.venv/bin/python replay.py                   # headline stats + charts
.venv/bin/python fetch.py 7                  # (optional) rebuild the tape from RPC yourself

# deploy (Unichain Sepolia)
cp .env.example .env                         # fill PRIVATE_KEY
forge script script/01_DeployHook.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
forge script script/02_CreatePoolAddLiquidity.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast
cd bot && npm i && npm start                 # keeper: poke/settle/flush
```

## Security posture

- Hook permission bits validated against implementation (`Hooks.validateHookPermissions`)
- `settle()` opens its own `unlock` — cannot be reentered from inside any swap (v4 lock)
- Callback authenticated to the PoolManager; verdicts computed only from finalized windows
- **θ's volatility input is clamped harder than the TWAP's** (10 ticks vs 60). The two clamps
  defend opposite parties: the TWAP's loose clamp protects the *trader* from a manipulated
  settlement price, while θ's tight clamp protects the *LPs* from a trader padding their own
  settlement window with round trips. Unclamped, that vector drove θ to 171 ticks — above the
  entire realistic markout distribution (max 110, p99 = 15 across 55,822 real swaps), which
  acquits everything (round-2 audit M4).
- TWAP: time-weighted with per-observation jump clamping; bond capped at the linearized cost of moving the pool by the toxicity threshold (`bond ≤ κ·L_active·θ`) so manipulation is never +EV — thin pools degrade toward a plain low-fee pool; range-exiting fills pay the standard bond (max realized price move = max markout exposure)
- Rounding: forfeits round down, refunds get the remainder (trader-favoring on dust)
- Invariant-tested: escrowed claims ≡ pending bonds; hook custody ≡ donation pot
- **The refund follows the money.** `hookData` is attacker-controlled, so it is honoured only
  when the named beneficiary *is* `tx.origin`, or when a whitelisted router vouches for a user
  via `IMsgSender`. Everything else refunds to `tx.origin`. An earlier version paid the
  hookData address unconditionally, which let any solver or frontend that builds the calldata
  skim the bond of a user who signed the transaction — the bond is withheld from the swap's
  own output, so it is never the calldata author's money. The same version paid `sender` when
  hookData was empty, stranding refunds inside routers whose call had long since ended. Both
  are closed and regression-tested (round-2 audit M5).
  *Known limitation:* for a relayed smart-contract-wallet swap, `tx.origin` is the relayer.
  That path must register as a trusted router implementing `IMsgSender` — which is the same
  requirement that already gets it proper reputation attribution.
- **Reputation cannot be moved by a third party.** It is read/written only for authenticated
  flow. Unauthenticated flow pays the full default bond and is reputation-neutral, so a fresh
  address buys nothing. (`tx.origin` is used as "who signed this transaction", never as an
  authorization grant.)
- **Owner powers are bounded, including over time.** `setParams` is read at settle time, so it
  is retroactive over in-flight bonds. The bounds are what make that safe: keeper tip ≤ 10%,
  `grace ≥ window`, `theta/ramp ≥ 1`, bond ≤ 100bps, `θ_min ≤ 1000` (so the mechanism cannot
  be switched off), and — new in v5 — **the settlement deadline `maturity + window + grace`
  may only ever move later.** Without that ratchet the owner could collapse the deadline to
  two stamps and auto-forfeit every escrowed bond at 100%, bypassing θ and the ramp entirely;
  the test that claimed to disprove this asserted `assertGe(unsigned, 0)` and was vacuously
  true (round-2 audit M6). Ownership is 2-step transferable and is an explicit constructor
  argument (hooks are deployed via the CREATE2 factory, so `msg.sender` would be the factory).
- **Waiting does not pay better than working.** A grace lapse and an evicted window both
  forfeit the full bond, so tipping the keeper on those branches made *waiting* pay 20× more
  than settling a benign bond promptly. The tip is now suppressed on any ungraded forfeit:
  prompt settlement weakly dominates for every swap, and the lapsed bond still goes to LPs in
  full (round-2 audit M7).
- **Batch settlement is fault-isolated**: each id settles behind an external self-call with a
  gas stipend, so one hostile beneficiary cannot stall the Chainlink/Reactive lanes.

### Audit
A multi-agent adversarial audit (4 attack lanes + independent verification of every finding)
was run against this codebase **twice**, and every surviving finding has an executable repro
committed *before* its fix, in `test/integration/AuditRepro.t.sol`,
`test/integration/AuditRepro2.t.sol` and `test/integration/EvictionExploit.t.sol`.

Round 1's fixes are the v3 deployment; two of its four headline claims did not reproduce
under our own repro tests and were **dropped rather than "fixed"**. Round 2 found eight more,
including a critical (buffer eviction let a toxic trade buy a full refund), a silent 25 bps
skim by anyone building the calldata, and an owner retune that could confiscate every
in-flight bond — plus a headline number of ours that did not survive its own null test. All
are closed in v6 and tabulated with their fixes in `DEPLOYMENTS.md`.

A ninth came from neither audit: **we found it by running the thing.** The Reactive lane
stalled for thirty minutes on the v5 deployment, and five swaps whose windows had already
been *finalized benign* were auto-forfeited in full, because the verdict logic checked the
grace deadline before consulting the finalized snapshot. Honest traders lost their entire
bond for a keeper being late. Fixed in v6, with the anti-escape property now carried by the
precise mechanism — a window whose data was *destroyed* still forfeits — rather than by a
blunt clock.

Two of the round-2 findings are worth reading in full even though they are closed, because
the honest version is more useful than the tidy one: §4 above publishes the case where our
own live demo inverts the pitch, and Future Work below names the structural change that
would remove the cause rather than bound it.

## Future work

- Production router with `IMsgSender` attribution and bond-aware `minAmountOut` (the demo router is v4-core's `PoolSwapTest` + `hookData` beneficiary passthrough, which the hook's `IMsgSender` fallback also supports)
- **Decouple θ's volatility window from the markout window**, so the drift being scored can
  no longer raise its own threshold. Today both are measured over `[exec+N, exec+N+W]`, which
  on a thin tape lets a burst's own companion prints acquit its early trades (see §4). The
  clamp bounds the damage; separating the windows would remove the coupling entirely. The
  obvious alternative — a lagged *pre-trade* volatility window — is rejected: it has no data
  for the first swaps into a pool or after any quiet period, collapsing θ to its floor and
  confiscating benign flow, which is the failure mode the vol-scaling exists to prevent.
- Time-weighted **median** settlement TWAP (current: jump-clamped time-weighted average)
- Cross-pool portable reputation via an attested registry; fast-lane flat-fee opt-out

## Status & provenance

Built during the UHI10 hookathon window (new code; scaffolding follows the UHI course's
v4 patterns — `Uniswap/v4-hooks-public` — credited here per the originality rules).
