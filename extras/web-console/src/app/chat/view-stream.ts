// view-stream.ts — the pure half of 只读 (task F481, view.ts): one SSE block
// read, and one {t:"items"} frame laid onto what the page holds. A frame is
// either the newest stretch of the record, in place of what the page had
// (replace: the first answer, a conversation changed), or what was added since
// the byte the page holds (at) — so a page back with ?at= never shows a line
// twice (task YP39: a byte cursor; the record is read from its end).

// Unknown capability is a connection in progress, not an old terminal session.
// An older service omits can_talk; it remains read-only. Only true enables send.
export type ViewConnection = "checking" | "live" | "offline";
export function writeAccess(state: { can_talk?: boolean | null; talk_reason?: string } | null, allowed: boolean | null, connection: ViewConnection = "live") {
  if (allowed === false) return "readonly";
  if (allowed === null) return "checking";
  if (connection === "offline" || state?.talk_reason === "unreachable") return "offline";
  if (connection === "checking" || !state || state.can_talk === null || state.talk_reason === "checking") return "checking";
  return state.can_talk === true ? "writable" : "readonly";
}

// one SSE block → its id and its data (the service writes one data line per event)
export function parseEvent(block: string): { id?: number; data?: Record<string, unknown> } {
  let id: number | undefined, data = "";
  for (const line of block.split("\n")) {
    if (line.startsWith("id:")) id = Number(line.slice(3).trim());
    else if (line.startsWith("data:")) data += line.slice(5).trimStart();
  }
  if (!data) return { id };
  try { return { id, data: JSON.parse(data) }; } catch { return { id }; }
}

// what the page holds of the session's machine's answer: the byte it read to,
// in which conversation, and where the next older page ends (0: none older).
// at < 0: nothing from the machine yet (a local or a copy may be on screen).
export type Held = { at: number; session: string; older: number };
export const NOTHING: Held = { at: -1, session: "", older: 0 };

export type Frame = { replace?: boolean; items?: unknown[]; at?: number; older?: number; session?: string };

// a frame onto what the page holds: the items to show now, or null when the
// frame changes nothing on screen
export function applyFrame<T>(h: Held, cur: T[], f: Frame): { held: Held; items: T[] | null } {
  const add = (f.items || []) as T[];
  const at = Number(f.at) || 0, session = String(f.session || "");
  if (f.replace || h.at < 0 || session !== h.session) {
    return { held: { at, session, older: Number(f.older) || 0 }, items: add };
  }
  // a stretch the page holds already (a frame for a byte it read past)
  if (at <= h.at) return { held: h, items: null };
  return { held: { ...h, at }, items: add.length ? [...cur, ...add] : null };
}

// one page further back (?before=) onto what the page holds: only when it is
// the page asked for, of the same conversation
export function prependOlder<T>(h: Held, cur: T[], asked: number, page: { items?: unknown[]; older?: number; session?: string }): { held: Held; items: T[] } | null {
  if (asked !== h.older || String(page.session || "") !== h.session || h.at < 0) return null;
  return { held: { ...h, older: Number(page.older) || 0 }, items: [...((page.items || []) as T[]), ...cur] };
}
