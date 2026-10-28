import type { Item } from "./chat";
import type { Frame, Held } from "./view-stream";

// Read backwards on demand without moving the conversation's visible scroll.
// Cached/latest pages are not evidence of the first message. Never substitute one.
export async function firstUserMessage(held: Held, items: Item[], page: (before: number) => Promise<Frame>): Promise<string> {
  if (held.at < 0 || !held.session) throw new Error("history unavailable");
  let cursor = held.older;
  let first = items.find(i => i.t === "user");
  for (let n = 0; cursor > 0; n++) {
    if (n >= 200) throw new Error("history too long");
    const older = await page(cursor);
    if (older.session !== held.session || !Array.isArray(older.items) || typeof older.older !== "number" || older.older < 0 || older.older >= cursor) throw new Error("history changed");
    first = (older.items as Item[]).find(i => i.t === "user") ?? first;
    cursor = older.older;
  }
  if (!first || first.t !== "user" || !first.text.trim()) throw new Error("first message has no text");
  return first.text;
}
