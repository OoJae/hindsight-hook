# Hindsight — Live Deployments (Aug 30, 2026)

**Public frontend: https://oojae.github.io/hindsight-hook/**

| Route | What it is |
|---|---|
| `/` | The landing page — what the mechanism is, in one scroll |
| `/mechanism` | How a swap becomes a verdict, in four steps |
| `/evidence` | The numbers, the nulls, and the retracted claims |
| `/swap` | The live tool: swap on the pool and watch it settle |
| `/lp` · `/toxicity` · `/explorer` | LP dashboard, address lookup, client-side re-pricer |

Deployer (all chains): `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f`

## Current deployment: v8 (three audit rounds closed — this is what to review)

v8 closes round 3. Every finding across all three rounds has an executable repro committed
*before* its fix (`test/integration/AuditRepro2.t.sol`,
`test/integration/EvictionExploit.t.sol`). Verify the source matches the chain with
`forge build && python3 tools/verify_deployment.py`.

| # | Finding | Fix |
|---|---|---|
| **M1** *critical* | Evicting the 128-slot ring buffer with cheap micro-swaps made the window unreadable, and the "no data" branch **refunded in full** — any toxic trade could buy its way out | permissionless `finalize(swapId)` locks the verdict the instant the window closes; `_noDataVerdict` now separates *destroyed* data (forfeit, ungraded) from *absent* data (refund) |
| **M4** *high* | A trader could pad their own settlement window with round trips and drive θ to `θ_min + k·maxJumpTicks` = **171 ticks** — above the entire realistic markout distribution (max 110, p99 = 15 across 55,822 real swaps), acquitting everything. The existing regression test probed inside the *maturity* period, so it never touched θ and would have passed with the clamp deleted | θ's volatility input is clamped at `MAX_VOL_JUMP_TICKS = 10` instead of the TWAP's 60. The two clamps defend opposite parties: the TWAP's loose clamp protects the trader from a manipulated settlement price, θ's tight clamp protects LPs from self-padding |
| **M5** *high* | The bond is withheld from the swapper's own output, but the refund was paid to whatever address `hookData` named — a **silent 25 bps skim** by any solver or frontend that builds calldata. With *empty* hookData the payee was the router, stranding refunds in a contract whose call had ended | `hookData` is honoured only when it names `tx.origin`, or when a trusted router vouches via `IMsgSender`; everything else refunds to `tx.origin` |
| **M6** *high* | `setParams` is read at settle time, so `maturity=0, window=1, grace=1` retroactively pushed **every escrowed bond** past grace and auto-forfeited it at 100%, bypassing θ and the ramp. The test that "disproved" this asserted `assertGe(unsigned, 0)` — vacuously true | the settlement deadline `maturity + window + grace` may only ever move **later**, and `θ_min ≤ 1000` so the mechanism cannot be switched off |
| **M7** *medium* | A benign settle pays `keeperTipBps × 0 = 0`, while a lapsed bond auto-forfeits at 100% and tips 5% of the whole bond — so **waiting paid 20× more than settling** (measured) | no keeper tip on any *ungraded* forfeit. Prompt settlement now weakly dominates for every swap, and the lapsed bond still goes to LPs in full |
| **M8** *medium* | The explorer rendered `NaN%` and `5 + 200.00·σ bps` at the horizon stop its own copy told you to try | the degenerate stop is unreachable and every derived statistic renders `n/a` rather than `NaN`; swept all sliders to their extremes to confirm |
| **M9** *medium* | The live proof the project cited inverted the pitch: the largest markout was acquitted and two smaller ones convicted, because θ and the markout were measured over **the same window** — so a trade's own companion prints raised the very bar it was judged against | **v7 closes this at the root.** θ's volatility is now measured over `[exec−600, exec−1]`, a window that has already closed when the swap lands, and is snapshotted into the swap record at execution. Padding the settlement window now moves θ by *exactly zero* — asserted as an equality, not a bound. See "What changed in v7" below |
| **M10** *high, found live* | Not from the audit — **found by running v5 on-chain.** The Reactive lane stalled for ~30 minutes, and five swaps whose windows had already been **finalized benign** (markout 22–27 against θ 31) were auto-forfeited in full, because `_verdict` checked the grace deadline *before* consulting the finalized snapshot. That defeats the entire purpose of `finalize` and confiscates honest traders' bonds whenever a keeper is late | a finalized verdict now outranks the grace deadline. The anti-escape property is unchanged, carried by the precise mechanism instead of a blunt clock: a window whose data was *destroyed* still forfeits in full |

### Round 3 — what a third adversarial pass found in v7

Six attack lanes, refute-by-default verification (two skeptics per finding, defaulting to
*refuted*), then a completeness critic. 25 raw findings → 14 verified → 13 survived. Report in
`../AUDIT-REPORT-3.md`. The shape of it: v7 froze θ because a mutable θ made the verdict
retroactive — and froze exactly *one* of the four inputs to a verdict.

| # | Finding | Fix |
|---|---|---|
| **B** *critical* | `setParams` could **relocate an in-flight swap's markout window**. The M6 ratchet guards the deadline *sum*; nothing pinned the *split*, and `_doSettle` recomputed the window from live params. At the live values the owner could set `maturity=a, grace=3050−a`, pass the bound with **equality**, and repeat without limit. Reproduced: the markout a swap was judged on moved **1110 → 1200 ticks** after it landed | `SwapRecord` now carries `fMaturity`, `fWindow` and `fRamp` beside `fTheta`. The entire verdict tuple is fixed at execution |
| **C** *high* | `rampTicks` was read live too, and its bound was **arithmetically vacuous**: `MarkoutLib` returns a full forfeit for any excess ≥ ramp, so `ramp=1` and the forbidden `ramp=0` are identical. An owner could turn every in-flight partial forfeit into a total one | ramp frozen in the record; bound raised to `≥ 2` so it means something |
| **D** *high* | A refund that **cannot be delivered** made a record permanently unretirable. The payout was a push transfer; a currency that reverts to one address froze that swap in `status 0` forever, and **both** automation cursors break at the first pending id — starving every honest swap behind it, with no admin recovery | the take is wrapped, falling back to minting ERC-6909 claims to the trader. Claims cannot fail, so the record always retires |
| **E** *high* | The forfeit drip was a **bearer instrument**. It released half the pot per epoch (the spec says ~1/50) and `flushDonations` is permissionless on a readable gate. Measured: a JIT with **1/7 of the incumbent's capital took 98% of a pot**, and a toxic trader recaptured **98% of their own forfeit**. `LPSet.t.sol` asserted a *single-epoch* bound and never measured the repeated snipe | `DRIP_DENOM = 50`, plus a **60-second liquidity residency** so the snipe cannot be atomic. Fee collection is explicitly exempt |
| **F** *high* | The earned bond discount was **farmable**, and `script/02` — added in v7 — turned the enabling parameter on for both live pools. `benignSettles` was global per address while `sizeTierCap` is per pool: farm 30 dust settles on a pool you control, spend a **10× discount** on a real one | reputation is now keyed **per pool** |
| **A** *high* | §6's "out-of-sample" test measured **window overlap, not prediction** — see below | re-anchored; §6 rebuilt around a per-address split-half test |
| **G3** *high* | The **backtest did not compute the contract's θ**: `ObservationLib` divides as integers and `_theta` floors again, while `compare.py` used floats | backtest is integer-for-integer, and capped at the 128-slot ring |
| **I** *high* | §2's "0.0% from benign flow" was a **string literal**, true by construction | scored a second way against an independent label |

Two findings of my own, found before the report landed, are folded in: the `rampTicks` lever
(C above) and that permissionless `poke()` can **deflate θ for everyone** by diluting a
count-mean with zero-magnitude jumps. The audit's economics on the latter were better than
mine — +$262/week, not the +$625 I first computed against the float model — and it is
disclosed rather than fixed, because the estimator change it needs would move every headline
again.

### What changed in v7 (retained — this is why θ moved to a trailing window)

v6 *bounded* M9 (the M4 clamp cut the pump from 171 ticks to 31). v7 removes the channel, and
the investigation that led there changed the mechanism's own story.

We A/B'd six θ estimators on the committed 55,822-swap tape, all calibrated to flag the
**same share** of flow so that "flags more" could not masquerade as "classifies better", and
refereed on the one label the mechanism never observes — realized drift on a **disjoint**
later window `[t+20s, t+60s)`:

| θ estimator | Spearman(charge, FUTURE harm) | false positives on harmless flow |
|---|---|---|
| static (no vol term) | 0.5042 | 5.6% |
| **trailing σ over `[t−120s, t)` — v7** | **0.5048** | **5.3%** |
| in-window σ — what v6 shipped | 0.4719 | 5.4% |

**The shipped estimator was the worst of the six.** The volatility term was never the
problem; where it was *sourced* was. A five-second forward window is both writable by the
trade being judged and far too noisy to estimate a volatility regime.

The measurement that settles it — on ordinary mainnet flow, with nobody attacking:

| | |
|---|---|
| swaps with ≥1 of their **own** sender's prints inside their own θ window | 9,154 (16.4%) |
| swaps that actually inflated their own θ | 4,195 |
| mean inflation among those | **+2.72 ticks** (max +22.4) |
| **swaps acquitted purely because of their own prints** | **927 (1.66% of all flow)** |

Under a window that closes before the trade lands, every number in that table is **zero** —
not because a clamp was tightened, but because there is nothing left for the trade to write
into. `k` was recalibrated 2.8 → 1.4 for the new σ; `θ_min` stays at 3 because it also sizes
the bond cap via `_bondCap`. Same aggressiveness (21.7% vs 21.6% flagged), same recovery
(ρ 46.5% vs 46.8%), better classification, and a **stronger** permutation null (z = +5.19 vs
+4.99).

Honest cost, published rather than buried: the in-window sourcing genuinely did buy better
false-positive protection in the top volatility decile (7.8% vs 14.2%), and the trailing one
does **not** reproduce that. We took the trade anyway, because that protection was bought
with a threshold a trader can move — see the 927 acquittals above. `compare.py` §4 prints the
decile table on *both* volatility axes, because each estimator flatters itself on the axis
that is its own input.

### Unichain Sepolia (1301) — primary, flashblock-native
| Contract | Address |
|---|---|
| **HindsightHook v8** | `0xDecF9FA10d1dE837D96Fca76fE31302D82641aC4` |
| dETH (token0) | `0x7A18330B94Cdc15cf2426A4C61d2948B5C78562d` |
| dUSDC (token1) | `0xDa18a4C19601E698Af9e74d0b84d945871f096ea` |
| PoolSwapTest router | `0x4C12f1300b5277FEb15Ba77F8d7e9D8781bD11d0` |
| PoolModifyLiquidityTest | `0x6faB9817C9c7bA2049DBdBf35705e2C04b1085B9` |
| Pool (5bps, ts=10) | poolId `0x00d329ee1d22b569f6912ff6d01795d6c7f221dcff386b89f12ba1be18f3ce5a` |
| Settlement horizon (live) | maturity **50** + window **25** flashblocks (~10s + 5s) |
| **HindsightCallback v8** (Reactive dest) | `0xF6Dad7BB03a9cf89f4E3b98912Aea695F6b27227` |
| Clock: official FlashblockNumber | `0x056466f1a50a6B5e4DCCF106074ee0083D721a42` (live, 200ms) |
| Reactive callback proxy | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Owner (admin, 2-step transferable) | `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f` |

**Settlement horizon (Aug 30):** both pools run a **10s + 5s** horizon, set through the
bounded `setParams` rather than a redeploy. Reason: our round-2 audit's permutation null
showed the original 3s+2s horizon does not beat random-label chance (z = −1.68), because
sub-5s post-swap drift is dominated by a trade's own price impact rather than by
information. At 10s+5s the true labels beat the null by **+4.5σ**. This is also the first
real exercise of the bounded-owner design: *lengthening* a horizon is exactly the direction
the M6 ratchet permits, because it can only ever push a settlement deadline later — never
pull one in under an already-escrowed bond.

**Operational note (worth knowing before you reproduce this).** A Reactive RSC pays for its
own `react()` executions out of its Lasna balance, and the Cron10/Cron100 subscriptions tick
constantly whether or not there is work. Our v5 RSC was funded with 0.05 REACT and ran dry
in about eight minutes, silently stalling settlement — which is how we found M10. v6 is
funded with 5 REACT. If autonomous settlement stops, check the RSC's Lasna balance first and
re-run `activateSubscriptions()` after topping up. Separately, the Unichain Sepolia bridge UI
404s; the L1 deposit path works fine directly — `depositTransaction` on the OptimismPortal
`0x0d83dab629f0e0F9d36c0Cbc89B69a489f0751bD` (verified via its SystemConfig
`0xaeE94b9aB7752D3F7704bDE212c0C6A0b701571D`, whose `l2ChainId()` returns 1301) credits the
same address on L2 in about 90 seconds.

**Live v8 proofs**
- benign swap #0 settled **autonomously by the Reactive Network** ~45s after the swap
- the 8-swap arb burst settled autonomously, and the θ column is now the cleanest it has been:

  | swap | markout | θ | ramp | verdict |
  |---|---|---|---|---|
  | #0 | 0 | 3 | 20 | refund |
  | #1 | 20 | 4 | 20 | **forfeit** |
  | #2 | 20 | 10 | 20 | **forfeit** |
  | #3 | 17 | 12 | 20 | **forfeit** |
  | #4 | 21 | 12 | 20 | **forfeit** |
  | #5 | 24 | 14 | 20 | **forfeit** |
  | #6 | 20 | 14 | 20 | **forfeit** |
  | #7 | 10 | 17 | 20 | refund |
  | #8 | 0 | 17 | 20 | refund |

  θ climbs **3 → 4 → 10 → 12 → 14 → 17** as the burst accumulates trailing volatility, instead
  of jumping in a single step: the threshold widens for the trades that come *after* the
  violence, never for the trades that caused it. Every markout above its threshold forfeits and
  every one below refunds. Compare v6, where the **largest** markout was acquitted and a
  10-tick one convicted.

  The `ramp` column is new and is the point of round 3: it is read from the swap record, not
  from live parameters, so nothing about how these swaps are judged could be changed after
  they landed.
- the Base leg's settled record shows the whole frozen tuple on-chain:
  `fTheta 3, fMaturity 50, fWindow 25, fRamp 20`
- `sizeTierCap` is configured on-chain and the live parameters come from `script/02`, so the
  deployment is reproducible from the repo

### Reactive Lasna (5318007)
| Contract | Address |
|---|---|
| **HindsightReactive v8 (RSC)** | `0x324d3DA5f40A9D533fe8FfEa7252D7f4b348cE77` |
| Subscriptions | SwapRecorded@1301 (v8 hook) + Cron10 + Cron100 — 3 confirmed via system-contract events |
| Monitor | https://lasna.reactscan.net/rvm/0x5d4e95e57cf3369e31e6a50d7c4fecb04177226f |

### Base Sepolia (84532) — Chainlink Automation leg, block-fallback clock
| Contract | Address |
|---|---|
| **HindsightHook v8** | `0xE07a6bb6657f1381e5665F7741DEc4d4eAC8dAc4` |
| dETH / dUSDC | `0x3Ac4FDD4c8c43fe14065F92F493b383B21F6F5C4` / `0x45901552fea21dDDA60c7269C299C307223fcE44` |
| PoolSwapTest router | `0xa027b4000DD79EE7A55FD6e3e788966a78D55239` |
| PoolModifyLiquidityTest | `0xd6e1F8D864D177ad55449aa4C4776e6709B8d8d3` |
| Pool (5bps, ts=10) | poolId `0x392b68199a0e1943b291ef4f5ff5357fd1b7b18800fcf8cdcb10fa743bfc549f` |
| **HindsightUpkeep v8** | `0x45109C72ED596bBD3786A4C5F36Ae1f88872b206` |
| Chainlink registry / registrar (v2.3) | `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3` / `0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A` |

**Upkeeps — registered programmatically** (the Automation UI is deprecated to withdraw-only):
| mode | upkeepId | forwarder (wired ✓) |
|---|---|---|
| 0 settle | `69152579333576010081723125963624263070200156798303860560930889289519614292457` | `0x2536917D3d3fAbD1E881b81806D110EB5D37cd23` |
| 1 flush | `46070468762791783498410043672320294357459978753086533144422649441817598946315` | `0xa1033A87129cD1e625c204b8f2e8B10B4d91DF15` |
| 2 poke | `46016421483709479932047679840499968928467126125948779487035541084177982875462` | `0xb95917D6B0A24B1375FE39259e6A7e06B0481cfC` |

(Funded by cancelling the v7 upkeeps and reclaiming their LINK — testnet LINK is not
faucet-replenishable at the rate five redeploys consume it.)

**Fallback-clock proof (v8, Base Sepolia).** Base has no flashblock counter, so this hook
is deployed with `flashblockNumber = address(0)` and runs the `block.number × 10` fallback
clock. Full cycle proven live: retail swap → observation stamped at `461836920` (a derived
stamp, not a flashblock) → `checkUpkeep(settle)` flipped **false → true** on-chain as the
window closed → `settle(0)` → **status Refunded**, the entire 0.0024987 dETH bond returned
to the trader in tx
a `settle(0)` that returned the full 0.0024987 dETH bond.
The same hook bytecode therefore works on a chain with 200ms flashblocks and on one with
2s blocks and no flashblock contract at all.

**Honest status on the Chainlink leg:** the upkeeps are registered, funded and wired, and
`checkUpkeep` returns true on-chain — but Chainlink sunset classic-Automation testnet
execution in mid-2026 and the Base Sepolia DON performs nothing for anyone (30h registry
scan: zero `UpkeepPerformed` events, registry-wide). The perform path is therefore proven
by the fork suite executing the full check→perform→refund cycle against the real Base
Sepolia PoolManager: `BASE_SEPOLIA_RPC_URL=<rpc> forge test --mc BaseSepoliaFork -vv`
(~13s). Without an RPC the fork tests SKIP loudly — they never report a silent pass.

## Verify that this repo is what is deployed

```bash
forge build && python3 tools/verify_deployment.py
```

```
local build: 24549 bytes runtime, 33 immutable spans masked, ObservationLib linked at 0xcc0d06b6a1794bf90ce44ab73d48a57cfe707908

  MATCH    Unichain Sepolia   0xDecF9FA10d1dE837D96Fca76fE31302D82641aC4
  MATCH    Base Sepolia       0xE07a6bb6657f1381e5665F7741DEc4d4eAC8dAc4

All live hooks run exactly this source.
```

The comparison is byte-for-byte over the full 24,549-byte runtime, with exactly two
normalisations, both mechanical: immutable spans are masked (their positions come from
solc's own `immutableReferences`, not from us — `poolManager`, `flashblockNumber` and the
owner necessarily differ per chain), and `ObservationLib`'s `__$…$__` link placeholders are
resolved to its deployed address `0xcc0d06b6a1794bf90ce44ab73d48a57cfe707908`. Both hooks
link the *same* library address on both chains. Nothing else is allowed to differ.

The hook is 24,549 bytes against the 24,576-byte EIP-170 limit — **27 bytes of headroom**.
That constraint shapes real decisions: `optimizer_runs` is 50 rather than 800;
`finalizeBatch` and `forceClockFallback` were removed rather than kept (`finalize` is
already called implicitly by `settle`/`settleOne`, and a manual clock override was a
liability we did not need); and the reputation-curve constants are `internal` rather than
`public`, because each auto-generated getter cost ~50 bytes we needed for the M4–M7 fixes.

## Archived
- **v7** (θ decoupled, but the rest of the verdict tuple was still mutable at settle time —
  round-3 findings B and C): Unichain hook `0xC4E83D74A486C056c6164655F1d2D5ae5408d0C4`,
  Base hook `0xc60C0be68D02BD38Bc8aF44cf71D157C904950c4`, RSC
  `0xC971B9073E118DF50FAE99FeFa7EeEaEEe32C1fC`.
- **v6** (M1–M10 fixed, but θ still shared the markout's window — the deployment whose own
  demo table inverted the pitch): Unichain hook
  `0x4475d1A77cb15f7867A37877B3f59E9a847990C4`, Base hook
  `0x1f4BdB8C84613aB9533bB473Cdef51182BB750c4`, RSC
  `0x163C7077F4480EB3315479bdf5831051DD91160a`.
- **v5** (M4–M8 fixed, but still forfeited finalized-benign bonds on a late settle — the
  deployment that surfaced M10): Unichain hook `0x606cc9e8378ccCa6730f22036794b275976D10C4`,
  Base hook `0x42ea635f451E58F83561dd2E8e5f4Fe7146690C4`, RSC
  `0xE1d388dDF96ab5a1d41b36c739D7bCaCDD554dc3`.
- **v4** (eviction fixed; M4–M10 still open): Unichain hook
  `0xcEC97e16765395c6F1Af849625b21b4a532110c4`, Base hook
  `0xdE2C8325275E86B61F9BA3b413cc43a905ba90C4`, RSC
  `0xF065d60db3aE5372BcC16c57D520aADd3116718A`.
- **v3** (post-audit-round-1, vulnerable to buffer eviction): Unichain hook
  `0xeb77d98A9dfB72Fb17d196a3ec08F985bF0510c4`, Base hook
  `0xE8eD0B1f0c14A09F84fC912C2cce90e77DEbd0C4`, RSC
  `0x54893ee6300BE90eF771fd17437600b6b1421e7C`.
- **v2** (bond-cap bytecode, pre-audit): Unichain hook
  `0x9b7835C368fc2E39f1225DaC36daA5c7560710c4`, Base hook
  `0xBec754788783e884b6C87708B39D587352C650C4`, RSC
  `0xB08c1A18905E6A8648B436BeaA112559938b1979`.
- **v1** (first live proofs): Unichain hook `0xbea8Ead88aE0E50bfC2F9633d1091875DE2890c4`;
  first full-cycle settle tx
  `0x940bf2f10c4e2990f32d835ffa923ea490c6d852bc746e70973df11d9f5deaf2`; **first autonomous
  Reactive settlement (29s, v1 bytecode)** tx
  `0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4`.

*(v1/v2 hooks were deployed with `owner = msg.sender` through the CREATE2 factory, which
left their admin functions unreachable — fixed in v3 with an explicit owner argument.)*
