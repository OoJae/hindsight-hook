"use client";
import { useEffect } from "react";
import { usePathname } from "next/navigation";
import Lenis from "lenis";
import { scrollProgress } from "./scroll";

/** Smooth scroll + one-shot reveals, for every page under (site).
 *
 *  Deliberately not GSAP/ScrollTrigger: the JS budget is spent on WebGL, and a
 *  dozen scattered triggers is exactly the "scattered animation" failure mode.
 *  One scroller, one observer, one class.
 */
export default function Motion() {
  const pathname = usePathname();

  // Lenis is set up once and lives for the session.
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      scrollProgress.current = 1;
      return;
    }
    const lenis = new Lenis({ lerp: 0.1 });
    let raf;
    const loop = (t) => {
      lenis.raf(t);
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    const emit = ({ scroll, limit }) => {
      scrollProgress.current = limit > 0 ? scroll / limit : 0;
    };
    lenis.on("scroll", emit);
    return () => {
      cancelAnimationFrame(raf);
      lenis.off("scroll", emit);
      lenis.destroy();
    };
  }, []);

  // Reveals are re-scanned per route: the observer set up on one page cannot
  // see the next page's nodes after a client-side navigation.
  useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const targets = document.querySelectorAll("[data-reveal]:not([data-shown])");
    if (reduced) {
      targets.forEach((el) => el.setAttribute("data-shown", ""));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            e.target.setAttribute("data-shown", "");
            io.unobserve(e.target);
          }
        }
      },
      { rootMargin: "0px 0px -12% 0px" }
    );
    targets.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, [pathname]);

  return null;
}
