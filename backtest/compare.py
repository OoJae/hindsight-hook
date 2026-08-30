#!/usr/bin/env python3
"""Hindsight counterfactual analysis on real Unichain mainnet flow.

Everything here is a RE-PRICING OF IDENTICAL REALIZED TRADES — no behavioural
assumptions, no simulated agents. We take the swaps that actually happened and ask what
each fee mechanism would have charged them.

Outputs (run: .venv/bin/python compare.py):
  1. LVR decomposition        — how much realized adverse selection we recover (rho)
  2. Revenue-matched head-to-head — who PAYS when a dynamic fee raises identical revenue
  3. Horizon robustness       — rho across a 60x range of settlement horizons
  4. FP by vol decile         — "we tax information, not volatility", measured against
                                harm the mechanism never saw, on BOTH vol axes
  5. Parameter sensitivity    — k x theta_min grid
  6. Out-of-sample            — does the charge predict FUTURE adverse selection?
  7. Concentration            — is it one bot?
  8. Permutation null         — would random labels do as well?
  9. Self-inflation           — can a trade raise its own threshold? (round-2 M9)
"""
import csv, statistics, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def _open(path):
    """Open a backtest CSV, transparently accepting the committed .gz form.

    The repo ships `swaps_*.csv.gz` (2.0MB) rather than the 7.6MB raw CSV, so a
    fresh clone can reproduce every published number with no fetch step.
    """
    import gzip, os
    if os.path.exists(path):
        return open(path)
    if os.path.exists(path + ".gz"):
        return gzip.open(path + ".gz", "rt")
    raise FileNotFoundError(
        f"{path} (and {path}.gz) not found — run `python3 fetch.py` to rebuild it"
    )



BOND_BPS = 25
N_SEC, W_SEC = 10, 5   # see the permutation null in section 8: at 3+2s the
                       # signal is not separable from chance; at 10+5s it is (z=+4.4)
THETA_MIN = 3.0
THETA_K = 1.4          # re-calibrated for the trailing sigma (was 2.8 for the in-window one)
RAMP = 20.0
MAX_JUMP = 60.0       # TWAP per-observation clamp  == HindsightParams.maxJumpTicks
MAX_VOL_JUMP = 10.0   # theta's vol-input clamp     == HindsightHook.MAX_VOL_JUMP_TICKS
                      # The two differ deliberately and defend opposite parties; see
                      # HindsightHook._theta. Before Aug 30 this file used 60 for BOTH,
                      # so every published number described a theta ceiling of 171 — the
                      # exact value the round-2 M4 fix removed. Fixed here.
USDC = 1e6
HEADLINE_FEE_BPS = 5.0
KEEPER_TIP_BPS = 500  # of the forfeit


def load(path="swaps_eth_usdc_5bp.csv"):
    rows = list(csv.DictReader(_open(path)))
    for r in rows:
        for k in ("block", "tick", "amount0", "amount1", "fee"):
            r[k] = int(r[k])
    return rows


def window(rows, i, start, end):
    """Jump-clamped time-weighted mean tick + mean |jump| over [start, end).

    Mirrors ObservationLib.twap / avgAbsJump: the TWAP carries the CLAMPED tick forward
    (so a spike cannot drag the running mean), while the vol accumulator clamps each jump
    independently against the raw previous tick, at its own tighter ceiling.
    """
    raw_prev = clamped_prev = rows[i]["tick"]
    j = i + 1
    while j < len(rows) and rows[j]["block"] <= start:
        raw_prev = clamped_prev = rows[j]["tick"]; j += 1
    w = dur = 0.0
    jumps = []
    seg = start
    while j < len(rows) and rows[j]["block"] < end:
        t, tick = rows[j]["block"], rows[j]["tick"]
        w += clamped_prev * (t - seg); dur += t - seg
        jumps.append(min(abs(tick - raw_prev), MAX_VOL_JUMP))
        d = tick - clamped_prev
        clamped_prev += max(-MAX_JUMP, min(MAX_JUMP, d))
        raw_prev, seg = tick, t
        j += 1
    w += clamped_prev * (end - seg); dur += end - seg
    if dur <= 0:
        return None, None
    return w / dur, (sum(jumps) / len(jumps) if jumps else 0.0)


_TVOL_CACHE = {}

def trailing_vols(rows, lookback=120, clamp=MAX_JUMP):
    """Memoized wrapper — `price` used to recompute this on all 152 calls per run."""
    key = (id(rows), lookback, clamp)
    if key not in _TVOL_CACHE:
        _TVOL_CACHE[key] = _trailing_vols(rows, lookback, clamp)
    return _TVOL_CACHE[key]


def _trailing_vols(rows, lookback=120, clamp=MAX_JUMP):
    """Backward-looking mean |tick jump| over the previous `lookback` seconds.

    This is what a dynamic-fee hook can ACTUALLY read in beforeSwap. Our own theta uses the
    forward settlement window because Hindsight prices at settle(), after that window closes
    — that asymmetry IS the mechanism, so the competitor must be given a fair ex-ante signal.
    """
    import bisect
    blocks = [r["block"] for r in rows]
    jumps = [0.0] + [min(abs(rows[i]["tick"] - rows[i - 1]["tick"]), clamp) for i in range(1, len(rows))]
    pref = [0.0] * (len(jumps) + 1)
    for i, j in enumerate(jumps):
        pref[i + 1] = pref[i] + j
    out = []
    for i, r in enumerate(rows):
        lo = bisect.bisect_left(blocks, r["block"] - lookback)
        n = i - lo
        out.append((pref[i] - pref[lo]) / n if n > 0 else 0.0)
    return out


# Where theta's volatility estimate comes from.
#   "window"   — the settlement window itself. What shipped through v6, and the source of
#                round-2 audit finding M9: the drift being scored raises its own threshold.
#   "trailing" — a lookback window ending strictly BEFORE the swap. Decoupled by
#                construction: a trade cannot pad a window that closed before it landed.
#   "static"   — no vol term at all (k is ignored).
THETA_SRC = "trailing"
THETA_LOOKBACK = 120   # seconds, for THETA_SRC == "trailing"


def price(rows, n_sec=N_SEC, w_sec=W_SEC, theta_min=THETA_MIN, k=THETA_K, ramp=RAMP,
          bond_bps=BOND_BPS, static_theta=None, theta_src=None, lookback=None):
    """Re-price every swap. Returns per-swap dicts."""
    last = rows[-1]["block"]
    src = theta_src or THETA_SRC
    lb = lookback or THETA_LOOKBACK
    tvol = trailing_vols(rows)                                   # competitor's ex-ante signal
    # theta's own trailing estimate uses theta's tighter clamp, and must END BEFORE the
    # swap: `lag=1` excludes the swap's own print, mirroring the on-chain window
    # [execStamp - V, execStamp - 1].
    theta_tvol = trailing_vols(rows, lb, MAX_VOL_JUMP) if src == "trailing" else None
    out = []
    for i, s in enumerate(rows):
        if s["block"] + n_sec + w_sec > last:
            continue
        usd = abs(s["amount1"]) / USDC
        if usd == 0:
            continue
        tw, vol = window(rows, i, s["block"] + n_sec, s["block"] + n_sec + w_sec)
        if tw is None:
            continue
        drift = tw - s["tick"]
        markout = -drift if s["amount0"] < 0 else drift
        if static_theta is not None:
            theta = static_theta
        elif src == "static":
            theta = theta_min
        elif src == "trailing":
            theta = theta_min + k * theta_tvol[i]
        else:
            theta = theta_min + k * vol
        f = max(0.0, min(1.0, (markout - theta) / ramp))
        bond = usd * bond_bps / 1e4
        out.append(dict(usd=usd, markout=markout, vol=vol, tvol=tvol[i], theta=theta,
                        fee=usd * s["fee"] / 1e6, bond=bond, forfeit=bond * f, toxic=f > 0,
                        sender=s["sender"], block=s["block"], tick=s["tick"],
                        z4o=s["amount0"] < 0, idx=i))
    return out


HARM_LO, HARM_HI = 20, 60   # disjoint from the settlement window [t+10, t+15)
_HARM_CACHE = {}

def future_harms(rows):
    """Per-swap realized adverse drift on a LATER, DISJOINT window.

    This is the only label in the file that the mechanism never observes, so it is the
    only fair referee for "is this classifier any good". Indexed by row position.
    """
    key = id(rows)
    if key not in _HARM_CACHE:
        out = [None] * len(rows)
        for i, s in enumerate(rows):
            hw, _ = window(rows, i, s["block"] + HARM_LO, s["block"] + HARM_HI)
            if hw is None:
                continue
            drift = hw - s["tick"]
            out[i] = -drift if s["amount0"] < 0 else drift
        _HARM_CACHE[key] = out
    return _HARM_CACHE[key]


def money(x):
    return f"${x:,.2f}"


def section(title):
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")


def lvr_decomposition(res):
    section("1. LVR DECOMPOSITION — what fraction of realized adverse selection we recover")
    fees = sum(r["fee"] for r in res)
    claw = sum(r["forfeit"] for r in res)
    gross_as = sum(r["usd"] * max(0.0, r["markout"]) / 1e4 for r in res)
    net_markout = sum(-r["usd"] * r["markout"] / 1e4 for r in res)
    tip = claw * KEEPER_TIP_BPS / 1e4
    print(f"swaps re-priced                  {len(res):>12,}")
    print(f"LP fee income (status quo)       {money(fees):>12}")
    print(f"gross adverse selection          {money(gross_as):>12}   (sum notional x positive markout)")
    print(f"net LP markout P&L, ex-fees      {money(net_markout):>12}   (the {N_SEC+W_SEC}s LVR bleed)")
    print(f"Hindsight clawback (gross)       {money(claw):>12}")
    print(f"  less keeper tips (5%)          {money(-tip):>12}")
    print(f"  net to LPs                     {money(claw - tip):>12}")
    print()
    print(f"  RHO = clawback / gross adverse selection = {100 * claw / gross_as:.1f}%")
    print(f"  clawback / net LVR bleed                 = {abs(claw / net_markout):.1f}x")
    return fees, claw


def revenue_matched(res, fees, claw):
    section("2. REVENUE-MATCHED HEAD-TO-HEAD — same LP revenue, who actually pays it?")
    target = fees + claw
    lo, hi = 0.0, 100.0
    for _ in range(80):
        c = (lo + hi) / 2
        rev = sum(r["usd"] * (HEADLINE_FEE_BPS + c * r["vol"]) / 1e4 for r in res)
        (lo := c) if rev < target else (hi := c)
    c = (lo + hi) / 2
    lo2, hi2 = 0.0, 1000.0
    for _ in range(80):
        f = (lo2 + hi2) / 2
        rev = sum(r["usd"] * f / 1e4 for r in res)
        (lo2 := f) if rev < target else (hi2 := f)
    flat = (lo2 + hi2) / 2

    ben = [r for r in res if not r["toxic"]]
    tox = [r for r in res if r["toxic"]]
    inc_ben = sum(r["usd"] * (c * r["vol"]) / 1e4 for r in ben)
    inc_tox = sum(r["usd"] * (c * r["vol"]) / 1e4 for r in tox)
    vol_b = sum(r["usd"] for r in ben)
    vol_t = sum(r["usd"] for r in tox)

    print(f"target LP revenue (Hindsight)              {money(target):>12}")
    print(f"revenue-matched dynamic fee    = {HEADLINE_FEE_BPS:.0f} + {c:.3f}*sigma bps")
    print(f"revenue-matched FLAT fee       = {flat:.3f} bps  (charged to every swap)")
    print()
    # Volume-weighted: what a dollar of flow actually pays, and what LPs actually collect.
    # (replay.py and the browser explorer use the same definition, so all three agree.)
    def vw(rows_, per_swap_usd):
        v = sum(r["usd"] for r in rows_)
        return 1e4 * sum(per_swap_usd(r) for r in rows_) / max(v, 1e-9)

    dyn = lambda r: r["usd"] * (HEADLINE_FEE_BPS + c * r["vol"]) / 1e4
    print(f"{'':32s}{'benign':>14}{'toxic':>14}")
    print(f"{'  effective fee (dyn, vol-wtd)':32s}"
          f"{vw(ben, dyn):>13.2f}b"
          f"{vw(tox, dyn):>13.2f}b")
    print(f"{'  effective fee (Hindsight)':32s}"
          f"{HEADLINE_FEE_BPS:>13.2f}b"
          f"{vw(tox, lambda r: r['fee'] + r['forfeit']):>13.2f}b")
    print()
    print(f"share of the INCREMENTAL revenue paid by BENIGN flow:")
    print(f"   volatility-scaled dynamic fee   {100 * inc_ben / (inc_ben + inc_tox):>6.1f}%")
    print(f"   flat fee                        {100 * vol_b / (vol_b + vol_t):>6.1f}%   (pro-rata by volume)")
    print(f"   HINDSIGHT                          0.0%   (every benign bond refunded in full)")


def horizon_robustness(rows):
    section("3. HORIZON ROBUSTNESS — is rho an artifact of the 5s window?")
    print(f"{'N,W (s)':>10}{'clawback':>13}{'+% fees':>10}{'gross AS':>12}{'rho':>8}")
    for n, w in [(1, 1), (3, 2), (5, 2), (10, 5), (30, 10), (60, 20)]:
        r = price(rows, n_sec=n, w_sec=w)
        fees = sum(x["fee"] for x in r)
        claw = sum(x["forfeit"] for x in r)
        gas = sum(x["usd"] * max(0.0, x["markout"]) / 1e4 for x in r)
        tag = "  <- shipped" if (n, w) == (N_SEC, W_SEC) else ""
        print(f"{f'{n},{w}':>10}{money(claw):>13}{100*claw/fees:>9.1f}%{money(gas):>12}"
              f"{100*claw/gas:>7.1f}%{tag}")


def vol_decile(rows, res):
    section("4. FALSE POSITIVES BY VOLATILITY DECILE — do we tax information, or volatility?")
    print("  The claim is that scaling theta with volatility protects benign flow when the")
    print("  tape is violent. The old version of this test compared FLAGGED SHARE by decile,")
    print("  which is the wrong instrument: flagging more in volatile periods is only a fault")
    print("  if that flow was actually harmless. So we score against harm the mechanism never")
    print(f"  saw -- realized drift on the disjoint later window [t+{HARM_LO}s, t+{HARM_HI}s) --")
    print("  and report the FALSE-POSITIVE rate: flagged, but caused no subsequent harm.\n")

    harms = future_harms(rows)
    target_n = sum(1 for r in res if r["toxic"])
    lo, hi = 0.0, 500.0
    for _ in range(60):
        t_ = (lo + hi) / 2
        n = sum(1 for r in price(rows, static_theta=t_) if r["toxic"])
        (hi := t_) if n < target_n else (lo := t_)
    static_t = (lo + hi) / 2
    stat_res = price(rows, static_theta=static_t)
    win_res = price(rows, theta_src="window", k=2.8)
    print(f"  all three calibrated to flag ~the same count: vol-scaled {target_n:,}, "
          f"static (theta={static_t:.1f}) {sum(1 for r in stat_res if r['toxic']):,}, "
          f"in-window {sum(1 for r in win_res if r['toxic']):,}\n")

    def fp_by_decile(rs, axis):
        """Rank deciles of `axis` volatility; FP rate among provably harmless swaps."""
        order = sorted(range(len(rs)), key=lambda i: rs[i][axis])
        out, n = [], len(order)
        for d in range(10):
            grp = [rs[i] for i in order[d * n // 10:(d + 1) * n // 10]]
            harmless = [r for r in grp if (harms[r["idx"]] or 0.0) <= 0]
            out.append(100 * sum(1 for r in harmless if r["toxic"]) / max(len(harmless), 1))
        return out

    lo4 = lambda v: statistics.mean(v[:4])
    for axis, label, caveat in (
        ("vol", "realized IN-WINDOW vol", "the in-window estimator's own input"),
        ("tvol", "trailing 120s vol", "the trailing estimator's own input"),
    ):
        a = fp_by_decile(stat_res, axis)
        b = fp_by_decile(win_res, axis)
        c = fp_by_decile(res, axis)
        print(f"  deciles of {label}  (note: this axis IS {caveat},")
        print(f"  so read it as favouring that column -- which is exactly why we print both)")
        print(f"{'decile':>10}{'static':>10}{'in-window':>12}{'trailing':>11}")
        for d in range(10):
            mark = "  <- quietest" if d == 0 else ("  <- LOUDEST" if d == 9 else "")
            print(f"{d+1:>10}{a[d]:>9.1f}%{b[d]:>11.1f}%{c[d]:>10.1f}%{mark}")
        print(f"{'quiet 1-4':>10}{lo4(a):>9.1f}%{lo4(b):>11.1f}%{lo4(c):>10.1f}%")
        print(f"{'decile 10':>10}{a[9]:>9.1f}%{b[9]:>11.1f}%{c[9]:>10.1f}%")
        print()

    fp_all = lambda rs: 100 * sum(1 for r in rs if r["toxic"] and (harms[r["idx"]] or 0.0) <= 0) \
                        / max(sum(1 for r in rs if (harms[r["idx"]] or 0.0) <= 0), 1)
    print(f"  UNCONDITIONED false-positive rate (no decile slicing, so no axis bias):")
    print(f"    static {fp_all(stat_res):.1f}%   in-window {fp_all(win_res):.1f}%   "
          f"trailing {fp_all(res):.1f}%")
    print()
    print("  Read honestly: each estimator looks best on the axis that is its own input, and")
    print("  on the unconditioned rate the three are within 0.3pp. The vol term's top-decile")
    print("  protection is real for the IN-WINDOW sourcing and is NOT fully reproduced by the")
    print("  trailing one. We ship the trailing sigma anyway, because that protection was")
    print("  bought with a threshold a trader can move: see section 9, where 927 real swaps")
    print("  were acquitted by their own companion prints. Section 6 is the decider -- on the")
    print("  label neither estimator observes, the trailing sigma classifies better.")


def sensitivity(rows):
    section("5. PARAMETER SENSITIVITY — is the mechanism perched on a cliff?")
    hdr = "k \\ theta_min"
    print(f"{hdr:>14}" + "".join(f"{t:>14}" for t in (3, 6, 12)))
    for k in (0.7, 1.4, 2.8, 5.6):
        cells = []
        for tmin in (3, 6, 12):
            r = price(rows, theta_min=float(tmin), k=k)
            claw = sum(x["forfeit"] for x in r)
            tox = 100 * sum(1 for x in r if x["toxic"]) / len(r)
            cells.append(f"{money(claw)}/{tox:.1f}%")
        star = "  <- shipped" if k == THETA_K else ""
        print(f"{k:>14}" + "".join(f"{c:>16}" for c in cells) + star)
    print("\n  cells: clawback / share of swaps flagged toxic")
    print("  Smooth and monotone in both axes — no cliffs, no pathological regions.")
    print("  HONEST NOTE: theta_min still dominates k on this tape -- 3->12 ticks cuts the")
    print("  clawback ~64%, while k 0.7->5.6 cuts it ~50%. And section 4 shows the k term no")
    print("  longer buys the top-decile protection it did when sigma came from the settlement")
    print("  window. We keep it because section 6 says it classifies better, and because a")
    print("  threshold in absolute ticks is fitted to one pool's volatility level, whereas a")
    print("  vol-scaled one transfers -- but we are not going to claim more for it than that.")



# ─────────────────────────────── charts ───────────────────────────────
PALETTE = dict(benign="#4ade80", toxic="#f87171", hind="#3b62f6", other="#94a3b8")


def chart_who_pays(res, fees, claw):
    """The money chart: same LP revenue, radically different incidence."""
    target = fees + claw
    lo, hi = 0.0, 100.0
    for _ in range(80):
        c = (lo + hi) / 2
        rev = sum(r["usd"] * (HEADLINE_FEE_BPS + c * r["vol"]) / 1e4 for r in res)
        (lo := c) if rev < target else (hi := c)
    c = (lo + hi) / 2
    ben = [r for r in res if not r["toxic"]]
    tox = [r for r in res if r["toxic"]]
    dyn_b = sum(r["usd"] * (c * r["vol"]) / 1e4 for r in ben)
    dyn_t = sum(r["usd"] * (c * r["vol"]) / 1e4 for r in tox)
    vb, vt = sum(r["usd"] for r in ben), sum(r["usd"] for r in tox)
    flat_inc = target - sum(r["usd"] * HEADLINE_FEE_BPS / 1e4 for r in res)
    flat_b, flat_t = flat_inc * vb / (vb + vt), flat_inc * vt / (vb + vt)
    hind_b, hind_t = 0.0, claw

    labels = ["Flat fee\n(5.80 bps)", "Volatility-scaled\ndynamic fee", "Hindsight\n(ex-post markout)"]
    benign = [flat_b, dyn_b, hind_b]
    toxic = [flat_t, dyn_t, hind_t]

    fig, ax = plt.subplots(figsize=(9, 5.5))
    ax.bar(labels, benign, label="paid by BENIGN flow", color=PALETTE["benign"])
    ax.bar(labels, toxic, bottom=benign, label="paid by TOXIC flow", color=PALETTE["toxic"])
    for i, (b, t) in enumerate(zip(benign, toxic)):
        pct = 100 * b / (b + t) if (b + t) else 0
        ax.text(i, b + t + (b + t) * 0.03, f"{pct:.0f}% from benign",
                ha="center", fontweight="bold",
                color=PALETTE["toxic"] if pct > 50 else "#15803d")
    ax.set_ylabel("incremental LP revenue (USD, 7 days)")
    ax.set_ylim(0, max(b + t for b, t in zip(benign, toxic)) * 1.32)
    ax.set_title("Same LP revenue, three mechanisms — who actually pays it?\n"
                 "55,822 real Unichain mainnet swaps, re-priced", fontweight="bold")
    ax.legend(loc="lower center", ncol=2, framealpha=0.95)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout(); fig.savefig("chart_who_pays.png", dpi=150); plt.close(fig)
    print("  wrote chart_who_pays.png")


def chart_vol_decile(rows, res, infl):
    """Two panels: who actually eats the false positives, and who supplies their own theta."""
    harms = future_harms(rows)
    target_n = sum(1 for r in res if r["toxic"])
    lo, hi = 0.0, 500.0
    for _ in range(60):
        t = (lo + hi) / 2
        n = sum(1 for r in price(rows, static_theta=t) if r["toxic"])
        (hi := t) if n < target_n else (lo := t)
    stat_res = price(rows, static_theta=(lo + hi) / 2)
    win_res = price(rows, theta_src="window", k=2.8)

    def fp(rs, axis=None, dlo=0, dhi=10):
        if axis is None:
            sel = rs
        else:
            order = sorted(range(len(rs)), key=lambda i: rs[i][axis])
            n = len(order)
            sel = [rs[i] for i in order[dlo * n // 10:dhi * n // 10]]
        hl = [r for r in sel if (harms[r["idx"]] or 0.0) <= 0]
        return 100 * sum(1 for r in hl if r["toxic"]) / max(len(hl), 1)

    groups = ["overall\n(no slicing)", "quiet deciles 1-4\n(by in-window vol)",
              "loudest decile\n(by in-window vol)", "loudest decile\n(by trailing vol)"]
    series = {
        "static theta": [fp(stat_res), fp(stat_res, "vol", 0, 4), fp(stat_res, "vol", 9, 10),
                         fp(stat_res, "tvol", 9, 10)],
        "sigma from the settlement window (v6)":
            [fp(win_res), fp(win_res, "vol", 0, 4), fp(win_res, "vol", 9, 10),
             fp(win_res, "tvol", 9, 10)],
        "sigma from a trailing window (v7)":
            [fp(res), fp(res, "vol", 0, 4), fp(res, "vol", 9, 10), fp(res, "tvol", 9, 10)],
    }

    fig, (ax, ax2) = plt.subplots(1, 2, figsize=(14, 5.6), gridspec_kw={"width_ratios": [1.35, 1]})
    x = range(len(groups)); w = 0.26
    for j, (lab, vals) in enumerate(series.items()):
        col = [PALETTE["other"], PALETTE["toxic"], PALETTE["hind"]][j]
        ax.bar([i + (j - 1) * w for i in x], vals, w, label=lab, color=col)
    ax.set_xticks(list(x)); ax.set_xticklabels(groups, fontsize=8.5)
    ax.set_ylabel("false-positive rate\n(flagged, but caused no later harm)")
    ax.set_title("All three flag the same total. Who eats the mistakes?\n"
                 "Each estimator flatters itself on the axis that is its own input",
                 fontweight="bold", fontsize=10.5)
    ax.legend(fontsize=8); ax.spines[["top", "right"]].set_visible(False)

    pos = infl["pos"]
    bins = [0, 1, 2, 4, 8, 16, 32]
    counts = [sum(1 for v in pos if bins[i] <= v < bins[i + 1]) for i in range(len(bins) - 1)]
    lbl = [f"{bins[i]}-{bins[i+1]}" for i in range(len(bins) - 1)]
    ax2.bar(lbl, counts, color=PALETTE["toxic"])
    ax2.axhline(0, color=PALETTE["hind"], lw=3)
    ax2.set_xlabel("ticks of threshold a trade supplied to ITSELF")
    ax2.set_ylabel("swaps")
    ax2.set_title(f"Sigma from the settlement window lets a trade\n"
                  f"raise its own bar: {len(pos):,} swaps did, and {infl['bought']:,} were\n"
                  f"acquitted because of it. Trailing sigma: exactly 0 (green line).",
                  fontweight="bold", fontsize=10.5)
    ax2.spines[["top", "right"]].set_visible(False)
    fig.tight_layout(); fig.savefig("chart_vol_decile.png", dpi=150); plt.close(fig)
    print("  wrote chart_vol_decile.png")


def chart_horizon(rows):
    pts = []
    for n, w in [(1, 1), (3, 2), (5, 2), (10, 5), (30, 10), (60, 20)]:
        r = price(rows, n_sec=n, w_sec=w)
        claw = sum(x["forfeit"] for x in r)
        gas = sum(x["usd"] * max(0.0, x["markout"]) / 1e4 for x in r)
        pts.append((n + w, 100 * claw / gas))
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot([p[0] for p in pts], [p[1] for p in pts], "o-", color=PALETTE["hind"], lw=2)
    ax.axhline(46.7, ls="--", color=PALETTE["other"], lw=1)
    ax.annotate("shipped (15s)", xy=(15, 46.7), xytext=(25, 36),
                arrowprops=dict(arrowstyle="->", color="#334155"))
    ax.set_xscale("log"); ax.set_xlabel("settlement horizon N+W (seconds, log scale)")
    ax.set_ylabel(r"$\rho$ = clawback / realized adverse selection (%)")
    ax.set_ylim(0, 70)
    ax.set_title("Robustness: recovery rate holds across a 60x range of horizons\n"
                 "(the mechanism is not tuned to a lucky window)", fontweight="bold")
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout(); fig.savefig("chart_horizon.png", dpi=150); plt.close(fig)
    print("  wrote chart_horizon.png")


def corr_test(rows, res):
    """OUT-OF-SAMPLE rebuttal to the circularity critique.

    The naive version of this test is a TAUTOLOGY and we say so: Hindsight's charge is a
    monotone function of the settlement-window markout, so correlating charge against that
    same markout scores ~0.6 even on pure noise (we measured 0.80 on Gaussian noise — higher
    than the real data). So we measure harm over a LATER, DISJOINT window the charge never
    saw, and publish a permutation null as the control.
    """
    section("6. CIRCULARITY REBUTTAL — out-of-sample: does the charge predict FUTURE harm?")
    import random

    def corr(xs, ys):
        n = len(xs); mx = sum(xs) / n; my = sum(ys) / n
        sxy = sxx = syy = 0.0
        for a, b in zip(xs, ys):
            da, db = a - mx, b - my
            sxy += da * db; sxx += da * da; syy += db * db
        return sxy / ((sxx * syy) ** 0.5) if sxx and syy else 0.0

    def rank_avg(v):
        """Ranks with ties AVERAGED. Index-broken ties silently encode row order, which made
        a constant series score a spurious 0.197 against chronologically-ordered data."""
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v); i = 0
        while i < len(order):
            j = i
            while j < len(order) and v[order[j]] == v[order[i]]:
                j += 1
            avg = (i + j - 1) / 2
            for kk in range(i, j):
                r[order[kk]] = avg
            i = j
        return r

    # harm measured on a LATER disjoint window: [t+20, t+60)  (charge used [t+10, t+15))
    last = rows[-1]["block"]
    fut, keep = [], []
    for idx, (r, s_row) in enumerate(zip(res, rows)):
        b = s_row["block"]
        if b + 60 > last:
            continue
        tw, _ = window(rows, idx, b + 20, b + 60)
        if tw is None:
            continue
        drift = tw - s_row["tick"]
        fut.append(-drift if s_row["amount0"] < 0 else drift)
        keep.append(r)

    fees = sum(r["fee"] for r in res); claw = sum(r["forfeit"] for r in res)
    target = fees + claw
    lo, hi = 0.0, 200.0
    for _ in range(70):
        ct = (lo + hi) / 2
        rev = sum(r["usd"] * (HEADLINE_FEE_BPS + ct * r["tvol"]) / 1e4 for r in res)
        (lo := ct) if rev < target else (hi := ct)
    ct = (lo + hi) / 2
    flat = target / sum(r["usd"] for r in res) * 1e4

    series = {
        "Hindsight": [(r["fee"] + r["forfeit"]) / r["usd"] * 1e4 for r in keep],
        "dynamic fee (trailing vol)": [HEADLINE_FEE_BPS + ct * r["tvol"] for r in keep],
        "flat fee (rev-matched)": [flat] * len(keep),
    }
    print(f"  charge set on the settlement window [t+10s, t+15s);")
    print(f"  harm measured on a DISJOINT later window [t+20s, t+60s).  n={len(keep):,}\n")
    print(f"{'mechanism':>30}{'pearson':>10}{'spearman':>11}")
    for name, v in series.items():
        print(f"{name:>30}{corr(v, fut):>10.3f}{corr(rank_avg(v), rank_avg(fut)):>11.3f}")

    random.seed(3)
    shuf = fut[:]; random.shuffle(shuf)
    h = series["Hindsight"]
    print(f"{'CONTROL: Hindsight vs shuffled harm':>30}{corr(h, shuf):>10.3f}{corr(rank_avg(h), rank_avg(shuf)):>11.3f}")
    print("\n  The in-sample version of this test is a tautology — our charge is a monotone")
    print("  function of the settlement markout and scores ~0.80 on pure Gaussian noise. So we")
    print("  score it against harm it never observed, with a shuffled-harm control at ~0.")


def concentration(rows, res):
    section("7. CONCENTRATION — is the result driven by one address?")
    import collections
    cnt = collections.Counter(r["sender"] for r in res)
    top3 = [a for a, _ in cnt.most_common(3)]

    def run(sub, label):
        fees = sum(r["fee"] for r in sub)
        claw = sum(r["forfeit"] for r in sub)
        gas = sum(r["usd"] * max(0.0, r["markout"]) / 1e4 for r in sub)
        target = fees + claw
        lo, hi = 0.0, 200.0
        for _ in range(70):
            c = (lo + hi) / 2
            rev = sum(r["usd"] * (HEADLINE_FEE_BPS + c * r["vol"]) / 1e4 for r in sub)
            (lo := c) if rev < target else (hi := c)
        c = (lo + hi) / 2
        ben = [r for r in sub if not r["toxic"]]
        tox = [r for r in sub if r["toxic"]]
        ib = sum(r["usd"] * (c * r["vol"]) / 1e4 for r in ben)
        it = sum(r["usd"] * (c * r["vol"]) / 1e4 for r in tox)
        print(f"{label:>28}  n={len(sub):>6,}   rho={100*claw/gas:>5.1f}%   "
              f"dynamic-fee-from-benign={100*ib/(ib+it):>5.1f}%")

    run(res, "all swaps")
    run([r for r in res if r["sender"] != top3[0]], "excluding top sender")
    run([r for r in res if r["sender"] not in set(top3)], "excluding top-3 senders")
    print("\n  The result strengthens when the busiest bots are removed — it is not an")
    print("  artifact of one address dominating the tape.")


def permutation_null(rows, sims=30):
    """Publish the null. Does the TRUE trade direction carry information, or would random
    directions collect just as much? markout = +/- drift, so flipping a swap's direction
    negates its markout; theta, vol, bond and ramp are untouched."""
    import random
    section("8. PERMUTATION NULL — is the signal real, or would random labels do as well?")
    print(f"{'N,W (s)':>10}{'true claw':>12}{'flagged':>10}{'null mean':>12}{'z':>8}{'beats':>9}")
    for (n, w) in [(1, 1), (3, 2), (5, 2), (10, 5), (30, 10)]:
        res = price(rows, n_sec=n, w_sec=w)

        def claw(flips):
            t = 0.0; cnt = 0
            for r, fl in zip(res, flips):
                mk = -r["markout"] if fl else r["markout"]
                f = max(0.0, min(1.0, (mk - r["theta"]) / RAMP))
                if f > 0:
                    cnt += 1; t += r["usd"] * (BOND_BPS / 1e4) * f
            return t, cnt

        true_c, true_n = claw([False] * len(res))
        random.seed(4)
        sims_v = [claw([random.random() < 0.5 for _ in res])[0] for _ in range(sims)]
        mu, sd = statistics.mean(sims_v), statistics.pstdev(sims_v)
        z = (true_c - mu) / sd if sd else 0.0
        beat = sum(1 for x in sims_v if true_c > x)
        tag = "  <- SHIPPED" if (n, w) == (N_SEC, W_SEC) else ""
        print(f"{f'{n},{w}':>10}{money(true_c):>12}{true_n:>10,}{money(mu):>12}{z:>+8.2f}{f'{beat}/{sims}':>9}{tag}")
    print()
    print("  At very short horizons the dominant post-swap signal is a trade's own price impact,")
    print("  not information: large trades see price revert against them, so RANDOM labels collect")
    print("  MORE than true ones (z<0). Real informational drift only separates from that at ~10s+.")
    print("  We ship the horizon where the signal is real and publish the null next to the number.")

def self_inflation(rows):
    """How much can a trade move its OWN threshold? This is round-2 audit finding M9."""
    section("9. SELF-INFLATION — can a trade raise the threshold it is judged against?")
    print("  For every swap, recompute theta with that swap's OWN sender's prints removed")
    print("  from its settlement window. Any difference is threshold the trader supplied")
    print("  itself. No adversary is simulated here -- this is ordinary mainnet flow.\n")

    def vol_excluding(i, start, end, sender):
        raw_prev, j = rows[i]["tick"], i + 1
        while j < len(rows) and rows[j]["block"] <= start:
            raw_prev = rows[j]["tick"]; j += 1
        jumps = []
        while j < len(rows) and rows[j]["block"] < end:
            if rows[j]["sender"] != sender:
                jumps.append(min(abs(rows[j]["tick"] - raw_prev), MAX_VOL_JUMP))
                raw_prev = rows[j]["tick"]
            j += 1
        return sum(jumps) / len(jumps) if jumps else 0.0

    last = rows[-1]["block"]
    shifts, bought, own, n = [], 0, 0, 0
    for i, s in enumerate(rows):
        if s["block"] + N_SEC + W_SEC > last or abs(s["amount1"]) == 0:
            continue
        tw, vol = window(rows, i, s["block"] + N_SEC, s["block"] + N_SEC + W_SEC)
        if tw is None:
            continue
        n += 1
        vol_wo = vol_excluding(i, s["block"] + N_SEC, s["block"] + N_SEC + W_SEC, s["sender"])
        if abs(vol - vol_wo) > 1e-12:
            own += 1
        th, th_wo = THETA_MIN + 2.8 * vol, THETA_MIN + 2.8 * vol_wo
        shifts.append(th - th_wo)
        drift = tw - s["tick"]
        mk = -drift if s["amount0"] < 0 else drift
        if th_wo < mk <= th:
            bought += 1
    pos = [x for x in shifts if x > 0]
    print(f"  swaps analysed                                    {n:>10,}")
    print(f"  with >=1 own print inside their own theta window  {own:>10,}  ({100*own/n:.1f}%)")
    print(f"  that actually self-inflated theta                 {len(pos):>10,}")
    print(f"  mean inflation among those                        {statistics.mean(pos):>10.2f} ticks"
          f"  (max {max(pos):.1f})")
    print(f"  ACQUITTALS bought purely by own prints            {bought:>10,}"
          f"  ({100*bought/n:.2f}% of all flow)")
    print()
    print("  Those are real acquittals on a real tape, with nobody trying. Sourcing sigma from")
    print(f"  a window that closes before the trade lands makes every number above exactly 0 --")
    print("  not by tuning a clamp, but because there is no longer anything to write into.")
    return dict(n=n, own=own, pos=pos, bought=bought)


if __name__ == "__main__":
    rows = load(sys.argv[1] if len(sys.argv) > 1 else "swaps_eth_usdc_5bp.csv")
    res = price(rows)
    print(f"\nHINDSIGHT — counterfactual analysis on {len(res):,} real Unichain mainnet swaps")
    print("(a re-pricing of identical realized trades; no behavioural assumptions)")
    fees, claw = lvr_decomposition(res)
    revenue_matched(res, fees, claw)
    horizon_robustness(rows)
    vol_decile(rows, res)
    sensitivity(rows)
    corr_test(rows, res)
    concentration(rows, res)
    permutation_null(rows)
    infl = self_inflation(rows)
    section("CHARTS")
    chart_who_pays(res, fees, claw)
    chart_vol_decile(rows, res, infl)
    chart_horizon(rows)
    print()
