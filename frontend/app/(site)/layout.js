import Link from "next/link";
import Glyph from "./_components/Glyph";
import Motion from "./_components/Motion";

export default function SiteLayout({ children }) {
  return (
    <>
      <Motion />
      <header className="siteheader">
        <Link href="/" className="lockup" aria-label="Hindsight — home">
          <Glyph size={20} />
          <span>Hindsight</span>
        </Link>
        <nav aria-label="Primary">
          <Link className="u" href="/mechanism">Mechanism</Link>
          <Link className="u" href="/evidence">Evidence</Link>
          <Link className="u" href="/explorer">Explorer</Link>
          <Link className="u cta" href="/swap">Open the app</Link>
        </nav>
      </header>
      <main id="main">{children}</main>
      <footer className="sitefooter">
        <div className="mono">Unichain Sepolia · Base Sepolia · Reactive Lasna</div>
        <div className="mono">
          <a className="u" href="https://github.com/OoJae/hindsight-hook">Source</a>
        </div>
      </footer>
    </>
  );
}
