"use client";
import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";
import { pub } from "../../../lib/clients";
import { HOOK, HOOK_BLOCK, hookAbi } from "../../../lib/config";
import { getLogsChunked, withRetry } from "../../../lib/logs";

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
  // loading — no complete read has landed yet, so there are no figures to show
  // ready   — a complete read; the figures are the whole truth
  // partial — some windows were unreadable; the figures are a lower bound
  // stale   — a refresh degraded, so the LAST GOOD figures are still on screen
  // error   — could not read at all
  const [status, setStatus] = useState("loading");
  const scanned = useRef(null);   // head of the last complete scan, for incremental refresh

  // This used to be an initial fetch plus setInterval(location.reload, 20_000).
  // The scan took longer than twenty seconds, so the reload aborted it a beat
  // before it resolved and the page never rendered a settlement in its life. It
  // refreshes in place now, and a run still in flight is never overlapped.
  useEffect(() => {
    if (!HOOK) return;
    let stop = false;
    let running = false;

    const keyOf = (e) => `${e.blockNumber}-${e.logIndex}`;
    const merge = (prev, next) => {
      const m = new Map(prev.map((e) => [keyOf(e), e]));
      for (const e of next) m.set(keyOf(e), e);
      return [...m.values()].sort((a, b) =>
        a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
      );
    };

    const run = async () => {
      if (running) return;
      running = true;
      try {
        const settledEvent = hookAbi.find((x) => x.type === "event" && x.name === "Settled");
        const flushEvent = hookAbi.find((x) => x.type === "event" && x.name === "DonationFlushed");

        // One head for both scans: two scans resolving against two different
        // heads would produce totals drawn from different chain states. Retried,
        // because every window is gated behind it and it was the one call in the
        // path with no second chance.
        const latest = await withRetry(() => pub.getBlockNumber());

        if (HOOK_BLOCK === null) throw new Error("NEXT_PUBLIC_HOOK_BLOCK is not a block number");
        if (HOOK_BLOCK > latest) throw new Error(`HOOK_BLOCK ${HOOK_BLOCK} is ahead of head ${latest}`);

        // Settled history is immutable, so after one complete scan the later
        // ticks only need the new tail. REORG_SLACK re-reads a little of what we
        // already have; the merge is keyed by block+logIndex, so re-reading is
        // free and a shallow reorg cannot leave a duplicate behind.
        const REORG_SLACK = 200n;
        const from =
          scanned.current === null
            ? HOOK_BLOCK
            : scanned.current + 1n > REORG_SLACK
              ? scanned.current + 1n - REORG_SLACK
              : HOOK_BLOCK;

        const [settled, flushed] = await Promise.all([
          getLogsChunked(pub, { address: HOOK, event: settledEvent, fromBlock: from, latest }),
          getLogsChunked(pub, { address: HOOK, event: flushEvent, fromBlock: from, latest }),
        ]);
        if (stop) return;

        const failed = settled.failed + flushed.failed;
        const incremental = scanned.current !== null;

        if (failed > 0 && !incremental) {
          // First read, and it has holes. Show what we have, labelled — a
          // partial total is worth more than an empty page, but only if it says
          // it is partial.
          setSettles(settled.logs.slice().reverse());
          setFlushes(flushed.logs.slice().reverse());
          setStatus("partial");
          return;
        }
        if (failed > 0) {
          // A refresh degraded. Keep the last good figures rather than letting an
          // incomplete read overwrite a complete one — clobbering here would put
          // the page back to the "0 settlements" it was just fixed to stop
          // showing, off a single dropped request.
          setStatus("stale");
          return;
        }

        setSettles((prev) => merge(incremental ? [...prev].reverse() : [], settled.logs).reverse());
        setFlushes((prev) => merge(incremental ? [...prev].reverse() : [], flushed.logs).reverse());
        scanned.current = latest;
        setStatus("ready");
      } catch (e) {
        console.error(e);
        if (!stop) setStatus(scanned.current === null ? "error" : "stale");
      } finally {
        running = false;
      }
    };

    run();
    const t = setInterval(run, 20_000);
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

  // Has a read actually landed? Until one has, formatUnits(0n) renders a
  // confident "0" under "value clawed back from toxic flow" — a fabricated
  // figure for a pool that has recaptured real value, and the loudest thing on
  // the page. The state machine used to gate only the count line below the grid,
  // which is the one place the reader looks last.
  const hasFigures = status === "ready" || status === "partial" || status === "stale";
  const lowerBound = status === "partial" || status === "stale";

  // A withheld figure is set the way /toxicity withholds its bond and the way
  // the landing hero withholds its verdict: mono em dash, not a display zero.
  const Figure = ({ value, className = "big" }) =>
    hasFigures ? (
      <div className={className}>
        {lowerBound && <span className="dim">≥ </span>}
        {amount(formatUnits(value, 18))}
      </div>
    ) : (
      <div className="big warn">—</div>
    );

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
          <Figure value={totalForfeited} className="big ok" />
        </div>
        <div className="card">
          <div className="label">refunded to benign traders</div>
          {/* Left at --ink. The recapture figure beside it already carries the
              strip's one accent, and two signal numbers side by side would read
              as decoration rather than as the headline. */}
          <Figure value={totalRefunded} className="big" />
        </div>
        <div className="card">
          {/* Left at --ink. Three loud figures would read as three accents. */}
          <div className="label">dripped to in-range LPs</div>
          <Figure value={totalFlushed} className="big" />
        </div>
      </div>

      {/* Counts are not prose — as a mono label line they stop jittering on each
          refresh (Plex Mono is fixed-pitch) and `·` is the site's own separator.
          Not a <p>, so the deck above keeps the `p.muted:first-of-type`
          promotion.

          The scan state is printed here rather than left implicit. "0
          settlements" while the scan is still running is not a loading state,
          it is a wrong answer that happens to be rendered early — and a scan
          with windows missing produces a total that is only a lower bound, so
          it says so instead of quietly under-reporting. */}
      <div className="label">
        {status === "loading" && <>reading the chain <span className="dim">·</span> settlements since deploy</>}
        {status === "error" && <>could not reach the RPC <span className="dim">·</span> retrying</>}
        {(status === "ready" || status === "partial" || status === "stale") && (
          <>
            {settles.length} settlements <span className="dim">·</span> {toxicCount} toxic
            ({settles.length ? Math.round((100 * toxicCount) / settles.length) : 0}%)
            {status === "partial" && (
              <> <span className="dim">·</span> partial read, totals are a lower bound</>
            )}
            {status === "stale" && (
              <> <span className="dim">·</span> last refresh was incomplete, showing the previous complete read</>
            )}
          </>
        )}
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
            {/* An empty tbody under the Settlements heading reads as "this pool
                has never settled a swap", which is a different claim from "we
                have not read it yet". */}
            {!hasFigures && (
              <tr>
                <td colSpan={6} className="muted">
                  {status === "error" ? "could not reach the RPC" : "reading the chain…"}
                </td>
              </tr>
            )}
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
