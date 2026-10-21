// legacy.ts — where every old member-side address goes now (GR5E C9): the ONE
// table, read by routes.tsx (each old path a <Navigate replace>) and held by
// test/legacy.mjs row by row. A bookmark, a notice's link, ⌘P's and a home
// screen's shortcut all still open — on the page that holds it now:
//
//   /usage /devices /settings → 我的's tab · /me → 账号
//   /tasks                    → the list; ?q= <ref> → that session
//   /sessions?q= <ref>        → that session (bare /sessions is still 会话's
//                               full page, ?open= its own row)
//   /terminal                 → your Shell's session; ?worker= <id> → that
//                               session's terminal
//
// The query (bar the key that became the path) and the hash ride along: a
// sign-in flow comes back to /settings#logins, ?tab= picks the tab.

// The Shell — the home's own terminal — as a session's ref: its address is
// /s/shell?view=term. Never a code (four characters) nor an identity.
export const SHELL_REF = "shell";

// The new addresses, spelled here once.
export const LIST_PATH = "/";
export const sessionRefPath = (ref: string, view?: "chat" | "term") => `/s/${encodeURIComponent(ref)}${view ? `?view=${view}` : ""}`;
export const shellPath = (extra = "") => `${sessionRefPath(SHELL_REF, "term")}${extra ? `&${extra}` : ""}`;
export const terminalPath = (worker: string) => sessionRefPath(worker, "term");

// to = path + what is left of the query (a "?" or "&" already in `path` kept) + hash
function join(path: string, q: URLSearchParams, hash: string) {
  const rest = q.toString();
  return `${path}${rest ? (path.includes("?") ? "&" : "?") + rest : ""}${hash}`;
}

// One row per old path: what it becomes, given its query (mutated: a key the
// path took is deleted) — null: not moved, the page there serves it.
const ME = (tab: string) => () => `/me/${tab}`;
export const LEGACY: Record<string, (q: URLSearchParams) => string | null> = {
  "/me": ME("account"),
  "/usage": ME("usage"),
  "/devices": ME("devices"),
  "/settings": ME("settings"),
  "/tasks": (q) => { const to = session(q); q.delete("q"); return to || LIST_PATH; },
  "/sessions": session,
  "/terminal": (q) => {
    const w = q.get("worker");
    q.delete("worker");
    return w === null ? sessionRefPath(SHELL_REF, "term") : w ? terminalPath(w) : LIST_PATH;
  },
};
function session(q: URLSearchParams) {
  const ref = (q.get("q") || "").trim();
  if (!ref) return null;
  q.delete("q");
  return sessionRefPath(ref);
}

// legacyTarget(path, search, hash): where an old address lands, null for one
// that is not old.
export function legacyTarget(path: string, search = "", hash = ""): string | null {
  const row = LEGACY[path.replace(/\/+$/, "") || "/"];
  if (!row) return null;
  const q = new URLSearchParams(search);
  const to = row(q);
  return to === null ? null : join(to, q, hash);
}
