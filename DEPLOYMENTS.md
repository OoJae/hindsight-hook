# Hindsight — Live Deployments (Aug 29, 2026)

Deployer (all chains): `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f`

## Unichain Sepolia (1301) — primary, flashblock-native
| Contract | Address |
|---|---|
| **HindsightHook** | `0xbea8Ead88aE0E50bfC2F9633d1091875DE2890c4` |
| dETH (token0) | `0x3Ef7Dd4E40C6Ff36B139DB2E2E678E11759f538E` |
| dUSDC (token1) | `0xB08c1A18905E6A8648B436BeaA112559938b1979` |
| PoolSwapTest router | `0x54893ee6300BE90eF771fd17437600b6b1421e7C` |
| PoolModifyLiquidityTest | `0x175A277a63B24980E17E74c68b4d301E0105755B` |
| Pool (5bps, ts=10) | poolId `0x88871bb5c98298404990adf25963f542f8e0337c1b44f789fdf58d86aef90ad8` |
| HindsightCallback (Reactive dest) | `0xC971B9073E118DF50FAE99FeFa7EeEaEEe32C1fC` |
| Clock: official FlashblockNumber | `0x056466f1a50a6b5e4dccf106074ee0083d721a42` (live, 200ms) |
| Reactive callback proxy | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |

**Live proof (full cycle):** swap #0 settled benign — markout −1 tick vs θ=3, full bond
refund. Settle tx `0x940bf2f10c4e2990f32d835ffa923ea490c6d852bc746e70973df11d9f5deaf2`.

## Base Sepolia (84532) — Chainlink Automation leg, block-fallback clock
| Contract | Address |
|---|---|
| **HindsightHook** | `0x9C5e288E599EC90be441a5cCaFF73603F69E10C4` |
| dETH / dUSDC / routers | same addresses as 1301 (same deployer nonces) |
| **HindsightUpkeep** | `0x163C7077F4480EB3315479bdf5831051DD91160a` |
| Chainlink registry (v2.3) | `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3` |
| Chainlink registrar (v2.3) | `0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A` |

**Upkeeps — registered PROGRAMMATICALLY via the v2.3 registrar** (the Automation web UI
is deprecated to withdraw-only; registration flow removed — done with cast against
`registerUpkeep(RegistrationParams)` incl. the v2.3 `billingToken` field, auto-approved):

| mode | name | upkeepId | forwarder (wired ✓) |
|---|---|---|---|
| 0 settle (2M gas, 2 LINK) | hindsight-settle | `51747108707998861380173403952443167944368945447506334027843948685279363770052` | `0x5421C2236f245D0B08339A61c4c525b61c617C3B` |
| 1 flush (800k, 1 LINK) | hindsight-flush | `56537333564254720060701579846199481314031894726327294970644483346858838476651` | `0xB8CbA46C68e95652Ac7481ee5dBfe0072C6128F6` |
| 2 poke (500k, 1 LINK) | hindsight-poke | `23193929133341913901063287104405604679642704539803669672834394425561263029096` | `0xb3b26146240AEDc556b89E43A466D4CBF5Db1951` |

**Status / honesty note:** all three upkeeps are registered, auto-approved, LINK-funded and
active on the registry; our `checkUpkeep` verifiably returns `upkeepNeeded=true` on-chain.
However, classic Automation testnets were sunset by Chainlink in mid-2026 and the Base
Sepolia DON is no longer executing: the ENTIRE v2.3 registry
(`0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3`) shows **zero UpkeepPerformed events in the
30+ hours we scanned**. The perform path is therefore demonstrated two ways instead:
(1) the fork test `test/fork/BaseSepolia.t.sol` executes the full check→perform→refund
cycle against the real Base Sepolia PoolManager through the real forwarder auth pattern;
(2) the mechanism's liveness never depended on any single keeper — settlement is
permissionless, the Reactive lane settles live, and auto-forfeit protects LPs regardless.

## Reactive Lasna (5318007)
| Contract | Address |
|---|---|
| **HindsightReactive (RSC)** | `0x20dF56E0c2271A0D1e835A69A872139849e96F08` |
| Subscriptions | SwapRecorded@1301 + Cron10 + Cron100 — all confirmed via system-contract events (tx `0x19f61b4c…a0a9`) |
| Monitor | https://lasna.reactscan.net/rvm/0x5d4e95e57cf3369e31e6a50d7c4fecb04177226f |

**LIVE AUTONOMOUS SETTLEMENT PROOF:** swap #1 (fired 18:01:52 UTC+1) was settled at
18:02:21 with zero manual action — callback tx
`0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4` on Unichain Sepolia,
sent by the Reactive relayer (`0xd499725b8D4AaD361060A5fC5d30022285159449`) through the
official callback proxy into HindsightCallback → hook.trySettle → full benign refund.
A second delivery (`0x24df308d…e9a2`) confirms the Cron sweep lane fires as well.
