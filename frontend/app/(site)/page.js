"use client";
import { useEffect, useState } from "react";
import dynamic from "next/dynamic";
import Link from "next/link";
import { scrollProgress } from "./_components/scroll";
import "./site.css";

// output: "export" prerenders every page in Node at build time, which would
// crash on a WebGL context. The canvas can only ever exist in the browser.
const Ribbon = dynamic(() => import("./_components/Ribbon"), { ssr: false });

/** The flashblock clock, ticking at Unichain's real 200ms cadence. */
function Clock({ onClose }) {
  const [n, setN] = useState(0);
  const reduced =
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  useEffect(() => {
    if (reduced) {
      onClose?.();
      return;
    }
    const id = setInterval(() => {
      setN((v) => {
        if (v === 11) onClose?.();
        return v + 1;
      });
    }, 200);
    return () => clearInterval(id);
  }, [onClose, reduced]);

  const stamp = 98067412 + (reduced ? 12 : n);
  return (
    <span className="num" aria-live="off">
      {String(stamp).slice(0, 2)}
      <span className="dim">·</span>
      {String(stamp).slice(2)}
    </span>
  );
}

function Verdict() {
  const [settled, setSettled] = useState(false);
  return (
    <div className={`verdict ${settled ? "is-settled" : ""}`}>
      <div className="label">
        Settlement <span className="dim">· compressed</span>
      </div>
      <div className="verdict-clock">
        <Clock onClose={() => setSettled(true)} />
      </div>
      <div className="verdict-row">
        <span className="label">Verdict</span>
        <span className="verdict-value num">
          {settled ? "5.00 bps · refunded" : "—"}
        </span>
      </div>
      <div className="bar" aria-hidden="true">
        <i />
      </div>
    </div>
  );
}

export default function Landing() {
  return (
    <>
      <div className="stage" aria-hidden="true">
        <Ribbon progressRef={scrollProgress} />
      </div>

      {/* ---- act 0 — the hero withholds ---------------------------------- */}
      <section className="hero" data-reveal>
        <div className="hero-stamp">
          <div className="label">Stamp</div>
          <Verdict />
        </div>

        <div className="hero-body">
          <h1 className="display h-hero hero-title">
            <span className="rv"><span>The fee is</span></span>
            <span className="rv"><span style={{ "--rv-delay": "80ms" }}>decided after</span></span>
            <span className="rv"><span style={{ "--rv-delay": "160ms" }}>your trade</span></span>
          </h1>
          <p className="lede fade" style={{ "--rv-delay": "420ms" }}>
            Your swap posts a small refundable bond. Fifteen seconds later the pool
            checks what the price actually did. Retail gets it back. Arbitrage pays
            for the harm it caused.
          </p>
          <div className="hero-foot fade" style={{ "--rv-delay": "560ms" }}>
            <span className="label">Scroll to settle</span>
          </div>
        </div>
      </section>

      {/* ---- acts 1-4 ---------------------------------------------------- */}
      <Act
        n="01"
        stamp="+00·000"
        title="The bond is held, not charged"
        body="Twenty-five basis points of your output is withheld inside the pool as an
        ERC-6909 claim. No transfer, no approval, no second transaction. If your trade
        turns out to be benign, all of it comes back."
      />
      <Act
        n="02"
        stamp="+50·000"
        title="θ is measured before you arrive"
        body="The threshold breathes with volatility, so a violent tape doesn't confiscate
        honest flow. It is computed from the two minutes before your swap landed — a window
        that had already closed, which is the only way you cannot move the bar you are
        judged against."
      />
      <Act
        n="03"
        stamp="+75·000"
        title="The window closes, and the pool looks back"
        body="Markout is the distance the price kept travelling in your direction after you
        left. Below θ, the bond is refunded in full. Above it, you forfeit in proportion to
        how far past you went — and it streams to the liquidity providers you took it from."
      />
      <Act
        n="04"
        stamp="55·822"
        title="Measured on real flow, not simulated agents"
        body="Seven days of Unichain mainnet ETH/USDC, re-priced through the exact on-chain
        logic. Benign flow paid the 5.00 bps headline. Informed flow paid 12.32."
        stat={{ v: "53.8%", k: "of realized adverse selection, recovered" }}
      />

      {/* ---- handoff ------------------------------------------------------ */}
      <section className="band handoff" data-reveal>
        <div className="stamp label">Next</div>
        <div className="bandbody">
          <div className="handoff-grid">
            <Card href="/mechanism" k="Mechanism" v="How a swap becomes a verdict, in four steps." />
            <Card href="/evidence" k="Evidence" v="The numbers, the nulls, and the two headlines we retracted." />
            <Card href="/explorer" k="Explorer" v="Re-price 55,822 real swaps yourself, in the browser." />
            <Card href="/swap" k="Open the app" v="Swap on the live pool and watch it settle." />
          </div>
        </div>
      </section>
    </>
  );
}

function Act({ n, stamp, title, body, stat }) {
  return (
    <section className="band act" data-reveal>
      <div className="stamp">
        <div className="label">{stamp}</div>
        <div className="act-n num">{n}</div>
      </div>
      <div className="bandbody">
        <h2 className="display h-section act-title">
          <span className="rv"><span>{title}</span></span>
        </h2>
        <p className="act-body fade" style={{ "--rv-delay": "180ms" }}>{body}</p>
        {stat && (
          <div className="stat fade" style={{ "--rv-delay": "300ms" }}>
            <div className="stat-v display num">{stat.v}</div>
            <div className="stat-k label">{stat.k}</div>
          </div>
        )}
      </div>
    </section>
  );
}

function Card({ href, k, v }) {
  return (
    <Link href={href} className="hcard">
      <span className="label">{k}</span>
      <span className="hcard-v">{v}</span>
      <span className="hcard-arrow" aria-hidden="true">→</span>
    </Link>
  );
}
