// view.ts — 只读 (task F481, EPIC GR5E C5): a session running in a terminal,
// its conversation followed from the web. GET /v1/chat/view?worker=<id> is the
// service's Server-Sent Events (extras/web-chat/server.mjs viewStream):
// {t:"state"} — which agent, answering or not — and {t:"items"} frames
// (view-stream.ts): the newest stretch in place, then what was added, each with
// the byte read to. A page back from a drop or a hidden tab asks ?at=<byte>&s=
// <conversation>, so nothing shows twice; ?before=<byte> fetches the page before.
// Never a turn, never a take: 接管 is its own step (handover.ts, task VV8F).
//
// Opening it draws at once what was seen last (task YP39), the same three
// layers as the chat (task KSQG, local.ts): this browser's record < the entry's
// copy (?cached=1) < the session's machine, which always replaces the others.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useExternalStoreRuntime, type ThreadMessageLike } from "@assistant-ui/react";
import { meOnce } from "@/shared/api";
import { viewAs } from "@/shared/viewAs";
import { toMessages, type Item, type Msg } from "./chat";
import { browserCache, mayCache, mayShow, type Layer } from "./local";
import { NOTHING, applyFrame, parseEvent, prependOlder, type Frame, type Held } from "./view-stream";

export type ViewState = { agent: string; session: string; busy: boolean; state: string; label: string; holder: string };
// why there is nothing to follow: the entry's or the service's code
// (not_yours · old_agent · no_session · home_down · gone · …) and its words
export type ViewGate = { code: string; msg: string } | null;

const RETRY_MS = [1000, 2000, 4000, 8000, 15000];
// a refusal that stays one: asking again changes nothing
const FINAL = new Set(["not_yours", "bad_target", "old_agent", "no_session", "agent", "operator", "signin", "view_as", "forbidden", "gone"]);
const API = "/v1/chat/view";
// a session's record in this browser: the chat's store, one side per session
export const viewSide = (worker: string) => `view:${worker}`;

// The first history on screen after the session opened, and which layer drew it
// (the 0.1 s measure): performance marks view:first:<layer> and, for a test,
// window.__fleetViewFirst = { layer, ms } — ms from the session's opening.
function markFirst(layer: Layer, since: number) {
  try {
    performance.mark(`view:first:${layer}`);
    const w = window as unknown as { __fleetViewFirst?: { layer: string; ms: number } };
    w.__fleetViewFirst ??= { layer, ms: Math.round(performance.now() - since) };
  } catch { /* no performance API */ }
}

export function useSessionView(worker: string) {
  const [items, setItems] = useState<Item[]>([]);
  const [state, setState] = useState<ViewState | null>(null);
  const [gate, setGate] = useState<ViewGate>(null);
  const [loaded, setLoaded] = useState(false);
  const [live, setLive] = useState(false);       // the stream is open now
  const [layer, setLayer] = useState<Layer | null>(null);
  const [older, setOlder] = useState(0);         // >0: there is more before what is shown
  const [lead, setLead] = useState(0);           // items drawn above the first answer (ids stay put)
  // what the page holds, read by the loop without re-running it
  const held = useRef<Held>(NOTHING);
  const shown = useRef<Item[]>([]);
  const top = useRef<Layer | null>(null);
  const keeper = useRef("");

  useEffect(() => {
    if (!worker) return;
    let on = true, tries = 0, wake: (() => void) | null = null, saveT = 0;
    let ac: AbortController | null = null;
    const opened = performance.now();
    held.current = NOTHING; shown.current = []; top.current = null; keeper.current = "";
    try { delete (window as unknown as { __fleetViewFirst?: unknown }).__fleetViewFirst; } catch { /* none */ }
    setItems([]); setState(null); setGate(null); setLoaded(false); setLayer(null); setOlder(0); setLead(0);
    const draw = (next: Item[], l: Layer) => {
      shown.current = next; setItems(next); setLoaded(true);
      if (top.current !== l) { top.current = l; setLayer(l); }
      markFirst(l, opened);
    };
    // keep the machine's answer (and what was added since) for the next opening
    const save = () => {
      clearTimeout(saveT);
      saveT = window.setTimeout(() => {
        const who = keeper.current;
        if (!who || top.current !== "home") return;
        void browserCache()?.write(who, viewSide(worker), { session: held.current.session, items: shown.current }).catch(() => {});
      }, 600);
    };
    // 1. this browser's record, once /v1/me says it is this person's own page
    const cache = browserCache();
    void meOnce().then(async (me) => {
      if (!on || !mayCache(me, viewAs)) return;
      keeper.current = me!.person!;
      if (top.current === "home") { save(); return; }
      if (!cache) return;
      const snap = await cache.read(keeper.current, viewSide(worker)).catch(() => null);
      if (!on || !snap?.items.length || !mayShow("local", top.current)) return;
      draw(snap.items as Item[], "local");
    }).catch(() => {});
    // 2. the entry's copy: no crossing to the session's machine
    void fetch(`${API}?worker=${encodeURIComponent(worker)}&cached=1`, { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : null)).then((j) => {
        if (!on || !j?.mirror || !Array.isArray(j.items) || !j.items.length || !mayShow("copy", top.current)) return;
        draw(j.items as Item[], "copy");
      }).catch(() => {});
    // 3. the session's machine: its stream, for as long as the page is open
    const take = (f: Frame) => {
      const h = held.current;
      if (f.replace || h.at < 0 || String(f.session || "") !== h.session) setLead(0);
      const m = applyFrame(h, shown.current, f);
      held.current = m.held;
      setOlder(m.held.older);
      if (m.items) draw(m.items, "home");
      else if (top.current !== "home") draw(shown.current, "home");
      save();
    };
    const sleep = (ms: number) => new Promise<void>((r) => { const t = setTimeout(r, ms); wake = () => { clearTimeout(t); r(); }; });
    const onShow = () => { if (document.visibilityState === "visible") wake?.(); };
    document.addEventListener("visibilitychange", onShow);
    window.addEventListener("online", onShow);
    (async () => {
      while (on) {
        ac = new AbortController();
        const h = held.current;
        const q = h.at >= 0 ? `&at=${h.at}&s=${encodeURIComponent(h.session)}` : "";
        let final = false;
        try {
          const r = await fetch(`${API}?worker=${encodeURIComponent(worker)}${q}`,
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
                else if (data.t === "items") take(data as Frame);
                else if (data.t === "reset") held.current = { ...held.current, at: -1 };   // the next frame replaces
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
    return () => {
      on = false; ac?.abort(); wake?.(); clearTimeout(saveT);
      document.removeEventListener("visibilitychange", onShow); window.removeEventListener("online", onShow);
    };
  }, [worker]);

  // the page before what is shown (?before=), drawn above it — assistant-ui's own
  // 「更早的消息」 (the runtime runs one at a time and says it is loading)
  const loadEarlier = useCallback(async () => {
    const h = held.current;
    if (!worker || !h.older) return;
    const r = await fetch(`${API}?worker=${encodeURIComponent(worker)}&before=${h.older}`, { cache: "no-store" });
    const j = r.ok ? await r.json() : null;
    const m = j && prependOlder(held.current, shown.current, h.older, j);
    if (!m) return;
    const n = m.items.length - shown.current.length;
    held.current = m.held; shown.current = m.items as Item[];
    setLead((x) => x + n); setItems(m.items as Item[]); setOlder(m.held.older);
  }, [worker]);

  // a message's id is its item's place counted from the first answer's first
  // item, so a page drawn above keeps every row (and the scroll) where it was
  const messages = useMemo<Msg[]>(() => toMessages(items, [], new Map(), worker)
    .map((m) => ({ ...m, id: m.id[0] + (Number(m.id.slice(1)) - lead) })), [items, worker, lead]);
  const runtime = useExternalStoreRuntime<Msg>({
    messages,
    convertMessage: (m) => m as ThreadMessageLike,
    isRunning: !!state?.busy,
    isLoading: !loaded,
    isDisabled: true,
    hasEarlier: older > 0,
    onLoadEarlier: loadEarlier,
    onNew: async () => { /* read-only: the composer is never offered */ },
  });
  return { runtime, state, gate, loaded, live, count: items.length, layer };
}
