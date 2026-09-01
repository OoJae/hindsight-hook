"use client";
import { useState } from "react";
import { pub } from "../../../lib/clients";
import { HOOK, POOL_ID, hookAbi } from "../../../lib/config";
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

  // app.css turns a lone .card into a machine line between two rules, so the
  // misconfigured build still looks like this product. NEXT_PUBLIC_* is a config
  // token, not prose: <code> puts it in mono and promotes it to --ink.
  if (!HOOK)
    return (
      <div className="card">
        Set <code>NEXT_PUBLIC_*</code> env vars first.
      </div>
    );

  // Presentation only — same arithmetic the value cell used to do inline, lifted
  // out so the headline figure and its machine sub-line read off one source.
  const wad = result ? formatUnits(result.quote, 18) : null;
  const bps = result ? (Number(wad) * 10000).toFixed(1) : null;

  return (
    <>
      {/* Stamp then claim, matching the other three routes and the (site) bands.
          The claim was the deck a moment ago; as the h1 it stops being said
          twice on the same page. */}
      <div className="label">Toxicity</div>
      <h1>Reputation is earned, never granted</h1>
      <p className="muted">
        New addresses pay the full <span className="num">25 bps</span> bond (Sybil-proof). Settled
        benign history earns a discount down to <span className="num">0.1×</span>; getting caught
        extracting resets it and raises the multiplier up to <span className="num">3×</span>.
      </p>

      <div className="card">
        <div className="row">
          {/* An address is 42 characters, so the field is measured in characters
              now that app.css sets it in mono — 420px was picked against 15px
              system sans and would be the wrong length in any other face. No
              .mono/.label class here: their uppercasing would corrupt the
              mixed-case checksummed address the regex below accepts. */}
          <input
            placeholder="0x…"
            value={addr}
            onChange={(e) => setAddr(e.target.value)}
            style={{ flex: "1 1 24ch", maxWidth: "44ch" }}
          />
          <button onClick={lookup} disabled={!/^0x[0-9a-fA-F]{40}$/.test(addr)}>Look up</button>
        </div>
      </div>

      {/* The record. A second card rather than a block inside the first: app.css
          pulls consecutive cards onto one shared hairline, so the query and its
          answer read as one ledger.

          It renders from first paint with the verdict withheld. That is the
          product's whole thesis, and .warn is the class the system gives it —
          "the verdict is not in yet", in --muted, exactly as the landing page's
          hero withholds before it settles. */}
      <div className="card">
        <div className="label">bond on a 1.0 swap</div>
        <div className={result ? "big" : "big warn"}>{result ? `${bps} bps` : "—"}</div>
        {result && <div className="muted num">{wad}</div>}
        <table style={{ marginTop: "clamp(1rem, 2vw, 1.5rem)", borderTop: "var(--rule)" }}>
          <tbody>
            <tr>
              <td className="label">toxicity EMA (WAD ticks)</td>
              <td className={result ? "num" : "num warn"} style={{ overflowWrap: "anywhere" }}>
                {result ? result.score.toString() : "—"}
              </td>
            </tr>
            <tr>
              <td className="label">benign settles (earned)</td>
              <td className={result ? "num" : "num warn"}>
                {result ? result.benign.toString() : "—"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </>
  );
}
