import "../site.css";
import "./doc.css";

export const metadata = {
  title: "Mechanism",
  description:
    "How a swap becomes a verdict: the bond is held, θ is measured from before you arrived, the window closes, and the pool settles from what the price actually did.",
};

const STEPS = [
  {
    n: "01",
    stamp: "+00·000",
    t: "The bond is held",
    b: `Twenty-five basis points of your output is withheld inside the pool as an
    ERC-6909 claim. Nothing is transferred and nothing is approved — the hook returns a
    positive delta in afterSwap and mints itself the claim, so the bond never leaves the
    PoolManager. A reverted transaction never lands, never posts a bond, and never enters
    the measurement, which is why revert-spam does not apply here.`,
    k: [["Bond", "25 bps of the unspecified amount"], ["Custody", "ERC-6909 claims, in-pool"]],
  },
  {
    n: "02",
    stamp: "+50·000",
    t: "θ is fixed at execution",
    b: `The threshold scales with realized volatility, so a violent tape does not confiscate
    honest flow. It is measured over the 120 seconds before your swap landed — a window that
    had already closed — and written into your swap record on the spot. Through v6 we measured
    it over the settlement window instead, which let a trade raise the bar it was judged
    against: 927 swaps on the real tape were acquitted by their own companion prints. Now that
    number is zero, because there is nothing left to write into.`,
    k: [["θ", "θ_min + 1.4 × trailing σ"], ["Source", "[t − 120s, t), already closed"]],
  },
  {
    n: "03",
    stamp: "+75·000",
    t: "The window closes",
    b: `Ten seconds to maturity, then a five-second settlement window, measured on Uniswap's
    official FlashblockNumber contract at 200ms resolution. Once it closes, anyone can call
    settle — the verdict is a pure read of observations that are already in the past, so there
    is nothing left to sandwich.`,
    k: [["Maturity", "50 flashblocks · 10s"], ["Window", "25 flashblocks · 5s"]],
  },
  {
    n: "04",
    stamp: "settle",
    t: "The pool looks back",
    b: `Markout is the distance the price kept travelling in your direction after you left.
    Below θ the bond is refunded in full and you paid exactly the headline fee. Above it you
    forfeit in proportion to how far past you went, and the forfeit is dripped to the liquidity
    providers who wore the adverse selection — not lumped, so it cannot be sniped in one block.`,
    k: [["Benign", "5.00 bps · full refund"], ["Informed", "12.32 bps average"]],
  },
];

export default function Mechanism() {
  return (
    <>
      <section className="doc-head band">
        <div className="stamp label">Mechanism</div>
        <div className="bandbody">
          <h1 className="display h-section doc-title">
            How a swap becomes a verdict
          </h1>
          <p className="lede">
            Four steps, in the order they happen. Every number here is the one the deployed
            contract runs.
          </p>
        </div>
      </section>

      {STEPS.map((s) => (
        <section className="band step" key={s.n} data-reveal>
          <div className="stamp">
            <div className="label">{s.stamp}</div>
            <div className="act-n num">{s.n}</div>
          </div>
          <div className="bandbody">
            <h2 className="display h-sub step-title fade">{s.t}</h2>
            <p className="act-body fade" style={{ "--rv-delay": "90ms" }}>{s.b}</p>
            <dl className="keys fade" style={{ "--rv-delay": "180ms" }}>
              {s.k.map(([k, v]) => (
                <div key={k}>
                  <dt className="label">{k}</dt>
                  <dd className="num">{v}</dd>
                </div>
              ))}
            </dl>
          </div>
        </section>
      ))}

      <section className="band" data-reveal>
        <div className="stamp label">Also true</div>
        <div className="bandbody">
          <h2 className="display h-sub step-title fade">What it does not do</h2>
          <p className="act-body fade" style={{ "--rv-delay": "90ms" }}>
            It does not predict. A trade whose markout forecast further drift in the same
            direction would be a standing arbitrage, and our own out-of-sample test says the
            per-trade figure is about zero — we publish that as a negative result. What it does
            is identify the flow that keeps adversely selecting, which is a claim about traders
            and which does survive out of sample.
          </p>
        </div>
      </section>
    </>
  );
}
