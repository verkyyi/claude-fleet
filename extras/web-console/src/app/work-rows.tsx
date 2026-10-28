// work-rows.tsx — the session list's ONE data source for the whole app (GR5E
// C2): the person's task records and sessions, read once (one stream, one
// watchdog) and joined into work.ts's rows — the hub's board (A4G2) when it
// sent one, the page's own join for an older hub. The left column, the phone's
// list, a session's page and 会话 all read it here; none reads its own copy.
// It also keeps which rows the person has opened (this browser), so a new or
// moved-on row reads bold.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type FC, type ReactNode } from "react";
import { useSessions, type Board, type SessionRow } from "@/shared/sessions";
import { useTasks } from "./use-tasks";
import { boardRows, buildRows, type Row } from "./work";
import { machineCount, repliesDone, seenMark } from "./session-list";
import { NET_BACK } from "@/shared/net";
import { meOnce } from "@/shared/api";
import { viewAs } from "@/shared/viewAs";
import { mayCache } from "./chat/local";
import { browserListCache, markListFirst } from "./list-local";

type WorkRows = {
  rows: Row[] | null;
  board: Board | null;
  boardAt: number;
  live: SessionRow[] | null;
  failed: boolean;      // nothing could be read at all
  stale: boolean;       // the task records are last-known
  tasks: ReturnType<typeof useTasks>;
  reload: () => void;
  seen: Record<string, string>;
  markSeen: (r: Row) => void;
  // 新回复 (会话合一 Y01K; WD8F ②): rows that finished a reply the person has
  // not opened since — an orange dot and the word in the list — and the last
  // one to finish, for the one line on top (「X」答完了 · 去看)
  replied: Record<string, string>;
  done: { row: Row; at: number } | null;
  setOpenRow: (id: string) => void;
  machines: number;     // the person's machines: one ⇒ no machine name is drawn
};
const Ctx = createContext<WorkRows | null>(null);
export const useWorkRows = () => useContext(Ctx)!;

const SEEN_KEY = "fleet.console.seen";
const REPLIED_KEY = "fleet.console.replied";
// hidden this long, the list is read again on the way back
const BACK_AFTER_MS = 15_000;
function readSeen(): Record<string, string> | null {
  try { const v = JSON.parse(localStorage.getItem(SEEN_KEY) || "null"); return v && typeof v === "object" ? v : null; } catch { return null; }
}

function saveSeen(v: Record<string, string>, key = SEEN_KEY) {
  try { localStorage.setItem(key, JSON.stringify(v)); } catch { /* private mode */ }
}
function readReplied(): Record<string, string> {
  try { const v = JSON.parse(localStorage.getItem(REPLIED_KEY) || "{}"); return v && typeof v === "object" ? v : {}; } catch { return {}; }
}

export const WorkRowsProvider: FC<{ children: ReactNode }> = ({ children }) => {
  const tasks = useTasks();
  const { live, ended, board, boardAt, failed, reload, etag, fresh, prime } = useSessions(tasks.accept, tasks.reload);
  const rows = useMemo(() => (live && tasks.data ? (board ? boardRows(board, tasks.data.tasks, live, ended || [])
    : buildRows(tasks.data.tasks, live, ended || [])) : null), [live, ended, board, tasks.data]);

  // the list this browser kept (task T47B): read beside /v1/me (no other
  // network), drawn only when /v1/me names the same person on their own page —
  // never a view, never a read-only ticket — and only until the hub answers;
  // the same rows by the same ids, so the answer that replaces it moves nothing
  // that did not change
  const keeper = useRef("");
  useEffect(() => {
    const kept = browserListCache()?.readAny().catch(() => null) ?? Promise.resolve(null);
    let gone = false;
    void meOnce().then(async (me) => {
      if (!mayCache(me, viewAs)) return;
      keeper.current = me!.person!;
      const any = await kept;
      if (gone || !any || any.principal !== me!.person) return;
      const s = any.snap;
      if (prime({ live: s.live, ended: s.ended, board: s.board, etag: s.etag, at: s.at })) tasks.seed(s.tasks);
    }).catch(() => {});
    return () => { gone = true; };
    // once, at the page's opening
  }, []);
  useEffect(() => { if (rows) markListFirst(fresh ? "net" : "local"); }, [rows, fresh]);
  // what the hub said is kept for next time — at most once a second, never a
  // task read the hub marked incomplete
  useEffect(() => {
    if (!fresh || tasks.loading || !keeper.current || !live || !tasks.data || tasks.data.stale) return;
    const snap = { live, ended, board, etag, tasks: tasks.data };
    const who = keeper.current;
    const t = window.setTimeout(() => { void browserListCache()?.write(who, snap).catch(() => {}); }, 1000);
    return () => clearTimeout(t);
  }, [fresh, live, ended, board, etag, tasks.data, tasks.loading]);

  // first visit in this browser: what is there now counts as seen
  const [stored, setStored] = useState(readSeen);
  useEffect(() => {
    if (stored || !rows) return;
    const first = Object.fromEntries(rows.map((r) => [r.id, seenMark(r)]));
    setStored(first);
    saveSeen(first);
  }, [stored, rows]);
  const seen = useMemo(() => stored || {}, [stored]);
  const [replied, setReplied] = useState(readReplied);
  const markSeen = useCallback((r: Row) => {
    setStored(() => {
      // only the rows still listed are kept: the book never outgrows the list
      const next: Record<string, string> = {};
      for (const x of rows || []) if (seen[x.id]) next[x.id] = seen[x.id];
      next[r.id] = seenMark(r);
      saveSeen(next);
      return next;
    });
    setReplied((old) => {
      if (!old[r.id]) return old;
      const next = { ...old };
      delete next[r.id];
      saveSeen(next, REPLIED_KEY);
      return next;
    });
  }, [seen, rows]);

  // a reply that finished: the row's glyph left 「回答中」 between two reads —
  // never on the first read, never for the session the person is looking at
  const glyphs = useRef<Record<string, string> | null>(null);
  const openRow = useRef("");
  const setOpenRow = useCallback((id: string) => { openRow.current = id; }, []);
  const [done, setDone] = useState<{ row: Row; at: number } | null>(null);
  useEffect(() => {
    if (!rows) return;
    // what this browser kept is not a read: only two of the hub's answers compare
    const prev = glyphs.current;
    glyphs.current = fresh ? Object.fromEntries(rows.map((r) => [r.id, r.glyph])) : null;
    if (!prev || !fresh) return;
    const fin = repliesDone(prev, rows).filter((r) => !r.board?.archived && r.id !== openRow.current);
    if (!fin.length) return;
    setReplied((old) => {
      const next: Record<string, string> = {};
      for (const x of rows) if (old[x.id]) next[x.id] = old[x.id];
      for (const r of fin) next[r.id] = seenMark(r);
      saveSeen(next, REPLIED_KEY);
      return next;
    });
    setDone({ row: fin[fin.length - 1], at: Date.now() });
  }, [rows, fresh]);

  const reloadAll = useCallback(() => { reload(); tasks.reload(); }, [reload, tasks]);
  // back from the background (WeChat freezes a hidden page: its stream and
  // timers stop) or the network back (NetBar): read the list again at once,
  // so what shows is now, not when the page left (GR5E C8)
  const again = useRef(reloadAll);
  again.current = reloadAll;
  useEffect(() => {
    let hidAt = 0;
    const now = () => again.current();
    const vis = () => {
      if (document.visibilityState === "hidden") { hidAt = Date.now(); return; }
      if (hidAt && Date.now() - hidAt >= BACK_AFTER_MS) now();
      hidAt = 0;
    };
    document.addEventListener("visibilitychange", vis);
    window.addEventListener(NET_BACK, now);
    return () => { document.removeEventListener("visibilitychange", vis); window.removeEventListener(NET_BACK, now); };
  }, []);
  const value: WorkRows = {
    rows, board, boardAt, live, tasks, seen, markSeen, reload: reloadAll, replied, done, setOpenRow,
    machines: typeof board?.machines === "number" ? board.machines : machineCount(rows),
    failed: (failed && !live) || (tasks.failed && !tasks.data), stale: !!(tasks.failed || tasks.data?.stale),
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
};
