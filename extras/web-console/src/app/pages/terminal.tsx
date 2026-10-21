import { useEffect, useRef, useState } from "react";
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

type View = TerminalState & { destination?: string };
const errors: Record<string, [string, string]> = {
  open_elsewhere: ["此终端正在另一处使用。点击「在这里使用」接管。", "This terminal is open elsewhere. Choose Use here to take control."],
  revoked: ["登录已失效，请重新登录。", "Your session was revoked. Sign in again."],
  login: ["登录已过期，请重新登录。", "Your login expired. Sign in again."],
  no_home: ["先在设备页设置你的机器。", "Choose your home in Devices first."],
  unsupported: ["这台机器尚不支持网页终端，请更新节点。", "This node does not support browser terminals yet. Update the node."],
  offline: ["你的机器暂时离线。", "Your machine is offline."],
  maintenance: ["你的机器正在维护，请稍后再试。", "Your machine is under maintenance. Try again later."],
  ended: ["终端已结束。回到会话列表查看状态。", "The terminal ended. Check its state in Sessions."],
  interrupted: ["运行环境已改变，已停止连接。确认后可连接当前会话。", "The environment changed. You can explicitly connect to the current session."],
  input: ["输入可能只发送了一部分。请重新连接并检查，未发送的内容不会重放。", "Input may be partial. Reconnect and inspect it; unsent input will not be replayed."],
  lease: ["浏览器设备连接已失效，请重新连接。", "This browser's device lease ended. Connect again."],
};

// The scheme a person picked, else the page's light / dark (BBVR).
const pageDark = () => document.documentElement.dataset.theme === "dark";
const currentTheme = () => xtermTheme(termPick().scheme, pageDark());

// The toolbar's 配色 / 字号: kept on this device, applied at once (BBVR).
function TermLook({ pick, onPick }: { pick: TermPick; onPick: (p: TermPick) => void }) {
  return <Popover>
    <PopoverTrigger asChild><Button size="sm" variant="outline" title={tr("终端配色与字号", "Terminal colours and font size")}><Palette />{tr("配色", "Colours")}</Button></PopoverTrigger>
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
    : view.doorDown ? tr(`经入口连接 · ${view.doorDown}暂不可用`, `Via hub · ${view.doorDown} unavailable`)
    : tr("经入口连接", "Via hub");
  return view.echo !== undefined ? `${path} · ${view.echo} ms` : path;
}

export default function TerminalPage() {
  usePage(tr("我的终端", "My Terminal"));
  const [query] = useSearchParams();
  // An explicit empty/invalid worker remains explicit and is refused server-side.
  const worker = query.get("worker");
  const location = useLocation();
  const navigate = useNavigate();
  const go = useRef(navigate); go.current = navigate;
  const title = worker === null ? tr("我的终端", "My Terminal")
    : typeof location.state?.title === "string" ? location.state.title : tr("会话终端", "Session terminal");
  const [attempt, retry] = useState(0);
  const [view, setView] = useState<View>({ state: "connecting" });
  const [offers, setOffers] = useState<BrowserOffer[]>([]);
  const container = useRef<HTMLDivElement>(null);
  const take = useRef<() => void>(() => {});
  const send = useRef<(text: string) => void>(() => {});
  const renewal = useRef<string | undefined>(undefined);
  const [pick, setPick] = useState<TermPick>(termPick);
  const [screen, setScreen] = useState(currentTheme().background);

  useEffect(() => {
    const host = container.current!;
    const renew = renewal.current; renewal.current = undefined;
    const abort = new AbortController();
    let term: Terminal | undefined, fit: FitAddon | undefined;
    let composing = false, ready = false, ended = false, dead = false;
    let connection: ReturnType<typeof connectTerminal> | undefined;
    let client: ReturnType<typeof browserClient> | undefined;
    setView({ state: "connecting" }); setOffers([]);
    const disposeTerminal = () => {
      ready = false;
      term?.blur();
      // End only the abandoned composition, with input already fenced. xterm
      // retains a caret-layout timer while composing even after dispose; its
      // own end handler cancels it. Never reconstruct or forward this text.
      if (composing) term?.textarea?.dispatchEvent(new CompositionEvent("compositionend"));
      composing = false;
      // Remove xterm's textarea and its pending composition on disconnect. A
      // late compositionend belongs to that disposed terminal, never its successor.
      term?.dispose(); term = undefined; fit = undefined; host.replaceChildren();
    };
    const fail = (error: string) => {
      if (dead) return;
      ended = true; disposeTerminal(); connection?.close(); client?.close();
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
    const resize = new ResizeObserver(size); resize.observe(host);
    // the page turning light / dark, or a new pick, repaints at once
    const repaint = () => {
      const t = currentTheme(); setScreen(t.background); setPick(termPick());
      if (term) { term.options.theme = t; term.options.fontSize = termPick().size; size(); }
    };
    const theme = new MutationObserver(repaint);
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    const unpick = onTermPick(repaint);
    const start = async () => {
      const response = await fetch("/v1/term/home", { signal: abort.signal, credentials: "same-origin", headers: { Accept: "application/json" } });
      if (dead) return;
      if (response.status === 401) { fail("login"); return; }
      const home = await response.json();
      if (!response.ok) { fail(home.code || "refused"); return; }
      // A session's terminal goes where the session runs — home or another of
      // your machines (C8X3): only the personal terminal waits on home.
      if (worker === null) setView((v) => ({ ...v, destination: home.machine }));
      if (worker === null && home.state !== "ok") { fail(home.state || "refused"); return; }
      connection = connectTerminal(worker, {
        signal: abort.signal, renew,
        onState(state) {
          if (dead || ended) return;
          if (state.state !== "ready") {
            ready = false;
            if (term) { term.options.disableStdin = true; term.blur(); }
            composing = false;
            if (term?.textarea) term.textarea.value = "";
          }
          setView((v) => ({ ...v, ...state }));
          if (!["connecting", "reconnecting", "ready"].includes(state.state)) { disposeTerminal(); client?.close(); client = undefined; setOffers([]); return; }
          if (state.state === "ready") {
            if (!ready) { disposeTerminal(); ready = true; createTerminal(); }
            if (!client) client = browserClient(worker, (offer) => { if (!dead) setOffers((old) => [...old.slice(-3), offer]); }, () => { client = undefined; if (!dead) setOffers([]); });
          }
        },
        onBytes(bytes) { term?.write(bytes); },
        onExit() { fail("ended"); },
      });
      take.current = () => connection?.takeControl();
    };
    void start().catch(() => { if (!dead) fail("connection_failed"); });
    return () => {
      dead = true; send.current = () => {}; abort.abort(); connection?.close(); client?.close();
      resize.disconnect(); theme.disconnect(); unpick(); disposeTerminal();
    };
  }, [worker, attempt]);

  const status = view.state === "reconnecting" ? tr("正在重新连接…", "Reconnecting…") : view.state === "open-elsewhere" ? tr("正在另一处使用", "Open elsewhere") : view.state === "connecting" ? tr("正在连接…", "Connecting…") : view.state !== "ready" ? tr("已断开", "Disconnected")
    : terminalPath(view);
  return <div className="flex h-full min-h-80 flex-col gap-3 p-4 md:p-6">
    <header className="flex flex-wrap items-center gap-2">
      <h1 className="min-w-0 flex-1 truncate font-display text-lg" title={view.destination}>
        {title}
        <span className="text-muted-foreground ms-2 font-sans text-xs">{view.destination}</span>
      </h1>
      <span role="status" className="text-muted-foreground text-xs">{status}</span>
      <Button size="sm" variant="outline" disabled={view.state !== "ready"} onClick={() => send.current(FLEET_MENU)} title={tr("也可按 Ctrl+]，再按 p", "Also: Ctrl+] then p")}><List />{tr("Fleet 菜单", "Fleet menu")}</Button>
      <Button size="sm" variant="outline" disabled={view.state !== "ready"} onClick={() => send.current(FLEET_SHELL)} title={tr("再次点击返回会话", "Click again to return to the session")}><TerminalSquare />{tr("打开 Shell", "Open shell")}</Button>
      <TermLook pick={pick} onPick={setTermPick} />
      <Button asChild size="sm" variant="ghost"><Link to="/sessions"><Layers />{tr("会话", "Sessions")}</Link></Button>
    </header>
    {!["connecting", "reconnecting", "ready"].includes(view.state) ? <div role="alert" className="flex flex-wrap items-center gap-3 rounded-lg border p-4 text-sm">
      <p>{worker === null && view.error === "ended" ? tr("个人终端已结束。可重新打开，已退出的命令不会重启。", "Your personal terminal ended. Reopen it to continue; exited commands will not restart.") : tr(...(errors[view.error || ""] || ["无法连接这个终端。请确认登录、机器和会话状态。", "Could not connect. Check your login, machine and session state."]))}</p>
      {view.state === "open-elsewhere" ? <Button size="sm" onClick={() => take.current()}>{tr("在这里使用", "Use here")}</Button> : view.state === "unauthorized" || view.error === "login" ? <Button asChild size="sm"><a href="/app/signin">{tr("登录", "Sign in")}</a></Button>
        : view.error === "no_home" ? <Button asChild size="sm"><Link to="/devices?tab=home">{tr("设备", "Devices")}</Link></Button>
          : worker === null && view.error === "ended" && view.terminalGeneration ? <Button size="sm" onClick={() => { renewal.current = view.terminalGeneration; setView({ state: "connecting" }); retry((n) => n + 1); }}>{tr("重新打开终端", "Reopen terminal")}</Button>
          : view.error === "interrupted" ? <Button size="sm" onClick={() => { forgetTerminalGeneration(worker); retry((n) => n + 1); }}>{tr("连接当前会话", "Connect current session")}</Button>
          : !["ended", "interrupted"].includes(view.error || "") ? <Button size="sm" onClick={() => retry((n) => n + 1)}>{tr("重新连接", "Reconnect")}</Button>
            : <Button asChild size="sm"><Link to="/sessions">{tr("查看会话", "View sessions")}</Link></Button>}
    </div> : null}
    {offers.map((offer) => <p key={offer.id} role="status" className="text-sm break-all">
      {offer.url ? <a href={offer.url} target="_blank" rel="noopener noreferrer" className="underline">{tr("打开链接：", "Open link: ")}{offer.url}</a>
        : tr("此操作需要本地终端：浏览器暂不支持端口转发、文件传送或登录回调。", "This action needs a local terminal: browser port forwarding, file transfer and login callbacks are not supported.")}
    </p>)}
    <div ref={container} data-terminal style={{ background: screen }} className="min-h-0 min-w-0 flex-1 overflow-hidden rounded-lg border p-2" />
  </div>;
}
