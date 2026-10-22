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
import { SimpleImageAttachmentAdapter, useExternalStoreRuntime, type AppendMessage, type ExternalThreadQueueAdapter,
  type RespondToToolApprovalOptions, type ThreadMessageLike } from "@assistant-ui/react";
import { meOnce } from "@/shared/api";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { toMessages, type Item, type Msg } from "./chat";
import { attachedPics, MAX_PICS, packPics } from "./pics";
import { afterSay, askOf, bubbles, replying, settle, userLines, type Pending, type Queued, type ViewAsk } from "./talk";
import { browserCache, mayCache, mayShow, type Layer } from "./local";
import { NOTHING, applyFrame, parseEvent, prependOlder, type Frame, type Held } from "./view-stream";

// can_talk (会话合一 Y01K): the web may talk to it — absent on the old road,
// false for an older session (read-only); queue: its lines waiting; ask: what it asks now
export type ViewState = { agent: string; session: string; busy: boolean; state: string; label: string; holder?: string;
  can_talk?: boolean; queue?: Queued[]; ask?: ViewAsk | null;
  continuation?: { state: string; to: string; message: string } };
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

  // 会话合一 (Y01K): talking to it — what this page said and is waiting on
  const canTalk = state?.can_talk === true;
  const [pending, setPending] = useState<Pending[]>([]);
  const [answered, setAnswered] = useState<Map<string, { approved: boolean; answers?: Record<string, { optionIds: string[] }> }>>(new Map());
  const [note, setNote] = useState("");
  const itemsNow = useRef<Item[]>([]);
  itemsNow.current = items;
  useEffect(() => { setPending([]); setAnswered(new Map()); setNote(""); }, [worker]);
  // what the record and the session's queue say settle what this page shows of its own lines
  const queue = state?.queue;
  useEffect(() => { setPending((ps) => settle(ps, items as { t: string; text?: string }[], queue, Date.now())); }, [items, queue]);
  const waiting = pending.some((p) => p.state !== "failed");
  useEffect(() => {
    if (!waiting) return;
    const t = window.setInterval(() => setPending((ps) => settle(ps, itemsNow.current as { t: string; text?: string }[], queue, Date.now())), 1000);
    return () => clearInterval(t);
  }, [waiting, queue]);

  // same: a line not known to have gone is said again under its own id (the door never takes one twice)
  const sayLine = useCallback(async (text: string, pics: string[], replace?: string, same?: string) => {
    const id = same || crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
    const p: Pending = { id, text, pics, at: Date.now(), base: userLines(itemsNow.current as { t: string; text?: string }[], text), state: "sending" };
    setNote("");
    setPending((ps) => [...ps.filter((x) => x.id !== replace), p]);
    let images: { media_type: string; data: string }[] = [];
    try { images = pics.length ? await packPics(pics, text) : []; } catch {
      setPending((ps) => ps.filter((x) => x.id !== id));
      setNote(tr("这张图读不出来，换一张试试。", "That picture could not be read; try another."));
      return;
    }
    const r = await fetch(`/v1/chat/say?worker=${encodeURIComponent(worker)}`, {
      method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, cache: "no-store",
      body: JSON.stringify({ id, text, ...(images.length ? { images } : {}) }),
    }).catch(() => null);
    const j = r ? await r.json().catch(() => ({})) : {};
    const said = r?.ok ? { ok: true, delivery: String(j.delivery || ""), state: String(j.state || "sent"), reason: j.reason ? String(j.reason) : undefined }
      : { ok: false, code: String(j.code || (r ? `http_${r.status}` : "offline")) };
    setPending((ps) => ps.map((x) => (x.id === id ? afterSay(x, said, Date.now()) : x)));
  }, [worker]);
  const onSay = useCallback(async (m: AppendMessage) => {
    const text = m.content.map((c) => (c.type === "text" ? c.text : "")).join("").trim();
    const pics = attachedPics(m);
    if (!text && !pics.length) return;
    if (pics.length > MAX_PICS) setNote(tr(`一次最多发 ${MAX_PICS} 张图，只发了前 ${MAX_PICS} 张。`, `At most ${MAX_PICS} pictures a message; the first ${MAX_PICS} went.`));
    await sayLine(text, pics.slice(0, MAX_PICS));
  }, [sayLine]);
  // 重试: the same words again; 算了: let it go
  const retry = useCallback((id: string) => {
    const p = pending.find((x) => x.id === id);
    if (p) void sayLine(p.text, p.pics, id, p.returned ? undefined : p.id);
  }, [pending, sayLine]);
  // a line the door gave back is acked once: it is the page's now
  const acked = useRef(new Set<string>());
  useEffect(() => {
    for (const p of pending) {
      if (!p.returned || !p.delivery || acked.current.has(p.delivery)) continue;
      acked.current.add(p.delivery);
      void fetch(`/v1/chat/ack?worker=${encodeURIComponent(worker)}`, {
        method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, cache: "no-store",
        body: JSON.stringify({ delivery: p.delivery }),
      }).catch(() => {});
    }
  }, [pending, worker]);
  const dismiss = useCallback((id: string) => setPending((ps) => ps.filter((x) => x.id !== id)), []);
  const post = useCallback(async (what: "stop" | "answer", body: Record<string, unknown>) => {
    const r = await fetch(`/v1/chat/${what}?worker=${encodeURIComponent(worker)}`, {
      method: "POST", headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, cache: "no-store", body: JSON.stringify(body),
    }).catch(() => null);
    return !!r?.ok;
  }, [worker]);
  const onStop = useCallback(async () => {
    if (!(await post("stop", {}))) setNote(tr("没停下来，稍后再试。", "It did not stop; try again."));
  }, [post]);
  const asks = useMemo(() => { const a = askOf(state?.ask); return a ? [a] : []; }, [state?.ask]);
  const onAnswer = useCallback(async (o: RespondToToolApprovalOptions) => {
    const a = asks.find((x) => x.rid === o.approvalId);
    if (!a) return;
    let body: Record<string, unknown>;
    let picked: Record<string, { optionIds: string[] }> | undefined;
    if (a.kind === "question") {
      const out: Record<string, string | string[]> = {};
      picked = {};
      for (const [q, ans] of Object.entries(o.answers || {})) {
        const picked1 = [...(ans.optionIds || []), ...(ans.text ? [ans.text] : [])];
        out[q] = picked1.length > 1 ? picked1 : picked1[0] || "";
        picked[q] = { optionIds: [...(ans.optionIds || [])] };
      }
      body = { fp: a.rid, answers: out };
    } else body = { fp: a.rid, allow: o.approved };
    if (await post("answer", body)) setAnswered((m) => new Map(m).set(a.rid, { approved: a.kind === "question" ? true : o.approved, ...(picked ? { answers: picked } : {}) }));
    else setNote(tr("这个回答没送到，再点一次。", "That answer didn't go through; pick it again."));
  }, [asks, post]);
  // every send goes through the queue lane: the session's own door orders them,
  // so the composer stays open while it answers (assistant-ui's queue capability)
  const sayRef = useRef(onSay);
  sayRef.current = onSay;
  const lane = useMemo<ExternalThreadQueueAdapter | undefined>(() => (canTalk ? {
    items: [], steerItems: [],
    enqueue: (m) => { void sayRef.current(m); }, steer: (m) => { void sayRef.current(m); },
    move: () => {}, edit: () => {}, remove: () => {},
  } : undefined), [canTalk]);
  const attach = useMemo(() => new SimpleImageAttachmentAdapter(), []);

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
  const messages = useMemo<Msg[]>(() => {
    const base = toMessages(items, canTalk ? asks : [], answered, worker)
      .map((m) => ({ ...m, id: m.id[0] === "a" && m.id[1] === "-" ? m.id : m.id[0] + (Number(m.id.slice(1)) - lead) }));
    // what this page said and the session holds queued: after the record, a waiting one faded
    const more = bubbles(pending, canTalk ? queue : undefined).map((b) => ({
      id: `p-${b.id}`, role: "user" as const,
      content: [...b.pics.map((g) => ({ type: "image", image: g })), ...(b.text ? [{ type: "text", text: b.text }] : [])] as Msg["content"],
      ...(b.wait ? { metadata: { custom: { queued: b.wait } } } : {}),
    }));
    return [...base, ...more];
  }, [items, worker, lead, canTalk, asks, answered, pending, queue]);
  const sending = replying(pending, queue);
  const runtime = useExternalStoreRuntime<Msg>({
    messages,
    convertMessage: (m) => m as ThreadMessageLike,
    // a line handed over runs from the moment it went: waking a parked session is 「回答中」 too
    isRunning: !!state?.busy || (canTalk && sending),
    isLoading: !loaded,
    isDisabled: !canTalk,
    isSendDisabled: canTalk && !!gate,
    hasEarlier: older > 0,
    onLoadEarlier: loadEarlier,
    onNew: onSay,
    ...(canTalk ? { onCancel: onStop, onRespondToToolApproval: onAnswer, queue: lane, adapters: { attachments: attach } } : {}),
  });
  const failed = pending.filter((p) => p.state === "failed");
  return { runtime, state, gate, loaded, live, count: items.length, layer, canTalk, failed, retry, dismiss, note,
    busy: !!state?.busy || (canTalk && sending) };
}
