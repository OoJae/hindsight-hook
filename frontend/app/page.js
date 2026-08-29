"use client";
import { useCallback, useEffect, useState } from "react";
import { encodeAbiParameters, formatUnits, parseUnits } from "viem";
import { pub, getWallet } from "../lib/clients";
import {
  HOOK, POOL_ID, POOL_KEY, SWAP_ROUTER, TOKEN0, TOKEN1,
  MATURITY, WINDOW, MIN_SQRT_PRICE_PLUS_1, MAX_SQRT_PRICE_MINUS_1,
  hookAbi, swapRouterAbi, erc20Abi,
} from "../lib/config";

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
      <h1>Swap — the fee is decided <em>after</em> your trade</h1>
      <p className="muted">
        Your swap escrows a refundable bond. {MATURITY + WINDOW} flashblocks (~{(MATURITY + WINDOW) / 5}s) later,
        anyone can settle it: benign markout → full refund; toxic markout → forfeit streams to LPs.
      </p>

      <div className="card">
        <div className="row">
          {account
            ? <code>{account.slice(0, 6)}…{account.slice(-4)}</code>
            : <button onClick={connect}>Connect wallet</button>}
          <button className="ghost" onClick={faucet} disabled={busy}>Mint demo tokens</button>
          <span className="muted">flashblock <b>{stamp.toString()}</b></span>
        </div>
      </div>

      <div className="card">
        <div className="row">
          <select value={zeroForOne ? "0to1" : "1to0"} onChange={(e) => setZeroForOne(e.target.value === "0to1")}>
            <option value="0to1">dETH → dUSDC</option>
            <option value="1to0">dUSDC → dETH</option>
          </select>
          <input value={amount} onChange={(e) => setAmount(e.target.value)} style={{ width: 140 }} />
          <button onClick={doSwap} disabled={busy || !account}>Swap</button>
        </div>
        <p className="muted" style={{ marginBottom: 0 }}>
          headline fee: <b>5 bps</b> · refundable bond ≈{" "}
          <b>{bondQuote !== null ? `${formatUnits(bondQuote, 18)} (25 bps × your reputation)` : "…"}</b>
        </p>
        {log && <p className="warn">{log}</p>}
      </div>

      <h2>Your swaps</h2>
      {pending.length === 0 && <p className="muted">none yet {account ? "" : "(connect to filter to yours)"}</p>}
      {pending.map(({ id, r, preview }) => {
        const windowEnd = BigInt(r.execStamp) + BigInt(MATURITY + WINDOW);
        const left = windowEnd > stamp ? windowEnd - stamp : 0n;
        const total = BigInt(MATURITY + WINDOW);
        const pct = Number(((total - (left > total ? total : left)) * 100n) / total);
        return (
          <div className="card" key={id.toString()}>
            <div className="row" style={{ justifyContent: "space-between" }}>
              <span>#{id.toString()} · {r.zeroForOne ? "dETH→dUSDC" : "dUSDC→dETH"} · bond <b>{formatUnits(r.bond, 18)}</b></span>
              {r.status === 0 && left > 0n && <span className="warn">window open — {left.toString()} flashblocks left</span>}
              {r.status === 0 && left === 0n && (
                <button onClick={() => doSettle(id)} disabled={busy}>
                  Settle {preview && (preview[4] > 0n
                    ? <span className="bad"> (forfeit {(Number(preview[4]) / 1e16).toFixed(0)}%)</span>
                    : <span className="ok"> (full refund)</span>)}
                </button>
              )}
              {r.status === 1 && <span className="ok">✓ refunded in full</span>}
              {r.status === 2 && <span className="bad">✗ forfeited to LPs</span>}
            </div>
            {r.status === 0 && (
              <>
                <div className="bar" style={{ marginTop: 10 }}><div style={{ width: `${pct}%` }} /></div>
                {preview && (
                  <p className="muted" style={{ marginBottom: 0 }}>
                    provisional markout {preview[2].toString()} ticks vs θ {preview[3].toString()} —{" "}
                    {preview[4] > 0n ? "currently reads TOXIC" : "currently reads benign"}
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
