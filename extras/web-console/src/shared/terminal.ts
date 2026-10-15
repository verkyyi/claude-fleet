import { BrowserAttachment, BUFFER_MAX, FRAME_MAX, type AttachmentState } from "../../../browser-transport/attachment";

export const terminalLink = (worker: string) => `/terminal?worker=${encodeURIComponent(worker)}`;
export const FLEET_MENU = "\x1b[927~";
export const FLEET_SHELL = "\x1c"; // native Fleet Ctrl+\ toggle, including return

// Let xterm own keys and its hidden textarea, including IME. Returning false
// here leaves browser shortcuts to the browser; no keydown builds text.
export function terminalKey(event: KeyboardEvent, composing: boolean): boolean {
  if (composing || event.isComposing || event.keyCode === 229) return true;
  if (event.metaKey) return false;
  if (event.ctrlKey && (/[plwtnr]/i.test(event.key) && event.key.length === 1 || event.shiftKey && /[cv]/i.test(event.key))) return false;
  return true;
}

export type TerminalConnection = ReturnType<typeof connectTerminal>;
export function connectTerminal(worker: string | null, options: {
  signal: AbortSignal;
  onState: (s: AttachmentState) => void;
  onBytes: (bytes: Uint8Array) => void;
  onExit: () => void;
}) {
  const query = new URLSearchParams({ service: "term", ...(worker === null ? { target: "personal" } : { worker }) });
  const attachment = new BrowserAttachment({
    url: `/v1/attachment/connect?${query}`, signal: options.signal,
    onState: options.onState,
    onData(data) {
      // xterm's streaming UTF-8 decoder retains partial scalars across frames.
      if (data instanceof ArrayBuffer) options.onBytes(new Uint8Array(data));
      else {
        try {
          const control = JSON.parse(data);
          if (control.t === "exit") { options.onExit(); attachment.close(); }
          else attachment.close();
        } catch { attachment.close(); }
      }
    },
  });
  return {
    close: () => attachment.close(),
    input(text: string) {
      const bytes = new TextEncoder().encode(text);
      if (bytes.length > BUFFER_MAX) throw new Error("paste_too_large");
      // No queue, no replay. An interrupted paste may be partial; close the
      // connection and require the person to inspect before recommitting.
      for (let at = 0; at < bytes.length; at += FRAME_MAX) attachment.send(bytes.slice(at, at + FRAME_MAX));
    },
    resize(cols: number, rows: number) { attachment.send(JSON.stringify({ t: "resize", cols, rows })); },
  };
}
