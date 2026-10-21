// view.ts — 只读 (task F481, EPIC GR5E C5): a session running in a terminal,
// its conversation followed from the web. GET /v1/chat/view?worker=<id>&from=<n>
// is the service's Server-Sent Events (extras/web-chat/server.mjs viewStream):
// {t:"state"} — which agent, answering or not — and {t:"items", from, items}
// with id = the count so far. The page keeps the count it holds and comes back
// with ?from= after a drop or a hidden tab, so nothing shows twice. Never a
// turn, never a take: 接管 is its own step (handover.ts, task VV8F).
import { useEffect, useMemo, useRef, useState } from "react";
import { useExternalStoreRuntime, type ThreadMessageLike } from "@assistant-ui/react";
import { toMessages, type Item, type Msg } from "./chat";
import { mergeView, parseEvent } from "./view-stream";

export type ViewState = { agent: string; session: string; busy: boolean; state: string; label: string; holder: string };
// why there is nothing to follow: the entry's or the service's code
// (not_yours · old_agent · no_session · home_down · gone · …) and its words
export type ViewGate = { code: string; msg: string } | null;

const RETRY_MS = [1000, 2000, 4000, 8000, 15000];
// a refusal that stays one: asking again changes nothing
const FINAL = new Set(["not_yours", "bad_target", "old_agent", "no_session", "agent", "operator", "signin", "view_as", "forbidden", "gone"]);

export function useSessionView(worker: string) {
  const [items, setItems] = useState<Item[]>([]);
  const [base, setBase] = useState(0);          // the absolute index of items[0]
  const [state, setState] = useState<ViewState | null>(null);
  const [gate, setGate] = useState<ViewGate>(null);
  const [loaded, setLoaded] = useState(false);
  const [live, setLive] = useState(false);       // the stream is open now
  // what the page holds, read by the loop without re-running it
  const held = useRef({ base: 0, n: 0 });

  useEffect(() => {
    if (!worker) return;
    let on = true, tries = 0, wake: (() => void) | null = null;
    let ac: AbortController | null = null;
    held.current = { base: 0, n: 0 };
    setItems([]); setBase(0); setState(null); setGate(null); setLoaded(false);
    const take = (from: number, add: Item[]) => {
      const m = mergeView(held.current, from, add);
      held.current = m.held;
      if (m.replace) { setBase(m.held.base); setItems(m.fresh); }
      else if (m.fresh.length) setItems((cur) => [...cur, ...m.fresh]);
    };
    const reset = () => { held.current = { base: 0, n: 0 }; setBase(0); setItems([]); };
    const sleep = (ms: number) => new Promise<void>((r) => { const t = setTimeout(r, ms); wake = () => { clearTimeout(t); r(); }; });
    const onShow = () => { if (document.visibilityState === "visible") wake?.(); };
    document.addEventListener("visibilitychange", onShow);
    window.addEventListener("online", onShow);
    (async () => {
      while (on) {
        ac = new AbortController();
        const from = held.current.base + held.current.n;
        let final = false;
        try {
          const r = await fetch(`/v1/chat/view?worker=${encodeURIComponent(worker)}&from=${from}`,
            { headers: { Accept: "text/event-stream" }, cache: "no-store", signal: ac.signal });
          if (!r.ok || !r.body) {
            const j = await r.json().catch(() => ({}));
            const code = String(j.code || (r.status === 404 ? "old_service" : `http_${r.status}`));
            setGate({ code, msg: String(j.error || "") });
            setLoaded(true);
            final = FINAL.has(code) || code === "old_service";
          } else {
            setGate(null); setLive(true); tries = 0;
            const rd = r.body.getReader();
            const dec = new TextDecoder();
            let buf = "";
            for (;;) {
              const { value, done } = await rd.read();
              if (done) break;
              buf = (buf + dec.decode(value, { stream: true })).replace(/\r\n/g, "\n");
              let i;
              while ((i = buf.indexOf("\n\n")) >= 0) {
                const { data } = parseEvent(buf.slice(0, i));
                buf = buf.slice(i + 2);
                if (!data) continue;
                if (data.t === "state") setState(data as unknown as ViewState);
                else if (data.t === "items") { take(Number(data.from) || 0, (data.items as Item[]) || []); setLoaded(true); }
                else if (data.t === "reset") reset();
                else if (data.t === "gone") { setGate({ code: "gone", msg: "" }); final = true; }
              }
            }
          }
        } catch { /* dropped: come back from what we hold */ }
        setLive(false);
        if (!on || final) break;
        // a hidden page waits until it is looked at again
        await sleep(document.visibilityState === "hidden" ? 60_000 : RETRY_MS[Math.min(tries++, RETRY_MS.length - 1)]);
      }
    })();
    return () => { on = false; ac?.abort(); wake?.(); document.removeEventListener("visibilitychange", onShow); window.removeEventListener("online", onShow); };
  }, [worker]);

  const messages = useMemo<Msg[]>(() => toMessages(items, [], new Map()), [items]);
  const runtime = useExternalStoreRuntime<Msg>({
    messages,
    convertMessage: (m) => m as ThreadMessageLike,
    isRunning: !!state?.busy,
    isLoading: !loaded,
    isDisabled: true,
    onNew: async () => { /* read-only: the composer is never offered */ },
  });
  return { runtime, state, gate, loaded, live, count: base + items.length };
}
