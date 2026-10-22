import { BrowserAttachment, BUFFER_MAX, FRAME_MAX, type AttachmentState } from "../../../browser-transport/attachment";
import { doorRetryDelay, endedStep, retryDelay } from "./terminal-retry";
export { doorRetryDelay, endedStep, retryDelay };

// a session's terminal is its page's 终端 view (GR5E C9): /s/<worker>?view=term
export const terminalLink = (worker: string) => `/s/${encodeURIComponent(worker)}?view=term`;
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
  /** the door that failed on this page, so the status can say so */
  doorDown?: string;
  state: "connecting" | "ready" | "reconnecting" | "open-elsewhere" | "ended" | "unauthorized" | "unsupported" | "closed";
  /** a word the page says once on arrival (RMVE): the node's worker_gone, or
   * renewed (a personal terminal that had ended was reopened) and current (the
   * session's process was replaced: this is the current one) */
  notice?: string;
  /** when this disconnect began (ms epoch), for the page's 「已等 N 秒」 */
  since?: number;
};
export function forgetTerminalGeneration(worker: string | null) {
  try { sessionStorage.removeItem(`fleet-terminal:${worker ?? "personal"}`); } catch { /* optional */ }
}
export type TerminalConnection = ReturnType<typeof connectTerminal>;
export const transient = new Set(["connection_closed", "connection_failed", "direct_closed", "direct_failed", "attachment_timeout", "negotiation_failed", "node_unavailable", "home_down", "offline", "maintenance", "rate", "limit", "too_many", "door_failed", "door_unavailable", "hub_restart"]);

export function connectTerminal(worker: string | null, options: {
  signal: AbortSignal;
  onState: (s: TerminalState) => void;
  onBytes: (bytes: Uint8Array) => void;
  onExit: () => void;
  preferRelay?: boolean;
  renew?: string;
  /** opening the page takes the terminal (RMVE); a reconnect never does */
  take?: boolean;
  /** why this page connects: first (opened) · manual (a button) */
  cause?: "first" | "manual";
}) {
  const key = `fleet-terminal:${worker ?? "personal"}`;
  let resume = options.renew || "";
  let renewing = Boolean(options.renew);
  try { resume ||= sessionStorage.getItem(key) || ""; } catch { /* private storage unavailable */ }
  const remember = (gen: string) => { resume = gen; try { sessionStorage.setItem(key, gen); } catch { /* optional */ } };
  const forget = () => { resume = ""; try { sessionStorage.removeItem(key); } catch { /* optional */ } };
  let attachment: BrowserAttachment | undefined, timer: ReturnType<typeof setTimeout> | undefined, doorTimer: ReturnType<typeof setTimeout> | undefined;
  let stopped = false, ready = false, serial = 0, failures = 0, previous: string | undefined, pending = false;
  let relay = Boolean(options.preferRelay), doorFails = 0, lastInput = 0, since: number | undefined;
  let take = Boolean(options.take), cause: string = options.cause || "first";
  let retried: string | undefined, notice: string | undefined, pendingNotice: string | undefined, interruptedAt = 0;
  const renewed = new Set<string>();
  let info: Partial<TerminalState> = {};
  const publish = (state: TerminalState["state"], error?: string) => options.onState({ ...info, state, error, notice: state === "ready" ? notice : undefined, since: state === "ready" ? undefined : since });
  const dispose = () => { ++serial; ready = false; pending = false; clearTimeout(timer); clearTimeout(doorTimer); const old = attachment; attachment = undefined; old?.close(); };
  const visible = () => typeof document === "undefined" || document.visibilityState !== "hidden";
  // Never given up on: a hidden page or no network waits for the event that
  // ends it (visibilitychange / focus / online) instead of a timer (RMVE).
  const schedule = (error?: string, now = false) => {
    dispose(); since ??= Date.now(); publish("reconnecting", error);
    cause = "auto";
    probe(error);
    if (!navigator.onLine || !visible()) { pending = true; return; }
    const delay = now ? 0 : retryDelay(failures, error);
    if (!now && error !== "hub_restart") failures++;
    pending = true;
    timer = setTimeout(() => { pending = false; start(); }, delay);
  };
  // A WebSocket refused before it opened says nothing (a plain 401 from an
  // auth layer looks like the network). Ask the page's own read once per
  // failure: signed out ⇒ stop and say so; home offline ⇒ that is the reason.
  const probe = (error?: string) => {
    if (error !== "connection_failed" && error !== "connection_closed") return;
    void fetch("/v1/term/home", { credentials: "same-origin", headers: { Accept: "application/json" }, signal: options.signal })
      .then(async (r) => {
        if (stopped || ready) return;
        if (r.status === 401) { finish("login"); return; }
        const home = await r.json().catch(() => ({}));
        if (stopped || ready) return;
        if (home.state === "offline" || home.state === "maintenance") publish("reconnecting", home.state);
      })
      .catch(() => { /* the retry says the rest */ });
  };
  const kick = () => { if (!stopped && !ready && pending) { clearTimeout(timer); pending = false; start(); } };
  const finish = (error: string) => {
    dispose(); stopped = true;
    const state = error === "open_elsewhere" ? "open-elsewhere"
      : ["login", "revoked", "unauthorized"].includes(error) ? "unauthorized"
      : error === "unsupported" ? "unsupported"
      : ["ended", "interrupted", "not_yours"].includes(error) ? "ended" : "closed";
    publish(state, error);
  };
  const ended = (gen: string) => {
    const step = endedStep(worker, gen, retried, renewed);
    if (step === "leave") { finish("ended"); options.onExit(); return; }
    if (step === "stop") { finish("ended"); return; }
    remember(gen);
    if (step === "reconnect") { retried = gen; schedule("ended", true); return; }
    renewed.add(gen); renewing = true; schedule("ended", true);
  };
  // After the door failed this connection went through the hub; try the door
  // again later, when nobody is typing — a reconnect the page keeps the screen over.
  const doorLater = () => {
    clearTimeout(doorTimer);
    doorTimer = setTimeout(function again() {
      if (stopped || !ready) return;
      if (!visible() || Date.now() - lastInput < 2000) { doorTimer = setTimeout(again, 2000); return; }
      relay = false; schedule(undefined, true);
    }, doorRetryDelay(doorFails));
  };
  const start = () => {
    if (stopped || options.signal.aborted) return;
    if (!navigator.onLine || !visible()) { since ??= Date.now(); pending = true; publish("reconnecting"); return; }
    const token = ++serial;
    publish(since ? "reconnecting" : "connecting");
    const query = new URLSearchParams({ service: "term", controller: "1", errors: "stream", cause: renewing ? "renew" : cause, ...(worker === null ? { target: "personal" } : { worker }) });
    if (resume) query.set("term_resume", resume);
    if (take && !renewing) query.set("take", "1");
    if (renewing) query.set("renew", "1");
    const viaHub = relay;
    attachment = new BrowserAttachment({
      url: `/v1/attachment/connect?${query}`, reconnect: false, previous, preferRelay: relay,
      onState(state) {
        if (token !== serial || stopped) return;
        info = { ...info, ...state };
        if (state.state === "ready") {
          // only a connection that held the terminal is «previous»: its lease
          // is the one a reconnect may take back (a failed try held none)
          if (state.connection) previous = state.connection;
          if (!state.terminalGeneration || !state.controllerEpoch) { finish("unsupported"); return; }
          notice = state.notice || pendingNotice; pendingNotice = undefined;
          // Another tab renewed it, or the session's process was replaced: this
          // is the terminal there is now — say so, never a button (RMVE).
          if (!renewing && resume && resume !== state.terminalGeneration) notice ||= worker === null ? "renewed" : "current";
          if (renewing) notice ||= "renewed";
          remember(state.terminalGeneration);
          // Later reconnects never take: the node takes over only a lease held by
          // this page's own previous connection — a page taken from stays taken.
          renewing = false; ready = true; failures = 0; since = undefined; take = false; cause = "auto";
          // Not forced through the hub this time: the door question is settled
          // (taken, or the hub measured faster) — nothing is «unavailable».
          if (!viaHub) { relay = Boolean(options.preferRelay); doorFails = 0; info = { ...info, doorDown: undefined }; }
          publish("ready");
          if (viaHub && info.doorDown) doorLater();
        } else if (state.state === "closed") {
          ready = false;
          const error = state.error || "connection_closed";
          if (error === "ended") { ended(state.terminalGeneration || resume); return; }
          if (error === "interrupted") {
            // The generation asked for is not the one there (renewed elsewhere,
            // or a renew whose answer was lost): connect the current one, once.
            if (Date.now() - interruptedAt < 10000) { finish("interrupted"); return; }
            interruptedAt = Date.now(); renewing = false; forget(); notice = undefined;
            pendingNotice = worker === null ? "renewed" : "current";
            schedule(error, true); return;
          }
          // Admission throttling refused the request before the node ran it:
          // keep the pending renewal and retry with the same generation.
          // A lost answer is uncertain: reconnect plainly; «interrupted» says
          // whether that renewal happened, without opening another terminal.
          if (renewing && transient.has(error) && !["rate", "too_many"].includes(error)) renewing = false;
          if (transient.has(error)) {
            // a failed door or direct path: the hub for now, the door again later (XX79, RMVE)
            if (state.mode === "direct" || state.mode === "door") relay = true;
            if (state.mode === "door") { doorFails++; info = { ...info, doorDown: state.door || "door" }; }
            schedule(error);
          }
          else finish(error);
        }
      },
      onData(data) {
        if (token !== serial || !ready) return;
        if (data instanceof ArrayBuffer) options.onBytes(new Uint8Array(data));
        else {
          try {
            const control = JSON.parse(data);
            if (control.t === "exit") ended(resume);
            else finish(control.error || "invalid_control");
          } catch { finish("invalid_control"); }
        }
      },
    });
  };
  const offline = () => { if (!stopped) { renewing = false; schedule(); } };
  const online = () => kick();
  const back = () => { if (visible()) kick(); };
  window.addEventListener("offline", offline); window.addEventListener("online", online);
  window.addEventListener("focus", back); document.addEventListener("visibilitychange", back);
  const close = () => {
    stopped = true; dispose();
    window.removeEventListener("offline", offline); window.removeEventListener("online", online);
    window.removeEventListener("focus", back); document.removeEventListener("visibilitychange", back);
    options.signal.removeEventListener("abort", close);
  };
  options.signal.addEventListener("abort", close, { once: true });
  // Defer callbacks until the owner has captured this connection, including
  // synchronous resize in onState(ready).
  queueMicrotask(() => start());
  return {
    close,
    takeControl() { dispose(); stopped = false; previous = undefined; failures = 0; take = true; cause = "take"; start(); },
    input(text: string) {
      if (!ready || !attachment) throw new Error("terminal disconnected");
      const bytes = new TextEncoder().encode(text);
      if (bytes.length > BUFFER_MAX) throw new Error("paste_too_large");
      lastInput = Date.now();
      for (let at = 0; at < bytes.length; at += FRAME_MAX) attachment.send(bytes.slice(at, at + FRAME_MAX));
    },
    resize(cols: number, rows: number) {
      if (ready) attachment?.send(JSON.stringify({ t: "resize", cols, rows }));
    },
  };
}
