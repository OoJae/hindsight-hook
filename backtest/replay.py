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

# ── the pricing model lives in ONE place ────────────────────────────────────────────
# This file used to carry its own byte-identical copy of _open/load/twap_and_vol plus a
# second set of THETA_* constants, kept in step by a comment. They drifted anyway (the
# vol clamp here said 60 while the hook said 10). Import instead, so there is exactly one
# definition of what Hindsight charges and it cannot silently disagree with compare.py.
from compare import (  # noqa: E402
    _open, load, window, price,
    BOND_BPS, N_SEC, W_SEC, THETA_MIN, THETA_K, RAMP, MAX_JUMP, MAX_VOL_JUMP,
    USDC as USDC_DECIMALS, THETA_SRC, THETA_LOOKBACK,
)

THETA_VOL_K = THETA_K   # back-compat alias for this file's chart labels


def replay(swaps, label):
    per_sender = defaultdict(lambda: {"n": 0, "toxic": 0, "volume": 0.0, "forfeit": 0.0, "markouts": []})
    results = price(swaps)   # the one shared model
    for r in results:
        ps = per_sender[r["sender"]]
        ps["n"] += 1
        ps["volume"] += r["usd"]
        ps["forfeit"] += r["forfeit"]
        ps["markouts"].append(r["markout"])
        if r["toxic"]:
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
