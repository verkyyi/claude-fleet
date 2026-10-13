// nav.ts — the admin side's left column, grouped 人 · 机器 · 钱 · 发布 · 入口
// (EPIC #3923 C10). A page that has moved to the new console is a route here
// (`to`); one still on the old console links to its old address (`href`) until
// its own ticket (C11–C15) lands it and swaps the line to `to`.
import type { LucideIcon } from "lucide-react";
import { BarChart3, CreditCard, MessageSquareWarning, Rocket, ScrollText, Server, Settings, Users } from "lucide-react";
import type { MsgKey } from "./i18n";

export type NavItem = { key: MsgKey; icon: LucideIcon; to?: string; href?: string };
export type NavGroup = { key: MsgKey; items: NavItem[] };

export const NAV: NavGroup[] = [
  { key: "nav.people", items: [{ key: "page.people", icon: Users, to: "/people" }] },
  { key: "nav.machines", items: [{ key: "page.machines", icon: Server, to: "/machines" }] },
  {
    key: "nav.money",
    items: [
      { key: "page.pool", icon: CreditCard, href: "/app/subscriptions" },
      { key: "page.usage", icon: BarChart3, href: "/app/admin/overview" },
    ],
  },
  { key: "nav.release", items: [{ key: "page.release", icon: Rocket, to: "/release" }] },
  {
    key: "nav.entry",
    items: [
      { key: "page.settings", icon: Settings, href: "/app/admin/settings" },
      { key: "page.audit", icon: ScrollText, href: "/app/admin/audit" },
      { key: "page.feedback", icon: MessageSquareWarning, href: "/app/admin/feedback" },
    ],
  },
];

