import Link from "next/link";
import "../site.css";
import "../mechanism/doc.css";
import "./evidence.css";

export const metadata = {
  title: "Evidence",
  description:
    "55,822 real Unichain mainnet swaps, re-priced through the exact on-chain logic — including the permutation null we fail, and the two headline numbers we retracted.",
};

const NUMBERS = [
  {
    id: "rho",
    k: (<><span className="keep-case">ρ</span> — realized adverse selection recovered</>),
    v: "53.8",
    u: "%",
    note: "$2,688 of $5,002",
  },
  { id: "benign", k: "Benign flow", v: "5.00", u: "bps", note: "the headline fee, bond refunded in full" },
  { id: "informed", k: "Informed flow", v: "12.32", u: "bps", note: "fee plus the forfeited share of its bond" },
  { id: "null", k: "Permutation null at the shipped horizon", v: "+6.14", u: "z", note: "beats random labels 30 of 30" },
];

export default function Evidence() {
  return (
    <>
      <section className="doc-head band">
        <div className="stamp label">Evidence</div>
        <div className="bandbody">
          <h1 className="display h-section doc-title">
            Measured on flow that actually happened
          </h1>
          <p className="lede">
            Seven days of Unichain mainnet ETH/USDC — 55,822 swaps — re-priced through the exact
            on-chain logic. No simulated agents, no assumed behaviour. Every number below
            regenerates from a file committed to the repo, with no RPC:{" "}
            <code className="mono">cd backtest &amp;&amp; python3 -m venv .venv &amp;&amp; .venv/bin/pip install matplotlib &amp;&amp; .venv/bin/python compare.py</code>.
          </p>
        </div>
      </section>

      <section className="band" data-reveal>
        <div className="stamp label">Headline</div>
        <div className="bandbody">
          <dl className="figures">
            {NUMBERS.map((f, i) => (
              <div key={f.id} className="fade" style={{ "--rv-delay": `${i * 70}ms` }}>
                <dt className="label">{f.k}</dt>
                <dd>
                  <span className="fig num">
                    {f.v}
                    <span className="fig-u">{f.u}</span>
                  </span>
                  <span className="fig-note">{f.note}</span>
                </dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      <section className="band ev-row" data-reveal>
        <div className="stamp label">The null</div>
        <div className="bandbody">
          <h2 className="display h-sub step-title fade">We publish the horizons that fail</h2>
          <p className="act-body fade" style={{ "--rv-delay": "90ms" }}>
            Before any headline: would random labels collect as much? Flipping a swap&apos;s
            direction negates its markout, so we shuffle directions and re-run. At short
            horizons the mechanism <em>does not beat chance</em> — the dominant signal there is
            a trade&apos;s own price impact, not information. We ship the horizon where the
            signal is real and print the failures beside it.
          </p>
          <table className="tbl fade" style={{ "--rv-delay": "180ms" }}>
            <thead>
              <tr><th>Horizon</th><th>True clawback</th><th>Random-label mean</th><th>z</th></tr>
            </thead>
            <tbody>
              <tr><td>1 + 1s</td><td className="num">$570</td><td className="num">$852</td><td className="num neg">−4.27</td></tr>
              <tr><td>3 + 2s</td><td className="num">$1,239</td><td className="num">$1,270</td><td className="num neg">−0.42</td></tr>
              <tr><td>5 + 2s</td><td className="num">$1,681</td><td className="num">$1,531</td><td className="num">+1.86</td></tr>
              <tr className="is-shipped"><td>10 + 5s <span className="label">shipped</span></td><td className="num">$2,688</td><td className="num">$2,186</td><td className="num pos">+6.14</td></tr>
              <tr><td>30 + 10s</td><td className="num">$4,565</td><td className="num">$3,539</td><td className="num">+10.93</td></tr>
            </tbody>
          </table>
        </div>
      </section>

      {/* The differentiator. Every other submission shows what worked. */}
      <section className="band retract ev-row" data-reveal>
        <div className="stamp label">Retracted</div>
        <div className="bandbody">
          <h2 className="display h-section step-title fade">What we got wrong</h2>
          <p className="act-body fade" style={{ "--rv-delay": "90ms" }}>
            This project has been through three rounds of adversarial audit. Twice, the honest
            answer cost us a headline. Both corrections are here rather than quietly restated,
            because a number you can check matters more than a number that flatters us.
          </p>

          <ol className="retractions">
            <li className="fade" style={{ "--rv-delay": "160ms" }}>
              <div className="label">Was — out-of-sample correlation 0.441</div>
              <p>
                The label was anchored at the swap&apos;s own execution price, which makes it
                identically <em>markout + later drift</em>. Verified across all 55,822 swaps:
                the difference is exactly zero. Disjoint in time, overlapping in information —{" "}
                <strong>91% of that number was the tautology the test existed to rebut</strong>,
                and a placebo tape with no predictability scored higher than the real data.
              </p>
              <div className="label">Now — the per-trade figure is ≈ 0, published as a negative result</div>
            </li>

            <li className="fade" style={{ "--rv-delay": "240ms" }}>
              <div className="label">Was — &ldquo;0.0% of revenue from benign flow&rdquo;</div>
              <p>
                A string literal. True by construction, because we defined benign as{" "}
                <em>the swaps we did not charge</em>. Scored against an independent label —
                address behaviour in the half of the week the charge never saw — the honest
                figure is <strong>5.6%</strong>, against 14.4% for a flat fee. Still roughly
                three times better. Far less than the tautology implied.
              </p>
              <div className="label">Now — both numbers ship, with the tautology labelled</div>
            </li>

            <li className="fade" style={{ "--rv-delay": "320ms" }}>
              <div className="label">Was — &ldquo;a JIT can capture at most ~15% of the pot&rdquo;</div>
              <p>
                Our own test measured a <em>single</em> epoch and never repeated the snipe,
                which was the entire attack. Repeated across twelve flushes a JIT with one
                seventh of the incumbent&apos;s capital took <strong>98%</strong>. Liquidity now
                has to sit for sixty seconds before it can be withdrawn, so the snipe cannot be
                atomic.
              </p>
              <div className="label">Now — the bound is gone; residency replaces it</div>
            </li>
          </ol>

          <p className="act-body ev-tail fade" style={{ "--rv-delay": "400ms" }}>
            What replaced the first retraction is the test that actually holds. Charge measured
            on the first half of the week predicts which <em>addresses</em> adversely select in
            the second: Spearman <span className="num">+0.739</span>, permutation{" "}
            <span className="num">p = 0.0005</span>. The addresses we charged most went on to
            impose <span className="num">6.43 bps</span> of adverse selection; the ones we
            charged least, <span className="num">0.43</span>. Small sample, stated plainly: only
            34 addresses trade this pool in both halves.
          </p>
        </div>
      </section>

      <section className="band" data-reveal>
        <div className="stamp label">Check it</div>
        <div className="bandbody">
          <p className="act-body">
            The tape ships with the repo, so a clean clone reproduces every figure offline. Or{" "}
            <Link className="u" href="/explorer">re-price all 55,822 swaps in your browser</Link>{" "}
            and move the parameters yourself.
          </p>
        </div>
      </section>
    </>
  );
}
