#!/usr/bin/env python3
"""Precompute a compact dataset so the browser can re-price 55k swaps instantly.

For each swap we store: notional (USD), realized markout at six horizons, the realized
volatility proxy at each horizon, and the fee actually paid. The explorer then applies
theta_min / k / ramp / bondBps client-side — no RPC, no server, instant sliders.
"""
import json, struct, base64, sys
from compare import load, window, USDC, MAX_JUMP

HORIZONS = [(1, 1), (3, 2), (5, 2), (10, 5), (30, 10), (60, 20)]

rows = load(sys.argv[1] if len(sys.argv) > 1 else "swaps_eth_usdc_5bp.csv")
last = rows[-1]["block"]
recs = []
for i, s in enumerate(rows):
    usd = abs(s["amount1"]) / USDC
    if usd == 0:
        continue
    mk, vol = [], []
    ok = True
    for n, w in HORIZONS:
        if s["block"] + n + w > last:
            ok = False
            break
        tw, v = window(rows, i, s["block"] + n, s["block"] + n + w)
        if tw is None:
            ok = False
            break
        drift = tw - s["tick"]
        mk.append(-drift if s["amount0"] < 0 else drift)
        vol.append(v)
    if not ok:
        continue
    recs.append((usd, s["fee"] / 1e6, mk, vol))

# float32 columnar: usd | feeRate | markout[6] | vol[6]
buf = bytearray()
for usd, fee, mk, vol in recs:
    buf += struct.pack("<2f", usd, fee)
    buf += struct.pack("<6f", *mk)
    buf += struct.pack("<6f", *vol)

import os
os.makedirs("../frontend/public", exist_ok=True)
open("../frontend/public/explorer-data.bin", "wb").write(bytes(buf))
json.dump({
    "n": len(recs),
    "horizons": [f"{n}+{w}s" for n, w in HORIZONS],
    "stride": 14,
    "pool": "Unichain mainnet ETH/USDC 5bps",
    "days": 7,
    "bin": "explorer-data.bin",
}, open("../frontend/public/explorer-meta.json", "w"))
print(f"{len(recs):,} swaps -> explorer-data.bin ({len(buf)/1e6:.2f} MB)")
