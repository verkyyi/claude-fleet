// routes.tsx — the member side's ONE page table (EPIC #3923 C3). A page the
// new console draws has its `page`; one still on the old console has none, and
// its tab is a plain link to the old address — until that page's ticket (C4–C8)
// adds its file under pages/ and fills in this one line (and flips its row in
// the hub's consolePages, app_mount.go).
//
// 我的 holds 用量 · 设备 · 设置 · 账号 as four tabs at /me/<tab> (GR5E C1): the
// sidebar and the bottom bar carry none of them — the avatar is the way in —
// and their old addresses move on there, query and hash kept.
//
// Every old address moves on through legacy.ts's one table (GR5E C9): 任务 /
// 会话's ?q= opens that session, /terminal your Shell's (/s/shell?view=term).
//
// The session list is the one way in (GR5E C2): the computer's left column and
// the phone's first screen (/) are the list, a row opens /s/<ref>, and the web
// conversation is a row of it at /chat — on a computer / still shows it beside
// the list, and a phone's /?about= (a link into the conversation) opens it too.
import { lazy, useEffect, useRef, useState, type ComponentType } from "react";
import { Navigate, useLocation } from "react-router";
import { Gauge, Layers, MessageCircle, MonitorSmartphone, Plus, Settings, CircleUserRound, type LucideIcon } from "lucide-react";
import { tr } from "@/shared/i18n";
// the front page is in the first bundle: the conversation is the first screen
import ChatPage, { ChatThread } from "./pages/chat";
import { SessionListPage, sessionPath } from "./SessionList";
import { useUnified } from "./chat/home";
import { useWorkRows } from "./work-rows";
import { migrateLegacy } from "./chat/legacy";
import { LEGACY, legacyTarget } from "./legacy";

// The front page: the list on a phone, the conversation beside the list on a
// computer (the left column already is the list). Read before the first paint,
// so a phone never flashes the conversation.
const PHONE = "(max-width: 767px)";
const SchedulePanel = lazy(() => import("./pages/schedules").then(m => ({ default: m.SchedulePanel })));
const NewSession = lazy(() => import("./NewSession"));
function Home() {
  const { search } = useLocation();
  const unified = useUnified();
  const [phone, setPhone] = useState(() => matchMedia(PHONE).matches);
  useEffect(() => { const m = matchMedia(PHONE); const f = () => setPhone(m.matches); m.addEventListener("change", f); return () => m.removeEventListener("change", f); }, []);
  if (new URLSearchParams(search).has("schedule") || new URLSearchParams(search).has("schedules")) return <SchedulePanel />;
  // the old first screen was the conversation: only a link into it (?about=) opens it now
  if (phone && !new URLSearchParams(search).has("about")) return <SessionListPage />;
  // 会话合一 (Y01K): a chat is a session; a computer's front page is a new one
  if (unified === null) return null;
  return unified ? <NewSession /> : <ChatPage />;
}

// /chat: the old road's one conversation; on the new one it became a session
// named 「我的对话」 — opened as any session, else the list.
function ChatRoute() {
  const unified = useUnified();
  const { rows, reload } = useWorkRows();
  const refresh = useRef(reload);
  refresh.current = reload;
  const { search } = useLocation();
  const [legacy, setLegacy] = useState<Awaited<ReturnType<typeof migrateLegacy>> | null>(null);
  useEffect(() => {
    if (!unified) return;
    let live = true;
    const read = () => { void migrateLegacy().then((r) => { if (live) { setLegacy(r); if (r.ok) refresh.current(); } }); };
    read();
    const timer = setInterval(read, 5000);
    return () => { live = false; clearInterval(timer); };
  }, [unified]);
  if (unified === false) return <ChatPage />;
  if (unified === null || !rows) return null;
  const codex = new URLSearchParams(search).get("provider") === "codex";
  const fid = codex ? legacy?.codex_fid : legacy?.fid;
  const mine = fid ? rows.find((r) => r.id === fid || r.board?.history?.id === fid || r.live?.ident === fid) : undefined;
  if (mine) return <Navigate to={sessionPath(mine)} replace />;
  // Closed records age out of the board; the owner's FID stays readable through
  // the normal authenticated history reader, even before its first board push.
  if (legacy?.ok && fid) return <ChatThread source={{ kind: "session", worker: `fid:${fid}`,
    machine: "", key: "", agent: codex ? "codex" : "claude" }} />;
  if (legacy?.ok && !fid) return <Navigate to="/" replace />;
  if (legacy?.readOnly) return <p role="status" className="p-4 text-sm">{tr("旧对话尚未整理，请用本人的账号登录后继续。", "Your previous chat has not been migrated yet. Sign in with your own account to continue.")}</p>;
  if (legacy && !legacy.ok && legacy.why !== "busy") return <p role="status" className="p-4 text-sm">{tr("暂时无法读取以前的对话，正在重试…", "Could not read your previous chat yet. Retrying…")}</p>;
  return <p role="status" className="p-4 text-sm">{tr("正在把以前的对话加入会话列表…", "Adding your previous chat to the session list…")}</p>;
}

// Moved: an old address, sent on to where legacy.ts says it lives now — or,
// for one it leaves be (bare /sessions), the page still there.
const STAYS: Record<string, ComponentType> = { "/sessions": lazy(() => import("./pages/sessions")) };
function Moved() {
  const { pathname, search, hash } = useLocation();
  const to = legacyTarget(pathname, search, hash);
  const Stay = to === null ? STAYS[pathname.replace(/\/+$/, "")] : undefined;
  return Stay ? <Stay /> : <Navigate to={to ?? "/"} replace />;
}

export type PageDef = {
  id: string;
  path: string;            // under /app ("/" is /app itself)
  label: string;
  icon: LucideIcon;
  page?: ComponentType;
  href?: string;           // the old page's address, while it has no page here
};

export const PAGES: PageDef[] = [
  { id: "studio", path: "/studio", label: "活页工作台", icon: Layers, page: lazy(() => import("./pages/studio")) },
  { id: "schedules", path: "/schedules", label: tr("定时任务", "Schedules"), icon: Gauge, page: lazy(() => import("./pages/schedules")) },
  { id: "health", path: "/health", label: tr("服务健康", "Service health"), icon: Gauge, page: lazy(() => import("./pages/health")) },
  { id: "home", path: "/", label: tr("会话", "Sessions"), icon: Layers, page: Home },
  { id: "chat", path: "/chat", label: tr("我的对话", "My chat"), icon: MessageCircle, page: ChatRoute },
  // 新会话 (GR5E C3; 会话合一 Y01K: the one way to start one): 对话 | 终端, on the right of a computer, a phone's whole screen
  { id: "new", path: "/new", label: tr("新会话", "New session"), icon: Plus, page: NewSession },
  { id: "session", path: "/s/:ref", label: tr("会话", "Session"), icon: Layers, page: lazy(() => import("./pages/session")) },
  { id: "me", path: "/me/:tab", label: tr("我的", "Me"), icon: CircleUserRound, page: lazy(() => import("./pages/me")) },
  // the old addresses (legacy.ts): each a hop to where it lives now
  ...Object.keys(LEGACY).map((path) => ({ id: `old${path}`, path, label: path, icon: Layers, page: Moved })),
];

// 我的's tabs, in order: each the page it was before, drawn under the tabs.
export type MeTab = { id: string; path: string; label: string; icon: LucideIcon; page: ComponentType; wide?: boolean };
export const ME_TABS: MeTab[] = [
  { id: "usage", path: "/me/usage", label: tr("用量", "Usage"), icon: Gauge, page: lazy(() => import("./pages/usage")), wide: true },
  { id: "devices", path: "/me/devices", label: tr("设备", "Devices"), icon: MonitorSmartphone, page: lazy(() => import("./pages/devices")) },
  { id: "settings", path: "/me/settings", label: tr("设置", "Settings"), icon: Settings, page: lazy(() => import("./pages/settings")) },
  { id: "account", path: "/me/account", label: tr("账号", "Account"), icon: CircleUserRound, page: lazy(() => import("./pages/account")) },
];
export const meTab = (id: string) => ME_TABS.find((t) => t.id === id)!;

// The admin side, for an admin only (EPIC #3923 rule 6; C10).
export const ADMIN_HREF = "/admin";

// Where a page lives: a route inside this app, or the old page's address.
export const linkOf = (p: PageDef) => (p.page ? { to: p.path } : { href: p.href! });
