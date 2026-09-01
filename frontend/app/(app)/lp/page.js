"use client";
import { useEffect, useState } from "react";
import { formatUnits } from "viem";
import { pub } from "../../../lib/clients";
import { HOOK, hookAbi } from "../../../lib/config";
import { getLogsChunked } from "../../../lib/logs";

// Presentation only. formatUnits has already done the arithmetic; this trims the
// STRING it handed back and never touches a BigInt. Eighteen decimals under a
// display face is a column of noise rather than a figure, and the KPI strip's
// geometry stays unbounded until the fraction is bounded. Six places, trailing
// zeros dropped. A value too small to survive six places is printed in full
// rather than rounded down to a zero it is not.
const DP = 6;
function amount(s) {
  const [whole, frac = ""] = s.split(".");
  const cut = frac.slice(0, DP).replace(/0+$/, "");
  if (cut) return `${whole}.${cut}`;
  return /[1-9]/.test(frac) ? s : whole;
}

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

  // app.css's `.appmain > .card:only-child` already strips the fill and sets this
  // as a mono line between two rules, so a misconfigured build still looks like
  // the product. The variable name is the one piece of it that is a machine
  // token, so it goes in <code> and is promoted to --ink out of the muted line.
  if (!HOOK)
    return (
      <div className="card">
        Set <code>NEXT_PUBLIC_*</code> env vars first.
      </div>
    );

  const totalForfeited = settles.reduce((a, e) => a + e.args.forfeit, 0n);
  const totalRefunded = settles.reduce((a, e) => a + e.args.refund, 0n);
  const totalFlushed = flushes.reduce((a, e) => a + e.args.amount0 + e.args.amount1, 0n);
  const toxicCount = settles.filter((e) => e.args.toxic).length;

  return (
    <>
      {/* Every (site) band opens with a mono stamp over the heading. The old h1
          welded a title and a subtitle with an em dash and set the pair in one
          line; at 125% stretch and uppercase that is a very long line, and the
          framing belongs in the stamp. Same words, split at the weld. */}
      <div className="label">LP dashboard</div>
      <h1>Value clawed back from toxic flow</h1>

      {/* The deck. app.css promotes the first `p.muted` in the column to --ink at
          58ch, and describes it as the paragraph each route "opens with" — so it
          moves above the figures, where a deck goes. `donate()` is a machine
          identifier and is set as one; the bare `code` rule in app.css reaches it
          without a class. */}
      <p className="muted">
        Forfeits drip via <code>donate()</code> each epoch (1/50 of the pot), and
        liquidity must reside 60s before it can be withdrawn, so the snipe cannot
        be atomic
      </p>

      {/* /evidence's three-figure treatment, which is a grid rather than a set of
          flexed tiles: `flex: 1` inside a wrapping row leaves a lone full-width
          card on the second line, a layout nobody chose. The track is .figures'
          own. app.css already kills the gutter and pulls the cards onto a shared
          hairline, so the strip reads as one seamed ledger row. */}
      <div
        className="row"
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 14rem), 1fr))",
        }}
      >
        <div className="card">
          <div className="label">recaptured from informed flow</div>
          {/* The recapture figure. evidence.css paints this same number --signal
              via .fig ("53.8% of realized adverse selection recovered"), so it is
              .ok here for the same reason: a recapture is the mechanism working. */}
          <div className="big ok">{amount(formatUnits(totalForfeited, 18))}</div>
        </div>
        <div className="card">
          <div className="label">refunded to benign traders</div>
          {/* Left at --ink. The recapture figure beside it already carries the
              strip's one accent, and two signal numbers side by side would read
              as decoration rather than as the headline. */}
          <div className="big">{amount(formatUnits(totalRefunded, 18))}</div>
        </div>
        <div className="card">
          {/* Left at --ink. Three loud figures would read as three accents. */}
          <div className="label">dripped to in-range LPs</div>
          <div className="big">{amount(formatUnits(totalFlushed, 18))}</div>
        </div>
      </div>

      {/* Counts are not prose. They were fused to the mechanism paragraph above
          by an em dash and set at the same 13px; as a mono label line they stop
          jittering on the 20s reload (Plex Mono is fixed-pitch) and the `·` is
          the site's own separator idiom. Not a <p>, so the deck above keeps the
          `p.muted:first-of-type` promotion. */}
      <div className="label">
        {settles.length} settlements <span className="dim">·</span> {toxicCount} toxic
        ({settles.length ? Math.round((100 * toxicCount) / settles.length) : 0}%)
      </div>

      <h2>Settlements</h2>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>trader</th>
              <th>verdict</th>
              {/* app.css uppercases `th`, which turns θ into Θ. */}
              <th>markout vs <span className="keep-case">θ</span></th>
              <th>refund</th>
              <th>forfeit</th>
            </tr>
          </thead>
          <tbody>
            {settles.slice(0, 40).map((e) => (
              <tr key={e.args.swapId.toString()}>
                <td><span className="num">{e.args.swapId.toString()}</span></td>
                <td><code>{e.args.trader.slice(0, 8)}…</code></td>
                {/* A verdict is a stamped word: mono, uppercase, tracked. No
                    claw: this renders once per row, and forty orange cells IS
                    the palette the three-uses rule exists to prevent. The
                    promotion from --muted to --ink is the loud move here. */}
                <td>
                  {e.args.toxic ? (
                    <span className="mono bad">toxic</span>
                  ) : (
                    <span className="mono ok">benign</span>
                  )}
                </td>
                {/* The comparison the whole hook makes. Both sides tabular mono;
                    the separator recedes so the pair reads as one measurement. */}
                <td>
                  <span className="num">{e.args.markoutTicks.toString()}</span>
                  <span className="dim">{" / "}</span>
                  <span className="num">{e.args.thetaTicks.toString()}</span>
                </td>
                <td><span className="num">{amount(formatUnits(e.args.refund, 18))}</span></td>
                <td>
                  {e.args.forfeit > 0n ? (
                    <span className="num">{amount(formatUnits(e.args.forfeit, 18))}</span>
                  ) : (
                    <span className="dim">—</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
