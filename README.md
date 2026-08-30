# Hindsight

[![tests](https://github.com/OoJae/hindsight-hook/actions/workflows/ci.yml/badge.svg)](https://github.com/OoJae/hindsight-hook/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Ex-post markout-settled fees for Uniswap v4 — the fee is decided *after* your trade.**

> Every deployed MEV defense prices flow **before** it knows anything — volatility guesses, priority-fee taxes, auctions for rights. Hindsight prices flow from the one signal that cannot be faked, spoofed, or revert-spammed: **what the price actually did after your trade landed.** Benign flow is refunded to ~0. Informed flow pays its realized adverse-selection cost — streamed back to LPs.

Built for the **UHI10 Hookathon** (theme: *Sustainable Liquidity & MEV Protection*).

**🔗 Live app (Unichain Sepolia): https://oojae.github.io/hindsight-hook/**
**🔬 Interactive evidence: https://oojae.github.io/hindsight-hook/explorer/** — re-prices all
55,822 real mainnet swaps *in your browser* under any parameters you choose. Try to break it.
**Hook:** `0xcEC97e16765395c6F1Af849625b21b4a532110c4` · all addresses in [`DEPLOYMENTS.md`](DEPLOYMENTS.md) — watch the real
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

It is not only a backtest result — it is visible in the live deployment. An 8-swap arb
burst on Unichain Sepolia settled autonomously, and the verdicts split like this:

| swap | markout | θ | verdict |
|---|---|---|---|
| #1–#5 | 22–27 ticks | **31** | refunded — the burst's own violence raised θ above its markout |
| **#6** | 20 ticks | **3** | **forfeited** |
| **#7** | 10 ticks | **3** | **forfeited** |
| #8 | 0 ticks | 3 | refunded |

Same trader, same direction, same size. During the loud part of the burst the threshold
rises and the pool declines to confiscate; once the tape is quiet again and the price has
*stayed* where the arb pushed it, that persistence is the informational signature and those
trades forfeit. (Addresses and the on-chain reads are in `DEPLOYMENTS.md`.) The backtest
below measures the same behaviour across 55,822 swaps:

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

- **Reactive Network** — **live and verified end-to-end.** An RSC on Reactive Lasna (`src/integrations/reactive/HindsightReactive.sol`, deployed `0xF065d60db3aE5372BcC16c57D520aADd3116718A`) subscribes to the hook's `SwapRecorded` events on Unichain Sepolia plus Cron sweep/flush topics, and drives settlement through the official callback proxy into `HindsightCallback` (`0xb8d4CE44e1BaB3B712daE6568B51f9B7F85Fe9E8`). The current v4 deployment settles autonomously ~60s after the swap (10s maturity + 5s window + RSC latency); the first such settlement we captured a tx hash for was on the v1 bytecode, when the horizon was shorter: `0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4` (29s). Settlement liveness without any operated infrastructure.

- **Chainlink Automation** — `src/integrations/chainlink/HindsightUpkeep.sol` deployed on Base Sepolia (`0xDED9BF5E6bE87A82bDa4f9C268efe066FfADb468`) against a second, chain-identical hook deployment (`0xdE2C8325275E86B61F9BA3b413cc43a905ba90C4`, running the hook's `block.number` fallback clock): three-mode conditional upkeep (settle/flush/poke), forwarder-gated, **three upkeeps registered programmatically against the live v2.3 registrar** (the web UI is deprecated to withdraw-only; we encoded the v2.3 `RegistrationParams` incl. `billingToken` by hand), auto-approved, LINK-funded, forwarders wired on-chain. This leg also proves the **fallback clock end-to-end on a chain with no flashblocks**: a live retail swap stamped at `461731830` (a `block.number × 10` stamp), `checkUpkeep(settle)` flipping false→true on-chain as the window closed, and `settle(0)` returning the full bond — tx `0x9984206868526b036a5e8bd6932063a2d3cbde1047fb01eef43cbd21b521796c`. Full transparency: Chainlink sunset classic-Automation testnet execution in mid-2026 and the Base Sepolia DON currently performs nothing for anyone (30h registry scan: zero `UpkeepPerformed` events) — so the perform path is proven by the fork suite executing the complete check→perform→refund cycle against the real Base Sepolia PoolManager (reproduce: `BASE_SEPOLIA_RPC_URL=<rpc> forge test --mc BaseSepoliaFork -vv`, ~13s; without an RPC the fork tests SKIP loudly rather than passing silently).

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
  integration/AuditRepro.t.sol      one regression test per surviving audit finding
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
forge test                                   # 109 tests: unit, integration, invariant
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
- TWAP: time-weighted with per-observation jump clamping; bond capped at the linearized cost of moving the pool by the toxicity threshold (`bond ≤ κ·L_active·θ`) so manipulation is never +EV — thin pools degrade toward a plain low-fee pool; range-exiting fills pay the standard bond (max realized price move = max markout exposure)
- Rounding: forfeits round down, refunds get the remainder (trader-favoring on dust)
- Invariant-tested: escrowed claims ≡ pending bonds; hook custody ≡ donation pot
- **Attribution is authenticated.** `hookData` is attacker-controlled, so it can direct a
  refund (the payer's own money) but can never move someone else's reputation: reputation is
  read/written only for self-attributed flow (`beneficiary == tx.origin`) or flow vouched by
  a whitelisted router via `IMsgSender`. Unauthenticated flow pays the full default bond and
  is reputation-neutral. (`tx.origin` is used purely as "did this address participate", never
  as an authorization grant; AA wallets use the trusted-router path.)
- **Owner powers are bounded.** `setParams` is read at settle time, so it is retroactive over
  in-flight bonds — the bounds are what make that safe: keeper tip ≤ 10%, `grace ≥ window`,
  `theta/ramp ≥ 1`, bond ≤ 100bps. The owner can never construct a universal forfeit or route
  a bond to itself. Ownership is 2-step transferable, and is an explicit constructor argument
  (hooks are deployed via the CREATE2 factory, so `msg.sender` would be the factory).
- **Batch settlement is fault-isolated**: each id settles behind an external self-call with a
  gas stipend, so one hostile beneficiary cannot stall the Chainlink/Reactive lanes.

### Audit
A multi-agent adversarial audit (4 attack lanes + independent verification of every finding)
was run against this codebase **twice**. Round 1's fixes are the v3 deployment; two of its
four headline claims did not reproduce under our own repro tests and were dropped rather
than "fixed". Round 2 found a genuine **critical**: an attacker could evict a pending
swap's observation window from the 128-slot ring buffer with cheap micro-swaps, and the
resulting "no data" branch refunded the bond in full — buying your way out of a forfeit.
v4 closes it with a permissionless `finalize(swapId)` that snapshots the verdict the
instant the window closes, plus a `_noDataVerdict` that distinguishes *destroyed* data
(forfeit, ungraded) from *absent* data (refund). Every surviving issue, its exploit, and
its regression test lives in `test/integration/AuditRepro.t.sol` and
`test/integration/EvictionExploit.t.sol` — the latter reproduces the exploit against the
old logic and confirms it is closed against the new.

## Future work

- Production router with `IMsgSender` attribution and bond-aware `minAmountOut` (the demo router is v4-core's `PoolSwapTest` + `hookData` beneficiary passthrough, which the hook's `IMsgSender` fallback also supports)
- Time-weighted **median** settlement TWAP (current: jump-clamped time-weighted average)
- Cross-pool portable reputation via an attested registry; fast-lane flat-fee opt-out

## Status & provenance

Built during the UHI10 hookathon window (new code; scaffolding follows the UHI course's
v4 patterns — `Uniswap/v4-hooks-public` — credited here per the originality rules).
