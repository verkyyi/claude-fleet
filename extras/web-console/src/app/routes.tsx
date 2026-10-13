// routes.tsx — the member side's ONE page table (EPIC #3923 C3). A page the
// new console draws has its `page`; one still on the old console has none, and
// its tab is a plain link to the old address — until that page's ticket (C4–C8)
// adds its file under pages/ and fills in this one line (and flips its row in
// the hub's consolePages, app_mount.go).
import { createElement, lazy, type ComponentType } from "react";
import { Navigate } from "react-router";
import { Gauge, Layers, ListChecks, MessageCircle, MonitorSmartphone, Settings, CircleUserRound, type LucideIcon } from "lucide-react";
import { tr } from "@/shared/i18n";
// the front page is in the first bundle: the conversation is the first screen
import ChatPage from "./pages/chat";

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
  { id: "sessions", path: "/sessions", label: tr("会话", "Sessions"), icon: Layers, tab: true, side: true, href: "/app/sessions" },
  { id: "tasks", path: "/tasks", label: tr("任务", "Tasks"), icon: ListChecks, tab: true, side: true, page: lazy(() => import("./pages/tasks")) },
  // one ticket, under 任务 (C5); /tasks/tickets/ alone is the tickets tab
  { id: "ticket", path: "/tasks/tickets/:owner/:name/:n", label: tr("单子", "Ticket"), icon: ListChecks, page: lazy(() => import("./pages/ticket")) },
  { id: "tickets", path: "/tasks/tickets", label: tr("单子", "Tickets"), icon: ListChecks, page: () => createElement(Navigate, { to: "/tasks?tab=tickets", replace: true }) },
  { id: "usage", path: "/usage", label: tr("用量", "Usage"), icon: Gauge, tab: true, side: true, page: lazy(() => import("./pages/usage")) },
  { id: "devices", path: "/devices", label: tr("设备", "Devices"), icon: MonitorSmartphone, side: true, page: lazy(() => import("./pages/devices")) },
  { id: "settings", path: "/settings", label: tr("设置", "Settings"), icon: Settings, side: true, href: "/app/config" },
  { id: "me", path: "/me", label: tr("我的", "Me"), icon: CircleUserRound, tab: true, page: lazy(() => import("./pages/me")) },
];

// The admin side, for an admin only (EPIC #3923 rule 6; C10).
export const ADMIN_HREF = "/admin";

// Where a page lives: a route inside this app, or the old page's address.
export const linkOf = (p: PageDef) => (p.page ? { to: p.path } : { href: p.href! });
