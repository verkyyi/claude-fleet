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
