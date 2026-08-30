"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

const STRIDE = 14;
const HORIZON_LABELS = ["1+1s", "3+2s", "5+2s", "10+5s", "30+10s", "60+20s"];
const HEADLINE_BPS = 5;
const MAX_JUMP = 60;

function Slider({ label, value, min, max, step, onChange, fmt, note }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div className="row" style={{ justifyContent: "space-between", marginBottom: 4 }}>
        <span>{label}</span>
        <b>{fmt ? fmt(value) : value}</b>
      </div>
      <input type="range" min={min} max={max} step={step} value={value} style={{ width: "100%" }}
             onChange={(e) => onChange(Number(e.target.value))} />
      {note && <div className="muted" style={{ fontSize: 12 }}>{note}</div>}
    </div>
  );
}

export default function Explorer() {
  const [data, setData] = useState(null);
  const [meta, setMeta] = useState(null);
  const [err, setErr] = useState(null);

  // parameters (defaults == the deployed hook)
  const [thetaMin, setThetaMin] = useState(3);
  const [k, setK] = useState(2.8);
  const [ramp, setRamp] = useState(20);
  const [bondBps, setBondBps] = useState(25);
  const [hz, setHz] = useState(3); // 10+5s == the deployed hook (N=50,W=25 flashblocks)

  useEffect(() => {
    const base = process.env.NEXT_PUBLIC_BASE_PATH ?? "";
    (async () => {
      try {
        const m = await (await fetch(`${base}/explorer-meta.json`)).json();
        const buf = await (await fetch(`${base}/${m.bin}`)).arrayBuffer();
        setMeta(m);
        setData(new Float32Array(buf));
      } catch (e) { setErr(String(e)); }
    })();
  }, []);

  const stats = useMemo(() => {
    if (!data) return null;
    const n = data.length / STRIDE;
    let fees = 0, claw = 0, grossAS = 0, netMarkout = 0;
    let toxN = 0, benUsd = 0, toxUsd = 0, benFee = 0, toxFee = 0, toxForfeit = 0;
    let sumVolUsd = 0;
    for (let i = 0; i < n; i++) {
      const o = i * STRIDE;
      const usd = data[o], feeRate = data[o + 1];
      const mk = data[o + 2 + hz], vol = data[o + 8 + hz];
      const fee = usd * feeRate;
      const theta = thetaMin + k * vol;
      const f = Math.max(0, Math.min(1, (mk - theta) / ramp));
      const forfeit = usd * (bondBps / 1e4) * f;
      fees += fee; claw += forfeit;
      if (mk > 0) grossAS += usd * mk / 1e4;
      netMarkout -= usd * mk / 1e4;
      sumVolUsd += usd * vol;
      if (f > 0) { toxN++; toxUsd += usd; toxFee += fee; toxForfeit += forfeit; }
      else { benUsd += usd; benFee += fee; }
    }
    // revenue-matched volatility-scaled dynamic fee: solve c so revenue == fees + claw
    const target = fees + claw;
    let lo = 0, hi = 200;
    for (let it = 0; it < 60; it++) {
      const c = (lo + hi) / 2;
      let rev = 0;
      for (let i = 0; i < n; i++) {
        const o = i * STRIDE;
        rev += data[o] * (HEADLINE_BPS + c * data[o + 8 + hz]) / 1e4;
      }
      if (rev < target) lo = c; else hi = c;
    }
    const c = (lo + hi) / 2;
    let dynBen = 0, dynTox = 0;
    for (let i = 0; i < n; i++) {
      const o = i * STRIDE;
      const usd = data[o], mk = data[o + 2 + hz], vol = data[o + 8 + hz];
      const f = Math.max(0, Math.min(1, (mk - (thetaMin + k * vol)) / ramp));
      const inc = usd * (c * vol) / 1e4;
      if (f > 0) dynTox += inc; else dynBen += inc;
    }
    return {
      n, fees, claw, grossAS, netMarkout, toxN,
      rho: 100 * claw / grossAS,
      lvrX: Math.abs(claw / netMarkout),
      pctFees: 100 * claw / fees,
      toxPct: 100 * toxN / n,
      benignEff: 1e4 * benFee / benUsd,
      toxicEff: 1e4 * (toxFee + toxForfeit) / toxUsd,
      dynC: c,
      dynBenignShare: 100 * dynBen / (dynBen + dynTox),
      dynBenignEff: HEADLINE_BPS + c * (sumVolUsd / (benUsd + toxUsd)),
    };
  }, [data, thetaMin, k, ramp, bondBps, hz]);

  const reset = () => { setThetaMin(3); setK(2.8); setRamp(20); setBondBps(25); setHz(3); };
  const isDefault = thetaMin === 3 && k === 2.8 && ramp === 20 && bondBps === 25 && hz === 3;

  if (err) return <div className="card">Failed to load dataset: {err}</div>;
  if (!stats) return <div className="card">Loading 55,822 real mainnet swaps…</div>;

  const f0 = (x) => `$${x.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;

  return (
    <>
      <h1>Explorer — don't take our word for it</h1>
      <p className="muted">
        Every number below is computed <b>in your browser</b>, right now, by re-pricing{" "}
        <b>{stats.n.toLocaleString()} real Unichain mainnet ETH/USDC swaps</b> ({meta?.days} days)
        under the parameters you choose. No server, no RPC — this is the same arithmetic the
        hook runs on-chain, applied to trades that actually happened. Move a slider and try to
        break the result.
      </p>

      <div className="row" style={{ alignItems: "flex-start", gap: 24 }}>
        <div className="card" style={{ flex: "1 1 320px" }}>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <b>Parameters</b>
            <button className="ghost" onClick={reset} disabled={isDefault}>
              {isDefault ? "= deployed hook" : "reset to deployed"}
            </button>
          </div>
          <div style={{ marginTop: 14 }}>
            <Slider label="θ floor (ticks ≈ bps)" value={thetaMin} min={1} max={20} step={1}
                    onChange={setThetaMin} note="below this markout, flow is always benign" />
            <Slider label="k — volatility scaling" value={k} min={0} max={8} step={0.1}
                    onChange={setK} fmt={(v) => v.toFixed(1)}
                    note="θ = floor + k · realized vol. k=0 makes the threshold static." />
            <Slider label="forfeit ramp (ticks)" value={ramp} min={5} max={80} step={5}
                    onChange={setRamp} note="markout beyond θ+ramp forfeits the full bond" />
            <Slider label="bond (bps of notional)" value={bondBps} min={5} max={100} step={5}
                    onChange={setBondBps} />
            <Slider label="settlement horizon" value={hz} min={0} max={5} step={1}
                    onChange={setHz} fmt={(v) => HORIZON_LABELS[v]}
                    note="maturity + TWAP window" />
          </div>
        </div>

        <div style={{ flex: "1 1 380px" }}>
          <div className="card">
            <div className="muted">ρ — share of realized adverse selection recovered</div>
            <div className="big ok">{stats.rho.toFixed(1)}%</div>
            <div className="muted">
              {f0(stats.claw)} clawed back of {f0(stats.grossAS)} — {stats.lvrX.toFixed(1)}× the
              pool's net LVR bleed, and +{stats.pctFees.toFixed(1)}% on {f0(stats.fees)} of fees
            </div>
          </div>
          <div className="card">
            <div className="muted">who pays, at identical LP revenue</div>
            <table>
              <tbody>
                <tr><td>benign flow — Hindsight</td><td><b className="ok">{stats.benignEff.toFixed(2)} bps</b></td></tr>
                <tr><td>toxic flow — Hindsight</td><td><b className="bad">{stats.toxicEff.toFixed(2)} bps</b></td></tr>
                <tr><td className="muted">revenue-matched dynamic fee</td><td className="muted">5 + {stats.dynC.toFixed(2)}·σ bps</td></tr>
                <tr>
                  <td>…its incremental revenue from <b>benign</b> flow</td>
                  <td><b className="bad">{stats.dynBenignShare.toFixed(1)}%</b></td>
                </tr>
                <tr><td>…Hindsight's, from benign flow</td><td><b className="ok">0.0%</b></td></tr>
              </tbody>
            </table>
            <div className="muted" style={{ marginTop: 8 }}>
              {stats.toxPct.toFixed(1)}% of swaps flagged ({stats.toxN.toLocaleString()})
            </div>
          </div>
        </div>
      </div>

      <div className="card">
        <b>Things worth trying</b>
        <ul className="muted" style={{ marginBottom: 0 }}>
          <li><b>Set k = 0</b> — a static threshold. ρ barely moves, but the mechanism starts
            confiscating volatile-but-uninformed flow (that's what the vol-decile chart measures).</li>
          <li><b>Shorten the horizon</b> — at 3+2s the mechanism stops beating a random-label
            null (see §0 of the README). That is why we ship 10+5s, and why we publish the null.</li>
          <li><b>Raise the bond</b> — clawback scales, but benign flow still pays exactly the
            headline fee, because benign bonds are refunded in full. That is the whole point:
            the bond is a deposit, not a fee.</li>
        </ul>
      </div>
    </>
  );
}
