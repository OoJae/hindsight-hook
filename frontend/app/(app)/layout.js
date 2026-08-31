import Link from "next/link";

// The product chrome. Lifted verbatim from the old root layout so the four
// tool pages are untouched by the marketing work; only the nav targets moved
// (`/` is now the landing page, the swap tool lives at `/swap`).
const css = `
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; background: #0b0e14; color: #e6e9ef; font: 15px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif; }
  a { color: #7aa2ff; text-decoration: none; }
  nav { display: flex; gap: 20px; padding: 18px 28px; border-bottom: 1px solid #1d2330; align-items: baseline; }
  nav .brand { font-weight: 700; font-size: 18px; color: #fff; margin-right: 12px; }
  main { max-width: 860px; margin: 0 auto; padding: 32px 20px 80px; }
  .card { background: #121826; border: 1px solid #1d2330; border-radius: 12px; padding: 20px; margin: 16px 0; }
  .row { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
  input, select { background: #0b0e14; color: #e6e9ef; border: 1px solid #2a3245; border-radius: 8px; padding: 10px 12px; font-size: 15px; }
  button { background: #3b62f6; color: #fff; border: 0; border-radius: 8px; padding: 10px 18px; font-size: 15px; cursor: pointer; }
  button:disabled { opacity: 0.45; cursor: default; }
  button.ghost { background: #1d2330; }
  .muted { color: #8b93a7; font-size: 13px; }
  .big { font-size: 26px; font-weight: 700; }
  .ok { color: #4ade80; } .bad { color: #f87171; } .warn { color: #facc15; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #1d2330; }
  .bar { height: 8px; background: #1d2330; border-radius: 4px; overflow: hidden; }
  .bar > div { height: 100%; background: #3b62f6; transition: width .4s; }
  code { background: #1d2330; padding: 2px 6px; border-radius: 5px; font-size: 13px; }
`;

export default function AppLayout({ children }) {
  return (
    <>
      <style dangerouslySetInnerHTML={{ __html: css }} />
      <nav>
        <Link href="/" className="brand">
          <svg width="17" height="17" viewBox="0 0 32 32" fill="none" aria-hidden="true">
            <path d="M12 6 H27" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" opacity=".6"/>
            <path d="M12 6 V10" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" opacity=".6"/>
            <path d="M27 6 V10" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" opacity=".6"/>
            <path d="M2 25 H12 L21 14 H30" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"/>
            <circle cx="12" cy="25" r="2.8" fill="currentColor"/>
          </svg>
          Hindsight
        </Link>
        <Link href="/swap">Swap</Link>
        <Link href="/lp">LP dashboard</Link>
        <Link href="/toxicity">Toxicity</Link>
        <Link href="/explorer">Explorer</Link>
        <span className="muted" style={{ marginLeft: "auto" }}>
          fees decided after the trade · Unichain Sepolia
        </span>
      </nav>
      <main>{children}</main>
    </>
  );
}
