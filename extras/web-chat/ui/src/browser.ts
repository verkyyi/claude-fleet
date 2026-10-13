// browser.ts — what this browser knows of itself, sent with each turn
// (issue #4034): the device, its system and browser, the language, the screen,
// the time zone, the network. Only what the browser itself answers (navigator,
// UA Client Hints, Intl, screen); the address and the city are the server's.
// The service turns it into one short line for the model and keeps the rest
// for its browser_context tool — nothing here is shown on the page.

type UAData = {
  brands?: { brand: string; version: string }[];
  mobile?: boolean;
  platform?: string;
  getHighEntropyValues?: (hints: string[]) => Promise<Record<string, unknown>>;
};
type Conn = { effectiveType?: string; downlink?: number; rtt?: number; saveData?: boolean; type?: string };

let hints: Record<string, unknown> | null = null;
let asked: Promise<void> | null = null;

// the high-entropy hints are async: asked once per page, before the first turn
export function primeBrowser(): Promise<void> {
  if (asked) return asked;
  const ua = (navigator as Navigator & { userAgentData?: UAData }).userAgentData;
  asked = (ua?.getHighEntropyValues
    ? ua.getHighEntropyValues(["platformVersion", "model", "architecture", "fullVersionList"])
      .then((h) => { hints = h; }, () => {})
    : Promise.resolve());
  return asked;
}

export function browserContext() {
  const n = navigator as Navigator & { userAgentData?: UAData; connection?: Conn };
  const ua = n.userAgentData;
  const c = n.connection;
  let tz = "";
  try { tz = Intl.DateTimeFormat().resolvedOptions().timeZone || ""; } catch { /* none */ }
  return {
    ua: n.userAgent,
    uaData: ua ? {
      brands: (ua.brands || []).map((b) => `${b.brand} ${b.version}`),
      mobile: !!ua.mobile, platform: ua.platform || "",
      ...(hints ? {
        platformVersion: String(hints.platformVersion || ""), model: String(hints.model || ""),
        architecture: String(hints.architecture || ""),
      } : {}),
    } : undefined,
    lang: n.language || "",
    langs: [...(n.languages || [])].slice(0, 5),
    tz,
    tzOffset: -new Date().getTimezoneOffset(),
    screen: { w: screen.width, h: screen.height, dpr: window.devicePixelRatio || 1 },
    viewport: { w: window.innerWidth, h: window.innerHeight },
    touch: n.maxTouchPoints || 0,
    net: c ? { type: c.type || "", effectiveType: c.effectiveType || "", downlink: c.downlink ?? null, rtt: c.rtt ?? null, saveData: !!c.saveData } : undefined,
    dark: window.matchMedia?.("(prefers-color-scheme: dark)").matches || false,
  };
}
