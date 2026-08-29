# Hindsight — demo video script (target 4:45, hard cap 5:00, REAL VOICE ONLY)

> Judges stop watching at 5:00. AI voice = disqualified from Demo Day. Record with a
> quiet background; speeding up to ~1.2x is fine. Send an early cut to Regina for feedback.

---

## 0:00–0:40 — The problem (slide: one chart, two numbers)

**On screen:** title card "Hindsight — the fee is decided AFTER your trade", then a slide:
"$233.8M extracted from AMM LPs by CEX-DEX arbitrage in 19 months. 75% of it by 3 addresses."

**Say:**
"LPs on volatile pairs bleed money to informed flow — arbitrageurs who know where the price
is going before the pool does. Every existing defense prices this *before* the trade:
volatility-scaled fees, priority-fee MEV taxes, auctions for first place. The organizers of
this hookathon put the problem perfectly: a dynamic fee can't tell the difference between a
retail trader and a bot — it punishes everyone equally.

And the newest defenses — the priority-fee MEV taxes — have a documented crack: on fast
rollups, searchers don't bid for priority anymore. They spam cheap reverting probes, which
pay zero tax. Ex-ante pricing is structurally gameable."

## 0:40–1:40 — The mechanism (slide: the flow diagram from the README)

**Say:**
"Hindsight prices flow from the one signal that can't be faked or revert-spammed: what the
price actually did after your trade landed.

Every swap escrows a small refundable bond — about 25 basis points, held as ERC-6909 claims,
no extra transfers. Then we wait 25 flashblocks — five seconds, measured on Uniswap's official
FlashblockNumber contract on Unichain, at 200-millisecond resolution. We're the first hook
to use it.

Then anyone can settle. If the price didn't keep moving your way — you're benign: full bond
refund, you paid just the 5-basis-point headline fee. If the price kept moving in your
direction — your trade predicted the move, that's the definition of informed flow — you
forfeit proportionally, and the forfeit streams to the LPs you extracted from.

The threshold scales with realized volatility, so trending markets don't punish honest
momentum traders. We tax information, not volatility. And a reverted transaction never
lands, never posts a bond, never enters the measurement — the revert-spam attack simply
does not apply here."

## 1:40–3:10 — Live demo (screen recording: frontend, two browser profiles)

**Actions + say:**
1. *(Swap page, "retail" wallet)* "Here's the retail experience on Unichain Sepolia. I swap
   one ETH. The quote shows my refundable bond next to the 5 bps fee. The countdown is
   live flashblocks from Uniswap's real counter." *(point at the ticking flashblock number)*
2. *(Wait ~5s, countdown completes, provisional verdict shows 'full refund')* "Window
   closed, price stayed put — settle. Full refund. My effective fee: five basis points."
3. *(Run the arb script in a terminal: `MODE=arb forge script script/03_ScriptedSwaps.s.sol ...`)*
   "Now the arbitrageur: a directional burst that pushes the price and keeps it there —
   classic toxic flow."
4. *(Settle it; verdict shows forfeit; switch to LP dashboard)* "Settlement reads the
   finalized window: toxic. The bond forfeits, and here on the LP dashboard you can watch
   it drip to in-range LPs — dripped, not lumped, so a JIT LP can't snipe it."
5. *(Toxicity page, look up the arb address)* "And the extractor's on-chain reputation just
   got worse — their next bond costs more. Reputation is earned, never granted: fresh
   addresses pay full price, so Sybils buy nothing."

## 3:10–4:00 — The receipts (backtest charts)

**On screen:** chart_lp_value_eth_usdc_1bp.png, then chart_effective_fee_*.png

**Say:**
"This isn't just a testnet toy. We replayed seven days of real Unichain mainnet ETH/USDC
swaps through the exact on-chain logic. This shaded band is LP value that Hindsight would
have clawed back from measurably-informed flow — on top of fee income, on the pool's
existing 1-basis-point fee. And this histogram is the whole thesis in one picture: benign
flow clusters at the headline fee; toxic flow pays its markout."

*(quote the actual numbers from replay.py output — X% of swaps toxic, $Y recaptured, +Z% vs fees)*

## 4:00–4:40 — Why this is different (comparison slide from README)

**Say:**
"How is this not Angstrom, or Balancer's MEV hook, or an auction-managed AMM? All of those
price ex-ante — the intent to be first, a lease on the fee switch, a guess about volatility.
Hindsight is a different mechanism class: per-trade, ex-post price discrimination. No
auction, no manager, no off-chain network, no oracle. Fully on-chain with a permissionless,
tipped keeper. And it's the only one of these designs that revert-spam can't touch.

Nothing like this exists in production — and across all 666 past UHI submissions, the words
'markout' and 'adverse selection' appear exactly zero times."

## 4:40–5:00 — Close (repo slide)

**Say:**
"Hindsight: benign flow trades nearly free, informed flow pays for exactly the harm it
causes, and LPs on volatile pairs finally keep the spread. Sixty-plus tests including
invariants and a fork suite against the real Unichain PoolManager. Repo and full mechanism
spec linked below. Thanks."

---

### Recording checklist
- [ ] ≤ 5:00 total, real voice, quiet room
- [ ] Video covers: problem ✓ how it works ✓ comparison ✓ (the three required beats)
- [ ] Frontend demo pre-funded and rehearsed; keeper bot running
- [ ] Backtest numbers filled in from replay.py output
- [ ] Upload unlisted YouTube → test the link in an incognito window
- [ ] Send early cut to Regina (@reginaelyse) for feedback
