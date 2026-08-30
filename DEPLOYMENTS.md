# Hindsight — Live Deployments (Aug 30, 2026)

**Public frontend: https://oojae.github.io/hindsight-hook/**

Deployer (all chains): `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f`

## Current deployment: v7 (all audit findings closed at the root — this is what to review)

v7 is the deployment in which every audit finding is closed, each with an executable repro
committed *before* the fix (`test/integration/AuditRepro2.t.sol`,
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

### What changed in v7, and why it is not just a patch

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
| **HindsightHook v7** | `0xC4E83D74A486C056c6164655F1d2D5ae5408d0C4` |
| dETH (token0) | `0x7401fd17a05Bf34CABAaDb233638E90375bb7d41` |
| dUSDC (token1) | `0xEbb36dd92C105c88C8Eb8d9e1c6d611F0191f157` |
| PoolSwapTest router | `0x5117b13AeB096e24FDf2F90a2012Df7D77DFF4da` |
| PoolModifyLiquidityTest | `0x6c85c9d828610375326DDE333335F80c788ab8a7` |
| Pool (5bps, ts=10) | poolId `0xd745e877a4fdbd31ba9989e11750a9a720af064e773a7b65fe68b6c48213ab03` |
| Settlement horizon (live) | maturity **50** + window **25** flashblocks (~10s + 5s) |
| **HindsightCallback v7** (Reactive dest) | `0x7d7Bf00f54648944Cafc336F357934f8F8994d76` |
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

**Live v7 proofs**
- benign swap #0 settled **autonomously by the Reactive Network**, no manual action — status
  flipped to Refunded ~70s after the swap (10s maturity + 5s window + RSC latency)
- the 8-swap arb burst (#1–#8) settled **entirely autonomously**. This is the table that
  motivated the whole v7 change, so compare it against v6's directly:

  | swap | markout | θ | v7 verdict | | v6 markout | v6 θ | v6 verdict |
  |---|---|---|---|---|---|---|---|
  | #1 | 29 | 3 | **forfeit** | | 20 | 31 | refund |
  | #2 | 30 | 17 | **forfeit** | | 20 | 31 | refund |
  | #3 | 26 | 17 | **forfeit** | | 24 | 31 | refund |
  | #4 | 26 | 17 | **forfeit** | | 27 | 31 | refund |
  | #5 | 25 | 17 | **forfeit** | | 24 | 31 | refund |
  | #6 | 20 | 17 | **forfeit** | | 20 | 3 | forfeit |
  | #7 | 10 | 17 | refund | | 10 | 3 | forfeit |
  | #8 | 0 | 17 | refund | | 0 | 3 | refund |

  **v6 convicted a 10-tick markout and acquitted a 27-tick one.** v7 is monotone: every
  markout above its threshold forfeits, every one below refunds, and the ordering follows the
  markout rather than the accident of who else happened to print inside the window.

  Read the θ column too. It is 3 for #1 — the first trade of the burst, judged against a
  quiet tape — and 17 for #2–#8, because by then the burst *is* the trailing history. That is
  the intended behaviour and the exact inversion of the old one: a violent tape widens the
  threshold for the trades that come **after** it, never for the trade that caused it. #7
  carries a 10-tick markout into a genuinely volatile tape and is correctly refunded; #1
  carries 29 ticks into a calm one and is correctly charged.
- forfeits stream to in-range LPs through the epoch drip rather than one lump — the anti-JIT
  behaviour, live
- `sizeTierCap` configured on-chain (10e18), and **the live parameters now come from
  `script/02`** rather than an out-of-band `cast send`, so the deployment is reproducible

### Reactive Lasna (5318007)
| Contract | Address |
|---|---|
| **HindsightReactive v7 (RSC)** | `0xC971B9073E118DF50FAE99FeFa7EeEaEEe32C1fC` |
| Subscriptions | SwapRecorded@1301 (v7 hook) + Cron10 + Cron100 — 3 confirmed via system-contract events |
| Monitor | https://lasna.reactscan.net/rvm/0x5d4e95e57cf3369e31e6a50d7c4fecb04177226f |

### Base Sepolia (84532) — Chainlink Automation leg, block-fallback clock
| Contract | Address |
|---|---|
| **HindsightHook v7** | `0xc60C0be68D02BD38Bc8aF44cf71D157C904950c4` |
| dETH / dUSDC | `0x30d1Fe73d5FC78Df3Be220eCa3A85Db12E3f8494` / `0xeFeB3Ea04E929eC8A76a41aD2F809d05361dd2a2` |
| PoolSwapTest router | `0x90CA9b6a60818AA77513Fe31919f41D747100db1` |
| PoolModifyLiquidityTest | `0xd6e1F8D864D177ad55449aa4C4776e6709B8d8d3` |
| Pool (5bps, ts=10) | poolId `0x72b00ee0c99e47a997cd624d200613f4a12045a60dc1c4471501525c238603be` |
| **HindsightUpkeep v7** | `0x38dED78f1ec799C5178aC1e16821aB2aB35B6893` |
| Chainlink registry / registrar (v2.3) | `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3` / `0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A` |

**Upkeeps — registered programmatically** (the Automation UI is deprecated to withdraw-only):
| mode | upkeepId | forwarder (wired ✓) |
|---|---|---|
| 0 settle | `69094049181521839374126344695202283104093419738140858415992704141098068099202` | `0x7568f3928f227413A490603250a2966001a6b7A6` |
| 1 flush | `13549975320375616542271876752189533374370366669386936248115233791090478765302` | `0x0A712E6529F543FF57065C7A4703060D3A8444dE` |
| 2 poke | `84809890909325669932730498371579414686682490134801380414810286204373809808010` | `0x0a0101F834455fB9433f0632538769B45B9C7Dad` |

**Fallback-clock proof (v7, Base Sepolia).** Base has no flashblock counter, so this hook
is deployed with `flashblockNumber = address(0)` and runs the `block.number × 10` fallback
clock. Full cycle proven live: retail swap → observation stamped at `461791240` (a derived
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
local build: 24443 bytes runtime, 31 immutable spans masked, ObservationLib linked at 0xf210c23792630cf1a119b696d3a2922b7b7550d4

  MATCH    Unichain Sepolia   0xC4E83D74A486C056c6164655F1d2D5ae5408d0C4
  MATCH    Base Sepolia       0xc60C0be68D02BD38Bc8aF44cf71D157C904950c4

All live hooks run exactly this source.
```

The comparison is byte-for-byte over the full 24,443-byte runtime, with exactly two
normalisations, both mechanical: immutable spans are masked (their positions come from
solc's own `immutableReferences`, not from us — `poolManager`, `flashblockNumber` and the
owner necessarily differ per chain), and `ObservationLib`'s `__$…$__` link placeholders are
resolved to its deployed address `0xf210c23792630cf1a119b696d3a2922b7b7550d4`. Both hooks
link the *same* library address on both chains. Nothing else is allowed to differ.

The hook is 24,443 bytes against the 24,576-byte EIP-170 limit — **133 bytes of headroom**.
That constraint shapes real decisions: `optimizer_runs` is 200 rather than 800;
`finalizeBatch` and `forceClockFallback` were removed rather than kept (`finalize` is
already called implicitly by `settle`/`settleOne`, and a manual clock override was a
liability we did not need); and the reputation-curve constants are `internal` rather than
`public`, because each auto-generated getter cost ~50 bytes we needed for the M4–M7 fixes.

## Archived
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
