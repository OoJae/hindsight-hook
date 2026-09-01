# Hindsight — brand system

Everything here is derived from the mechanism's own instruments: flashblocks, the settlement
window, markout, θ, ticks, the verdict. Nothing is borrowed from generic fintech or crypto
visual language.

## The mark

`frontend/public/brand/glyph.svg` — a **caliper held over a segment of tape**. A trade lands
(the dot), the price rises through the window, and it is still higher when it leaves the far
edge. That exit is the thing being priced.

Tested at 96/40/24/16px against two alternatives before being chosen: a box-enclosed variant
became a generic chart-in-a-box at small sizes, and a two-tick variant merged the bracket and
the price into one shape. This is the only version where both elements stay distinguishable
at favicon size.

Use `currentColor`. On dark, the mark is `--signal`; the price line may drop to `--ink` at
60% when it needs to recede.

`frontend/public/brand/wordmark.svg` — HINDSIGHT in Archivo 700 at 125% width, with a hairline
beneath that **breaks under "SIGHT"**: the window opening over the part of the word that does
the looking.

## Colour

| Token | Value | Role |
|---|---|---|
| `--ground` | `#0B0D0E` | Cool near-black. The pool is not a void. |
| `--ground-lift` | `#121517` | One step up, for surfaces that must separate. |
| `--ink` | `#EDEAE4` | Warm paper, not screen-white — this is a *record*. |
| `--muted` | `#82888B` | Axes, labels, the parts of a chart that aren't signal. |
| `--hairline` | `#22262A` | Rules and borders: the grid of the ledger. |
| `--signal` | `#CCFF00` | The accent. Live markout, the counter, θ. Reads as instrumentation — a plotter trace — not as a brand colour. |
| `--claw` | `#FF5A36` | **Three uses on the entire site.** |

`--muted` was `#6E7477` until the app routes were brought onto this system. That value
measures **4.11:1** on `--ground` and 3.87:1 on `--ground-lift`, so it failed AA for body
text — and `.act-body`, the landing page's own prose, is set in it. `#82888B` is the same
hue at **5.42:1 / 5.10:1**. One token rather than an app-scoped override, so the marketing
pages and the product stay the same grey instead of drifting apart.

### The three-uses rule

`--claw` marks confiscation and nothing else — **and only where confiscation has actually
happened.** Never a projection of one, and never a per-row state. It is currently spent
twice: a settled forfeit verdict (`/swap`), and a retracted claim (`/evidence`).

The rule survived contact with the app, but only after breaking. Four agents restyling the
four product routes in parallel each concluded, correctly in isolation, that their own page
deserved the forfeit slot — three separate files ended up carrying a comment claiming to
spend "slot 2 and nowhere else", and one of them painted the word *toxic* on up to forty
rows of a settlements table. Forty orange cells is the definition of a palette. The lesson
is that a scarcity rule cannot be enforced locally: it is a property of the whole site, so
it has to be checked against the whole site.

The clawback figure was going to be the third use, until it turned out `evidence.css`
already paints that exact number — ρ, "53.8% of realized adverse selection recovered" — in
`--signal`. A recapture is the mechanism succeeding, which is what `--signal` means here, so
the app matches the page it is meant to match and the third slot stays unspent.

Do not reach for `--claw` for warnings, errors, or emphasis. Failure is encoded by
*promotion* — `--muted` to `--ink` — because on a near-black ground that is the loudest move
the palette has: `--ink` is 16.2:1 where `--claw` is only 6.3:1.

## Type

- **Archivo** variable (`--display`) — Expanded ~125% width, 700, tracking `-0.035em`,
  uppercase. Industrial grotesque: it goes enormous while reading engineered rather than
  fashionable.
- **Newsreader** (`--body`) — 400, line-height 1.65. Editorial serif; gives the ledger
  register. Deliberately not Inter, which would be a default rather than a choice.
- **IBM Plex Mono** (`--mono`) — 500, `+0.1em`, uppercase for labels. Ticks, stamps, bps, θ,
  addresses. Anything the machine measured is set in mono.

All three are self-hosted by `next/font` — no CDN at runtime, and no basePath hazard.

## Layout

**A ledger that scrolls.** Every band is a row: a mono gutter on the left carrying the
flashblock stamp, content to its right. The stamp column collapses below 780px, where the
stamp moves inline above the content.

Use `.band` + `.stamp` + `.bandbody`. Reading measure is 62–68ch.

## Motion

- Easing: `--ease-out` `cubic-bezier(0.16, 1, 0.3, 1)` for reveals and entrances;
  `--ease-io` for state toggles.
- Reveals fire **once**, near the viewport, via one IntersectionObserver in
  `(site)/_components/Motion.js`. Add `data-reveal` to a section; children carry `.rv`
  (masked line rise) or `.fade`, staggered with `--rv-delay`.
- Smooth scroll is Lenis at lerp 0.1. There is no GSAP: the JS budget belongs to WebGL, and
  scattered scroll triggers are the failure mode this system is built to avoid.
- Animate transform and opacity only.
- `prefers-reduced-motion` resolves everything instantly, including the hero's withheld
  verdict.

## Motion, and what is deliberately absent

There is **no smooth-scroll library**. One was tried and removed: it hijacked the wheel and
simultaneously fought `scroll-behavior: smooth` in the stylesheet, which made the page feel
laggy and detached. Native scrolling is what the wheel should feel like.

There is also **no 3D**. A scroll-driven WebGL ribbon built from the real tape was built,
shipped, and cut: it needed explaining, which means it failed. The lesson is worth keeping —
an idea that is intellectually good ("the object IS the dataset") is not automatically
legible, and four rounds of fighting a visual to make it read is the signal to drop it rather
than iterate again.

What carries the page instead is the type, the ledger structure, and the one moment that did
communicate without explanation: the hero's **withheld verdict** — a real 200ms flashblock
counter, and a fee that is genuinely not shown until the window closes.
