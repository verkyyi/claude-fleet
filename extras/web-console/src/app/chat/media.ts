// media.ts — where the page reads what the home keeps for the conversation
// (task T773): an image by its ref, a linked file by its ref. Pure, so
// test/chat-media.mjs runs it as it is.

const FILE = "/v1/chat/file";

export type Pic = { ref?: string; w?: number; h?: number; thumb?: string };

// An image part's address: the home's file by its ref — ABSOLUTE, because
// assistant-ui keeps an image part only when its URL is https:, blob: or data:
// (fromThreadMessageLike drops "/v1/…" with a console warning and nothing on the
// page) — else the copy's preview (a data: URL).
export function picSrc(g: Pic, base: string = location.href): string {
  return g.ref ? new URL(`${FILE}?ref=${encodeURIComponent(g.ref)}`, base).href : g.thumb || "";
}

// a reply's Markdown link / image target the home gave a ref for → that file's address
export function linkFiles(text: string, files: Map<string, string>, base: string = location.href): string {
  if (!files.size) return text;
  return text.replace(/\]\(\s*<?([^)\s<>]+)>?((?:\s+"[^"]*")?\s*)\)/g, (all, target: string, rest: string) => {
    const ref = files.get(target);
    return ref ? `](${new URL(`${FILE}?ref=${encodeURIComponent(ref)}`, base).href}${rest})` : all;
  });
}
