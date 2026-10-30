// files.ts — 附件 (task GXR5): a file the person sends with a line. A picture
// stays a picture (pics.ts); anything else goes up BY ITSELF when the line is
// sent — POST /v1/chat/upload?worker=<id> (the session's login), the bytes as
// the body, its name in X-Fleet-File-Name — and the line names it {ref, name}.
// The service hands the agent the kept file's path as one line under the words,
//   [附件] 报告.pdf → /…/webchat/uploads/<ref>/报告.pdf
// which the page shows as 「📎 报告.pdf」 (showAttach) and leaves out when it
// matches its own line against the record (attachFree). Pure but the adapter.
import type { AppendMessage, AttachmentAdapter, CompleteAttachment, PendingAttachment } from "@assistant-ui/react";
import { tr } from "../../shared/i18n.ts"; // .ts: the test runs this file as it is

export const MAX_FILES = 5;
export const FILE_MAX = 20 * 1024 * 1024;
const REF_RE = /^[0-9a-f]{32}$/;
const ATTACH_LINE = /^\[附件\] (.+?) → \S.*$/gm;

export type SentFile = { ref: string; name: string };

// the files attached to a message, uploaded: the adapter's file parts carry the ref
export function attachedFiles(m: Pick<AppendMessage, "attachments">): SentFile[] {
  const out: SentFile[] = [];
  for (const a of m.attachments || []) for (const c of a.content || []) {
    if (c.type === "file" && REF_RE.test(c.data)) out.push({ ref: c.data, name: c.filename || a.name });
  }
  return out;
}

// the record's words for a line, its file lines shown as 「📎 name」
export const showAttach = (text: string) => text.replace(ATTACH_LINE, (_, name: string) => `📎 ${name}`);
// the record's words without its file lines: what the person typed
export const attachFree = (text: string) => text.replace(ATTACH_LINE, "").trim();
// what this page draws for a line it said, before the record has it
export const sentWords = (text: string, files: SentFile[] = []) =>
  [text, files.map((f) => `📎 ${f.name}`).join("\n")].filter(Boolean).join("\n\n");

// the adapter: last in the composite (accept "*"), after the pictures'
export class UploadAdapter implements AttachmentAdapter {
  accept = "*";
  target: () => string;
  constructor(target: () => string) { this.target = target; }
  async add({ file }: { file: File }): Promise<PendingAttachment> {
    const big = file.size > FILE_MAX;
    return { id: crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`, type: "file", name: file.name, contentType: file.type, file,
      status: big ? { type: "incomplete", reason: "error", message: tr("文件太大：一个最多 20 MB", "Too large: 20 MB at most") }
        : { type: "requires-action", reason: "composer-send" } };
  }
  async send(a: PendingAttachment, options?: { signal?: AbortSignal }): Promise<CompleteAttachment> {
    if (a.file.size > FILE_MAX) throw new Error(tr("文件太大：一个最多 20 MB", "Too large: 20 MB at most"));
    const r = await fetch(`/v1/chat/upload?${this.target()}`, {
      method: "POST", cache: "no-store", signal: options?.signal, body: a.file,
      headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/octet-stream", "X-Fleet-File-Name": encodeURIComponent(a.file.name) },
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !REF_RE.test(String(j.ref || ""))) throw new Error(String(j.error || tr("文件没传上去，再试一次", "The file didn't upload; try again")));
    return { ...a, status: { type: "complete" },
      content: [{ type: "file", data: String(j.ref), filename: String(j.name || a.name), mimeType: a.contentType || "application/octet-stream" }] };
  }
  async remove(): Promise<void> {}
}
