# Hindsight — Live Deployments (Aug 30, 2026)

**Public frontend: https://oojae.github.io/hindsight-hook/**

Deployer (all chains): `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f`

## Current deployment: v4 (post-audit-round-2 — this is what to review)

v4 closes the round-2 audit's critical finding: an attacker could previously push a
pending swap's observation window out of the 128-slot ring buffer with cheap
micro-swaps, and the resulting "no data" branch **refunded the bond in full** — so any
toxic trader could buy their way out of a forfeit for the price of a few pokes. Two-layer
fix:

1. **`finalize(uint256 swapId)`** — permissionless, callable the instant the window
   closes, and snapshots the verdict (`fMarkout`, `fTheta`, `finalized`) into the swap
   record. Once finalized, later eviction cannot change the outcome. `settle()` and
   `settleOne()` call it implicitly, so the happy path is unchanged.
2. **`_noDataVerdict`** now distinguishes *destroyed* data from *absent* data. If the
   buffer is full and its oldest stamp is already past the window end, the data was
   evicted — the bond is **forfeited** and the trade is left ungraded (reputation-neutral,
   so eviction cannot be used to farm reputation either). Only genuinely absent data
   (a young buffer) still refunds.

Also in v4: `ObservationLib.writeOrUpdate` refreshes in place when the newest stamp
matches, `oldest()` exposes eviction state, and `avgAbsJump` clamps per-step jumps.
Repro tests: `test/integration/EvictionExploit.t.sol` (exploit before, closed after) and
`AuditRepro.t.sol` M4a/M4b/M4c.

Carried forward from v3: the post-swap tick enters the observation series (the classifier
previously scored trades against their own pre-trade price), reputation is written only
for authenticated attribution, auto-forfeits no longer launder reputation, `setParams` is
bounded with 2-step ownership, `settleBatch` is fault-isolated, and the hook takes an
explicit owner (CREATE2 otherwise made the factory the owner).

### Unichain Sepolia (1301) — primary, flashblock-native
| Contract | Address |
|---|---|
| **HindsightHook v4** | `0xcEC97e16765395c6F1Af849625b21b4a532110c4` |
| dETH (token0) | `0xbe082B9aC7b052B0fdbF4Ee0e0b097F292bfAB19` |
| dUSDC (token1) | `0xfaEf98c9630cB42aEFb1C3a362AC217086C9da3B` |
| PoolSwapTest router | `0x112433567508c6640349D5C8Faf1151D71f88926` |
| PoolModifyLiquidityTest | `0x768Ca822ca012d5185AA0D405f2bA2322aa57f13` |
| Pool (5bps, ts=10) | poolId `0x6b7762dbf8e30d6a5cc94d7d38e14ef90469e0b0d2ae90d362e5fd6d1beba0bb` |
| Settlement horizon (live) | maturity **50** + window **25** flashblocks (~10s + 5s) |
| **HindsightCallback v4** (Reactive dest) | `0xb8d4CE44e1BaB3B712daE6568B51f9B7F85Fe9E8` |
| Clock: official FlashblockNumber | `0x056466f1a50a6B5e4DCCF106074ee0083D721a42` (live, 200ms) |
| Reactive callback proxy | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Owner (admin, 2-step transferable) | `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f` |

**Settlement horizon (Aug 30):** both pools run a **10s + 5s** horizon, set through the
bounded `setParams` rather than a redeploy. Reason: our round-2 audit's permutation null
showed the original 3s+2s horizon does not beat random-label chance (z = −1.68), because
sub-5s post-swap drift is dominated by a trade's own price impact rather than by
information. At 10s+5s the true labels beat the null by **+4.5σ**. This was also the first
real exercise of the bounded-owner design: the retune was possible *because* the bounds
guarantee it cannot confiscate an in-flight bond.

**Live v4 proofs**
- benign swap #0 settled **autonomously by the Reactive Network**, no manual action —
  status flipped to Refunded ~60s after the swap (10s maturity + 5s window + RSC latency)
- the 8-swap arb burst (swaps #1–#8) settled **entirely autonomously**: within ~35s of the
  last window closing, all 8 were resolved with no keeper run and no manual transaction.
  The verdicts are the vol-scaled threshold visibly doing its job:

  | swap | markout (ticks) | θ (ticks) | verdict |
  |---|---|---|---|
  | #1–#5 | 22–27 | **31** | refunded — the burst's *own* violence raised θ above its markout |
  | **#6** | 20 | **3** | **forfeited** |
  | **#7** | 10 | **3** | **forfeited** |
  | #8 | 0 | 3 | refunded |

  Read the θ column: during the loud part of the burst the threshold rises and the pool
  declines to confiscate — that is "we tax information, not volatility" happening on-chain,
  not in a backtest. By #6 the realized-vol EWMA has decayed to a quiet tape, and the price
  has *stayed* where the arb pushed it. Persistent drift on a quiet tape is the
  informational signature, and those are exactly the two trades that forfeit.
- forfeits totalled **0.1242 dETH**, of which the epoch drip had already released about half
  to in-range LPs by the time we read it (`pendingDonations` = 0.0457 remaining) — the
  anti-JIT drip working live rather than lumping the whole pot into one flush
- `sizeTierCap` configured on-chain (10e18), so the earned discount is actually enabled and
  the whale guard is real rather than nominal

### Reactive Lasna (5318007)
| Contract | Address |
|---|---|
| **HindsightReactive v4 (RSC)** | `0xF065d60db3aE5372BcC16c57D520aADd3116718A` |
| Subscriptions | SwapRecorded@1301 (v4 hook) + Cron10 + Cron100 — 3 confirmed via system-contract events |
| Monitor | https://lasna.reactscan.net/rvm/0x5d4e95e57cf3369e31e6a50d7c4fecb04177226f |

### Base Sepolia (84532) — Chainlink Automation leg, block-fallback clock
| Contract | Address |
|---|---|
| **HindsightHook v4** | `0xdE2C8325275E86B61F9BA3b413cc43a905ba90C4` |
| dETH / dUSDC | `0x23aa3161B73E62D8fDf3e5137F959CF2FB8B66B1` / `0x982E966606cf0728e7BbBe362F72a3fDE6153488` |
| PoolSwapTest router | `0x4A54458c9a77a6A917524223Cc1D041bAbd3B8dd` |
| PoolModifyLiquidityTest | `0xf4d61F0dc0AAd02402F33208A06C6450dd32E0a3` |
| Pool (5bps, ts=10) | poolId `0x428e77303425e01587608682eaf6a32db3fba93c7145e857ebbc1a5b82a50481` |
| **HindsightUpkeep v4** | `0xDED9BF5E6bE87A82bDa4f9C268efe066FfADb468` |
| Chainlink registry / registrar (v2.3) | `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3` / `0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A` |

**Upkeeps — registered programmatically** (the Automation UI is deprecated to withdraw-only):
| mode | upkeepId | forwarder (wired ✓) |
|---|---|---|
| 0 settle | `34106365664403569171452609308688590213870799923305038747181226546071492074738` | `0xDCCF2eCa5CF28e8D6A424B4C3074523AAa095d4f` |
| 1 flush | `69004095486190517898207932162007416188847732908476968996488953250769248312979` | `0x4a370ab3705031b991E87DbF2A3B29e7C1de3578` |
| 2 poke | `8041869766249537449249240847475964560576728122058410156024555506207474548261` | `0x66E9F4056fC6F67c51048A550d55EB8DD6A53141` |

**Fallback-clock proof (v4, Base Sepolia).** Base has no flashblock counter, so this hook
is deployed with `flashblockNumber = address(0)` and runs the `block.number × 10` fallback
clock. Full cycle proven live: retail swap → observation stamped at `461731830` (a derived
stamp, not a flashblock) → `checkUpkeep(settle)` flipped **false → true** on-chain as the
window closed → `settle(0)` → **status Refunded**, the entire 0.0024987 dETH bond returned
to the trader in tx
[`0x99842068…b521796c`](https://sepolia.basescan.org/tx/0x9984206868526b036a5e8bd6932063a2d3cbde1047fb01eef43cbd21b521796c).
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
local build: 24190 bytes runtime, 31 immutable spans masked, ObservationLib linked at 0xf210c2…50d4

  MATCH    Unichain Sepolia   0xcEC97e16765395c6F1Af849625b21b4a532110c4
  MATCH    Base Sepolia       0xdE2C8325275E86B61F9BA3b413cc43a905ba90C4

All live hooks run exactly this source.
```

The comparison is byte-for-byte over the full 24,190-byte runtime, with exactly two
normalisations, both mechanical: immutable spans are masked (their positions come from
solc's own `immutableReferences`, not from us — `poolManager`, `flashblockNumber` and the
owner necessarily differ per chain), and `ObservationLib`'s `__$…$__` link placeholders are
resolved to its deployed address `0xf210c23792630cf1a119b696d3a2922b7b7550d4`. Both hooks
link the *same* library address on both chains. Nothing else is allowed to differ.

The hook is 24,190 bytes against the 24,576-byte EIP-170 limit — 386 bytes of headroom.
That is why `optimizer_runs` is 200 rather than 800, and why `finalizeBatch` and
`forceClockFallback` were removed rather than kept: `finalize` is already called implicitly
by `settle`/`settleOne`, and a manual clock override was a liability we did not need.

## Archived
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
