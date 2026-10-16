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

export type TerminalState = Omit<AttachmentState, "state"> & {
  state: "connecting" | "ready" | "reconnecting" | "open-elsewhere" | "ended" | "unauthorized" | "unsupported" | "closed";
};
export function forgetTerminalGeneration(worker: string | null) {
  try { sessionStorage.removeItem(`fleet-terminal:${worker ?? "personal"}`); } catch { /* optional */ }
}
export type TerminalConnection = ReturnType<typeof connectTerminal>;
const transient = new Set(["connection_closed", "connection_failed", "direct_closed", "direct_failed", "attachment_timeout", "negotiation_failed", "node_unavailable", "home_down", "offline", "rate", "limit"]);

export function connectTerminal(worker: string | null, options: {
  signal: AbortSignal;
  onState: (s: TerminalState) => void;
  onBytes: (bytes: Uint8Array) => void;
  onExit: () => void;
  preferRelay?: boolean;
  renew?: string;
}) {
  const key = `fleet-terminal:${worker ?? "personal"}`;
  let resume = options.renew || "";
  let renewing = Boolean(options.renew);
  try { resume ||= sessionStorage.getItem(key) || ""; } catch { /* private storage unavailable */ }
  let attachment: BrowserAttachment | undefined, timer: ReturnType<typeof setTimeout> | undefined;
  let stopped = false, ready = false, serial = 0, failures = 0, previous: string | undefined;
  let relay = Boolean(options.preferRelay), info: Partial<TerminalState> = {};
  const publish = (state: TerminalState["state"], error?: string) => options.onState({ ...info, state, error });
  const dispose = () => { ++serial; ready = false; clearTimeout(timer); const old = attachment; attachment = undefined; old?.close(); };
  const schedule = (error?: string) => {
    if (failures >= 6) { finish("offline"); return; }
    dispose(); publish("reconnecting", error);
    if (!navigator.onLine) return;
    const delay = Math.min(15000, 500 * 2 ** Math.min(failures++, 5)) * (0.75 + Math.random() * 0.5);
    timer = setTimeout(() => start(), delay);
  };
  const finish = (error: string) => {
    dispose(); stopped = true;
    const state = error === "open_elsewhere" ? "open-elsewhere"
      : ["login", "revoked", "unauthorized"].includes(error) ? "unauthorized"
      : error === "unsupported" ? "unsupported"
      : ["ended", "interrupted", "not_yours"].includes(error) ? "ended" : "closed";
    publish(state, error);
  };
  const start = (take = false) => {
    if (stopped || options.signal.aborted) return;
    if (!navigator.onLine) { schedule(); return; }
    const token = ++serial;
    publish(failures ? "reconnecting" : "connecting");
    const query = new URLSearchParams({ service: "term", controller: "1", errors: "stream", ...(worker === null ? { target: "personal" } : { worker }) });
    if (resume) query.set("term_resume", resume);
    if (take) query.set("take", "1");
    if (renewing) query.set("renew", "1");
    attachment = new BrowserAttachment({
      url: `/v1/attachment/connect?${query}`, reconnect: false, previous, preferRelay: relay,
      onState(state) {
        if (token !== serial || stopped) return;
        info = { ...info, ...state };
        if (state.connection) previous = state.connection;
        if (state.state === "ready") {
          if (!state.terminalGeneration || !state.controllerEpoch) { finish("unsupported"); return; }
          if (!renewing && resume && state.terminalGeneration && resume !== state.terminalGeneration) { finish("interrupted"); return; }
          if (state.terminalGeneration) {
            resume = state.terminalGeneration;
            try { sessionStorage.setItem(key, resume); } catch { /* optional */ }
          }
          renewing = false; ready = true; failures = 0; publish("ready");
        } else if (state.state === "closed") {
          ready = false;
          const error = state.error || "connection_closed";
          // A lost response to renewal is uncertain. Never repeat a lifecycle
          // mutation as an ordinary network retry or replay old input.
          if (renewing && transient.has(error)) { finish("interrupted"); return; }
          if (error === "ended" && state.terminalGeneration) {
            resume = state.terminalGeneration;
            try { sessionStorage.setItem(key, resume); } catch { /* optional */ }
          }
          if (transient.has(error)) { if (state.mode === "direct") relay = true; schedule(error); }
          else finish(error);
        }
      },
      onData(data) {
        if (token !== serial || !ready) return;
        if (data instanceof ArrayBuffer) options.onBytes(new Uint8Array(data));
        else {
          try {
            const control = JSON.parse(data);
            if (control.t === "exit") { finish("ended"); options.onExit(); }
            else finish(control.error || "invalid_control");
          } catch { finish("invalid_control"); }
        }
      },
    });
  };
  const offline = () => { if (!stopped) { if (renewing) finish("interrupted"); else schedule(); } };
  const online = () => { if (!stopped && !ready) { clearTimeout(timer); start(); } };
  window.addEventListener("offline", offline); window.addEventListener("online", online);
  const close = () => {
    stopped = true; dispose();
    window.removeEventListener("offline", offline); window.removeEventListener("online", online);
    options.signal.removeEventListener("abort", close);
  };
  options.signal.addEventListener("abort", close, { once: true });
  // Defer callbacks until the owner has captured this connection, including
  // synchronous resize in onState(ready).
  queueMicrotask(() => start());
  return {
    close,
    takeControl() { dispose(); stopped = false; previous = undefined; failures = 0; start(true); },
    input(text: string) {
      if (!ready || !attachment) throw new Error("terminal disconnected");
      const bytes = new TextEncoder().encode(text);
      if (bytes.length > BUFFER_MAX) throw new Error("paste_too_large");
      for (let at = 0; at < bytes.length; at += FRAME_MAX) attachment.send(bytes.slice(at, at + FRAME_MAX));
    },
    resize(cols: number, rows: number) {
      if (ready) attachment?.send(JSON.stringify({ t: "resize", cols, rows }));
    },
  };
}
