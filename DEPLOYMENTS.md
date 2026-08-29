# Hindsight — Live Deployments (Aug 29, 2026)

Deployer (all chains): `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f`

## Current deployment: v2 (Aug 29 late — includes the manipulation-cost bond cap)

### Unichain Sepolia (1301) — primary, flashblock-native
| Contract | Address |
|---|---|
| **HindsightHook v2** | `0x9b7835C368fc2E39f1225DaC36daA5c7560710c4` |
| dETH (token0) | `0x43cfD0b48d741Bd6F947fBc86a42E0cDa625fE58` |
| dUSDC (token1) | `0x8Fb42abC96DcF78C86585Cff4823937140f09bCB` |
| PoolSwapTest router | `0x13502fa74BB545E9d279215802Be88959f2D6e3d` |
| PoolModifyLiquidityTest | `0x2E4a670152A5a4430FFD1B78C0B1e949Cf776554` |
| Pool (5bps, ts=10) | poolId `0xb9ea48e9c48411175d620a0df86efba05623279b4f46850323f9f04b734bdfc8` |
| HindsightCallback v2 (Reactive dest) | `0x81a7BDF402917Ea65F44e3489b10D8562AFB0861` |
| Clock: official FlashblockNumber | `0x056466f1a50a6B5e4DCCF106074ee0083D721a42` (live, 200ms) |
| Reactive callback proxy | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |

**Live v2 proofs:**
- swap #0 (benign) settled **autonomously by the Reactive Network in 24 seconds** — zero manual action
- arb burst (#1–#8): the mechanism discriminated live — **#6 flagged toxic** (markout 10 vs θ=3) and
  forfeited to the LP pot; the other 7 refunded in full; forfeits already **dripping to LPs** via the
  autonomous cron flush + keeper bot
- on-chain reputation moved: the arb address's next bond costs 25.3bps (penalty multiplier live)

### Reactive Lasna (5318007)
| Contract | Address |
|---|---|
| **HindsightReactive v2 (RSC)** | `0xB08c1A18905E6A8648B436BeaA112559938b1979` |
| Subscriptions | SwapRecorded@1301 (hook v2) + Cron10 + Cron100 — confirmed via system-contract events |
| Monitor | https://lasna.reactscan.net/rvm/0x5d4e95e57cf3369e31e6a50d7c4fecb04177226f |

### Base Sepolia (84532) — Chainlink Automation leg, block-fallback clock
| Contract | Address |
|---|---|
| **HindsightHook v2** | `0xBec754788783e884b6C87708B39D587352C650C4` |
| dETH / dUSDC | `0x13502fa74BB545E9d279215802Be88959f2D6e3d` / `0x2E4a670152A5a4430FFD1B78C0B1e949Cf776554` |
| swapRouter | `0xC6aB5bBeBfA1c46A3aA1C64Bf99cB26939126399` |
| **HindsightUpkeep v2** | `0xEA5Cf0985c1CDA3dea468a3D7295a9717F58CC5a` |
| Chainlink registry / registrar (v2.3) | `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3` / `0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A` |

**Upkeeps (registered programmatically; UI is withdraw-only post-deprecation):**
| mode | upkeepId | forwarder (wired ✓) |
|---|---|---|
| 0 settle | `36377096154386998995096217921434037153479878464665922958990593579688370866169` | `0x49937807B027f124ddDb52f4714C76cFd817d76D` |
| 1 flush | `36030292620762533330296431215473776385185689881553750483498684496058265179077` | `0x725E3604977F4839B37d1390B5eb46eFaD17b595` |
| 2 poke | `61657934368952509505231538609612036519284418581779687355872807873672370590719` | `0xb9977b933e5e1533f48Ea5E1a2bBf0fFdf42B16A` |

**Status / honesty note:** upkeeps active + funded; our checkUpkeep returns true on-chain. Chainlink
sunset classic-Automation testnet execution mid-2026 — the Base Sepolia DON performs nothing for
anyone (30h registry scan: zero UpkeepPerformed events). Perform path proven by the fork suite
against the real Base Sepolia PoolManager.

---

## Archived: v1 deployment (pre-bond-cap bytecode, first live proofs)
- Unichain Sepolia hook v1 `0xbea8Ead88aE0E50bfC2F9633d1091875DE2890c4`; first full-cycle settle tx
  `0x940bf2f10c4e2990f32d835ffa923ea490c6d852bc746e70973df11d9f5deaf2`; first AUTONOMOUS Reactive
  settlement (29s) tx `0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4`
- v1 RSC `0x20dF56E0c2271A0D1e835A69A872139849e96F08` (left to auto-deactivate at zero balance);
  v1 callback `0xC971B9073E118DF50FAE99FeFa7EeEaEEe32C1fC`; Base v1 hook `0x9C5e288E599EC90be441a5cCaFF73603F69E10C4`,
  upkeep `0x163C7077F4480EB3315479bdf5831051DD91160a` (v1 upkeep IDs in git history)
