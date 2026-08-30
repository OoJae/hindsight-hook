#!/usr/bin/env python3
"""Prove that the source in this repo is what is actually deployed.

Compiles nothing itself — run `forge build` first, then:

    python3 tools/verify_deployment.py

For each live hook it fetches the on-chain runtime code and compares it byte for byte
against `out/HindsightHook.sol/HindsightHook.json`, after two legitimate normalisations:

  * **immutables** are masked. `poolManager`, `flashblockNumber` and the owner are
    immutable, so they are baked into the runtime code at deploy time and necessarily
    differ per chain. The spans are read from solc's own `immutableReferences`, not
    guessed.
  * **library placeholders** are linked. `ObservationLib` is an external library, so the
    artifact carries `__$...$__` placeholders where the deployed code carries its address.

Anything else differing means the repo does not match the chain.
"""
import json, re, sys, urllib.request

OBSERVATION_LIB = "f210c23792630cf1a119b696d3a2922b7b7550d4"  # deterministic CREATE2, same on both chains

TARGETS = [
    ("Unichain Sepolia", "https://sepolia.unichain.org",
     "0xC4E83D74A486C056c6164655F1d2D5ae5408d0C4"),
    ("Base Sepolia", "https://sepolia.base.org",
     "0xc60C0be68D02BD38Bc8aF44cf71D157C904950c4"),
]


def code_at(rpc, addr):
    req = urllib.request.Request(
        rpc,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode",
                         "params": [addr, "latest"]}).encode(),
        headers={"Content-Type": "application/json",
                 "User-Agent": "Mozilla/5.0 (hindsight-verify)"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["result"][2:]


def main():
    art = json.load(open("out/HindsightHook.sol/HindsightHook.json"))["deployedBytecode"]
    local = re.sub(r"__\$[0-9a-f]{34}\$__", OBSERVATION_LIB, art["object"][2:])
    spans = sorted((r["start"] * 2, (r["start"] + r["length"]) * 2)
                   for refs in art.get("immutableReferences", {}).values() for r in refs)

    def mask(s):
        out = list(s)
        for a, z in spans:
            out[a:z] = ["."] * (z - a)
        return "".join(out)

    want, ok = mask(local), True
    print(f"local build: {len(local)//2} bytes runtime, "
          f"{len(spans)} immutable spans masked, ObservationLib linked at 0x{OBSERVATION_LIB}\n")
    for name, rpc, addr in TARGETS:
        got = mask(code_at(rpc, addr))
        match = got == want
        ok &= match
        print(f"  {'MATCH  ' if match else 'DIFFERS'}  {name:18s} {addr}")
    print("\n" + ("All live hooks run exactly this source." if ok else
                  "MISMATCH — the repo does not match the chain."))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
