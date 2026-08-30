# Hindsight — Live Deployments (Aug 29, 2026)

**Public frontend: https://oojae.github.io/hindsight-hook/**

Deployer (all chains): `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f`

## Current deployment: v3 (post-adversarial-audit — this is what to review)

v3 fixes the audit's critical + high findings: the post-swap tick now enters the
observation series (the classifier was previously scoring trades against their own
pre-trade price), reputation is only written for authenticated attribution, auto-forfeits
no longer launder reputation, `setParams` is bounded with 2-step ownership, `settleBatch`
is fault-isolated, and the hook takes an explicit owner (CREATE2 made `msg.sender` the
factory).

### Unichain Sepolia (1301) — primary, flashblock-native
| Contract | Address |
|---|---|
| **HindsightHook v3** | `0xeb77d98A9dfB72Fb17d196a3ec08F985bF0510c4` |
| dETH (token0) | `0x011ca1BBc0Eae03AA9Ef4Fbf4e64923dAD3FB588` |
| dUSDC (token1) | `0xd2b9c04a30E83ECf55FB5F4485F9910e74a9f082` |
| PoolSwapTest router | `0x2B1CcA9D8AAf82Ec4cF8E3A23cA5Ca323741E8eD` |
| PoolModifyLiquidityTest | `0xFff4EaAFBe82801B8A8eA11BE27184439a57B67E` |
| Pool (5bps, ts=10) | poolId `0xcb25338a48454517a0bab70a8f1929ab043294f3aa57f34ff1f6dd9950194015` |
| HindsightCallback v3 (Reactive dest) | `0x0caa8dE2A2aE4565987C0203B81aaB47D1cc70E6` |
| Clock: official FlashblockNumber | `0x056466f1a50a6B5e4DCCF106074ee0083D721a42` (live, 200ms) |
| Reactive callback proxy | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Owner (admin, 2-step transferable) | `0x5d4E95E57cf3369E31E6a50D7C4fECB04177226f` |

**Live v3 proofs**
- benign swap #0 settled **autonomously by the Reactive Network in ~24 seconds**, no manual action
- 8-swap arb burst: **#5 and #7 flagged toxic and forfeited**, the rest refunded in full —
  the hardened classifier caught **2×** what the pre-audit build caught on the identical
  script, and recaptured ~7× more value (0.031 vs 0.0045 dUSDC into the LP pot)
- `sizeTierCap` configured on-chain (10e18), so the earned discount is actually enabled and
  the whale guard is real rather than nominal

### Reactive Lasna (5318007)
| Contract | Address |
|---|---|
| **HindsightReactive v3 (RSC)** | `0x54893ee6300BE90eF771fd17437600b6b1421e7C` |
| Subscriptions | SwapRecorded@1301 (v3 hook) + Cron10 + Cron100 — 3 confirmed via system-contract events |
| Monitor | https://lasna.reactscan.net/rvm/0x5d4e95e57cf3369e31e6a50d7c4fecb04177226f |

### Base Sepolia (84532) — Chainlink Automation leg, block-fallback clock
| Contract | Address |
|---|---|
| **HindsightHook v3** | `0xE8eD0B1f0c14A09F84fC912C2cce90e77DEbd0C4` |
| dETH / dUSDC | `0x3b7Ad80e5e9f5C11996eA55741AfaD357a1A2388` / `0x78252F0084aD04fab97585bACc288820E497cb5B` |
| swapRouter | `0x243FF7D87cd61dF93E57F2b807AC189Dfc94b308` |
| Pool | poolId `0x553260157a2e05383a0f252599b3bb0543e3e111496396592f9d58bc81308c56` |
| **HindsightUpkeep v3** | `0x128dfBf63d16f0969f9c39587D0D4080B76A0488` |
| Chainlink registry / registrar (v2.3) | `0x91D4a4C3D448c7f3CB477332B1c7D420a5810aC3` / `0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A` |

**Upkeeps — registered programmatically** (the Automation UI is deprecated to withdraw-only):
| mode | upkeepId | forwarder (wired ✓) |
|---|---|---|
| 0 settle | `110125075826345663686457826890308126191985981941037011329885424732568684816319` | `0x0831212240355B3b1a3Ac5D4b899EB2f8830DA48` |
| 1 flush | `47862704171106303588391817869172749781777303657599445986136992085940681684172` | `0x70f4EAB729Cb55b05c4D2a6108ab7700045467DB` |
| 2 poke | `108327991428983536549553223678789134504030051278533146481908237955380209605182` | `0x225e138459d8b2f92B842aaB511c64da255f3FDe` |

**Honest status:** upkeeps are registered, funded and wired, and `checkUpkeep` returns true
on-chain — but Chainlink sunset classic-Automation testnet execution in mid-2026 and the
Base Sepolia DON performs nothing for anyone (30h registry scan: zero `UpkeepPerformed`
events, registry-wide). The perform path is therefore proven by the fork suite executing
the full check→perform→refund cycle against the real Base Sepolia PoolManager:
`BASE_SEPOLIA_RPC_URL=<rpc> forge test --mc BaseSepoliaFork -vv` (~13s). Without an RPC the
fork tests SKIP loudly — they never report a silent pass.

## Archived
- **v2** (bond-cap bytecode, pre-audit): Unichain hook `0x9b7835C368fc2E39f1225DaC36daA5c7560710c4`, Base hook `0xBec754788783e884b6C87708B39D587352C650C4`, RSC `0xB08c1A18905E6A8648B436BeaA112559938b1979`.
- **v1** (first live proofs): Unichain hook `0xbea8Ead88aE0E50bfC2F9633d1091875DE2890c4`; first full-cycle settle tx `0x940bf2f10c4e2990f32d835ffa923ea490c6d852bc746e70973df11d9f5deaf2`; **first autonomous Reactive settlement (29s, v1 bytecode)** tx `0xacc2cf71beba00a94862f41aafe62d185fb93d30eabcc4d1c68db029d86b11c4`.

*(v1/v2 hooks were deployed with `owner = msg.sender` through the CREATE2 factory, which
left their admin functions unreachable — fixed in v3 with an explicit owner argument.)*
