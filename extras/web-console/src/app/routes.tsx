// routes.tsx — the member side's ONE page table (EPIC #3923 C3). A page the
// new console draws has its `page`; one still on the old console has none, and
// its tab is a plain link to the old address — until that page's ticket (C4–C8)
// adds its file under pages/ and fills in this one line (and flips its row in
// the hub's consolePages, app_mount.go).
//
// 我的 holds 用量 · 设备 · 设置 · 账号 as four tabs at /me/<tab> (GR5E C1): the
// sidebar and the bottom bar carry none of them — the avatar is the way in —
// and their old addresses move on there, query and hash kept.
import { lazy, type ComponentType } from "react";
import { Navigate, useLocation } from "react-router";
import { Gauge, Layers, ListChecks, MessageCircle, MonitorSmartphone, Settings, CircleUserRound, TerminalSquare, type LucideIcon } from "lucide-react";
import { tr } from "@/shared/i18n";
// the front page is in the first bundle: the conversation is the first screen
import ChatPage from "./pages/chat";

// moved(to): an old address of a page that lives at `to` now, its query and
// hash carried along (a sign-in flow comes back to /settings#logins).
const moved = (to: string): ComponentType => function Moved() {
  const { search, hash } = useLocation();
  return <Navigate to={`${to}${search}${hash}`} replace />;
};

export type PageDef = {
  id: string;
  path: string;            // under /app ("/" is /app itself)
  label: string;
  icon: LucideIcon;
  tab?: boolean;           // one of the five on a phone's bottom bar
  side?: boolean;          // listed in the computer's sidebar
  page?: ComponentType;
  href?: string;           // the old page's address, while it has no page here
};

export const PAGES: PageDef[] = [
  { id: "chat", path: "/", label: tr("对话", "Chat"), icon: MessageCircle, tab: true, side: true, page: ChatPage },
  { id: "sessions", path: "/sessions", label: tr("会话", "Sessions"), icon: Layers, tab: true, side: true, page: lazy(() => import("./pages/sessions")) },
  { id: "terminal", path: "/terminal", label: tr("我的终端", "My Terminal"), icon: TerminalSquare, side: true, page: lazy(() => import("./pages/terminal")) },
  // 任务 is one list with 会话 since T769: its address (and a code's ?q=) opens it there
  { id: "tasks", path: "/tasks", label: tr("任务", "Tasks"), icon: ListChecks, page: moved("/sessions") },
  { id: "me", path: "/me/:tab", label: tr("我的", "Me"), icon: CircleUserRound, page: lazy(() => import("./pages/me")) },
  { id: "me-home", path: "/me", label: tr("我的", "Me"), icon: CircleUserRound, page: moved("/me/account") },
  { id: "usage", path: "/usage", label: tr("用量", "Usage"), icon: Gauge, page: moved("/me/usage") },
  { id: "devices", path: "/devices", label: tr("设备", "Devices"), icon: MonitorSmartphone, page: moved("/me/devices") },
  { id: "settings", path: "/settings", label: tr("设置", "Settings"), icon: Settings, page: moved("/me/settings") },
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
