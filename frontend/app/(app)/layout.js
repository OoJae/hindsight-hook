"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import Glyph from "../(site)/_components/Glyph";
import "./app.css";

// The product chrome. This used to inject a whole second design system through
// <style dangerouslySetInnerHTML> — a different ground, a link blue, a button
// blue, a system sans stack and 12px radii — and, because it was injected after
// globals.css, it also shadowed the brand's own body rule on these four routes.
// It is now a real stylesheet (./app.css) that speaks in the tokens.
//
// The bar itself is a sibling of the marketing header rather than a stranger to
// it: the real Glyph (imported, not a hand-inlined duplicate), the real .lockup,
// the same mono/uppercase nav at 0.08em, the same a.u underline. It does not
// clone .siteheader's fixed position and scrim — that treatment exists to float
// over a 100svh hero, and over a dense control column it would sit on top of
// the inputs. See app.css for the rest of the reasoning.
//
// "use client" is here for usePathname, which marks the current route in the
// bar — the one --signal item the header is allowed, spent on where you are
// rather than on a CTA into a place you already stand. It is export-safe: the
// pathname is known at prerender time and identical on hydration. The four page
// components were already client components; nothing about their data flow moves.

const ROUTES = [
  ["/swap", "Swap"],
  ["/lp", "LP dashboard"],
  ["/toxicity", "Toxicity"],
  ["/explorer", "Explorer"],
];

// next.config sets trailingSlash: true, so the live pathname is "/swap/" while
// the href is "/swap". Compare them stripped, or nothing ever reads as current.
const route = (p) => (p.length > 1 ? p.replace(/\/+$/, "") : p);

export default function AppLayout({ children }) {
  const here = route(usePathname() ?? "");

  return (
    <>
      <header className="appheader">
        <Link href="/" className="lockup" aria-label="Hindsight — home">
          <Glyph size={20} />
          <span>Hindsight</span>
        </Link>

        <nav aria-label="Product">
          {ROUTES.map(([href, label]) => (
            <Link
              key={href}
              className="u"
              href={href}
              aria-current={here === href ? "page" : undefined}
            >
              {label}
            </Link>
          ))}
        </nav>

        {/* Same job as the site footer's mono strip, and now the same voice. */}
        <span className="mono appstatus">
          fees decided after the trade · Unichain Sepolia
        </span>
      </header>

      {/* The root layout renders <a href="#main" className="skip">, and until
          now these four routes gave it nowhere to land. */}
      <main id="main" className="appmain">
        {children}
      </main>
    </>
  );
}
