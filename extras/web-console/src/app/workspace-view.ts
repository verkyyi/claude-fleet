// workspace-view.ts — one session's workspace (GR5E C4), the rules apart from the
// page: which way it is looked at (/s/<ref>?view=chat|term), how long a
// terminal left in the background stays connected, whether it has one at all.
import type { Row } from "./work";

export type View = "chat" | "term";

// ?view=term is the terminal; anything else — none, chat, a typo — the
// conversation: a session opened in a terminal is read along there first, and
// 新建's 终端 comes here with ?view=term (GR5E C3).
export const viewOf = (param: string | null): View => (param === "term" ? "term" : "chat");

// Switched to 对话, the terminal stays connected behind it this long: back
// within it, the same screen, never a reconnect.
export const KEEP_MS = 60_000;

// The terminal is there while it is looked at, or was left less than KEEP_MS ago.
export const termKept = (view: View, leftAt: number | null, now = Date.now()) =>
  view === "term" || (leftAt !== null && now - leftAt < KEEP_MS);

// What the 终端 side shows: its terminal (the live session's worker), it is
// still opening (started from 新建, not up yet), or it has ended.
export type TermState = { kind: "live"; worker: string } | { kind: "opening" } | { kind: "ended" };
export function termOf(r: Row): TermState {
  if (r.live) return { kind: "live", worker: r.live.id };
  return r.group === "gone" ? { kind: "ended" } : { kind: "opening" };
}

// A phone on its side: the terminal takes the whole screen, one line of head.
export const LANDSCAPE = "(orientation: landscape) and (max-height: 500px)";
