// chat.ts — the one conversation (issue #3567), as assistant-ui's external store
// (issue #3637). The server's protocol is unchanged: GET /api/conversation for
// the whole history, POST /api/turn streams NDJSON items, /api/stop, /api/answer.
// This file only turns those items into ThreadMessageLike[] for the components.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  useExternalStoreRuntime,
  type AppendMessage,
  type RespondToToolApprovalOptions,
  type ThreadMessageLike,
} from "@assistant-ui/react";

type Item =
  | { t: "user"; text: string }
  | { t: "text"; d: string }
  | { t: "tool"; id: string; name: string; summary?: string }
  | { t: "tool_result"; id: string; text?: string; error?: boolean }
  | { t: "stopped" }
  | { t: "error"; msg: string };

type Question = {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options?: { label: string; description?: string }[];
};
export type Ask = {
  t: "ask";
  rid: string;
  id?: string; // the tool_use it gates, when the server knows it
  kind: "question" | "permission";
  questions?: Question[];
  tool?: string;
  summary?: string;
};
type Answered = { approved: boolean; answers?: Record<string, { optionIds: string[] }> };
export type Model = { id: string; label: string };

const H = { "X-Fleet-Webchat": "1", "Content-Type": "application/json" };
type Part = Exclude<ThreadMessageLike["content"], string>[number];
type Msg = { id: string; role: "user" | "assistant"; content: Part[]; status?: ThreadMessageLike["status"] };

// items → messages: a user line is one message, everything after it up to the
// next user line is the assistant's (text, folded tool steps, the asks).
function toMessages(items: Item[], asks: Ask[], answered: Map<string, Answered>): Msg[] {
  const out: Msg[] = [];
  let cur: Msg | null = null;
  const tools = new Map<string, Record<string, unknown>>();
  const assistant = (i: number) => {
    if (!cur) { cur = { id: `a${i}`, role: "assistant", content: [] }; out.push(cur); }
    return cur;
  };
  items.forEach((it, i) => {
    switch (it.t) {
      case "user":
        cur = null;
        out.push({ id: `u${i}`, role: "user", content: [{ type: "text", text: it.text }] });
        break;
      case "text": {
        const m = assistant(i);
        const last = m.content[m.content.length - 1] as { type: string; text?: string } | undefined;
        if (last?.type === "text") m.content[m.content.length - 1] = { type: "text", text: (last.text || "") + it.d };
        else m.content.push({ type: "text", text: it.d });
        break;
      }
      case "tool": {
        // the gist rides in args.summary (the folded line); no raw-args block under it
        const p = { type: "tool-call", toolCallId: it.id, toolName: it.name, args: { summary: it.summary || it.name }, argsText: "" } as Record<string, unknown>;
        tools.set(it.id, p);
        assistant(i).content.push(p as Part);
        break;
      }
      case "tool_result": {
        let p = tools.get(it.id);
        if (!p) {
          p = { type: "tool-call", toolCallId: it.id, toolName: "工具结果", args: {}, argsText: "" };
          tools.set(it.id, p);
          assistant(i).content.push(p as Part);
        }
        p.result = it.text || "(空)";
        p.isError = !!it.error;
        break;
      }
      case "stopped":
        assistant(i).status = { type: "incomplete", reason: "cancelled" };
        cur = null;
        break;
      case "error":
        assistant(i).status = { type: "incomplete", reason: "error", error: it.msg };
        cur = null;
        break;
    }
  });
  // what the agent is asking right now rides on the tool step it gates
  for (const a of asks) {
    const done = answered.get(a.rid);
    const approval = a.kind === "question"
      ? {
          id: a.rid, display: "questions" as const,
          questions: (a.questions || []).map((q) => ({
            id: q.question, prompt: q.question, ...(q.header ? { header: q.header } : {}), multiple: !!q.multiSelect,
            options: (q.options || []).map((o) => ({ id: o.label, label: o.label, ...(o.description ? { description: o.description } : {}) })),
          })),
          ...(done ? { approved: done.approved, ...(done.answers ? { answers: done.answers } : {}) } : {}),
        }
      : {
          id: a.rid, prompt: `要用工具：${a.summary || a.tool}`,
          ...(done ? { approved: done.approved } : {}),
        };
    let p = a.id ? tools.get(a.id) : undefined;
    if (!p) {
      p = { type: "tool-call", toolCallId: a.id || a.rid, toolName: a.kind === "question" ? "AskUserQuestion" : a.tool || "工具",
        args: { summary: a.summary || "" }, argsText: "" };
      const m: Msg = out[out.length - 1]?.role === "assistant" ? out[out.length - 1] : (out.push({ id: `a-${a.rid}`, role: "assistant", content: [] }), out[out.length - 1]);
      m.content.push(p as Part);
      tools.set(String(p.toolCallId), p);
    }
    // the message keeps its own status (running): flipping it to requires-action
    // mid-stream freezes assistant-ui's smooth text reveal — the step opens itself
    // instead (App.tsx ToolStep, thread.aui.tsx PendingToolGroup)
    p.approval = approval;
  }
  return out;
}

async function readLines(r: Response, onItems: (items: Record<string, unknown>[]) => void) {
  const rd = r.body!.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await rd.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const batch: Record<string, unknown>[] = [];
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line) batch.push(JSON.parse(line));
    }
    if (batch.length) onItems(batch);
  }
}

export function useFleetChat() {
  const [items, setItems] = useState<Item[]>([]);
  const [asks, setAsks] = useState<Ask[]>([]);
  const [answered, setAnswered] = useState<Map<string, Answered>>(new Map());
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [models, setModels] = useState<Model[]>([]);
  const [model, setModelState] = useState("");
  const [resume, setResume] = useState<{ id: string; cwd: string } | null>(null);
  const [notice, setNotice] = useState("");
  const turnId = useRef<string | null>(null);
  const streaming = useRef(false);
  const follow = useRef<number | undefined>(undefined);

  const load = useCallback(async () => {
    clearTimeout(follow.current);
    const r = await fetch("/api/conversation", { headers: H });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { setNotice(j.error || "读不到对话"); setLoaded(true); return; }
    setNotice("");
    setModels(j.models || []);
    setModelState((m) => {
      if (m) return m;
      const saved = localStorage.getItem("fwc-model");
      return (j.models || []).some((x: Model) => x.id === saved) ? saved! : j.default;
    });
    setItems(j.items || []);
    setAsks(j.asks || []);
    setResume(j.session ? { id: j.session, cwd: j.cwd } : null);
    setBusy(!!j.busy);
    turnId.current = j.turn || null;
    setLoaded(true);
    // a turn this page did not start (or lost): follow it
    if (j.busy && !streaming.current) follow.current = window.setTimeout(load, 2500);
  }, []);

  useEffect(() => {
    load();
    const vis = () => { if (!document.hidden && !streaming.current) load(); };
    document.addEventListener("visibilitychange", vis);
    return () => document.removeEventListener("visibilitychange", vis);
  }, [load]);

  const setModel = useCallback((m: string) => { setModelState(m); localStorage.setItem("fwc-model", m); }, []);

  const onNew = useCallback(async (message: AppendMessage) => {
    const text = message.content.map((p) => (p.type === "text" ? p.text : "")).join("").trim();
    if (!text) return;
    clearTimeout(follow.current);
    streaming.current = true;
    setItems((xs) => [...xs, { t: "user", text }]);
    setAsks([]);
    setBusy(true);
    let lost = false;
    try {
      const r = await fetch("/api/turn", { method: "POST", headers: H, body: JSON.stringify({ text, model }) });
      if (!r.ok) {
        const j = await r.json().catch(() => ({}));
        setItems((xs) => [...xs, { t: "error", msg: String(j.error || r.status) }]);
        return;
      }
      await readLines(r, (batch) => {
        const add: Item[] = [];
        const newAsks: Ask[] = [];
        for (const o of batch) {
          switch (o.t) {
            case "turn": turnId.current = String(o.id); break;
            case "session": setResume({ id: String(o.id), cwd: String(o.cwd || "") }); break;
            case "ask": newAsks.push(o as unknown as Ask); break;
            case "done": break;
            default: add.push(o as unknown as Item);
          }
        }
        if (add.length) setItems((xs) => [...xs, ...add]);
        if (newAsks.length) setAsks((xs) => [...xs, ...newAsks.filter((a) => !xs.some((x) => x.rid === a.rid))]);
      });
    } catch {
      lost = true;
    } finally {
      streaming.current = false;
      setBusy(false);
      turnId.current = null;
    }
    // the line dropped; the turn goes on — pick it back up. A finished turn
    // reloads too: the transcript is the record, the stream was only its preview.
    if (lost) load(); else setAsks([]);
  }, [model, load]);

  const onCancel = useCallback(async () => {
    if (turnId.current) await fetch("/api/stop", { method: "POST", headers: H, body: JSON.stringify({ turn: turnId.current }) });
  }, []);

  const onRespondToToolApproval = useCallback(async (o: RespondToToolApprovalOptions) => {
    const a = asks.find((x) => x.rid === o.approvalId);
    if (!a) return;
    let payload: Record<string, unknown>;
    let answers: Record<string, { optionIds: string[] }> | undefined;
    if (a.kind === "question") {
      const out: Record<string, string> = {};
      answers = {};
      for (const [q, ans] of Object.entries(o.answers || {})) {
        const picked = [...(ans.optionIds || []), ...(ans.text ? [ans.text] : [])];
        out[q] = picked.join(", ");
        answers[q] = { optionIds: [...(ans.optionIds || [])] };
      }
      payload = { answers: out };
    } else {
      payload = { allow: o.approved };
    }
    setAnswered((m) => new Map(m).set(a.rid, { approved: a.kind === "question" ? true : o.approved, ...(answers ? { answers } : {}) }));
    await fetch("/api/answer", { method: "POST", headers: H, body: JSON.stringify({ rid: a.rid, ...payload }) });
  }, [asks]);

  const messages = useMemo(() => toMessages(items, asks, answered), [items, asks, answered]);

  const runtime = useExternalStoreRuntime<Msg>({
    messages,
    convertMessage: (m) => m as ThreadMessageLike,
    isRunning: busy,
    isLoading: !loaded,
    onNew,
    onCancel,
    onRespondToToolApproval,
  });

  return { runtime, models, model, setModel, resume, notice };
}
