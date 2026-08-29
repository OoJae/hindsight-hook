"use client";
import { useState } from "react";
import { pub } from "../../lib/clients";
import { HOOK, POOL_ID, hookAbi } from "../../lib/config";
import { parseUnits, formatUnits } from "viem";

export default function ToxicityPage() {
  const [addr, setAddr] = useState("");
  const [result, setResult] = useState(null);

  const lookup = async () => {
    const [score, benign, quote] = await Promise.all([
      pub.readContract({ address: HOOK, abi: hookAbi, functionName: "toxicityScore", args: [addr] }),
      pub.readContract({ address: HOOK, abi: hookAbi, functionName: "benignSettles", args: [addr] }),
      pub.readContract({ address: HOOK, abi: hookAbi, functionName: "previewBond", args: [POOL_ID, addr, parseUnits("1", 18)] }),
    ]);
    setResult({ score, benign, quote });
  };

  if (!HOOK) return <div className="card">Set NEXT_PUBLIC_* env vars first.</div>;

  return (
    <>
      <h1>Toxicity — reputation is earned, never granted</h1>
      <p className="muted">
        New addresses pay the full 25 bps bond (Sybil-proof). Settled benign history earns a discount
        down to 0.1×; getting caught extracting resets it and raises the multiplier up to 3×.
      </p>
      <div className="card">
        <div className="row">
          <input placeholder="0x…" value={addr} onChange={(e) => setAddr(e.target.value)} style={{ width: 420 }} />
          <button onClick={lookup} disabled={!/^0x[0-9a-fA-F]{40}$/.test(addr)}>Look up</button>
        </div>
        {result && (
          <table style={{ marginTop: 14 }}>
            <tbody>
              <tr><td className="muted">toxicity EMA (WAD ticks)</td><td>{result.score.toString()}</td></tr>
              <tr><td className="muted">benign settles (earned)</td><td>{result.benign.toString()}</td></tr>
              <tr><td className="muted">bond on a 1.0 swap</td><td><b>{formatUnits(result.quote, 18)}</b> ({(Number(formatUnits(result.quote, 18)) * 10000).toFixed(1)} bps)</td></tr>
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
