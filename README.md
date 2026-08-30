# Hindsight

[![tests](https://github.com/OoJae/hindsight-hook/actions/workflows/ci.yml/badge.svg)](https://github.com/OoJae/hindsight-hook/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Ex-post markout-settled fees for Uniswap v4 — the fee is decided *after* your trade.**

> Every deployed MEV defense prices flow **before** it knows anything — volatility guesses, priority-fee taxes, auctions for rights. Hindsight prices flow from the one signal that cannot be faked, spoofed, or revert-spammed: **what the price actually did after your trade landed.** Benign flow is refunded to ~0. Informed flow pays its realized adverse-selection cost — streamed back to LPs.

Built for the **UHI10 Hookathon** (theme: *Sustainable Liquidity & MEV Protection*).

**🔗 Live app (Unichain Sepolia): https://oojae.github.io/hindsight-hook/**
**🔬 Interactive evidence: https://oojae.github.io/hindsight-hook/explorer/** — re-prices all
55,822 real mainnet swaps *in your browser* under any parameters you choose. Try to break it.
**Hook:** `0xeb77d98A9dfB72Fb17d196a3ec08F985bF0510c4` · all addresses in [`DEPLOYMENTS.md`](DEPLOYMENTS.md) — watch the real
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
- **Forfeits drip** to LPs via `donate()` on an epoch schedule, which *bounds* JIT sniping rather than hand-waving it away: measured in `test/integration/LPSet.t.sol`, a JIT LP that adds matching liquidity, triggers the flush and exits captures **15% of the pot** (one epoch's release × its liquidity share), while a durable in-range LP earns **5.3× more** across the following epochs. A lump donation would have handed that sniper 100%.
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
under each mechanism. Every number below is a *re-pricing of identical realized trades* —
no simulated agents, no behavioural assumptions. Reproduce with one command:
`cd backtest && .venv/bin/python compare.py`.

### 1. How much of the bleeding does it actually stop?

| | |
|---|---|
| LP fee income (status quo, 5 bps) | $6,690.77 |
| Gross realized adverse selection | $2,758.00 |
| Net LP markout P&L, ex-fees (the 5s LVR bleed) | −$525.54 |
| **Hindsight clawback** | **$1,071.39** (net of keeper tips: $1,017.82 to LPs) |
| **ρ = clawback ÷ realized adverse selection** | **38.8%** |
| **clawback ÷ net LVR bleed** | **2.0×** |

**Hindsight recovers 39% of the adverse selection LPs actually suffered — twice the pool's
entire net 5-second LVR bleed.**

### 2. Same LP revenue — who pays it? (the whole thesis, measured)

Calibrate a volatility-scaled dynamic fee to raise *exactly* the revenue Hindsight raises
on the same flow, and ask who hands over the incremental money:

| mechanism | benign flow pays | toxic flow pays | share of incremental revenue from **benign** flow |
|---|---|---|---|
| Flat fee (5.80 bps) | 5.80 bps | 5.80 bps | **87.1%** |
| Volatility-scaled dynamic fee (5 + 2.875·σ) | 5.68 bps | 5.76 bps | **83.0%** |
| **Hindsight** | **5.00 bps** | **10.29 bps** | **0.0%** |

The dynamic fee charges toxic flow **5.76 bps** and benign flow **5.68 bps** — a 1.4% gap.
It cannot tell them apart. Hindsight charges **10.29 vs 5.00** — a 106% gap, with every
benign bond refunded in full. This is the organizers' own framing of the problem
("a dynamic fee can't tell the difference between a retail trader and a bot") turned into
a measurement. ![who pays](backtest/chart_who_pays.png)

### 3. We tax information, not volatility

Calibrate a *static* threshold to flag the same number of swaps, then bucket by realized-
volatility decile. In the most volatile decile the static threshold confiscates **2.3×**
more flow; the volatility-scaled threshold spares volatile-but-uninformed traders while
catching *more* in the quiet deciles, where a price move really does imply information.
![vol decile](backtest/chart_vol_decile.png)

### 4. Not tuned to a lucky window

ρ stays in a **39–59% band across a 60× range of settlement horizons** (1s → 80s), and the
k × θ_min sensitivity grid is smooth and monotone with no cliffs. Honest note: θ_min
dominates k on this tape (θ_min 3→12 ticks cuts the clawback ~70%; k 1.5→6.0 cuts it ~23%)
— §3 above is where the k term earns its keep. ![horizon](backtest/chart_horizon.png)

Plus the worked example from the mechanism design: a benign trader pays **$50 per $100k
swap** vs $300 on a 30 bps pool.

## Partner integrations

- **Unichain** — the mechanism is flashblock-native: settlement windows are measured on **Uniswap's official FlashblockNumber contract** (live builder-maintained proxies: mainnet [`0x3c3a…1ec3→proxy 0x3c3a8a41e095c76b03f79f70955fff3b03cf753e`], Sepolia [`0x056466f1a50a6B5e4DCCF106074ee0083D721a42`] — verified ticking at 200ms cadence). To our knowledge this is the **first v4 hook to consume it**. Graceful `block.number` fallback + owner emergency switch if builder infra ever halts; `src/OperatedFlashblockNumber.sol` mirrors the official V1 allowlist pattern as a contingency. Fork tests run the full cycle against the **real Unichain Sepolia PoolManager**.

- **Reactive Network** — **live and verified end-to-end.** An RSC on Reactive Lasna (`src/integrations/reactive/HindsightReactive.sol`, deployed `0x54893ee6300BE90eF771fd17437600b6b1421e7C`) subscribes to the hook's `SwapRecorded` events on Unichain Sepolia plus Cron sweep/flush topics, and drives settlement through the official callback proxy into `HindsightCallback` (`0x0caa8dE2A2aE4565987C0203B81aaB47D1cc70E6`). The current v3 deployment settles autonomously in ~24s; the first such settlement we captured a tx hash for was on the v1 bytecode: `0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4` (29s). Settlement liveness without any operated infrastructure.

- **Chainlink Automation** — `src/integrations/chainlink/HindsightUpkeep.sol` deployed on Base Sepolia (`0x128dfBf63d16f0969f9c39587D0D4080B76A0488`) against a second, chain-identical hook deployment (`0xE8eD0B1f0c14A09F84fC912C2cce90e77DEbd0C4`, running the hook's `block.number` fallback clock): three-mode conditional upkeep (settle/flush/poke), forwarder-gated, **three upkeeps registered programmatically against the live v2.3 registrar** (the web UI is deprecated to withdraw-only; we encoded the v2.3 `RegistrationParams` incl. `billingToken` by hand), auto-approved, LINK-funded, forwarders wired on-chain. Full transparency: Chainlink sunset classic-Automation testnet execution in mid-2026 and the Base Sepolia DON currently performs nothing for anyone (30h registry scan: zero `UpkeepPerformed` events) — so the perform path is proven by the fork suite executing the complete check→perform→refund cycle against the real Base Sepolia PoolManager (reproduce: `BASE_SEPOLIA_RPC_URL=<rpc> forge test --mc BaseSepoliaFork -vv`, ~13s; without an RPC the fork tests SKIP loudly rather than passing silently).

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
bot/keeper.mjs                 poke() open windows, settle() matured swaps, flushDonations()
backtest/                      fetch.py + replay.py against real Unichain mainnet swaps
test/
  spike/DeltaSigns.t.sol       bond delta math across ALL FOUR swap configs
  unit/                        fuzzed library tests
  integration/                 settlement, donation drip + LP accrual, reputation
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
forge test                                   # 101 tests: unit, integration, invariant
forge test --match-path 'test/fork/*'        # +5 fork tests (needs an RPC; SKIPs loudly without one)
forge test --mc UnichainSepoliaFork -vv      # fork suite vs real Unichain Sepolia state
forge test --gas-report

# backtest on real mainnet swaps
cd backtest && python3 -m venv .venv && .venv/bin/pip install matplotlib
.venv/bin/python fetch.py 7                  # 7 days of ETH/USDC swaps (1bp + 5bp pools)
.venv/bin/python replay.py                   # stats + charts

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
was run against this codebase; the resulting fixes are the v3 deployment. Two of the
headline claims did not reproduce under our own repro tests and were dropped rather than
"fixed" — the surviving issues, their exploits, and their regression tests live in
`test/integration/AuditRepro.t.sol`.

## Future work

- Production router with `IMsgSender` attribution and bond-aware `minAmountOut` (the demo router is v4-core's `PoolSwapTest` + `hookData` beneficiary passthrough, which the hook's `IMsgSender` fallback also supports)
- Time-weighted **median** settlement TWAP (current: jump-clamped time-weighted average)
- Cross-pool portable reputation via an attested registry; fast-lane flat-fee opt-out

## Status & provenance

Built during the UHI10 hookathon window (new code; scaffolding follows the UHI course's
v4 patterns — `Uniswap/v4-hooks-public` — credited here per the originality rules).
