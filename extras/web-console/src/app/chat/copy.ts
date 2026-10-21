// The entry's copy of the conversation (task V9DJ D): GET
// /v1/chat/conversation?cached=1. With none to give the entry answers 200
// {"items": [], "mirror": null} (task J091) — no copy yet is no error, the page
// just waits for the home's answer.

/** The copy in a cached answer, or null when the answer carries none. */
export function cachedCopy<T extends { mirror?: unknown }>(ok: boolean, j: T | null): T | null {
  if (!ok || !j || typeof j !== "object" || !j.mirror) return null;
  return j;
}
