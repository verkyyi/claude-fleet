// i18n.ts — the console's two languages (EPIC #3923 rule 8). The hub settles a
// page's language before it serves it (?lang= > the account's > the cf_lang
// cookie > the browser's, pagelang.go) and leaves the answer in cf_lang,
// readable by script on purpose — so the page reads that cookie and agrees
// with the server; no cookie (a dev server) falls back to the browser's.
export type Lang = "zh" | "en";

function pick(): Lang {
  // a ?lang= link wins on the server too (pagelang.go); the review build has no server
  const q = typeof location !== "undefined" ? new URLSearchParams(location.search).get("lang") : null;
  if (q) return q.toLowerCase().startsWith("zh") ? "zh" : "en";
  const m = typeof document !== "undefined" ? document.cookie.match(/(?:^|;\s*)cf_lang=([^;]*)/) : null;
  const v = (m ? decodeURIComponent(m[1]) : typeof navigator !== "undefined" ? navigator.language : "zh").toLowerCase();
  return v.startsWith("zh") ? "zh" : "en";
}

export const lang: Lang = pick();
if (typeof document !== "undefined") document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";

// tr("中文", "English") — the pair sits where the words are used, so neither
// language can be added without the other.
export const tr = (zh: string, en: string) => (lang === "zh" ? zh : en);

// fmtTokens — a token count the way every usage number is printed, here and on
// the admin side alike (the old console's fmtCompact): 2.28M / 228 万.
const sig3 = (x: number) => String(Number(x.toPrecision(3)));
const trim0 = (s: string) => s.replace(/\.0+$|(\.\d*?)0+$/, "$1");
export function fmtTokens(v: unknown): string {
  const n = Number(v) || 0, a = Math.abs(n);
  if (lang === "zh") {
    if (a >= 1e8) return sig3(n / 1e8) + " 亿";
    if (a >= 1e4) return sig3(n / 1e4) + " 万";
    return String(Math.round(n));
  }
  if (a >= 1e9) return trim0((n / 1e9).toFixed(2)) + "B";
  if (a >= 1e6) return trim0((n / 1e6).toFixed(1)) + "M";
  if (a >= 1e3) return trim0((n / 1e3).toFixed(1)) + "k";
  return String(Math.round(n));
}

// fmtWhen — a moment in local time: 「周一 08:00」 within the week ahead, else
// 「10月20日 08:00」 / "Mon 08:00", "Oct 20, 08:00".
export function fmtWhen(t: string | number | undefined): string {
  const ms = typeof t === "number" ? t : Date.parse(t || "");
  if (!Number.isFinite(ms) || ms <= 0) return "—";
  const d = new Date(ms), hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  const soon = ms - Date.now() < 6 * 864e5 && ms > Date.now() - 864e5;
  if (lang === "zh") return soon ? `${"周日周一周二周三周四周五周六".slice(d.getDay() * 2, d.getDay() * 2 + 2)} ${hm}` : `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
  return soon ? `${d.toLocaleDateString("en-US", { weekday: "short" })} ${hm}` : `${d.toLocaleDateString("en-US", { month: "short", day: "numeric" })}, ${hm}`;
}
