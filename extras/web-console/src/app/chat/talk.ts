// talk.ts — 会话合一 (Y01K): the web talks to any session, the pure half. A
// line goes to the session as its next turn through the entry —
//   POST /v1/chat/say?worker=<id>  {id, text, images?}  → {delivery, state: sent|queued|refused, reason?}
//   POST /v1/chat/answer?worker=   {fp, answers}|{fp, allow}  (a question's fingerprint, the option's own words)
//   POST /v1/chat/stop?worker=     {}
// and what the session holds comes back on the view stream (view.ts): its
// {t:"state"} carries can_talk (false / absent: an older session, read-only),
// queue [{delivery, text, why}] — the lines waiting for this turn to end or for
// the person typing in its terminal to send — and ask, what it is asking now.
// The page shows a line it sent the way it will land, until the record carries
// it. The session's door gives a line back on the queue with why expired ·
// session_changed · wake_timeout (a parked session that did not come back in
// 20 s) · no_session · old_version · exited · dropped: the page puts its words
// back in the box, says so in the composer with 重试, and acks it
// (POST /v1/chat/ack?worker= {delivery}). A line the page cannot tell went (no
// answer) is retried under the same id — the door never takes one twice.
// Pure: test/talk.mjs runs it.
import { tr } from "../../shared/i18n.ts"; // .ts: the test runs this file as it is

export type Queued = { delivery: string; text: string; why?: string };
export type ViewAsk = { fp: string; kind?: "question" | "permission"; tool?: string; summary?: string;
  questions?: { question: string; header?: string; multiSelect?: boolean; options?: { label: string; description?: string }[] }[] };

// how long a line handed over may take to show in the record: a parked session
// comes back in ~2 s; past this it is said not to have gone through
export const WAKE_MS = 20_000;

// A line this page said, until the record has it.
//   sending — on its way to the entry; sent — the session took it (or the entry
//   did, waking it); queued — waiting (this turn, a terminal draft); failed — not taken.
export type Pending = {
  id: string; text: string; pics: string[]; at: number;
  base: number;                 // the record's user lines with these words when it was said
  state: "sending" | "sent" | "queued" | "failed";
  delivery?: string; why?: string; sentAt?: number;
  returned?: boolean;           // the door gave it back: surely not taken (retry under a new id)
  seen?: boolean;               // the session's queue has listed it (a queue read before the answer has not)
};

// the queue's words for a line given back, not waiting
export const RETURNED = new Set(["expired", "session_changed", "wake_timeout", "no_session", "old_version", "exited", "dropped"]);
const waitingIn = (queue: Queued[] | undefined) => (queue || []).filter((q) => !RETURNED.has(q.why || ""));

type Line = { t: string; text?: string };
export const userLines = (items: Line[], text: string) => items.filter((i) => i.t === "user" && (i.text || "").trim() === text.trim()).length;

// What the page shows of what it said, now: a line the record carries is
// dropped; one out of the session's queue is sent (its clock starts then); a
// sent one the record does not carry after WAKE_MS did not go through.
export function settle(pending: Pending[], items: Line[], queue: Queued[] | undefined, now: number): Pending[] {
  const waiting = new Set(waitingIn(queue).map((q) => q.delivery));
  const back = new Map((queue || []).filter((q) => RETURNED.has(q.why || "")).map((q) => [q.delivery, q.why || ""]));
  let changed = false;
  const out: Pending[] = [];
  for (const p of pending) {
    if (p.state !== "failed" && p.state !== "sending" && userLines(items, p.text) > p.base) { changed = true; continue; }
    if (p.state !== "failed" && p.delivery && back.has(p.delivery)) { out.push({ ...p, state: "failed", why: back.get(p.delivery), returned: true }); changed = true; continue; }
    if (p.state === "queued" && p.delivery && waiting.has(p.delivery) && !p.seen) { out.push({ ...p, seen: true }); changed = true; continue; }
    if (p.state === "queued" && p.seen && p.delivery && !waiting.has(p.delivery)) { out.push({ ...p, state: "sent", sentAt: now }); changed = true; continue; }
    if (p.state === "sent" && now - (p.sentAt ?? p.at) > WAKE_MS) { out.push({ ...p, state: "failed", why: "wake_timeout" }); changed = true; continue; }
    out.push(p);
  }
  return changed ? out : pending;
}

// The entry's answer to a line.
export function afterSay(p: Pending, r: { ok: boolean; delivery?: string; state?: string; reason?: string; code?: string }, now: number): Pending {
  if (!r.ok) return { ...p, state: "failed", why: r.code || "offline" };
  const delivery = r.delivery || p.delivery;
  if (r.state === "queued") return { ...p, delivery, state: "queued", why: r.reason || "busy" };
  if (r.state === "refused") return { ...p, delivery, state: "failed", why: r.reason || "refused", returned: true };
  return { ...p, delivery, state: "sent", sentAt: now };
}

// Why a line waits, under it (faded).
// waking: a parked session coming back — the line shows as it will land (「回答中」), no wait
export const waking = (why = "") => why === "waking";
export function waitWords(why = ""): string {
  if (why === "typing" || why === "draft") return tr("终端里有人正在输入，等他发出后再送", "Someone is typing in the terminal — sends after they do");
  if (why === "asking") return tr("先回答上面的问题，答完就发出", "Answer the question above first; it sends after");
  return tr("等这一轮说完就发出", "Sends when this turn ends");
}

// Why a line did not go through, in the composer — and whether 重试 can help.
export function failWords(why = ""): { text: string; retry: boolean } {
  if (why === "wake_timeout" || why === "wake_failed" || why === "timeout" || why === "expired")
    return { text: tr("这一句没送到：会话没能在 20 秒内回来。", "This message didn't go through: the session didn't come back within 20 s."), retry: true };
  if (why === "home_down" || why === "offline" || why === "home_reconnecting")
    return { text: tr("这一句没送到：家机器暂时连不上。", "This message didn't go through: your machine is out of reach."), retry: true };
  if (why === "start_blocked")
    return { text: tr("这一句没送到：这个会话没能启动，停在了一个网页里按不了的提示上。", "This message didn't go through: this session never started — it is stuck on a prompt the web cannot answer."), retry: false };
  if (why === "unreachable")
    return { text: tr("这一句没送到：这个会话现在没有响应。", "This message didn't go through: this session is not responding."), retry: true };
  if (why === "budget") return { text: tr("这一句没送到：额度用完了。", "This message didn't go through: the limit is used up."), retry: false };
  if (why === "old_session" || why === "old_version" || why === "old_agent" || why === "old_service" || why === "cannot_talk")
    return { text: tr("这一句没送到：这个会话还旧，网页上说不了。", "This message didn't go through: this session is too old to talk to from the web."), retry: false };
  if (why === "session_changed") return { text: tr("这一句没送到：会话换了一段新的对话。", "This message didn't go through: the session started a new conversation."), retry: true };
  if (why === "gone" || why === "no_session" || why === "exited")
    return { text: tr("这一句没送到：这个会话已经不在了。", "This message didn't go through: this session is gone."), retry: false };
  return { text: tr("这一句没送到。", "This message didn't go through."), retry: true };
}

// The lines drawn after the record: what this page said and is waiting on, and
// what the session holds queued from elsewhere (another tab). `wait` is the
// faded line's words; none = it shows as it will land.
export type Bubble = { id: string; text: string; pics: string[]; wait?: string };
export function bubbles(pending: Pending[], queue: Queued[] | undefined): Bubble[] {
  const mine = new Set(pending.map((p) => p.delivery).filter(Boolean));
  const why = new Map(waitingIn(queue).map((q) => [q.delivery, q.why || ""]));
  const out: Bubble[] = pending.filter((p) => !p.returned).map((p) => {
    const w = p.delivery && why.has(p.delivery) ? why.get(p.delivery) : p.why;
    return { id: p.id, text: p.text, pics: p.pics, ...(p.state === "queued" && !waking(w) ? { wait: waitWords(w) } : {}) };
  });
  for (const q of waitingIn(queue)) if (!mine.has(q.delivery)) out.push({ id: `q-${q.delivery}`, text: q.text, pics: [], ...(waking(q.why) ? {} : { wait: waitWords(q.why) }) });
  return out;
}

// a line on its way counts as the session answering: sent, or queued while it wakes
export const replying = (pending: Pending[], queue: Queued[] | undefined) => {
  const why = new Map((queue || []).map((q) => [q.delivery, q.why || ""]));
  return pending.some((p) => p.state === "sending" || p.state === "sent" || (p.state === "queued" && waking(p.delivery ? why.get(p.delivery) ?? p.why : p.why)));
};

// the session's question as the chat's ask (rides on the step it gates): its
// fingerprint is the rid an answer names
export function askOf(a: ViewAsk | null | undefined): { t: "ask"; rid: string; kind: "question" | "permission"; questions?: ViewAsk["questions"]; tool?: string; summary?: string } | null {
  if (!a?.fp) return null;
  return { t: "ask", rid: a.fp, kind: a.kind === "permission" ? "permission" : "question", ...(a.questions ? { questions: a.questions } : {}),
    ...(a.tool ? { tool: a.tool } : {}), ...(a.summary ? { summary: a.summary } : {}) };
}
