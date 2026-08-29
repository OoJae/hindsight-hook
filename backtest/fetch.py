#!/usr/bin/env python3
"""Fetch Uniswap v4 Swap logs for Unichain mainnet ETH/USDC pools via chunked eth_getLogs.

Output: swaps_<label>.csv with block, txIndex, logIndex, sender, amount0, amount1,
sqrtPriceX96, liquidity, tick, fee columns.
"""
import csv
import json
import sys
import time
import urllib.request

RPCS = [
    "https://unichain-rpc.publicnode.com",
    "https://unichain.drpc.org",
    "https://mainnet.unichain.org",
]
POOL_MANAGER = "0x1f98400000000000000000000000000000000004"
TOPIC0 = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"  # Swap(...)

POOLS = {
    "eth_usdc_1bp": "0x9bdd72519ad7e2b5f0d5441d7af389771cc04a8406cd577fac0c68a8b6b396bd",
    "eth_usdc_5bp": "0x3258f413c7a88cda2fa8709a589d221a80f6574f63df5a5b6774485d8acc39d9",
}

CHUNK = 5_000  # blocks per eth_getLogs call


_rpc_idx = 0

def rpc(method, params, retries=9):
    global _rpc_idx
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(retries):
        url = RPCS[_rpc_idx % len(RPCS)]
        try:
            req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) hindsight-backtest/1.0"})
            with urllib.request.urlopen(req, timeout=30) as r:
                out = json.loads(r.read())
            if "error" in out:
                raise RuntimeError(out["error"])
            time.sleep(0.15)  # pacing
            return out["result"]
        except Exception:  # noqa: BLE001
            _rpc_idx += 1  # rotate endpoint on any failure
            if attempt == retries - 1:
                raise
            time.sleep(1.0 + attempt)


def to_int(hexstr, signed=False, bits=256):
    v = int(hexstr, 16)
    if signed and v >= 2 ** (bits - 1):
        v -= 2 ** bits
    return v


def decode_swap(log):
    data = log["data"][2:]
    words = [data[i : i + 64] for i in range(0, len(data), 64)]
    return {
        "block": int(log["blockNumber"], 16),
        "txIndex": int(log["transactionIndex"], 16),
        "logIndex": int(log["logIndex"], 16),
        "sender": "0x" + log["topics"][2][-40:],
        "amount0": to_int(words[0], signed=True, bits=128),
        "amount1": to_int(words[1], signed=True, bits=128),
        "sqrtPriceX96": int(words[2], 16),
        "liquidity": int(words[3], 16),
        "tick": to_int(words[4], signed=True, bits=24),
        "fee": int(words[5], 16),
    }


def main():
    days = float(sys.argv[1]) if len(sys.argv) > 1 else 7.0
    latest = int(rpc("eth_blockNumber", []), 16)
    span = int(days * 86_400)  # ~1s blocks on Unichain
    start = latest - span
    print(f"latest={latest}, fetching {days} days ≈ {span} blocks from {start}")

    for label, pool_id in POOLS.items():
        rows = []
        frm = start
        while frm <= latest:
            to = min(frm + CHUNK - 1, latest)
            logs = rpc(
                "eth_getLogs",
                [{
                    "address": POOL_MANAGER,
                    "fromBlock": hex(frm),
                    "toBlock": hex(to),
                    "topics": [TOPIC0, pool_id],
                }],
            )
            rows.extend(decode_swap(l) for l in logs)
            if (frm - start) % (CHUNK * 10) == 0:
                print(f"  {label}: {frm - start}/{span} blocks, {len(rows)} swaps")
            frm = to + 1

        rows.sort(key=lambda r: (r["block"], r["txIndex"], r["logIndex"]))
        out = f"swaps_{label}.csv"
        with open(out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["block"])
            w.writeheader()
            w.writerows(rows)
        print(f"{label}: {len(rows)} swaps -> {out}")


if __name__ == "__main__":
    main()
