// pics.ts — the pictures a person sends with a line (task T773 ③). Each goes
// through the browser's own canvas before it leaves: the long side at most
// LONG (Claude reads no more than that), JPEG, and small enough that every
// picture plus the words fit the chat's one request (1 MB, its transport's
// bound) — the quality steps down, then the size, until it does.
import type { AppendMessage } from "@assistant-ui/react";

export const MAX_PICS = 4;
const LONG = 1568;
const BODY = 1024 * 1024 - 8 * 1024;                     // the request, less room for the words and the envelope

export type SentPic = { media_type: string; data: string };

// the data URLs of the pictures attached to a message (assistant-ui keeps each
// as an image part: SimpleImageAttachmentAdapter reads the file as a data URL)
export function attachedPics(m: AppendMessage): string[] {
  const out: string[] = [];
  for (const a of m.attachments || []) for (const c of a.content || []) if (c.type === "image" && c.image) out.push(c.image);
  for (const c of m.content) if (c.type === "image" && c.image) out.push(c.image);
  return out;
}

const load = (src: string) => new Promise<HTMLImageElement>((ok, no) => {
  const img = new Image();
  img.onload = () => ok(img);
  img.onerror = () => no(new Error("not an image"));
  img.src = src;
});

// one picture as JPEG base64, its base64 at most `budget` characters
async function shrink(src: string, budget: number): Promise<string> {
  const img = await load(src);
  let scale = Math.min(1, LONG / Math.max(img.naturalWidth, img.naturalHeight, 1));
  for (let tries = 0; tries < 12; tries++) {
    const c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(img.naturalWidth * scale));
    c.height = Math.max(1, Math.round(img.naturalHeight * scale));
    const g = c.getContext("2d")!;
    g.fillStyle = "#fff";                                  // a transparent screenshot reads on white
    g.fillRect(0, 0, c.width, c.height);
    g.drawImage(img, 0, 0, c.width, c.height);
    for (const q of [0.86, 0.76, 0.64, 0.52]) {
      const data = c.toDataURL("image/jpeg", q).split(",")[1] || "";
      if (data.length <= budget) return data;
    }
    scale *= 0.75;
  }
  throw new Error("picture too large");
}

// the pictures, ready for the request; the words' share of it comes off first
export async function packPics(srcs: string[], words: string): Promise<SentPic[]> {
  if (!srcs.length) return [];
  const left = BODY - new TextEncoder().encode(words).length * 2;
  const each = Math.floor(left / srcs.length);
  const out: SentPic[] = [];
  for (const s of srcs) out.push({ media_type: "image/jpeg", data: await shrink(s, each) });
  return out;
}
