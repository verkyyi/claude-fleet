// work-rows.tsx — the session list's ONE data source for the whole app (GR5E
// C2): the person's task records and sessions, read once (one stream, one
// watchdog) and joined into work.ts's rows — the hub's board (A4G2) when it
// sent one, the page's own join for an older hub. The left column, the phone's
// list, a session's page and 会话 all read it here; none reads its own copy.
// It also keeps which rows the person has opened (this browser), so a new or
// moved-on row reads bold.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type FC, type ReactNode } from "react";
import { useSessions, type Board, type SessionRow } from "@/shared/sessions";
import { useTasks } from "./use-tasks";
import { boardRows, buildRows, type Row } from "./work";
import { seenMark } from "./session-list";

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
};
const Ctx = createContext<WorkRows | null>(null);
export const useWorkRows = () => useContext(Ctx)!;

const SEEN_KEY = "fleet.console.seen";
function readSeen(): Record<string, string> | null {
  try { const v = JSON.parse(localStorage.getItem(SEEN_KEY) || "null"); return v && typeof v === "object" ? v : null; } catch { return null; }
}

function saveSeen(v: Record<string, string>) {
  try { localStorage.setItem(SEEN_KEY, JSON.stringify(v)); } catch { /* private mode */ }
}

export const WorkRowsProvider: FC<{ children: ReactNode }> = ({ children }) => {
  const tasks = useTasks();
  const { live, ended, board, boardAt, failed, reload } = useSessions(tasks.accept, tasks.reload);
  const rows = useMemo(() => (live && tasks.data ? (board ? boardRows(board, tasks.data.tasks, live)
    : buildRows(tasks.data.tasks, live, ended || [])) : null), [live, ended, board, tasks.data]);

  // first visit in this browser: what is there now counts as seen
  const [stored, setStored] = useState(readSeen);
  useEffect(() => {
    if (stored || !rows) return;
    const first = Object.fromEntries(rows.map((r) => [r.id, seenMark(r)]));
    setStored(first);
    saveSeen(first);
  }, [stored, rows]);
  const seen = useMemo(() => stored || {}, [stored]);
  const markSeen = useCallback((r: Row) => {
    setStored(() => {
      // only the rows still listed are kept: the book never outgrows the list
      const next: Record<string, string> = {};
      for (const x of rows || []) if (seen[x.id]) next[x.id] = seen[x.id];
      next[r.id] = seenMark(r);
      saveSeen(next);
      return next;
    });
  }, [seen, rows]);

  const reloadAll = useCallback(() => { reload(); tasks.reload(); }, [reload, tasks]);
  const value: WorkRows = {
    rows, board, boardAt, live, tasks, seen, markSeen, reload: reloadAll,
    failed: (failed && !live) || (tasks.failed && !tasks.data), stale: !!(tasks.failed || tasks.data?.stale),
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
};
