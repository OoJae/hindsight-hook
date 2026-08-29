# Hindsight

**Ex-post markout-settled fees for Uniswap v4 — the fee is decided *after* your trade.**

> Every deployed MEV defense prices flow **before** it knows anything — volatility guesses, priority-fee taxes, auctions for rights. Hindsight prices flow from the one signal that cannot be faked, spoofed, or revert-spammed: **what the price actually did after your trade landed.** Benign flow is refunded to ~0. Informed flow pays its realized adverse-selection cost — streamed back to LPs.

Built for the **UHI10 Hookathon** (theme: *Sustainable Liquidity & MEV Protection*).

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
- **Forfeits drip** to LPs via `donate()` on an epoch schedule — no lump a JIT LP could snipe.
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

`backtest/` replays **7 days of real Unichain mainnet ETH/USDC swaps** through the exact on-chain markout logic (block-granular offline; the hook itself is 200ms-granular — conservative):

| ETH/USDC 5bp pool, 7 days | |
|---|---|
| swaps replayed | **55,822** ($13.4M volume) |
| LP fee income (status quo) | $6,691 |
| **Hindsight clawback on top** | **+$1,071 (+16.0% LP revenue)** |
| toxic flow identified | 9.9% of swaps, 12.9% of volume |
| benign effective fee | **exactly 5.00 bps** (bond fully refunded) |
| toxic effective fee | 11.2 bps (fee + forfeited bond) |

The top three forfeiting addresses are unmistakable bots (27,901 / 9,434 / 6,362 swaps in a week) — matching the research finding that a handful of searchers capture most CEX-DEX extraction. Meanwhile **90% of swaps pay exactly the headline fee**.

Plus the worked example in [mechanism-spec](../mechanism-spec.md): a benign trader pays **$50 per $100k swap** vs $300 on a 30bps pool; break-even recapture for LPs vs a 30bps pool is just 12%.

## Partner integrations

- **Unichain** — the mechanism is flashblock-native: settlement windows are measured on **Uniswap's official FlashblockNumber contract** (live builder-maintained proxies: mainnet [`0x3c3a…1ec3→proxy 0x3c3a8a41e095c76b03f79f70955fff3b03cf753e`], Sepolia [`0x056466f1a50a6B5e4DCCF106074ee0083D721a42`] — verified ticking at 200ms cadence). To our knowledge this is the **first v4 hook to consume it**. Graceful `block.number` fallback + owner emergency switch if builder infra ever halts; `src/OperatedFlashblockNumber.sol` mirrors the official V1 allowlist pattern as a contingency. Fork tests run the full cycle against the **real Unichain Sepolia PoolManager**.

- **Reactive Network** — **live and verified end-to-end**: an RSC on Reactive Lasna (`src/integrations/reactive/HindsightReactive.sol`, deployed `0x20dF56E0c2271A0D1e835A69A872139849e96F08`) subscribes to the hook's `SwapRecorded` events on Unichain Sepolia plus Cron sweep/flush topics, and drives settlement through the official callback proxy into `HindsightCallback` (`0xC971B9073E118DF50FAE99FeFa7EeEaEEe32C1fC`). Proof: swap settled autonomously in 29s by the Reactive relayer — tx `0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4`. Settlement liveness without any operated infrastructure.

- **Chainlink Automation** — `src/integrations/chainlink/HindsightUpkeep.sol` deployed on Base Sepolia (`0x163C7077F4480EB3315479bdf5831051DD91160a`) against a second, chain-identical hook deployment (`0x9C5e288E599EC90be441a5cCaFF73603F69E10C4`, running the hook's `block.number` fallback clock): three-mode conditional upkeep (settle/flush/poke), forwarder-gated, **three upkeeps registered programmatically against the live v2.3 registrar** (the web UI is deprecated to withdraw-only; we encoded the v2.3 `RegistrationParams` incl. `billingToken` by hand), auto-approved, LINK-funded, forwarders wired on-chain. Full transparency: Chainlink sunset classic-Automation testnet execution in mid-2026 and the Base Sepolia DON currently performs nothing for anyone (30h registry scan: zero `UpkeepPerformed` events) — so the perform path is proven by the fork suite executing the complete check→perform→refund cycle against the real Base Sepolia PoolManager. Registration txs + upkeep IDs in `DEPLOYMENTS.md`.

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

Measured gas (Foundry, `test/integration/Gas.t.sol`): swap+router+hook ≈ 313k total,
settle refund ≈ 91k, settle forfeit incl. donation flush ≈ 214k, poke ≈ 29k — cents on an L2.

```bash
forge test                                   # 63 tests: unit, integration, invariant, fork
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
- TWAP: time-weighted with per-observation jump clamping; bond capped so manipulation is never +EV (`bond ≤ κ·L_active·θ` — see mechanism spec §A3)
- Rounding: forfeits round down, refunds get the remainder (trader-favoring on dust)
- Invariant-tested: escrowed claims ≡ pending bonds; hook custody ≡ donation pot

## Status & provenance

Built during the UHI10 hookathon window (new code; scaffolding follows the UHI course's
v4 patterns — `Uniswap/v4-hooks-public` — credited here per the originality rules).
