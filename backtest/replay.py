#!/usr/bin/env python3
"""Replay real Unichain mainnet swaps through Hindsight's markout logic.

Mirrors the on-chain design faithfully:
  - execution price = post-swap tick from the Swap event
  - settlement TWAP = last-known-tick time-weighted over [T+N, T+N+W] seconds,
    built ONLY from subsequent observed swaps (same information the hook has)
  - theta = theta_min + k * mean |tick jump| inside the window (vol-scaled)
  - forfeit = bond * clamp((markout - theta) / ramp, 0, 1), bond = 25 bps of notional

Charts: (1) cumulative LP value: fees vs fees+clawback  (2) effective-fee histogram
        (3) per-sender toxicity scatter.
"""
import csv
import sys
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

def _open(path):
    """Open a backtest CSV, transparently accepting the committed .gz form.

    The repo ships `swaps_*.csv.gz` (2.0MB) rather than the 7.6MB raw CSV, so a
    fresh clone can reproduce every published number with no fetch step.
    """
    import gzip, os
    if os.path.exists(path):
        return open(path)
    if os.path.exists(path + ".gz"):
        return gzip.open(path + ".gz", "rt")
    raise FileNotFoundError(
        f"{path} (and {path}.gz) not found — run `python3 fetch.py` to rebuild it"
    )



# Hook default params (keep in sync with HindsightParams)
BOND_BPS = 25
N_SEC, W_SEC = 10, 5         # 50 + 25 flashblocks at 200ms — matches the live
                             # deployment and compare.py. Section 8 of compare.py
                             # shows the shorter 3+2s horizon does not beat a
                             # random-label null (z=-1.68); 10+5s beats it by +4.5σ.
THETA_MIN = 3.0              # ticks ≈ bps
THETA_VOL_K = 2.8
RAMP = 20.0
MAX_JUMP = 60.0              # per-observation contribution cap (matches the hook)
USDC_DECIMALS = 1e6          # token1 = USDC

def load(path):
    with _open(path) as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k in ("block", "tick", "amount0", "amount1", "fee"):
            r[k] = int(r[k])
    return rows

CLAMP = True  # apply the hook's jump clamp to the volatility input (theta)

def twap_and_vol(swaps, i, start, end):
    """Time-weighted avg tick + mean |jump| over [start, end] (block seconds),
    using the last swap tick at/before `start` as the entering price."""
    prev_tick, prev_t = swaps[i]["tick"], swaps[i]["block"]
    j = i + 1
    weighted, duration, jumps = 0.0, 0.0, []
    # advance to window start
    while j < len(swaps) and swaps[j]["block"] <= start:
        prev_tick, prev_t = swaps[j]["tick"], swaps[j]["block"]
        j += 1
    seg_start = start
    while j < len(swaps) and swaps[j]["block"] < end:
        t = swaps[j]["block"]
        weighted += prev_tick * (t - seg_start)
        duration += t - seg_start
        jump = abs(swaps[j]["tick"] - prev_tick)
        jumps.append(min(jump, MAX_JUMP) if CLAMP else jump)
        prev_tick, seg_start = swaps[j]["tick"], t
        j += 1
    weighted += prev_tick * (end - seg_start)
    duration += end - seg_start
    if duration <= 0:
        return None, None
    vol = sum(jumps) / len(jumps) if jumps else 0.0
    return weighted / duration, vol

def replay(swaps, label):
    per_sender = defaultdict(lambda: {"n": 0, "toxic": 0, "volume": 0.0, "forfeit": 0.0, "markouts": []})
    results = []
    last_block = swaps[-1]["block"] if swaps else 0

    for i, s in enumerate(swaps):
        # skip tail swaps whose window extends past the dataset
        if s["block"] + N_SEC + W_SEC > last_block:
            continue
        zero_for_one = s["amount0"] < 0
        notional_usd = abs(s["amount1"]) / USDC_DECIMALS
        if notional_usd == 0:
            continue
        twap, vol = twap_and_vol(swaps, i, s["block"] + N_SEC, s["block"] + N_SEC + W_SEC)
        if twap is None:
            continue  # missing data -> refund, excluded from toxic stats
        drift = twap - s["tick"]
        markout = -drift if zero_for_one else drift
        theta = THETA_MIN + THETA_VOL_K * vol
        excess = markout - theta
        fwad = max(0.0, min(1.0, excess / RAMP))
        bond = notional_usd * BOND_BPS / 10_000
        forfeit = bond * fwad
        fee_paid = notional_usd * s["fee"] / 1e6  # pool fee in hundredths of bps (1e6 = 100%)
        results.append({
            "block": s["block"], "sender": s["sender"], "usd": notional_usd,
            "markout": markout, "theta": theta, "bond": bond, "forfeit": forfeit,
            "fee": fee_paid, "toxic": fwad > 0,
        })
        ps = per_sender[s["sender"]]
        ps["n"] += 1
        ps["volume"] += notional_usd
        ps["forfeit"] += forfeit
        ps["markouts"].append(markout)
        if fwad > 0:
            ps["toxic"] += 1

    if not results:
        print(f"{label}: no replayable swaps")
        return

    mks = sorted(r["markout"] for r in results)
    def pct(q):
        return mks[min(len(mks) - 1, int(q * len(mks)))]
    print(f"markout distribution (ticks): p10={pct(0.1):.1f} p50={pct(0.5):.1f} p90={pct(0.9):.1f} "
          f"p99={pct(0.99):.1f} max={mks[-1]:.1f}")

    vol_usd = sum(r["usd"] for r in results)
    fees = sum(r["fee"] for r in results)
    clawback = sum(r["forfeit"] for r in results)
    toxic = [r for r in results if r["toxic"]]
    benign = [r for r in results if not r["toxic"]]
    toxic_vol = sum(r["usd"] for r in toxic)

    print(f"\n=== {label} ===")
    print(f"swaps replayed:        {len(results):>10}")
    print(f"volume:                ${vol_usd:>12,.0f}")
    print(f"LP fee income:         ${fees:>12,.2f}")
    print(f"Hindsight clawback:    ${clawback:>12,.2f}  (+{100*clawback/max(fees,1e-9):.1f}% vs fees alone)")
    print(f"toxic swaps:           {len(toxic):>10}  ({100*len(toxic)/len(results):.1f}% of swaps, "
          f"{100*toxic_vol/max(vol_usd,1e-9):.1f}% of volume)")
    if benign:
        eff_benign = 10_000 * sum(r['fee'] for r in benign) / max(sum(r['usd'] for r in benign), 1e-9)
        print(f"benign effective fee:  {eff_benign:>10.2f} bps (bond fully refunded)")
    if toxic:
        eff_toxic = 10_000 * (sum(r['fee'] for r in toxic) + sum(r['forfeit'] for r in toxic)) / max(toxic_vol, 1e-9)
        print(f"toxic effective fee:   {eff_toxic:>10.2f} bps (fee + forfeited bond)")
    top = sorted(per_sender.items(), key=lambda kv: -kv[1]["forfeit"])[:5]
    print("top extractors by forfeit:")
    for addr, ps in top:
        if ps["forfeit"] <= 0:
            break
        print(f"  {addr[:10]}…  swaps={ps['n']:>4}  toxic={ps['toxic']:>4}  vol=${ps['volume']:,.0f}  forfeit=${ps['forfeit']:,.2f}")

    # chart 1: cumulative LP value
    xs, cum_fees, cum_total = [], [], []
    f_acc = c_acc = 0.0
    for r in results:
        f_acc += r["fee"]
        c_acc += r["forfeit"]
        xs.append(r["block"])
        cum_fees.append(f_acc)
        cum_total.append(f_acc + c_acc)
    plt.figure(figsize=(9, 5))
    plt.plot(xs, cum_fees, label="LP fees (status quo)", lw=2)
    plt.plot(xs, cum_total, label="LP fees + Hindsight clawback", lw=2)
    plt.fill_between(xs, cum_fees, cum_total, alpha=0.25, label="value recaptured from toxic flow")
    plt.title(f"LP value: {label} (7d replay of real Unichain swaps)")
    plt.xlabel("block")
    plt.ylabel("USD")
    plt.legend()
    plt.tight_layout()
    plt.savefig(f"chart_lp_value_{label}.png", dpi=150)

    # chart 2: effective fee histogram
    plt.figure(figsize=(9, 5))
    eff = [10_000 * (r["fee"] + r["forfeit"]) / r["usd"] for r in results if r["usd"] > 1]
    plt.hist([e for e, r in zip(eff, results) if not r["toxic"]], bins=40, alpha=0.7, label="benign (refunded)")
    plt.hist([e for e, r in zip(eff, results) if r["toxic"]], bins=40, alpha=0.7, label="toxic (forfeited)")
    plt.title(f"Effective fee per swap: {label}")
    plt.xlabel("effective fee (bps)")
    plt.ylabel("swaps")
    plt.legend()
    plt.tight_layout()
    plt.savefig(f"chart_effective_fee_{label}.png", dpi=150)

    # chart 3: sender toxicity scatter
    plt.figure(figsize=(9, 5))
    xs2 = [ps["volume"] for ps in per_sender.values() if ps["n"] >= 2]
    ys2 = [sum(ps["markouts"]) / len(ps["markouts"]) for ps in per_sender.values() if ps["n"] >= 2]
    plt.scatter(xs2, ys2, alpha=0.6)
    plt.xscale("log")
    plt.axhline(0, color="grey", lw=1)
    plt.title(f"Per-sender mean markout vs volume: {label}")
    plt.xlabel("sender volume (USD, log)")
    plt.ylabel("mean markout (ticks ≈ bps)")
    plt.tight_layout()
    plt.savefig(f"chart_sender_toxicity_{label}.png", dpi=150)
    print(f"charts written: chart_*_{label}.png")

if __name__ == "__main__":
    for label in (sys.argv[1:] or ["eth_usdc_1bp", "eth_usdc_5bp"]):
        try:
            swaps = load(f"swaps_{label}.csv")
        except FileNotFoundError:
            print(f"{label}: run fetch.py first")
            continue
        replay(swaps, label)
