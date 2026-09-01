"use client";
import { useCallback, useEffect, useState } from "react";
import { encodeAbiParameters, formatUnits, parseUnits } from "viem";
import { pub, getWallet } from "../../../lib/clients";
import {
  HOOK, POOL_ID, POOL_KEY, SWAP_ROUTER, TOKEN0, TOKEN1,
  MATURITY, WINDOW, MIN_SQRT_PRICE_PLUS_1, MAX_SQRT_PRICE_MINUS_1,
  hookAbi, swapRouterAbi, erc20Abi,
} from "../../../lib/config";

/* ---- presentation only ---------------------------------------------------
   formatUnits(x, 18) hands the page a nineteen-character fraction
   ("0.0024999999999999998"). Tabular figures align digits; they do not shorten
   them, and the brand's numbers are short and set. These two shorten a value
   for DISPLAY and nothing else — no BigInt below is touched and neither of them
   goes anywhere near parseUnits.
   ------------------------------------------------------------------------ */

// Six decimals, or enough to keep two significant figures of a small fraction,
// with trailing zeros trimmed.
const amt = (wei) => {
  const [whole, frac = ""] = formatUnits(wei, 18).split(".");
  if (!frac) return whole;
  const lead = frac.search(/[1-9]/);
  const cut = frac.slice(0, Math.max(6, lead < 0 ? 0 : lead + 2)).replace(/0+$/, "");
  return cut ? `${whole}.${cut}` : whole;
};

// A WAD percentage, keeping at least one significant figure. .toFixed(0) printed
// a 0.4% forfeit as "0%" — i.e. as no forfeit at all, beside the word forfeit.
const pctOf = (wad) => {
  const v = Number(wad) / 1e16;
  return v >= 10 ? v.toFixed(0) : v >= 1 ? v.toFixed(1) : v.toFixed(2);
};

export default function SwapPage() {
  const [account, setAccount] = useState(null);
  const [amount, setAmount] = useState("1");
  const [zeroForOne, setZeroForOne] = useState(true);
  const [bondQuote, setBondQuote] = useState(null);
  const [pending, setPending] = useState([]);
  const [stamp, setStamp] = useState(0n);
  const [busy, setBusy] = useState(false);
  const [log, setLog] = useState("");

  const connect = async () => {
    const { account } = await getWallet();
    setAccount(account);
  };

  // live flashblock clock + pending swaps
  const refresh = useCallback(async () => {
    if (!HOOK) return;
    try {
      const [now, n] = await Promise.all([
        pub.readContract({ address: HOOK, abi: hookAbi, functionName: "currentStamp" }),
        pub.readContract({ address: HOOK, abi: hookAbi, functionName: "nextSwapId" }),
      ]);
      setStamp(BigInt(now));
      const items = [];
      const from = n > 25n ? n - 25n : 0n;
      for (let id = from; id < n; id++) {
        const r = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: "getSwap", args: [id] });
        if (account && r.trader.toLowerCase() !== account.toLowerCase()) continue;
        let preview = null;
        if (r.status === 0) {
          preview = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: "previewSettle", args: [id] }).catch(() => null);
        }
        items.push({ id, r, preview });
      }
      setPending(items.reverse());
    } catch (e) { console.error(e); }
  }, [account]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 1500);
    return () => clearInterval(t);
  }, [refresh]);

  // bond preview
  useEffect(() => {
    (async () => {
      if (!HOOK || !amount || Number(amount) <= 0) return setBondQuote(null);
      try {
        const q = await pub.readContract({
          address: HOOK, abi: hookAbi, functionName: "previewBond",
          args: [POOL_ID, account ?? "0x0000000000000000000000000000000000000001", parseUnits(amount, 18)],
        });
        setBondQuote(q);
      } catch { setBondQuote(null); }
    })();
  }, [amount, account]);

  const doSwap = async () => {
    setBusy(true);
    setLog("");
    try {
      const { wallet, account } = await getWallet();
      const value = parseUnits(amount, 18);
      const tokenIn = zeroForOne ? TOKEN0 : TOKEN1;
      await wallet.writeContract({
        address: tokenIn, abi: erc20Abi, functionName: "approve",
        args: [SWAP_ROUTER, value * 2n], account,
      });
      const hash = await wallet.writeContract({
        address: SWAP_ROUTER, abi: swapRouterAbi, functionName: "swap",
        args: [
          POOL_KEY,
          { zeroForOne, amountSpecified: -value, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1 },
          { takeClaims: false, settleUsingBurn: false },
          encodeAbiParameters([{ type: "address" }], [account]),
        ],
        account,
      });
      setLog(`swap sent: ${hash.slice(0, 14)}… — bond escrowed; countdown below`);
      await pub.waitForTransactionReceipt({ hash });
      refresh();
    } catch (e) { setLog(`error: ${e.shortMessage ?? e.message}`); }
    setBusy(false);
  };

  const doSettle = async (id) => {
    setBusy(true);
    try {
      const { wallet, account } = await getWallet();
      const hash = await wallet.writeContract({ address: HOOK, abi: hookAbi, functionName: "settle", args: [id], account });
      await pub.waitForTransactionReceipt({ hash });
      refresh();
    } catch (e) { setLog(`settle error: ${e.shortMessage ?? e.message}`); }
    setBusy(false);
  };

  const faucet = async () => {
    setBusy(true);
    try {
      const { wallet, account } = await getWallet();
      for (const t of [TOKEN0, TOKEN1]) {
        await wallet.writeContract({ address: t, abi: erc20Abi, functionName: "mint", args: [account, parseUnits("1000", 18)], account });
      }
      setLog("minted 1000 of each demo token");
    } catch (e) { setLog(`faucet error: ${e.shortMessage ?? e.message}`); }
    setBusy(false);
  };

  if (!HOOK) return <div className="card">Set NEXT_PUBLIC_* env vars (see .env.local.example), then restart.</div>;

  return (
    <>
      {/* Stamp then claim, the grammar every (site) band uses. Same words. */}
      <div className="label">Swap</div>
      <h1>The fee is decided <em>after</em> your trade</h1>
      <p className="muted">
        Your swap escrows a refundable bond. <span className="num">{MATURITY + WINDOW}</span> flashblocks (~
        <span className="num">{(MATURITY + WINDOW) / 5}</span>s) later, anyone can settle it: benign markout →
        full refund; toxic markout → forfeit streams to LPs.
      </p>

      <div className="card">
        <div className="row">
          {account
            ? <code className="num">{account.slice(0, 6)}…{account.slice(-4)}</code>
            : <button onClick={connect}>Connect wallet</button>}
          <button className="ghost" onClick={faucet} disabled={busy}>Mint demo tokens</button>
          {/* The counter globals reserves --signal for, finally set as one: a mono
              stamp label over a tabular figure. aria-live="off" matches the
              landing clock — it ticks every 1.5s and must not be announced. */}
          <span className="label" style={{ marginInlineStart: "auto" }}>
            flashblock{" "}
            <span className="num sig clock" aria-live="off">
              {stamp > 0n ? stamp.toString() : "—"}
            </span>
          </span>
        </div>
      </div>

      <div className="card">
        <div className="row">
          <select aria-label="Swap direction" value={zeroForOne ? "0to1" : "1to0"} onChange={(e) => setZeroForOne(e.target.value === "0to1")}>
            <option value="0to1">dETH → dUSDC</option>
            <option value="1to0">dUSDC → dETH</option>
          </select>
          {/* size= is a ch measure the 640px rule can still override; an inline
              width could not. The string handed to parseUnits is untouched. */}
          <input
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            inputMode="decimal"
            aria-label="Amount"
            size={9}
          />
          <button onClick={doSwap} disabled={busy || !account}>Swap</button>
        </div>
        <p className="muted">
          headline fee: <b className="num">5 bps</b> <span className="dim">·</span> refundable bond ≈{" "}
          <b className="num">
            {bondQuote !== null
              ? `${amt(bondQuote)} ${zeroForOne ? "dUSDC" : "dETH"}`
              : "—"}
          </b>{" "}
          <span className="dim">(25 bps of your output × your reputation)</span>
        </p>
        {/* Always mounted. A live region that enters the DOM in the same commit
            as its first text is usually not announced, which would have silently
            dropped the first result of every swap, settle and faucet call. */}
        <p
          className={log ? (log.includes("error") ? "warn is-err" : "warn") : "warn is-empty"}
          aria-live="polite"
        >
          {log}
        </p>
      </div>

      <h2>Your swaps</h2>
      {pending.length === 0 && (
        <p className="muted mono keep-case">none yet {account ? "" : "(connect to filter to yours)"}</p>
      )}
      {pending.map(({ id, r, preview }) => {
        const windowEnd = BigInt(r.execStamp) + BigInt(MATURITY + WINDOW);
        const left = windowEnd > stamp ? windowEnd - stamp : 0n;
        const total = BigInt(MATURITY + WINDOW);
        const pct = Number(((total - (left > total ? total : left)) * 100n) / total);
        return (
          <div className="card" key={id.toString()}>
            <div className="row" style={{ justifyContent: "space-between" }}>
              {/* The ledger stamp: keep-case so dETH does not come back DETH. */}
              <span className="label keep-case">
                <span className="num">#{id.toString()}</span> <span className="dim">·</span>{" "}
                {r.zeroForOne ? "dETH→dUSDC" : "dUSDC→dETH"} <span className="dim">·</span> bond{" "}
                <b className="num">{amt(r.bond)} {r.bondIsCurrency0 ? "dETH" : "dUSDC"}</b>
              </span>
              {/* The window is withheld, not a warning, so the phrase stays --muted
                  — but the count is the clock, and the landing hero sets its clock
                  in --signal while the verdict beneath it waits. */}
              {r.status === 0 && left > 0n && (
                <span className="warn mono keep-case">
                  window open — <span className="num sig">{left.toString()}</span> flashblocks left
                </span>
              )}
              {r.status === 0 && left === 0n && (
                <button onClick={() => doSettle(id)} disabled={busy}>
                  Settle {preview && (preview[4] > 0n
                    ? <span className="bad"> (forfeit {pctOf(preview[4])}%)</span>
                    : <span className="ok"> (full refund)</span>)}
                </button>
              )}
              {/* Mono stamps, not dingbats: ✓/✗ are not in a glyph vocabulary whose
                  only marks are the hook and →. The verdict is the word, in the
                  verdict's colour — and no claw. This renders once per swap in a
                  list, so it is a row state, which is the one thing the colour is
                  never allowed to be. Signal against --ink carries the verdict
                  perfectly well, exactly as it does in /lp's table. */}
              {r.status === 1 && <span className="label ok">refunded in full</span>}
              {r.status === 2 && <span className="label bad">forfeited to LPs</span>}
            </div>
            {r.status === 0 && (
              <>
                {/* scaleX, not width: the house rule is transform/opacity only, and
                    app.css already has the transition waiting on this element. */}
                <div className="bar" aria-hidden="true">
                  <div style={{ transform: `scaleX(${pct / 100})` }} />
                </div>
                {preview && (
                  <p className="muted">
                    provisional markout <span className="num">{preview[2].toString()}</span> ticks vs{" "}
                    <span className="num keep-case">θ {preview[3].toString()}</span> —{" "}
                    {preview[4] > 0n
                      ? <span className="label bad">currently reads toxic</span>
                      : <span className="label ok">currently reads benign</span>}
                  </p>
                )}
              </>
            )}
          </div>
        );
      })}
    </>
  );
}
