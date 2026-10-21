// term-theme.ts — the browser terminal's colours (BBVR). xterm's own palette is
// drawn for a black screen: on the console's paper its yellow, white and cyan
// were all but invisible. Every scheme's 16 ANSI colours are ≥ 4.5:1 (WCAG AA)
// on its own background except the ones that ARE a background tone (`twins`:
// dark's black, Solarized's base tones) — a program writing text in one of
// those, or a truecolor too close to the page (Claude Code, the fleet's Tokyo
// Night rows), is lifted by the terminal's minimumContrastRatio.
//
// A person picks a scheme and a font size on the terminal's toolbar; like the
// page's own 深色 / 浅色 (theme.ts, claude-fleet#3931) the pick stays on this
// device (localStorage), never sent anywhere. "follow" = the page's theme.
export const MIN_CONTRAST = 4.5;

const NAMES = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
  "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"] as const;

export type Scheme = { id: string; zh: string; en: string; bg: string; fg: string; ansi: readonly string[]; twins: readonly number[] };

// light / dark are the page's own backgrounds (extras/fleet-theme/theme.css);
// light's white / brightWhite are greys a reader can still read on paper (as
// GitHub Light's), not paper itself
export const SCHEMES: readonly Scheme[] = [
  { id: "light", zh: "浅色", en: "Light", bg: "#fbf8f4", fg: "#19182a", twins: [],
    ansi: ["#19182a", "#b3261e", "#1d7a36", "#8a5a00", "#1f55c4", "#8f3fa8", "#0d7280", "#5f5b6e",
      "#5f5b6e", "#a8321f", "#17692d", "#7a4f00", "#1b4bb0", "#7e3494", "#0b6470", "#3d3a52"] },
  { id: "dark", zh: "深色", en: "Dark", bg: "#19182a", fg: "#f3ede6", twins: [0],
    ansi: ["#4a4766", "#ef8c7a", "#7fcf9f", "#e6c26e", "#7aa2f7", "#c5a0f5", "#7dcfff", "#c4bdcc",
      "#9a94ad", "#f5a493", "#99ddb3", "#f0d38f", "#9bbaf9", "#d6bcf8", "#a6e0ff", "#f3ede6"] },
  // Solarized, its accents darkened / lightened just enough to read
  { id: "solarized-light", zh: "Solarized 浅色", en: "Solarized Light", bg: "#fdf6e3", fg: "#586e75", twins: [7, 15],
    ansi: ["#073642", "#cf2f2c", "#657400", "#8a6800", "#2074af", "#c7337a", "#207a74", "#eee8d5",
      "#002b36", "#bf4715", "#586e75", "#5c7078", "#647172", "#6367b3", "#667070", "#fdf6e3"] },
  { id: "solarized-dark", zh: "Solarized 深色", en: "Solarized Dark", bg: "#002b36", fg: "#93a1a1", twins: [0, 8],
    ansi: ["#073642", "#e66b69", "#859900", "#b58900", "#3f98d7", "#de68a1", "#2aa198", "#eee8d5",
      "#002b36", "#d87850", "#829297", "#81939a", "#839496", "#878bcf", "#93a1a1", "#fdf6e3"] },
  { id: "contrast", zh: "高对比", en: "High contrast", bg: "#000000", fg: "#ffffff", twins: [0],
    ansi: ["#000000", "#ff6b6b", "#5cff7a", "#ffe14d", "#6eb5ff", "#ff7bff", "#4dfdff", "#e6e6e6",
      "#a6a6a6", "#ff9a9a", "#9dffad", "#fff09a", "#a8d2ff", "#ffb0ff", "#a3feff", "#ffffff"] },
];

export const FONT_SIZES = [12, 13, 14, 15, 16, 18, 20] as const;
export type TermPick = { scheme: string; size: number };
const KEY = "fleet.term";
const DEFAULT: TermPick = { scheme: "follow", size: 14 };

export function schemeOf(id: string): Scheme | undefined { return SCHEMES.find((s) => s.id === id); }

export function termPick(): TermPick {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) || "{}");
    return {
      scheme: v.scheme === "follow" || schemeOf(v.scheme) ? v.scheme : DEFAULT.scheme,
      size: FONT_SIZES.includes(v.size) ? v.size : DEFAULT.size,
    };
  } catch { return { ...DEFAULT }; }
}

const listeners = new Set<() => void>();
export function setTermPick(p: TermPick) {
  try { localStorage.setItem(KEY, JSON.stringify(p)); } catch { /* this page still switches */ }
  listeners.forEach((f) => f());
}
export function onTermPick(f: () => void): () => void { listeners.add(f); return () => { listeners.delete(f); }; }

// xterm's theme for a pick: "follow" takes the page's light / dark
export function xtermTheme(scheme: string, pageDark: boolean) {
  const s = schemeOf(scheme) ?? schemeOf(pageDark ? "dark" : "light")!;
  return { ...Object.fromEntries(NAMES.map((n, i) => [n, s.ansi[i]])),
    background: s.bg, foreground: s.fg, cursor: s.fg, cursorAccent: s.bg, selectionBackground: `${s.fg}40` };
}

// WCAG 2 contrast ratio of two #rrggbb colours
export function contrast(a: string, b: string): number {
  const lum = (h: string) => {
    const [r, g, bl] = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [x, y] = [lum(a), lum(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
