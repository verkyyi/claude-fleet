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
import { lazy, useEffect, useState, type ComponentType } from "react";
import { Navigate, useLocation } from "react-router";
import { Gauge, Layers, MessageCircle, MonitorSmartphone, Plus, Settings, CircleUserRound, type LucideIcon } from "lucide-react";
import { tr } from "@/shared/i18n";
// the front page is in the first bundle: the conversation is the first screen
import ChatPage from "./pages/chat";
import { SessionListPage, sessionPath } from "./SessionList";
import { useUnified } from "./chat/home";
import { useWorkRows } from "./work-rows";
import { LEGACY, legacyTarget } from "./legacy";

// The front page: the list on a phone, the conversation beside the list on a
// computer (the left column already is the list). Read before the first paint,
// so a phone never flashes the conversation.
const PHONE = "(max-width: 767px)";
const NewSession = lazy(() => import("./NewSession"));
function Home() {
  const { search } = useLocation();
  const unified = useUnified();
  const [phone, setPhone] = useState(() => matchMedia(PHONE).matches);
  useEffect(() => { const m = matchMedia(PHONE); const f = () => setPhone(m.matches); m.addEventListener("change", f); return () => m.removeEventListener("change", f); }, []);
  // the old first screen was the conversation: only a link into it (?about=) opens it now
  if (phone && !new URLSearchParams(search).has("about")) return <SessionListPage />;
  // 会话合一 (Y01K): a chat is a session; a computer's front page is a new one
  if (unified === null) return null;
  return unified ? <NewSession /> : <ChatPage />;
}

// /chat: the old road's one conversation; on the new one it became a session
// named 「我的对话」 — opened as any session, else the list.
const MY_CHAT = ["我的对话", "My chat"];
function ChatRoute() {
  const unified = useUnified();
  const { rows } = useWorkRows();
  if (unified === false) return <ChatPage />;
  if (unified === null || !rows) return null;
  const mine = rows.find((r) => r.origin === "web" && MY_CHAT.includes(r.title));
  return <Navigate to={mine ? sessionPath(mine) : "/"} replace />;
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
