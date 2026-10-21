import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Link, useLocation, useNavigate, useSearchParams } from "react-router";
import { Layers, List, Palette, TerminalSquare } from "lucide-react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import "@xterm/xterm/css/xterm.css";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { tr } from "@/shared/i18n";
import { browserClient, type BrowserOffer } from "@/shared/terminal-client";
import { connectTerminal, forgetTerminalGeneration, type TerminalState, FLEET_MENU, FLEET_SHELL, terminalKey, terminalLink } from "@/shared/terminal";
import { touchWheel } from "@/shared/touch-wheel";
import { FONT_SIZES, MIN_CONTRAST, SCHEMES, onTermPick, setTermPick, termPick, xtermTheme, type TermPick } from "@/shared/term-theme";
import { webGoTarget } from "@/shared/web-go";
import { usePage } from "../Shell";
import { LIST_PATH, shellPath } from "../legacy";
import { meTab } from "../routes";
import { continueCommand, continueProvider } from "@/app/chat/continue";
import type { Provider } from "@/app/chat/chat";

type View = TerminalState & { destination?: string };
const errors: Record<string, [string, string]> = {
  open_elsewhere: ["这个终端已在另一个页面打开。回到这里点一下就切回来。", "This terminal is open in another tab. Click here to bring it back."],
  revoked: ["登录已失效，请重新登录。", "Your session was revoked. Sign in again."],
  login: ["登录已过期，请重新登录。", "Your login expired. Sign in again."],
  no_home: ["先在设备页设置你的机器。", "Choose your home in Devices first."],
  unsupported: ["这台机器尚不支持网页终端，请更新节点。", "This node does not support browser terminals yet. Update the node."],
  offline: ["你的机器暂时离线。", "Your machine is offline."],
  maintenance: ["你的机器正在维护，请稍后再试。", "Your machine is under maintenance. Try again later."],
  ended: ["原来的终端已结束，重新打开也没有成功。", "Your terminal ended and could not be reopened."],
  interrupted: ["终端刚被重新打开过两次，已停下。确认后连接现在的终端。", "The terminal was reopened twice in a row, so we paused. Connect to the current one when ready."],
  input: ["输入可能只发送了一部分。请重新连接并检查，未发送的内容不会重放。", "Input may be partial. Reconnect and inspect it; unsent input will not be replayed."],
  lease: ["浏览器设备连接已失效，请重新连接。", "This browser's device lease ended. Connect again."],
};

// What the page says once on arrival (RMVE), then lets go of after 6 s.
function noticeText(notice: string | undefined, name?: string): string | undefined {
  if (notice === "worker_gone") return tr("你上次看的会话已结束，已回到你的终端。", "The session you last viewed has ended — you're back in your terminal.");
  if (notice === "renewed") return tr("原来的终端已结束，已为你开了一个新的。之前退出的命令不会重启。", "Your previous terminal ended, so we opened a new one. Commands that had exited won't restart.");
  if (notice === "current") return tr("这个会话刚重启过，已连上现在的它。", "This session restarted — connected to the current one.");
  if (notice === "session_ended") return name ? tr(`会话「${name}」已结束，已转到你的终端。`, `Session “${name}” has ended — switched to your terminal.`)
    : tr("那个会话已结束，已转到你的终端。", "That session has ended — switched to your terminal.");
  return undefined;
}

// While a connection is being brought back: why, and how long (RMVE) — never a button.
function waitText(view: { error?: string; since?: number }, machine: string | undefined, now: number): string {
  const secs = view.since ? Math.max(0, Math.round((now - view.since) / 1000)) : 0;
  const waited = secs >= 120 ? tr(`${Math.round(secs / 60)} 分钟`, `${Math.round(secs / 60)} min`) : tr(`${secs} 秒`, `${secs} s`);
  const m = machine || tr("你的机器", "your machine");
  if (view.error === "maintenance") return tr(`你的机器 ${m} 正在维护，结束后自动连上。`, `${m} is under maintenance; we'll connect when it's done.`);
  if (view.error === "offline" || view.error === "home_down" || view.error === "node_unavailable")
    return tr(`你的机器 ${m} 现在连不上（已等 ${waited}）。它一上线就自动连上，不用刷新。`, `Your machine ${m} is unreachable (waited ${waited}). We'll connect as soon as it's back — no need to refresh.`);
  return tr(`连接断了，正在接回同一个终端 · 已等 ${waited}`, `Connection lost — reconnecting to the same terminal · ${waited}`);
}

// The scheme a person picked, else the page's light / dark (BBVR).
const pageDark = () => document.documentElement.dataset.theme === "dark";
const currentTheme = () => xtermTheme(termPick().scheme, pageDark());

// The toolbar's 配色 / 字号: kept on this device, applied at once (BBVR).
function TermLook({ pick, onPick, compact }: { pick: TermPick; onPick: (p: TermPick) => void; compact?: boolean }) {
  return <Popover>
    <PopoverTrigger asChild><Button size={compact ? "icon-sm" : "sm"} variant="outline" aria-label={tr("配色", "Colours")} title={tr("终端配色与字号", "Terminal colours and font size")}><Palette />{compact ? null : tr("配色", "Colours")}</Button></PopoverTrigger>
    <PopoverContent align="end" className="w-64 space-y-3">
      <div className="flex items-center justify-between gap-3">
        <Label htmlFor="term-scheme">{tr("配色", "Colours")}</Label>
        <Select value={pick.scheme} onValueChange={(scheme) => onPick({ ...pick, scheme })}>
          <SelectTrigger id="term-scheme" className="w-40"><SelectValue /></SelectTrigger>
          <SelectContent>
            <SelectItem value="follow">{tr("跟随页面", "Follow page")}</SelectItem>
            {SCHEMES.map((s) => <SelectItem key={s.id} value={s.id}>{tr(s.zh, s.en)}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>
      <div className="flex items-center justify-between gap-3">
        <Label htmlFor="term-size">{tr("字号", "Font size")}</Label>
        <Select value={String(pick.size)} onValueChange={(v) => onPick({ ...pick, size: Number(v) })}>
          <SelectTrigger id="term-size" className="w-40"><SelectValue /></SelectTrigger>
          <SelectContent>{FONT_SIZES.map((n) => <SelectItem key={n} value={String(n)}>{n}</SelectItem>)}</SelectContent>
        </Select>
      </div>
    </PopoverContent>
  </Popover>;
}

// The status says which way the bytes go and, once measured, how fast (XX79).
function terminalPath(view: View): string {
  const path = view.mode === "direct" ? tr("直连", "Direct")
    : view.mode === "door" ? tr(`经${view.door || "门"}`, `Via ${view.door || "door"}`)
    : view.doorDown ? tr(`经入口连接 · ${view.doorDown}稍后重试`, `Via hub · retrying ${view.doorDown} shortly`)
    : tr("经入口连接", "Via hub");
  return view.echo !== undefined ? `${path} · ${view.echo} ms` : path;
}

// A terminal as a page of its own — one <TerminalView> under a head: your
// Shell (/s/shell?view=term, worker null; ?continue= picks a web conversation
// up), or a session's the list does not hold (/s/<worker>?view=term) — GR5E C9;
// the old /terminal(?worker=) comes here (legacy.ts). An explicit
// empty/invalid worker remains explicit and is refused server-side.
export default function TerminalPage({ worker }: { worker: string | null }) {
  usePage(tr("我的终端", "My Terminal"));
  const [query] = useSearchParams();
  const location = useLocation();
  // 「在终端里继续」 (task R9A2): the personal terminal picks a web conversation up
  const cont = worker === null ? continueProvider(query.get("continue")) : null;
  const name = typeof location.state?.title === "string" ? location.state.title : undefined;
  const title = worker === null ? tr("我的终端", "My Terminal") : name || tr("会话终端", "Session terminal");
  return <TerminalView worker={worker} cont={cont} title={title} name={name} />;
}

// The tools a terminal's head carries: Fleet 菜单 · 打开 Shell · 配色 / 字号, and
// its status. In a session's workspace (GR5E C4) they go into the workspace's
// own head (`toolsInto`); a phone draws them as icons.
export type TerminalViewProps = {
  worker: string | null;           // null = the personal terminal
  cont?: Provider | null;          // 「在终端里继续」 that side's conversation
  title?: string;                  // the head's title; none with toolsInto
  name?: string;                   // the session's own name, for 「会话「X」已结束」
  toolsInto?: HTMLElement | null;  // draw the tools there instead of a head of its own
  compact?: boolean;               // no notice bars (a phone on its side)
  icons?: boolean;                 // tools as icons only (a phone)
  hidden?: boolean;                // kept in the background: connected, not drawn
};

export function TerminalView({ worker, cont = null, title, name, toolsInto, compact, icons, hidden }: TerminalViewProps) {
  const [contNote, setContNote] = useState("");
  const location = useLocation();
  const navigate = useNavigate();
  const go = useRef(navigate); go.current = navigate;
  const nameRef = useRef<string | undefined>(undefined); nameRef.current = name;
  const [attempt, retry] = useState(0);
  const [view, setView] = useState<View>({ state: "connecting" });
  const [pick, setPick] = useState<TermPick>(termPick);
  const [screen, setScreen] = useState(currentTheme().background);
  const [offers, setOffers] = useState<BrowserOffer[]>([]);
  const [notice, setNotice] = useState<string | undefined>();
  const [now, setNow] = useState(() => Date.now());
  const container = useRef<HTMLDivElement>(null);
  const take = useRef<() => void>(() => {});
  const send = useRef<(text: string) => void>(() => {});
  const focus = useRef<() => void>(() => {});
  const renewal = useRef<string | undefined>(undefined);
  const manual = useRef(false);

  // arriving from a session whose terminal ended (RMVE)
  useEffect(() => {
    const n = noticeText(location.state?.notice, typeof location.state?.ended === "string" ? location.state.ended : undefined);
    if (n) setNotice(n);
  }, [location.key]);
  // the notice says itself once, then goes (RMVE)
  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(undefined), 6000); return () => clearTimeout(t); }, [notice]);
  // 「已等 N 秒」 counts while a connection is being brought back
  useEffect(() => {
    if (view.state !== "reconnecting") return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [view.state]);
  // Coming back to (or clicking) a page another tab took over takes it back —
  // the only way two pages hand a terminal over (RMVE); never by itself.
  // Armed only once this page lost focus or was hidden: two pages in view
  // never pass it back and forth by themselves.
  useEffect(() => {
    if (view.state !== "open-elsewhere") return;
    let away = false;
    const left = () => { away = true; };
    const hid = () => { if (document.visibilityState === "hidden") away = true; else if (away) take.current(); };
    const back = () => { if (away && document.visibilityState !== "hidden") take.current(); };
    window.addEventListener("blur", left); window.addEventListener("focus", back); document.addEventListener("visibilitychange", hid);
    return () => { window.removeEventListener("blur", left); window.removeEventListener("focus", back); document.removeEventListener("visibilitychange", hid); };
  }, [view.state]);

  useEffect(() => {
    const host = container.current!;
    const renew = renewal.current; renewal.current = undefined;
    const cause = manual.current ? "manual" : "first"; manual.current = false;
    const abort = new AbortController();
    let term: Terminal | undefined, fit: FitAddon | undefined;
    let composing = false, ready = false, ended = false, dead = false;
    let connection: ReturnType<typeof connectTerminal> | undefined;
    let client: ReturnType<typeof browserClient> | undefined;
    let homeTimer: ReturnType<typeof setTimeout> | undefined;
    setView({ state: "connecting" }); setOffers([]);
    const disposeTerminal = () => {
      ready = false;
      term?.blur();
      // End only the abandoned composition, with input already fenced. xterm
      // retains a caret-layout timer while composing even after dispose; its
      // own end handler cancels it. Never reconstruct or forward this text.
      if (composing) term?.textarea?.dispatchEvent(new CompositionEvent("compositionend"));
      composing = false;
      // Remove xterm's textarea and its pending composition on reconnect. A
      // late compositionend belongs to that disposed terminal, never its successor.
      term?.dispose(); term = undefined; fit = undefined; host.replaceChildren();
    };
    // Disconnected: the last screen stays (greyed, no input) until the same
    // terminal is back and tmux draws it again (RMVE) — never a blank page.
    const freeze = () => {
      ready = false;
      if (term) { term.options.disableStdin = true; term.blur(); }
      if (composing) term?.textarea?.dispatchEvent(new CompositionEvent("compositionend"));
      composing = false;
      if (term?.textarea) term.textarea.value = "";
      host.dataset.stale = "1";
    };
    const fail = (error: string) => {
      if (dead) return;
      ended = true; freeze(); connection?.close(); client?.close();
      setOffers([]);
      setView((v) => ({ ...v, state: "closed", error }));
    };
    const input = (text: string) => {
      if (!ready || dead) return;
      try { connection!.input(text); client?.input(); }
      catch { fail("input"); }
    };
    const size = () => {
      if (!term || !fit || !host.clientWidth || !host.clientHeight) return;
      fit.fit();
      if (ready) {
        try { connection!.resize(Math.min(term.cols, 500), Math.min(term.rows, 300)); }
        catch { fail("input"); }
      }
    };
    const createTerminal = () => {
      delete host.dataset.stale;
      const current = new Terminal({
        cursorBlink: true, scrollback: 10000, fontSize: termPick().size,
        fontFamily: `${getComputedStyle(host).getPropertyValue("--font-mono")}, "PingFang SC", "Hiragino Sans", "Apple SD Gothic Neo", "Noto Sans CJK SC", monospace`,
        theme: currentTheme(), minimumContrastRatio: MIN_CONTRAST, allowProposedApi: true,
      });
      term = current; fit = new FitAddon(); current.loadAddon(fit);
      current.loadAddon(new Unicode11Addon()); current.unicode.activeVersion = "11";
      current.open(host);
      current.attachCustomKeyEventHandler((event) => terminalKey(event, composing));
      current.onData((text) => { if (term === current) input(text); });
      // ⌘P picked a session on another of your machines (C8X3): open its terminal
      current.parser.registerOscHandler(7502, (data) => {
        const to = term === current ? webGoTarget(data) : null;
        if (to) go.current(terminalLink(to));
        return true;
      });
      current.textarea?.addEventListener("compositionstart", () => { composing = true; });
      current.textarea?.addEventListener("compositionend", () => { composing = false; });
      // A phone's drag is the wheel while tmux reads the mouse (C8X3): history
      // scrolls in copy-mode or in the app itself, never only xterm's empty buffer.
      const el = current.element!;
      let lastY: number | null = null, carry = 0;
      el.addEventListener("touchstart", (e) => { lastY = e.touches.length === 1 ? e.touches[0].clientY : null; carry = 0; }, { passive: true });
      el.addEventListener("touchmove", (e) => {
        if (lastY === null || e.touches.length !== 1 || current.modes.mouseTrackingMode === "none") return;
        const t = e.touches[0];
        const r = touchWheel(carry, t.clientY - lastY, el.clientHeight / Math.max(1, current.rows));
        lastY = t.clientY; carry = r.carry; e.preventDefault();
        const target = el.querySelector(".xterm-screen") ?? el;
        for (let i = 0; i < Math.abs(r.steps); i++) {
          target.dispatchEvent(new WheelEvent("wheel", { deltaY: Math.sign(r.steps), deltaMode: WheelEvent.DOM_DELTA_LINE,
            clientX: t.clientX, clientY: t.clientY, bubbles: true, cancelable: true }));
        }
      }, { passive: false });
      size(); current.focus();
    };
    send.current = (text) => { if (!composing) { input(text); term?.focus(); } };
    focus.current = () => { if (ready) term?.focus(); };
    // once ready: the side's session and directory read from the home, then its
    // shell (the 看台's ⌃\) and the one command — never while a turn runs there
    let contDone = !cont;
    const continueHere = async () => {
      if (contDone) return;
      contDone = true;
      const name = cont === "codex" ? "Codex" : "Claude Code";
      const r = await fetch(`/v1/chat/conversation${cont === "codex" ? "?provider=codex" : ""}`, { signal: abort.signal, credentials: "same-origin", headers: { Accept: "application/json" } }).catch(() => null);
      const j = r?.ok ? await r.json().catch(() => null) : null;
      if (dead) return;
      if (!j?.session) { setContNote(tr(`${name} 这边还没有对话可以接。`, `There is no ${name} conversation to continue yet.`)); return; }
      if (j.busy) { setContNote(tr(`${name} 这边正在回复，等它答完再来接。`, `${name} is replying; continue here once it is done.`)); return; }
      const cmd = continueCommand(cont!, String(j.session), String(j.cwd || ""));
      if (!cmd) { setContNote(tr("这段对话的记录看不懂，没有接。", "Could not read that conversation; nothing was run.")); return; }
      setContNote(tr(`正在接上 ${name} 的对话…`, `Continuing the ${name} conversation…`));
      input(FLEET_SHELL);
      setTimeout(() => { if (!dead) { input(cmd + "\r"); setContNote(""); } }, 800);
    };
    const resize = new ResizeObserver(size); resize.observe(host);
    // a phone turned on its side (GR5E C4): the same connection, the columns
    // fitted again once the turn has settled — never a reconnect
    let turned: ReturnType<typeof setTimeout> | undefined;
    const turn = () => { clearTimeout(turned); turned = setTimeout(size, 250); };
    window.addEventListener("orientationchange", turn);
    // the page turning light / dark, or a new pick, repaints at once
    const repaint = () => {
      const t = currentTheme(); setScreen(t.background); setPick(termPick());
      if (term) { term.options.theme = t; term.options.fontSize = termPick().size; size(); }
    };
    const theme = new MutationObserver(repaint);
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    const unpick = onTermPick(repaint);
    const connect = () => {
      connection = connectTerminal(worker, {
        signal: abort.signal, renew, take: true, cause,
        onState(state) {
          if (dead || ended) return;
          if (state.state !== "ready") freeze();
          setView((v) => ({ ...v, ...state }));
          if (state.notice) setNotice(noticeText(state.notice));
          if (!["connecting", "reconnecting", "ready"].includes(state.state)) { client?.close(); client = undefined; setOffers([]); return; }
          if (state.state === "ready") {
            if (!ready) { disposeTerminal(); ready = true; createTerminal(); void continueHere(); }
            if (!client) client = browserClient(worker, (offer) => { if (!dead) setOffers((old) => [...old.slice(-3), offer]); }, () => { client = undefined; if (!dead) setOffers([]); });
          }
        },
        onBytes(bytes) { term?.write(bytes); },
        // A session's terminal ended: your own terminal, saying which (RMVE).
        onExit() { if (!dead) go.current(shellPath(), { replace: true, state: { notice: "session_ended", ended: nameRef.current } }); },
      });
      take.current = () => connection?.takeControl();
    };
    // Home offline or under maintenance: say so and look again every 10 s,
    // or at once when the page / the network comes back (RMVE) — never a button.
    let since: number | undefined;
    const start = async () => {
      clearTimeout(homeTimer);
      if (dead) return;
      let response: Response;
      try { response = await fetch("/v1/term/home", { signal: abort.signal, credentials: "same-origin", headers: { Accept: "application/json" } }); }
      catch { if (!dead) { since ??= Date.now(); setView((v) => ({ ...v, state: "reconnecting", error: "home_down", since })); homeTimer = setTimeout(start, 10000); } return; }
      if (dead) return;
      if (response.status === 401) { fail("login"); return; }
      const home = await response.json().catch(() => ({}));
      if (dead) return;
      if (response.status >= 500) { since ??= Date.now(); setView((v) => ({ ...v, state: "reconnecting", error: "home_down", since })); homeTimer = setTimeout(start, 10000); return; }
      if (!response.ok) { fail(home.code || "refused"); return; }
      // A session's terminal goes where the session runs — home or another of
      // your machines (C8X3): only the personal terminal waits on home.
      if (worker === null) setView((v) => ({ ...v, destination: home.machine }));
      if (worker === null && (home.state === "offline" || home.state === "maintenance")) {
        since ??= Date.now();
        setView((v) => ({ ...v, state: "reconnecting", error: home.state, since }));
        homeTimer = setTimeout(start, 10000);
        return;
      }
      if (worker === null && home.state !== "ok") { fail(home.state || "refused"); return; }
      connect();
    };
    const homeBack = () => { if (!connection && !ended && document.visibilityState !== "hidden") void start(); };
    window.addEventListener("online", homeBack); document.addEventListener("visibilitychange", homeBack);
    void start().catch(() => { if (!dead) fail("connection_failed"); });
    return () => {
      dead = true; send.current = () => {}; focus.current = () => {}; abort.abort(); connection?.close(); client?.close(); clearTimeout(homeTimer);
      window.removeEventListener("online", homeBack); document.removeEventListener("visibilitychange", homeBack);
      resize.disconnect(); theme.disconnect(); unpick(); disposeTerminal();
      clearTimeout(turned); window.removeEventListener("orientationchange", turn);
    };
  }, [worker, attempt, cont]);

  // back in view (GR5E C4): typing goes to it again at once
  useEffect(() => { if (!hidden) focus.current(); }, [hidden]);

  const again = () => { manual.current = true; setView({ state: "connecting" }); retry((n) => n + 1); };
  const status = view.state === "reconnecting" ? tr("正在接回…", "Reconnecting…") : view.state === "open-elsewhere" ? tr("在另一处使用", "Open elsewhere") : view.state === "connecting" ? tr("正在连接…", "Connecting…") : view.state !== "ready" ? tr("已断开", "Disconnected")
    : terminalPath(view);
  const final = !["connecting", "reconnecting", "ready"].includes(view.state);
  const icon = icons ? "icon-sm" as const : "sm" as const;
  const tools = <>
    <span role="status" className={icons ? "sr-only" : "text-muted-foreground text-xs"}>{status}</span>
    <Button size={icon} variant="outline" disabled={view.state !== "ready"} onClick={() => send.current(FLEET_MENU)} aria-label={tr("Fleet 菜单", "Fleet menu")} title={tr("也可按 Ctrl+]，再按 p", "Also: Ctrl+] then p")}><List />{icons ? null : tr("Fleet 菜单", "Fleet menu")}</Button>
    <Button size={icon} variant="outline" disabled={view.state !== "ready"} onClick={() => send.current(FLEET_SHELL)} aria-label={tr("打开 Shell", "Open shell")} title={tr("再次点击返回会话", "Click again to return to the session")}><TerminalSquare />{icons ? null : tr("打开 Shell", "Open shell")}</Button>
    <TermLook pick={pick} onPick={setTermPick} compact={icons} />
  </>;
  const inWorkspace = toolsInto !== undefined;
  return <div data-terminal-view hidden={hidden} className={inWorkspace ? `flex h-full min-h-0 flex-col ${compact ? "gap-1 p-1" : "gap-3 p-2 md:p-4"}` : "flex h-full min-h-80 flex-col gap-3 p-4 md:p-6"}>
    {inWorkspace ? (toolsInto && !hidden ? createPortal(tools, toolsInto) : null) : <header className="flex flex-wrap items-center gap-2">
      <h1 className="min-w-0 flex-1 truncate font-display text-lg" title={view.destination}>
        {title}
        <span className="text-muted-foreground ms-2 font-sans text-xs">{view.destination}</span>
      </h1>
      {tools}
      <Button asChild size="sm" variant="ghost"><Link to={LIST_PATH}><Layers />{tr("会话", "Sessions")}</Link></Button>
    </header>}
    {notice && !compact ? <p role="status" data-notice className="rounded-md border-s-4 border-primary bg-muted px-3 py-2 text-sm">{notice}</p> : null}
    {view.state === "reconnecting" && !compact ? <p role="status" data-waiting className="rounded-md bg-muted px-3 py-2 text-sm">{waitText(view, view.destination, now)}</p> : null}
    {view.state === "open-elsewhere" ? <button type="button" role="alert" className="rounded-lg border p-4 text-start text-sm" onClick={() => take.current()}>{tr(...errors.open_elsewhere)}</button> : null}
    {final && view.state !== "open-elsewhere" ? <div role="alert" className="flex flex-wrap items-center gap-3 rounded-lg border p-4 text-sm">
      <p>{tr(...(errors[view.error || ""] || ["无法连接这个终端。请确认登录、机器和会话状态。", "Could not connect. Check your login, machine and session state."]))}</p>
      {view.state === "unauthorized" || view.error === "login" ? <Button asChild size="sm"><a href="/app/signin">{tr("登录", "Sign in")}</a></Button>
        : view.error === "no_home" ? <Button asChild size="sm"><Link to={`${meTab("devices").path}?tab=home`}>{tr("设备", "Devices")}</Link></Button>
          : worker === null && view.error === "ended" && view.terminalGeneration ? <Button size="sm" onClick={() => { renewal.current = view.terminalGeneration; again(); }}>{tr("重新打开终端", "Reopen terminal")}</Button>
          : view.error === "interrupted" ? <Button size="sm" onClick={() => { forgetTerminalGeneration(worker); again(); }}>{tr("连接当前会话", "Connect current session")}</Button>
          : !["ended", "unsupported"].includes(view.error || "") && view.state !== "unsupported" ? <Button size="sm" onClick={again}>{tr("重新连接", "Reconnect")}</Button>
            : <Button asChild size="sm"><Link to={LIST_PATH}>{tr("查看会话", "View sessions")}</Link></Button>}
    </div> : null}
    {contNote ? <p role="status" className="text-muted-foreground text-sm">{contNote}</p> : null}
    {offers.map((offer) => <p key={offer.id} role="status" className="text-sm break-all">
      {offer.url ? <a href={offer.url} target="_blank" rel="noopener noreferrer" className="underline">{tr("打开链接：", "Open link: ")}{offer.url}</a>
        : tr("此操作需要本地终端：浏览器暂不支持端口转发、文件传送或登录回调。", "This action needs a local terminal: browser port forwarding, file transfer and login callbacks are not supported.")}
    </p>)}
    <div ref={container} data-terminal style={{ background: screen }} onPointerDown={() => { if (view.state === "open-elsewhere") take.current(); }}
      className="min-h-0 min-w-0 flex-1 overflow-hidden rounded-lg border p-2 transition-opacity data-[stale]:opacity-50" />
  </div>;
}
