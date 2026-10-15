// The existing signed device-action channel, with the browser's own cookie
// identity and truthful link-only capabilities. Keys never leave this closure.
const PATH = "/v1/term/client";
type Lease = { state: string; lease?: { id: string }; action_key?: string };
type Signed = { payload: string; sig: string };
type Action = { id: string; lease: string; ts: number; kind: string; url?: string; rport?: number; cport?: number };
export type BrowserOffer = { id: string; url?: string; unsupported?: boolean };

export function safeBrowserURL(value: string): string | null {
  try {
    const u = new URL(value);
    const host = u.hostname.toLowerCase();
    if (!["http:", "https:"].includes(u.protocol) || u.username || u.password ||
      host === "localhost" || host.endsWith(".localhost") || host === "[::1]" || /^127\./.test(host) || host === "0.0.0.0") return null;
    return u.href;
  } catch { return null; }
}

async function verified(signed: Signed, key: string, lease: string): Promise<Action | null> {
  if (!/^[a-f0-9]{64}$/.test(signed.sig) || signed.payload.length > 32768) return null;
  try {
    const hmac = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const signature = Uint8Array.from(signed.sig.match(/../g)!, (b) => parseInt(b, 16));
    if (!await crypto.subtle.verify("HMAC", hmac, signature, new TextEncoder().encode(signed.payload))) return null;
    const action: Action = JSON.parse(signed.payload);
    if (!action.id || action.lease !== lease || !Number.isFinite(action.ts) || Math.abs(Date.now() / 1000 - action.ts) > 120) return null;
    return action;
  } catch { return null; }
}

export function browserClient(worker: string | null, onOffer: (offer: BrowserOffer) => void, onLost: () => void) {
  let lease = "", key = "", stopped = false, lastInput = 0;
  let renewing = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  const abort = new AbortController();
  const seen = new Set<string>();
  const post = async <T>(path: string, body: unknown, signal?: AbortSignal): Promise<T> => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal });
    if (!response.ok) throw new Error("browser_lease_failed");
    return response.json();
  };
  const release = (id: string) => void fetch(PATH, { method: "POST", credentials: "same-origin", keepalive: true,
    headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "release", lease: id }) }).catch(() => {});
  const close = () => {
    if (stopped) return;
    stopped = true; clearInterval(timer); abort.abort();
    if (lease) release(lease);
    lease = ""; key = ""; seen.clear();
  };
  const lost = () => { if (!stopped) { close(); onLost(); } };
  const renew = async (action: "input" | "renew") => {
    if (!lease || stopped || renewing) return;
    renewing = true;
    try {
      const r = await post<Lease>(PATH, { action, lease, viewing: worker || "", last_input: lastInput }, abort.signal);
      if (stopped) return;
      if (r.state !== "active" || r.lease?.id !== lease || !r.action_key) { lost(); return; }
      key = r.action_key;
    } catch { lost(); } finally { renewing = false; }
  };
  const done = (id: string, ok: boolean, result: string) => post(PATH + "/actions", { action: "done", lease, id, ok, result }, abort.signal);
  const ready = (async () => {
    // Keep the acquire response so a React cleanup during admission can release
    // its newly issued lease. Aborting fetch would lose that id. Time is bounded.
    const r = await post<Lease>(PATH, { action: "acquire", device: "Web browser", terminal: "browser", caps: ["link"], viewing: worker || "" }, AbortSignal.timeout(10000));
    if (stopped) { if (r.lease) release(r.lease.id); return false; }
    if (r.state !== "active" || !r.lease || !r.action_key) throw new Error("browser_lease_failed");
    lease = r.lease.id; key = r.action_key;
    timer = setInterval(() => void renew("renew"), 15000);
    void (async () => {
      while (!stopped) {
        const reply = await post<{ state: string; actions: Signed[] }>(PATH + "/actions", { action: "poll", lease, wait: 25 }, abort.signal);
        if (stopped) return;
        if (reply.state !== "active") { lost(); return; }
        for (const signed of reply.actions) {
          const action = await verified(signed, key, lease);
          if (stopped) return;
          if (!action || seen.has(action.id)) continue;
          seen.add(action.id);
          if (seen.size > 128) seen.delete(seen.values().next().value!);
          const url = action.kind === "open_url" && !action.rport && !action.cport ? safeBrowserURL(action.url || "") : null;
          onOffer({ id: action.id, ...(url ? { url } : { unsupported: true }) });
          await done(action.id, Boolean(url), url ? "offered: browser link; opening not confirmed" : "unsupported: browser cannot forward ports, OAuth callbacks, files or terminal actions");
        }
      }
    })().catch(lost);
    return true;
  })().catch(() => { lost(); return false; });
  return { ready, close, input() {
    const now = Math.floor(Date.now() / 1000);
    if (now - lastInput >= 5) { lastInput = now; void renew("input"); }
  } };
}
