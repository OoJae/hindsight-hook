"use client";
import { useEffect } from "react";
import { usePathname } from "next/navigation";

/** One-shot reveals. Nothing else.
 *
 *  There is deliberately no smooth-scroll library here. Lenis was hijacking the
 *  scroll and fighting `scroll-behavior: smooth` in the stylesheet at the same
 *  time, which made the page feel laggy and detached from the wheel. Native
 *  scrolling is what people expect, and it is what this now uses.
 */
export default function Motion() {
  const pathname = usePathname();

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
