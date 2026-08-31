#!/usr/bin/env python3
"""Export a small, CONTIGUOUS slice of the real tape for the landing page ribbon.

The explorer already ships the full 55,822-swap tape (3.2 MB). The landing page
must not pay that, but the ribbon is only honest if it is real data — so this
takes an unbroken run of consecutive swaps rather than a decimated sample.
Decimating would smooth the price path into something that never happened.

Output: frontend/public/ribbon.bin — float32, stride 5, little-endian:
    t | tick | markout | theta | usd
where `t` is seconds since the slice start.
"""
import json, struct, sys, os
import compare as C

N = int(sys.argv[1]) if len(sys.argv) > 1 else 800

rows = C.load("swaps_eth_usdc_5bp.csv")
res = C.price(rows)

# Pick the window that best shows the mechanism working: the densest run of
# consecutive priced swaps that contains BOTH verdicts, so the ribbon has a
# refund and a forfeit to point at rather than a flat stretch of nothing.
best, best_score = 0, -1
for start in range(0, len(res) - N, 200):
    chunk = res[start:start + N]
    span = chunk[-1]["block"] - chunk[0]["block"]
    if span <= 0:
        continue
    toxic = sum(1 for r in chunk if r["toxic"])
    if toxic == 0 or toxic == len(chunk):
        continue
    rng = max(r["markout"] for r in chunk) - min(r["markout"] for r in chunk)
    score = rng / (span ** 0.5)          # movement per unit time
    if score > best_score:
        best, best_score = start, score

chunk = res[best:best + N]
t0 = chunk[0]["block"]

buf = bytearray()
for r in chunk:
    buf += struct.pack("<5f", r["block"] - t0, float(r["tick"]),
                       r["markout"], r["theta"], r["usd"])

out = "../frontend/public"
os.makedirs(out, exist_ok=True)
open(f"{out}/ribbon.bin", "wb").write(bytes(buf))

toxic = sum(1 for r in chunk if r["toxic"])
meta = {
    "n": len(chunk), "stride": 5,
    "fields": ["t", "tick", "markout", "theta", "usd"],
    "seconds": chunk[-1]["block"] - t0,
    "toxic": toxic,
    "tickMin": min(r["tick"] for r in chunk), "tickMax": max(r["tick"] for r in chunk),
    "pool": "Unichain mainnet ETH/USDC 5bps",
    "note": "A contiguous run of real consecutive swaps. Not sampled, not smoothed.",
    "bin": "ribbon.bin",
}
json.dump(meta, open(f"{out}/ribbon-meta.json", "w"))
print(f"{len(chunk)} consecutive swaps -> ribbon.bin ({len(buf)/1024:.1f} KB)")
print(f"  span {meta['seconds']}s · {toxic} forfeited / {len(chunk)-toxic} refunded"
      f" · ticks {meta['tickMin']}..{meta['tickMax']}")
