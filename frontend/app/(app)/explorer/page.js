"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

const STRIDE = 15;   // ... + trailing sigma at offset 14
const HORIZON_LABELS = ["1+1s", "3+2s", "5+2s", "10+5s", "30+10s", "60+20s"];
const HEADLINE_BPS = 5;

// A parameter is a ledger row: a mono key on the left, the measured value on the
// right, filed under a hairline. The <li> is load-bearing — app.css gives every
// li in the app a top rule and its own padding, so the stack rhythm and the
// separators come from the sheet rather than from a magic 14px margin here. The
// readout keeps its <b> (app.css targets `.row > b:last-child` for exactly this
// element) and gains .num, so the digits stop shuffling under a dragging thumb.
function Slider({ label, value, min, max, step, onChange, fmt, note }) {
  return (
    <li>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <span className="label keep-case">{label}</span>
        <b className="num">{fmt ? fmt(value) : value}</b>
      </div>
      <input type="range" min={min} max={max} step={step} value={value} aria-label={label}
             onChange={(e) => onChange(Number(e.target.value))} />
      {note && <div className="mono keep-case">{note}</div>}
    </li>
  );
}

export default function Explorer() {
  const [data, setData] = useState(null);
  const [meta, setMeta] = useState(null);
  const [err, setErr] = useState(null);

  // parameters (defaults == the deployed hook)
  const [thetaMin, setThetaMin] = useState(3);
  const [k, setK] = useState(1.4);
  // Where sigma comes from. "trailing" is what v7 ships: a window that closes BEFORE the
  // trade, so the trade cannot raise the bar it is judged against. "window" is v6's, kept
  // here so you can flip it and watch the difference yourself.
  const [sigmaSrc, setSigmaSrc] = useState("trailing");
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
      const mk = data[o + 2 + hz];
      const vol = sigmaSrc === "trailing" ? data[o + 14] : data[o + 8 + hz];
      const fee = usd * feeRate;
      // Theta as the CONTRACT computes it. The tape's trailing sigma is already the
      // integer mean jump (ObservationLib does integer division), and _theta floors a
      // second time in vol * thetaVolMultX10 / 10. Doing this in float overstated theta
      // and put rho seven points under compare.py at the deployed defaults.
      const theta = thetaMin + Math.floor((vol * Math.round(k * 10)) / 10);
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
      const usd = data[o], mk = data[o + 2 + hz];
      const vol = sigmaSrc === "trailing" ? data[o + 14] : data[o + 8 + hz];
      const f = Math.max(0, Math.min(1, (mk - (thetaMin + k * vol)) / ramp));
      const inc = usd * (c * vol) / 1e4;
      if (f > 0) dynTox += inc; else dynBen += inc;
    }
    // A horizon whose window is too narrow to contain an interior observation has zero
    // realized volatility everywhere. The dynamic-fee bisection is then constant in c, and
    // every derived share is 0/0. Report that honestly rather than rendering NaN.
    const dynDegenerate = !(dynBen + dynTox > 0) || !(sumVolUsd > 0);
    return {
      n, fees, claw, grossAS, netMarkout, toxN, dynDegenerate,
      rho: grossAS > 0 ? 100 * claw / grossAS : null,
      lvrX: netMarkout !== 0 ? Math.abs(claw / netMarkout) : null,
      pctFees: fees > 0 ? 100 * claw / fees : null,
      toxPct: 100 * toxN / n,
      benignEff: benUsd > 0 ? 1e4 * benFee / benUsd : null,
      toxicEff: toxUsd > 0 ? 1e4 * (toxFee + toxForfeit) / toxUsd : null,
      dynC: dynDegenerate ? null : c,
      dynBenignShare: dynDegenerate ? null : 100 * dynBen / (dynBen + dynTox),
      dynBenignEff: dynDegenerate ? null : HEADLINE_BPS + c * (sumVolUsd / (benUsd + toxUsd)),
    };
  }, [data, thetaMin, k, ramp, bondBps, hz, sigmaSrc]);

  const reset = () => { setThetaMin(3); setK(1.4); setRamp(20); setBondBps(25); setHz(3); setSigmaSrc("trailing"); };
  const isDefault = thetaMin === 3 && k === 1.4 && ramp === 20 && bondBps === 25 && hz === 3
    && sigmaSrc === "trailing";

  // Both guards render as .appmain > .card:only-child — app.css drops the fill and
  // sets them as a mono line between two rules. The failure is the one thing here
  // that is an interface fault rather than a verdict, so it takes .is-err: promoted
  // to --ink against an ink rule, which is the loudest move the palette has. No red.
  if (err) return (
    <div className="card">
      <p className="warn is-err">Failed to load dataset: {err}</p>
    </div>
  );
  if (!stats) return <div className="card">Loading 55,822 real mainnet swaps…</div>;

  const f0 = (x) => `$${x.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
  // null == the statistic is undefined at this slider position (see dynDegenerate).
  const fx = (x, d = 1, suffix = "") => (x == null ? "n/a" : x.toFixed(d) + suffix);
  // A verdict colour must never land on a statistic that does not exist: "n/a" in
  // --signal reads as a success. When the value is null the verdict is withheld,
  // which is what --muted says on this system (.warn), in mono like its neighbours.
  const vc = (x, cls) => (x == null ? "num warn" : cls);

  return (
    <>
      {/* Stamp then claim. The <em> goes with the weld: it would now wrap the
          entire heading, and a whole h1 in --signal is not an accent. */}
      <div className="label">Explorer</div>
      <h1>Don&rsquo;t take our word for it</h1>
      <p className="muted">
        Every number below is computed <b>in your browser</b>, right now, by re-pricing{" "}
        <b><span className="num">{stats.n.toLocaleString()}</span> real Unichain mainnet ETH/USDC swaps</b>{" "}
        (<span className="num">{meta?.days}</span> days)
        under the parameters you choose. No server, no RPC — this is the same arithmetic the
        hook runs on-chain, applied to trades that actually happened. Move a slider and try to
        break the result.
      </p>

      <p className="muted">
        Precision note: at the deployed defaults this page reproduces{" "}
        <code>backtest/compare.py</code> exactly — clawback{" "}
        <span className="num">$2,688.40</span> of <span className="num">$5,001.53</span> gross
        adverse selection, <span className="num">ρ = 53.8%</span>, to the cent. Theta is computed
        the way the contract computes it: integer division, capped at the observation ring&rsquo;s
        128 entries. The tape ships as float32 to keep the download small, so other figures can
        differ from the Python suite in the last decimal. The Python suite on the full-precision
        CSV remains the number of record.
      </p>

      {/* Two columns, and the wrappers are deliberate: with a bare .card as a direct
          child app.css treats a .row as a seamed KPI strip (gap 0, margins killed),
          which is the wrong object here — this is a control panel beside a result,
          not one strip. Wrapping each column keeps the cards' own margins, so both
          columns start on the same line, and the gap is a clamp off the type scale
          rather than a hardcoded 24. */}
      <div className="row" style={{ margin: 0, alignItems: "flex-start", gap: "clamp(1rem, 2.5vw, 2rem)" }}>
        <div style={{ flex: "1 1 20rem", minWidth: 0 }}>
          <div className="card">
            <div className="row" style={{ justifyContent: "space-between", borderBottom: "var(--rule)", paddingBottom: "0.75rem" }}>
              <span className="label keep-case">Parameters</span>
              <button className="ghost" onClick={reset} disabled={isDefault}>
                {isDefault ? "= deployed hook" : "reset to deployed"}
              </button>
            </div>
            {/* The parameter stack is a list, so app.css's li rule supplies the
                hairline between every parameter and the space around it. */}
            <ul>
              <Slider label="θ floor (ticks ≈ bps)" value={thetaMin} min={1} max={20} step={1}
                      onChange={setThetaMin} note="below this markout, flow is always benign" />
              <Slider label="k — volatility scaling" value={k} min={0} max={8} step={0.1}
                      onChange={setK} fmt={(v) => v.toFixed(1)}
                      note="θ = floor + k · realized vol. k=0 makes the threshold static." />
              <Slider label="forfeit ramp (ticks)" value={ramp} min={5} max={80} step={5}
                      onChange={setRamp} note="markout beyond θ+ramp forfeits the full bond" />
              <Slider label="bond (bps of notional)" value={bondBps} min={5} max={100} step={5}
                      onChange={setBondBps} />
              <Slider label="settlement horizon" value={hz} min={1} max={5} step={1}
                      onChange={setHz} fmt={(v) => HORIZON_LABELS[v]}
                      note="maturity + TWAP window" />
              {/* σ source is another parameter, so it is another row in the same
                  stack — the hairline above it comes from the same li rule that
                  separates the sliders, not from an 18px margin. */}
              <li>
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <span className="label keep-case">where &sigma; comes from</span>
                  <span className="mono keep-case">
                    {sigmaSrc === "trailing" ? "trailing 120s (v7)" : "settlement window (v6)"}
                  </span>
                </div>
                {/* One segmented control, not two pills: gap 0 and a −1px pull so the
                    pair shares a single hairline. Selection is already encoded as
                    "no class vs .ghost", which app.css renders as signal outline vs
                    hairline; aria-pressed states the same thing to a screen reader. */}
                <div className="row" style={{ gap: 0, marginTop: "0.6rem" }}>
                  <button className={sigmaSrc === "trailing" ? "" : "ghost"}
                          aria-pressed={sigmaSrc === "trailing"}
                          onClick={() => { setSigmaSrc("trailing"); setK(1.4); }}>before the trade</button>
                  <button className={sigmaSrc === "window" ? "" : "ghost"}
                          aria-pressed={sigmaSrc === "window"} style={{ marginLeft: -1 }}
                          onClick={() => { setSigmaSrc("window"); setK(2.8); }}>the settlement window</button>
                </div>
                <div className="muted" style={{ marginTop: "0.6rem" }}>
                  v6 measured &sigma; over the same window it measured the markout, so a
                  trader&rsquo;s own companion prints raised the bar it was judged against —{" "}
                  <span className="num">927</span> swaps on this tape were acquitted that way.
                  v7 measures &sigma; over a window that closes before the trade lands. Each
                  source carries its own calibrated k (<span className="num">1.4 vs 2.8</span>)
                  so the two flag the same share of flow — otherwise the comparison would just
                  be measuring which one is set more aggressively.
                </div>
              </li>
            </ul>
          </div>
        </div>

        <div style={{ flex: "1 1 22rem", minWidth: 0 }}>
          {/* The verdict card, in the same object the landing page uses: a mono
              caption (case preserved, or ρ uppercases to a Latin-looking Ρ), the
              figure in the display face, then the supporting line. ρ is .ok, not
              claw: evidence.css already paints this same number --signal. */}
          <div className="card">
            <div className="label"><span className="keep-case">ρ</span> — share of realized adverse selection recovered</div>
            <div className={stats.rho == null ? "big" : "big ok"}>{fx(stats.rho, 1, "%")}</div>
            <div className="muted">
              <span className="num">{f0(stats.claw)}</span> clawed back of{" "}
              <span className="num">{f0(stats.grossAS)}</span> —{" "}
              <span className="num">{fx(stats.lvrX, 1, "×")}</span> the
              pool&rsquo;s net LVR bleed, and +<span className="num">{fx(stats.pctFees, 1, "%")}</span>{" "}
              on <span className="num">{f0(stats.fees)}</span> of fees
            </div>
          </div>
          <div className="card">
            <div className="label">who pays, at identical LP revenue</div>
            <table>
              <tbody>
                <tr><td>benign flow — Hindsight</td><td><b className={vc(stats.benignEff, "ok")}>{fx(stats.benignEff, 2, " bps")}</b></td></tr>
                <tr><td>toxic flow — Hindsight</td><td><b className={vc(stats.toxicEff, "bad")}>{fx(stats.toxicEff, 2, " bps")}</b></td></tr>
                {/* The last three rows are one comparison against the rival, so their
                    keys are muted and only the values carry the verdict. */}
                <tr><td className="muted">revenue-matched dynamic fee</td><td className="muted">{stats.dynC == null ? "n/a — no realized vol at this horizon" : <span className="num">5 + {stats.dynC.toFixed(2)}·σ bps</span>}</td></tr>
                <tr>
                  <td className="muted">…its incremental revenue from <b>benign</b> flow</td>
                  <td><b className={vc(stats.dynBenignShare, "bad")}>{fx(stats.dynBenignShare, 1, "%")}</b></td>
                </tr>
                <tr><td className="muted">…Hindsight&rsquo;s, from benign flow</td><td><b className="ok">0.0%</b></td></tr>
              </tbody>
            </table>
            {/* A summary under a table is a ledger total: it gets the rule, not 8px. */}
            <div className="muted" style={{ borderTop: "var(--rule)", paddingTop: "0.75rem" }}>
              <span className="num">{stats.toxPct.toFixed(1)}%</span> of swaps flagged{" "}
              (<span className="num">{stats.toxN.toLocaleString()}</span>)
            </div>
          </div>
        </div>
      </div>

      {/* The only real section break on the page, so it gets the one thing app.css
          reserves for one: a rule with a word on it in the display face. Out of the
          card and onto the page — the instrument is above, this is the ledger, and
          the three imperatives are hairline-separated rows rather than discs on a
          40px indent. Measure is set in ch because it is prose, not a panel. */}
      <h2>Things worth trying</h2>
      <ul className="muted" style={{ maxWidth: "68ch" }}>
        <li><b>Set k = 0</b> — a static threshold. ρ barely moves, but the mechanism starts
          confiscating volatile-but-uninformed flow (that&rsquo;s what the vol-decile chart measures).</li>
        <li><b>Shorten the horizon</b> — at <span className="num">3+2s</span> the mechanism stops
          beating a random-label null (see §0 of the README). That is why we ship{" "}
          <span className="num">10+5s</span>, and why we publish the null.</li>
        <li><b>Raise the bond</b> — clawback scales, but benign flow still pays exactly the
          headline fee, because benign bonds are refunded in full. That is the whole point:
          the bond is a deposit, not a fee.</li>
      </ul>
    </>
  );
}
