// poster.ts — a 试用二维码 as a poster to send a friend (claude-fleet CHZ0).
// One picture, 1080 × 1440 (3:4 — what a WeChat chat shows whole and a phone
// saves at full width): the wordmark, the product in one line, the code on a white
// card with what it gives, three steps, and what to ask it. Drawn on a canvas in
// the browser from the code's own qr.png (same origin, so the canvas stays
// readable) — the hub builds nothing. The colours and the three families are
// the theme's (extras/fleet-theme), read off the page's CSS variables at draw
// time, never spelled here. The words and the layout are plain functions so
// test/poster.mjs can hold them without a browser.
import { BRAND } from "../shared/brand.ts";
import type { Wordmark } from "../shared/wordmark-parse.ts";

export type PosterLang = "zh" | "en";
export const W = 1080;
export const H = 1440;
const PAD = 84;

export type PosterCode = { channel: string; terms: string; approval: boolean; until: string };
export type PosterWords = {
  brand: string;
  badge: string;
  head: [string, string]; // the second line in the accent colour
  sub: string;
  scan: string;
  plan: string;
  tokens: string;
  how: string;
  steps: [string, string, string];
  asks: string;
  until: string;
};

const zeroTime = (iso?: string) => !iso || iso.startsWith("0001-");

// the plan's words for a friend: 「7 天免费试用」 · 「含 300 万 tokens 额度」
function plan(terms: string, l: PosterLang): { plan: string; tokens: string } {
  const m: Record<string, string> = Object.fromEntries(terms.split(",").map((p) => p.split("=").map((x) => x.trim())));
  const days = Number(m.days) || 0;
  const tok = Number(m.tokens) || 0;
  if (l === "zh") {
    return { plan: days ? `${days} 天免费试用` : "免费试用", tokens: tok ? `含 ${+(tok / 10_000).toFixed(1)} 万 tokens 额度` : "" };
  }
  return { plan: days ? `${days}-day free trial` : "Free trial", tokens: tok ? `${+(tok / 1_000_000).toFixed(1)}M tokens included` : "" };
}

// what the poster says, in one language; terms "" = the fleet's default plan
export function posterWords(c: PosterCode, l: PosterLang, defaultTerms: string): PosterWords {
  const p = plan(c.terms || defaultTerms, l);
  const until = zeroTime(c.until) ? "" : new Date(Date.parse(c.until) + 8 * 3600_000).toISOString().slice(0, 10);
  if (l === "zh") {
    return {
      brand: BRAND,
      badge: "免费试用",
      head: ["随时在线的", "Claude Code"],
      sub: "说一句话，它替你做完，做好了提醒你。手机上就能用。",
      scan: "微信扫一扫",
      ...p,
      how: c.approval ? "关注服务号，提交一句申请，通过即开通" : "关注服务号就开通，不用审批",
      steps: [
        "微信扫码，关注服务号",
        c.approval ? "写一句想用它做什么，通过后开通试用" : "试用自动开通，给你准备一台电脑",
        "点开对话，直接说你要做什么",
      ],
      asks: "写文案 · 整理表格 · 做一页网页 · 查资料",
      until: until ? `本码 ${until} 前有效` : "",
    };
  }
  return {
    brand: BRAND,
    badge: "Free trial",
    head: ["Claude Code,", "always on"],
    sub: "Say what you need — it does the work and tells you when it is done. Your phone is enough.",
    scan: "Scan with WeChat",
    ...p,
    how: c.approval ? "Follow the account and say what it is for — approved, it starts" : "Follow the account and it starts — no approval",
    steps: [
      "Scan with WeChat and follow the account",
      c.approval ? "Say what you want it for; approved, the trial starts" : "The trial starts at once, a computer set up for you",
      "Open the chat and just say what to do",
    ],
    asks: "Copy · spreadsheets · a web page · research",
    until: until ? `Valid until ${until}` : "",
  };
}

// lines no wider than max: a 中文 character is a break point, a Latin word is
// kept whole, and a closing mark never starts a line
const CJK = /[⺀-鿿豈-﫿＀-￯　-〿]/;
const NO_START = /^[，。、；：！？）」』”’,.;:!?)]/;
export function wrap(measure: (s: string) => number, text: string, max: number): string[] {
  const toks: string[] = [];
  for (const piece of text.match(/[A-Za-z0-9'’.\-+%/@]+\s*|\s+|[^\sA-Za-z0-9]/g) || []) {
    if (toks.length && NO_START.test(piece)) toks[toks.length - 1] += piece;
    else toks.push(piece);
  }
  const lines: string[] = [];
  let cur = "";
  for (const tk of toks) {
    if (cur && measure((cur + tk).trimEnd()) > max) {
      lines.push(cur.trimEnd());
      cur = tk.trimStart();
    } else cur += tk;
  }
  if (cur.trim()) lines.push(cur.trimEnd());
  return lines;
}
export const isCJK = (s: string) => CJK.test(s);

// the theme as the canvas needs it: colours and the three families
export type PosterTheme = {
  bg: string; surface: string; line: string; ink: string; ink2: string; muted: string;
  clay: string; clayHi: string; clayDeep: string; sand: string; onClay: string;
  display: string; ui: string; mono: string;
};
export function themeFromPage(el: Element = document.documentElement): PosterTheme {
  const s = getComputedStyle(el);
  const v = (n: string) => s.getPropertyValue(`--fleet-${n}`).trim();
  return {
    bg: v("bg"), surface: v("surface"), line: v("line"), ink: v("ink"), ink2: v("ink-2"), muted: v("muted"),
    clay: v("clay"), clayHi: v("clay-hi"), clayDeep: v("clay-deep"), sand: v("sand"), onClay: v("on-clay"),
    display: v("font-display"), ui: v("font-ui"), mono: v("font-mono"),
  };
}

// the 2D calls the poster makes — a real canvas context, or the test's recorder
export type Ctx = Pick<CanvasRenderingContext2D,
  "fillStyle" | "strokeStyle" | "lineWidth" | "lineCap" | "lineJoin" | "font" | "textBaseline" | "textAlign" | "imageSmoothingEnabled" |
  "fillRect" | "fillText" | "measureText" | "beginPath" | "moveTo" | "lineTo" | "arc" | "roundRect" | "fill" | "stroke" | "drawImage" |
  "save" | "restore" | "translate" | "scale" | "createRadialGradient" | "createLinearGradient">;

// draw the poster; qr is the code's own picture (anything drawImage takes);
// mark is the parsed wordmark (src/shared/wordmark-parse.ts) — none (the Node test,
// which has no Path2D) draws the name as type in its place
export function drawPoster(g: Ctx, w: PosterWords, qr: CanvasImageSource | null, th: PosterTheme, mark?: Wordmark): void {
  const font = (weight: number, px: number, fam: string) => `${weight} ${px}px ${fam}`;
  const text = (s: string, x: number, y: number, f: string, color: string) => {
    g.font = f;
    g.fillStyle = color;
    g.fillText(s, x, y);
  };
  const lines = (s: string, x: number, y: number, max: number, f: string, color: string, lh: number) => {
    g.font = f;
    const ls = wrap((t) => g.measureText(t).width, s, max);
    ls.forEach((l, i) => text(l, x, y + i * lh, f, color));
    return y + ls.length * lh;
  };
  g.textBaseline = "alphabetic";
  g.textAlign = "left";

  // the page: the site's dark, warmed at the top right
  g.fillStyle = th.bg;
  g.fillRect(0, 0, W, H);
  const glow = g.createRadialGradient(W - 120, 140, 40, W - 120, 140, 760);
  glow.addColorStop(0, th.clay + "55");
  glow.addColorStop(1, th.bg + "00");
  g.fillStyle = glow;
  g.fillRect(0, 0, W, H);
  const band = g.createLinearGradient(0, 0, W, 0);
  band.addColorStop(0, th.clayDeep);
  band.addColorStop(1, th.clayHi);
  g.fillStyle = band;
  g.fillRect(0, 0, W, 10);

  // the wordmark (extras/fleet-theme/wordmark.svg): letters in ink, its o clay
  if (mark && typeof Path2D !== "undefined") {
    const [vx, vy, , vh] = mark.viewBox;
    const k = 52 / vh;
    g.save();
    g.translate(PAD, 84);
    g.scale(k, k);
    g.translate(-vx, -vy);
    g.lineCap = "butt";
    g.lineJoin = "miter";
    for (const p of mark.parts) {
      const path = new Path2D(p.d);
      const paint = (c: string) => (c === "currentColor" ? th.ink : c.toLowerCase() === "#d9765a" ? th.clay || c : c);
      if (p.stroke && p.stroke !== "none") {
        g.strokeStyle = paint(p.stroke);
        g.lineWidth = p.strokeWidth ?? 1;
        g.stroke(path);
      }
      if (p.fill && p.fill !== "none") {
        g.fillStyle = paint(p.fill);
        g.fill(path);
      }
    }
    g.restore();
  } else {
    text(w.brand, PAD, 72 + 52, font(700, 48, th.display), th.ink);
  }
  // the badge, top right
  g.font = font(600, 28, th.ui);
  const bw = g.measureText(w.badge).width + 48;
  g.fillStyle = th.clay;
  g.beginPath();
  g.roundRect(W - PAD - bw, 84, bw, 52, 26);
  g.fill();
  g.textAlign = "center";
  text(w.badge, W - PAD - bw / 2, 84 + 36, font(600, 28, th.ui), th.onClay);
  g.textAlign = "left";

  // the product in one line
  const headPx = w.head.some(isCJK) ? 96 : 104;
  text(w.head[0], PAD, 280, font(800, headPx, th.display), th.ink);
  text(w.head[1], PAD, 280 + headPx * 1.14, font(800, headPx, th.display), th.clay);
  let y = lines(w.sub, PAD, 280 + headPx * 1.14 + 72, W - 2 * PAD, font(400, 31, th.ui), th.ink2, 46);

  // the code on its white card, what it gives beside it
  const cy = Math.max(y + 22, 590);
  const ch = 440;
  g.fillStyle = "#ffffff";
  g.beginPath();
  g.roundRect(PAD, cy, W - 2 * PAD, ch, 36);
  g.fill();
  const q = 372;
  const qx = PAD + 40;
  const qy = cy + (ch - q) / 2;
  if (qr) {
    g.imageSmoothingEnabled = false;
    g.drawImage(qr, qx, qy, q, q);
    g.imageSmoothingEnabled = true;
  }
  const rx = qx + q + 44;
  const rw = W - PAD - 40 - rx;
  let ry = cy + 92;
  ry = lines(w.scan, rx, ry, rw, font(700, 46, th.display), th.bg, 58) + 30;
  g.fillStyle = th.clay;
  g.fillRect(rx, ry - 30, 56, 6);
  ry = lines(w.plan, rx, ry + 34, rw, font(700, 38, th.ui), th.clayDeep, 50);
  if (w.tokens) ry = lines(w.tokens, rx, ry + 2, rw, font(500, 28, th.ui), th.bg, 40);
  lines(w.how, rx, ry + 30, rw, font(400, 27, th.ui), th.muted, 40);

  // three steps
  y = cy + ch + 80;
  w.steps.forEach((s, i) => {
    g.fillStyle = th.clay;
    g.beginPath();
    g.arc(PAD + 24, y - 11, 24, 0, Math.PI * 2);
    g.fill();
    g.textAlign = "center";
    text(String(i + 1), PAD + 24, y, font(700, 28, th.mono), th.onClay);
    g.textAlign = "left";
    y = lines(s, PAD + 72, y, W - 2 * PAD - 72, font(500, 31, th.ui), th.ink, 42) + 20;
  });

  // what to ask it, and how long the code is good for
  g.fillStyle = th.line;
  g.fillRect(PAD, H - 118, W - 2 * PAD, 2);
  text(w.asks, PAD, H - 64, font(400, 26, th.ui), th.sand);
  if (w.until) {
    g.textAlign = "right";
    text(w.until, W - PAD, H - 64, font(400, 24, th.ui), th.muted);
    g.textAlign = "left";
  }
}
