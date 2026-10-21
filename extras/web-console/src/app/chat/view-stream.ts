// view-stream.ts — the pure half of 只读 (task F481, view.ts): one SSE block
// read, and one {t:"items", from, items} batch laid onto what the page holds,
// so a page that came back with ?from= never shows a line twice.

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

// what the page holds: items[0] is the record's item `base`, and it holds `n`
export type Held = { base: number; n: number };
// a batch starting at `from`: either the whole view starts again there (the first
// answer, the last 600 only; or a gap) or only what is past the end is new
export function mergeView<T>(h: Held, from: number, add: T[]): { replace: boolean; held: Held; fresh: T[] } {
  const end = h.base + h.n;
  if (from > end || (h.n === 0 && from !== h.base)) return { replace: true, held: { base: from, n: add.length }, fresh: add };
  const fresh = add.slice(Math.max(0, end - from));
  return { replace: false, held: { base: h.base, n: h.n + fresh.length }, fresh };
}
