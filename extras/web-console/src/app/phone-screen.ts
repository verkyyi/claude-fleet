// phone-screen.ts — what a phone draws above each screen (GR5E C7). The list is
// the first screen and wears the top bar (the mark · the limit · search · the
// avatar into 我的); a session (/s/<ref>) and 新建 (/new) are whole screens with
// their own head (← · title · 对话 | 终端), so the shell draws nothing over them;
// every other screen (我的, the conversation, the old pages) gets a back bar —
// ← · its name · the limit. No bottom bar anywhere: screens move by the
// browser's history, and 返回 goes back to the screen before.

export type PhoneBar = "list" | "back" | "none";

// pathname is react-router's (under /app); search its query. A phone's
// /?about= is the conversation, not the list (routes.tsx Home).
export function phoneBar(pathname: string, search = ""): PhoneBar {
  const p = pathname.replace(/\/+$/, "") || "/";
  if (p === "/") return search ? "back" : "list";
  if (p === "/new" || p.startsWith("/s/")) return "none";
  return "back";
}

// Where 返回 goes: one step back when this tab has a step to go back to, else
// the list in place — never history.back() off the first entry, which in
// WeChat closes the page. `key` is react-router's location.key ("default" on
// the entry the tab opened on).
export function backStep(key: string | undefined): -1 | "/" {
  return key && key !== "default" ? -1 : "/";
}
