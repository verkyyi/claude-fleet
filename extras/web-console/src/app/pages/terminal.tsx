import { useEffect, useRef, useState } from "react";
import { Link, useLocation, useSearchParams } from "react-router";
import { Layers, List, TerminalSquare } from "lucide-react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import "@xterm/xterm/css/xterm.css";
import { Button } from "@/components/ui/button";
import { tr } from "@/shared/i18n";
import { browserClient, type BrowserOffer } from "@/shared/terminal-client";
import { connectTerminal, FLEET_MENU, FLEET_SHELL, terminalKey } from "@/shared/terminal";
import { usePage } from "../Shell";

type View = { state: "connecting" | "ready" | "closed"; mode?: "direct" | "relay"; error?: string; destination?: string };
const errors: Record<string, [string, string]> = {
  login: ["登录已过期，请重新登录。", "Your login expired. Sign in again."],
  no_home: ["先在设备页设置你的机器。", "Choose your home in Devices first."],
  unsupported: ["这台机器尚不支持网页终端，请更新节点。", "This node does not support browser terminals yet. Update the node."],
  offline: ["你的机器暂时离线。", "Your machine is offline."],
  maintenance: ["你的机器正在维护，请稍后再试。", "Your machine is under maintenance. Try again later."],
  ended: ["终端已结束。回到会话列表查看状态。", "The terminal ended. Check its state in Sessions."],
  interrupted: ["运行环境已改变，已停止连接。请回到会话列表。", "The environment changed. Return to Sessions before connecting again."],
  input: ["输入可能只发送了一部分。请重新连接并检查，未发送的内容不会重放。", "Input may be partial. Reconnect and inspect it; unsent input will not be replayed."],
  lease: ["浏览器设备连接已失效，请重新连接。", "This browser's device lease ended. Connect again."],
};

// Convert the shared theme's CSS colors (including oklch) for xterm's palette.
function terminalTheme(host: HTMLElement) {
  const ctx = document.createElement("canvas").getContext("2d", { willReadFrequently: true })!;
  const color = (value: string) => {
    ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = value; ctx.fillRect(0, 0, 1, 1);
    const rgba = ctx.getImageData(0, 0, 1, 1).data;
    return `#${Array.from(rgba.slice(0, 3), (n) => n.toString(16).padStart(2, "0")).join("")}`;
  };
  const css = getComputedStyle(host);
  const background = color(css.backgroundColor), foreground = color(css.color);
  return { background, foreground, cursor: foreground, selectionBackground: `${foreground}40` };
}

export default function TerminalPage() {
  usePage(tr("我的终端", "My Terminal"));
  const [query] = useSearchParams();
  // An explicit empty/invalid worker remains explicit and is refused server-side.
  const worker = query.get("worker");
  const location = useLocation();
  const title = worker === null ? tr("我的终端", "My Terminal")
    : typeof location.state?.title === "string" ? location.state.title : tr("会话终端", "Session terminal");
  const [attempt, retry] = useState(0);
  const [view, setView] = useState<View>({ state: "connecting" });
  const [offers, setOffers] = useState<BrowserOffer[]>([]);
  const container = useRef<HTMLDivElement>(null);
  const send = useRef<(text: string) => void>(() => {});

  useEffect(() => {
    const host = container.current!;
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
        cursorBlink: true, scrollback: 10000, fontSize: 14,
        fontFamily: `${getComputedStyle(host).getPropertyValue("--font-mono")}, "PingFang SC", "Hiragino Sans", "Apple SD Gothic Neo", "Noto Sans CJK SC", monospace`,
        theme: terminalTheme(host), allowProposedApi: true,
      });
      term = current; fit = new FitAddon(); current.loadAddon(fit);
      current.loadAddon(new Unicode11Addon()); current.unicode.activeVersion = "11";
      current.open(host);
      current.attachCustomKeyEventHandler((event) => terminalKey(event, composing));
      current.onData((text) => { if (term === current) input(text); });
      current.textarea?.addEventListener("compositionstart", () => { composing = true; });
      current.textarea?.addEventListener("compositionend", () => { composing = false; });
      size(); current.focus();
    };
    send.current = (text) => { if (!composing) { input(text); term?.focus(); } };
    const resize = new ResizeObserver(size); resize.observe(host);
    const theme = new MutationObserver(() => { if (term) term.options.theme = terminalTheme(host); });
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    const start = async () => {
      const response = await fetch("/v1/term/home", { signal: abort.signal, credentials: "same-origin", headers: { Accept: "application/json" } });
      if (dead) return;
      if (response.status === 401) { fail("login"); return; }
      const home = await response.json();
      if (!response.ok) { fail(home.code || "refused"); return; }
      setView((v) => ({ ...v, destination: home.machine }));
      if (home.state !== "ok") { fail(home.state); return; }
      client = browserClient(worker, (offer) => { if (!dead) setOffers((old) => [...old.slice(-3), offer]); }, () => fail("lease"));
      if (!await client.ready || dead) return;
      connection = connectTerminal(worker, {
        signal: abort.signal,
        onState(state) {
          if (dead || ended) return;
          if (state.state !== "ready") disposeTerminal();
          setView((v) => ({ ...v, state: state.state, mode: state.mode, error: state.error }));
          if (state.state === "closed") { client?.close(); setOffers([]); return; }
          if (state.state === "ready") {
            ready = true;
            if (!term) createTerminal();
          }
        },
        onBytes(bytes) { term?.write(bytes); },
        onExit() { fail("ended"); },
      });
    };
    void start().catch(() => { if (!dead) fail("connection_failed"); });
    return () => {
      dead = true; send.current = () => {}; abort.abort(); connection?.close(); client?.close();
      resize.disconnect(); theme.disconnect(); disposeTerminal();
    };
  }, [worker, attempt]);

  const status = view.state === "connecting" ? tr("正在连接…", "Connecting…") : view.state === "closed" ? tr("已断开", "Disconnected")
    : view.mode === "direct" ? tr("直连", "Direct") : tr("经入口连接", "Via hub");
  return <div className="flex h-full min-h-80 flex-col gap-3 p-4 md:p-6">
    <header className="flex flex-wrap items-center gap-2">
      <h1 className="min-w-0 flex-1 truncate font-display text-lg" title={view.destination}>
        {title}
        <span className="text-muted-foreground ms-2 font-sans text-xs">{view.destination}</span>
      </h1>
      <span role="status" className="text-muted-foreground text-xs">{status}</span>
      <Button size="sm" variant="outline" disabled={view.state !== "ready"} onClick={() => send.current(FLEET_MENU)} title={tr("也可按 Ctrl+]，再按 p", "Also: Ctrl+] then p")}><List />{tr("Fleet 菜单", "Fleet menu")}</Button>
      <Button size="sm" variant="outline" disabled={view.state !== "ready"} onClick={() => send.current(FLEET_SHELL)} title={tr("再次点击返回会话", "Click again to return to the session")}><TerminalSquare />{tr("打开 Shell", "Open shell")}</Button>
      <Button asChild size="sm" variant="ghost"><Link to="/sessions"><Layers />{tr("会话", "Sessions")}</Link></Button>
    </header>
    {view.state === "closed" ? <div role="alert" className="flex flex-wrap items-center gap-3 rounded-lg border p-4 text-sm">
      <p>{tr(...(errors[view.error || ""] || ["无法连接这个终端。请确认登录、机器和会话状态。", "Could not connect. Check your login, machine and session state."]))}</p>
      {view.error === "login" ? <Button asChild size="sm"><a href="/app/signin">{tr("登录", "Sign in")}</a></Button>
        : view.error === "no_home" ? <Button asChild size="sm"><Link to="/devices?tab=home">{tr("设备", "Devices")}</Link></Button>
          : !["ended", "interrupted"].includes(view.error || "") ? <Button size="sm" onClick={() => retry((n) => n + 1)}>{tr("重新连接", "Reconnect")}</Button> : null}
    </div> : null}
    {offers.map((offer) => <p key={offer.id} role="status" className="text-sm break-all">
      {offer.url ? <a href={offer.url} target="_blank" rel="noopener noreferrer" className="underline">{tr("打开链接：", "Open link: ")}{offer.url}</a>
        : tr("此操作需要本地终端：浏览器暂不支持端口转发、文件传送或登录回调。", "This action needs a local terminal: browser port forwarding, file transfer and login callbacks are not supported.")}
    </p>)}
    <div ref={container} data-terminal className="bg-background text-foreground min-h-0 min-w-0 flex-1 overflow-hidden rounded-lg border p-2" />
  </div>;
}
