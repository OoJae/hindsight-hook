"use client";
import { useEffect, useState } from "react";
import { formatUnits } from "viem";
import { pub } from "../../lib/clients";
import { HOOK, hookAbi } from "../../lib/config";
import { getLogsChunked } from "../../lib/logs";

export default function LpPage() {
  const [settles, setSettles] = useState([]);
  const [flushes, setFlushes] = useState([]);

  useEffect(() => {
    if (!HOOK) return;
    let stop = false;
    (async () => {
      const settledEvent = hookAbi.find((x) => x.type === "event" && x.name === "Settled");
      const flushEvent = hookAbi.find((x) => x.type === "event" && x.name === "DonationFlushed");
      const [settled, flushed] = await Promise.all([
        getLogsChunked(pub, { address: HOOK, event: settledEvent }),
        getLogsChunked(pub, { address: HOOK, event: flushEvent }),
      ]);
      if (stop) return;
      setSettles(settled.reverse());
      setFlushes(flushed.reverse());
    })().catch(console.error);
    const t = setInterval(() => location.reload(), 20_000);
    return () => { stop = true; clearInterval(t); };
  }, []);

  if (!HOOK) return <div className="card">Set NEXT_PUBLIC_* env vars first.</div>;

  const totalForfeited = settles.reduce((a, e) => a + e.args.forfeit, 0n);
  const totalRefunded = settles.reduce((a, e) => a + e.args.refund, 0n);
  const totalFlushed = flushes.reduce((a, e) => a + e.args.amount0 + e.args.amount1, 0n);
  const toxicCount = settles.filter((e) => e.args.toxic).length;

  return (
    <>
      <h1>LP dashboard — value clawed back from toxic flow</h1>
      <div className="row">
        <div className="card" style={{ flex: 1 }}>
          <div className="muted">recaptured from informed flow</div>
          <div className="big ok">{formatUnits(totalForfeited, 18)}</div>
        </div>
        <div className="card" style={{ flex: 1 }}>
          <div className="muted">refunded to benign traders</div>
          <div className="big">{formatUnits(totalRefunded, 18)}</div>
        </div>
        <div className="card" style={{ flex: 1 }}>
          <div className="muted">dripped to in-range LPs</div>
          <div className="big">{formatUnits(totalFlushed, 18)}</div>
        </div>
      </div>
      <p className="muted">
        {settles.length} settlements · {toxicCount} toxic ({settles.length ? Math.round((100 * toxicCount) / settles.length) : 0}%)
        — forfeits drip via donate() each epoch — a JIT sniper captures ≤15% (measured), a durable LP 5.3× more
      </p>

      <h2>Settlements</h2>
      <div className="card">
        <table>
          <thead><tr><th>#</th><th>trader</th><th>verdict</th><th>markout vs θ</th><th>refund</th><th>forfeit</th></tr></thead>
          <tbody>
            {settles.slice(0, 40).map((e) => (
              <tr key={e.args.swapId.toString()}>
                <td>{e.args.swapId.toString()}</td>
                <td><code>{e.args.trader.slice(0, 8)}…</code></td>
                <td>{e.args.toxic ? <span className="bad">toxic</span> : <span className="ok">benign</span>}</td>
                <td>{e.args.markoutTicks.toString()} / {e.args.thetaTicks.toString()}</td>
                <td>{formatUnits(e.args.refund, 18)}</td>
                <td>{e.args.forfeit > 0n ? <span className="bad">{formatUnits(e.args.forfeit, 18)}</span> : "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
