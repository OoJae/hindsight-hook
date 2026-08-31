import { Archivo, Newsreader, IBM_Plex_Mono } from "next/font/google";
import "./globals.css";

// An instrument that files a report: an industrial grotesque that can go
// enormous without reading as fashion, an editorial serif for the record
// itself, and a mono for everything the machine measured.
// next/font self-hosts all three into _next/static/media — no CDN at runtime,
// and no basePath hazard.
const archivo = Archivo({
  subsets: ["latin"],
  axes: ["wdth"],            // variable: weight is implicit, width is the point
  variable: "--font-archivo",
  display: "swap",
});
const newsreader = Newsreader({
  subsets: ["latin"],
  weight: ["300", "400"],
  style: ["normal", "italic"],
  variable: "--font-newsreader",
  display: "swap",
});
const plexMono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-plex-mono",
  display: "swap",
});

export const metadata = {
  metadataBase: new URL("https://oojae.github.io/hindsight-hook/"),
  title: {
    default: "Hindsight — the fee is decided after your trade",
    template: "%s — Hindsight",
  },
  description:
    "A Uniswap v4 hook that prices flow from what the price actually did. Benign swaps pay the headline fee. Informed flow pays for the harm it caused.",
  openGraph: {
    title: "Hindsight — the fee is decided after your trade",
    description:
      "Every MEV defense guesses toxicity before the trade. Hindsight measures it after, at 200ms resolution.",
    type: "website",
  },
  twitter: { card: "summary_large_image" },
};

export const viewport = {
  themeColor: "#0B0D0E",
  colorScheme: "dark",
};

export default function RootLayout({ children }) {
  return (
    <html
      lang="en"
      className={`${archivo.variable} ${newsreader.variable} ${plexMono.variable}`}
    >
      <body>
        <a href="#main" className="skip">
          Skip to content
        </a>
        {children}
      </body>
    </html>
  );
}
