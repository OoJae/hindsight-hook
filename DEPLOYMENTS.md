# Hindsight — Live Deployments (Aug 30, 2026)

**Public frontend: https://oojae.github.io/hindsight-hook/**

Deployer (all chains): `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f`

## Current deployment: v6 (post-audit-round-2, all findings closed — this is what to review)

v6 is the deployment in which every round-2 audit finding is closed, each with an executable
repro committed *before* the fix (`test/integration/AuditRepro2.t.sol`,
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
| **M9** *medium* | The live proof the project cited inverted the pitch: the largest markout was acquitted and two smaller ones convicted | published in full, diagnosed (θ and the markout share a window), and bounded with the 55,822-swap measurement — θ sits at its floor for 68.2% of swaps and never exceeds 32.4. Decoupling the windows is in README Future Work |
| **M10** *high, found live* | Not from the audit — **found by running v5 on-chain.** The Reactive lane stalled for ~30 minutes, and five swaps whose windows had already been **finalized benign** (markout 22–27 against θ 31) were auto-forfeited in full, because `_verdict` checked the grace deadline *before* consulting the finalized snapshot. That defeats the entire purpose of `finalize` and confiscates honest traders' bonds whenever a keeper is late | a finalized verdict now outranks the grace deadline. The anti-escape property is unchanged, carried by the precise mechanism instead of a blunt clock: a window whose data was *destroyed* still forfeits in full |

### Unichain Sepolia (1301) — primary, flashblock-native
| Contract | Address |
|---|---|
| **HindsightHook v6** | `0x4475d1A77cb15f7867A37877B3f59E9a847990C4` |
| dETH (token0) | `0x1FD46d8F28EA465b228Df9Ef0A8A00cB7f9A3906` |
| dUSDC (token1) | `0x7EFC03C77728919a56e2843817B824A8556aC744` |
| PoolSwapTest router | `0x39c026aC59e106B353b27b809E8bC7c698d57F9B` |
| PoolModifyLiquidityTest | `0x9812ab8300ed581ce10D8d2C94eEfE88847d2211` |
| Pool (5bps, ts=10) | poolId `0x022afa83b95fc7423696bcc99597b6f1b321ecec06b610bfa8e9e50237deabba` |
| Settlement horizon (live) | maturity **50** + window **25** flashblocks (~10s + 5s) |
| **HindsightCallback v6** (Reactive dest) | `0xD6e1F8D864D177ad55449aa4C4776e6709B8d8d3` |
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

**Live v6 proofs**
- benign swap #0 settled **autonomously by the Reactive Network**, no manual action — status
  flipped to Refunded ~40s after the swap (10s maturity + 5s window + RSC latency)
- the 8-swap arb burst (#1–#8) settled **entirely autonomously within ~60s** of the last
  window closing, with no keeper run and no manual transaction:

  | swap | markout | θ | verdict |
  |---|---|---|---|
  | #1–#5 | 20–27 ticks | 31 | refunded |
  | **#6** | 20 ticks | **3** | **forfeited** |
  | **#7** | 10 ticks | **3** | **forfeited** |
  | #8 | 0 ticks | 3 | refunded |

  Read the θ column honestly: **the largest markout was acquitted and two smaller ones
  convicted.** θ and the markout are measured over the same window, so the burst's own
  companion prints land inside the early swaps' windows and lift their threshold. On a
  9-print demo tape that is a timing artifact rather than classification, and we publish it
  as such (round-2 audit M9). The M4 clamp bounds it — θ can no longer be driven past 31,
  where it used to reach 171 — but it does not remove the coupling, which is why *decouple
  the θ window from the markout window* is in README Future Work. On the 55,822-swap mainnet
  tape the pathology is marginal: θ sits at its floor for **68.2%** of swaps, never exceeds
  **32.4**, and conviction is monotone in markout (every swap with markout ≥ 20 ticks is
  convicted at every θ level).
- forfeits stream to in-range LPs through the epoch drip rather than one lump
  (`pendingDonations` was 0.0457 dETH mid-drip) — the anti-JIT behaviour, live
- `sizeTierCap` configured on-chain (10e18), so the earned discount is actually enabled and
  the whale guard is real rather than nominal

### Reactive Lasna (5318007)
| Contract | Address |
|---|---|
| **HindsightReactive v6 (RSC)** | `0x163C7077F4480EB3315479bdf5831051DD91160a` |
| Subscriptions | SwapRecorded@1301 (v6 hook) + Cron10 + Cron100 — 3 confirmed via system-contract events |
| Monitor | https://lasna.reactscan.net/rvm/0x5d4e95e57cf3369e31e6a50d7c4fecb04177226f |

### Base Sepolia (84532) — Chainlink Automation leg, block-fallback clock
| Contract | Address |
|---|---|
| **HindsightHook v6** | `0x1f4BdB8C84613aB9533bB473Cdef51182BB750c4` |
| dETH / dUSDC | `0x157Cc52eFB280B44E98B8493B5BbbB7c142c3E54` / `0xC65Ced2D31EB581EF3F037bADeaf30597200D325` |
| PoolSwapTest router | `0x86e40a70A7A1d015868A884959E918f4b4dCAB67` |
| PoolModifyLiquidityTest | `0xa327f0bF1963Ae45dd9dB615a4c66b0F36369C52` |
| Pool (5bps, ts=10) | poolId `0x36f7849d9473f0c0482666557308568f096b1b1b3a9f4d39fdd80a3cc657f340` |
| **HindsightUpkeep v6** | `0xc8d20Aaa0436B7F0370Eda41c4Aa4064bDec7E9a` |
| Chainlink registry / registrar (v2.3) | `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3` / `0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A` |

**Upkeeps — registered programmatically** (the Automation UI is deprecated to withdraw-only):
| mode | upkeepId | forwarder (wired ✓) |
|---|---|---|
| 0 settle | `66401174158075418063792843285484099426173393167490233374515116707068100459557` | `0xcE2D5c831c9A68232d070bbC27a3bDee7835635c` |
| 1 flush | `51653760350982945631445245922043618952535209414620510075175420470135995064051` | `0xeCe7C46b94aD03b0ECEcFCc6fB84278B97436636` |
| 2 poke | `63612813285201522633405703465742207491968058638879835633354831708836748570782` | `0x3561eED61909f429b7581ab1E8C0eF070F8a3870` |

**Fallback-clock proof (v6, Base Sepolia).** Base has no flashblock counter, so this hook
is deployed with `flashblockNumber = address(0)` and runs the `block.number × 10` fallback
clock. Full cycle proven live: retail swap → observation stamped at `461768590` (a derived
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
local build: 24372 bytes runtime, 31 immutable spans masked, ObservationLib linked at 0xf210c23792630cf1a119b696d3a2922b7b7550d4

  MATCH    Unichain Sepolia   0x4475d1A77cb15f7867A37877B3f59E9a847990C4
  MATCH    Base Sepolia       0x1f4BdB8C84613aB9533bB473Cdef51182BB750c4

All live hooks run exactly this source.
```

The comparison is byte-for-byte over the full 24,372-byte runtime, with exactly two
normalisations, both mechanical: immutable spans are masked (their positions come from
solc's own `immutableReferences`, not from us — `poolManager`, `flashblockNumber` and the
owner necessarily differ per chain), and `ObservationLib`'s `__$…$__` link placeholders are
resolved to its deployed address `0xf210c23792630cf1a119b696d3a2922b7b7550d4`. Both hooks
link the *same* library address on both chains. Nothing else is allowed to differ.

The hook is 24,372 bytes against the 24,576-byte EIP-170 limit — **204 bytes of headroom**.
That constraint shapes real decisions: `optimizer_runs` is 200 rather than 800;
`finalizeBatch` and `forceClockFallback` were removed rather than kept (`finalize` is
already called implicitly by `settle`/`settleOne`, and a manual clock override was a
liability we did not need); and the reputation-curve constants are `internal` rather than
`public`, because each auto-generated getter cost ~50 bytes we needed for the M4–M7 fixes.

## Archived
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
