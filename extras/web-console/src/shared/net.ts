// net.ts — is the network there (GR5E C8): every read and write the console
// makes reports here (api.ts), and the browser's offline / online too. Two
// fetches in a row that never got an answer, or the browser saying offline,
// is「网络不太好」— the shell's top band says so, and how old what is on the
// screen is (the last answer's time). The first answer after that is「接上了」:
// window gets one `fleet:net-back`, and every reader re-reads (work-rows.tsx).
// An HTTP error is an answer — only a fetch that threw counts. No timer here;
// the band asks again (NetBar) while it shows.

export type Net = { bad: boolean; lastOk: number };
export const NET_BACK = "fleet:net-back";
const MISSES = 2;

let misses = 0;
let state: Net = { bad: false, lastOk: Date.now() };
const subs = new Set<(n: Net) => void>();
const offline = () => typeof navigator !== "undefined" && navigator.onLine === false;

function set(next: Net) {
  if (next.bad === state.bad && next.lastOk === state.lastOk) return;
  const back = state.bad && !next.bad;
  state = next;
  subs.forEach((f) => f(state));
  if (back && typeof window !== "undefined") window.dispatchEvent(new Event(NET_BACK));
}

// answered: a fetch got a response (any status)
export function netOk(now = Date.now()) {
  misses = 0;
  set({ bad: false, lastOk: now });
}
// missed: a fetch threw (no network, DNS, a reset)
export function netMiss() {
  misses++;
  if (misses >= MISSES || offline()) set({ ...state, bad: true });
}
export const netState = () => state;
export function netSubscribe(f: (n: Net) => void) { subs.add(f); return () => { subs.delete(f); }; }

// the band's words: how old the screen is, in whole minutes
export const minutesAgo = (lastOk: number, now = Date.now()) => Math.max(0, Math.floor((now - lastOk) / 60_000));

if (typeof window !== "undefined") {
  window.addEventListener("offline", () => set({ ...state, bad: true }));
  // the browser is back: not yet an answer — the band's next ask decides
  window.addEventListener("online", () => { misses = 0; });
}

// test seam
export function netReset(now = Date.now()) { misses = 0; state = { bad: false, lastOk: now }; }
