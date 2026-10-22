// nav.ts — the admin side's left column, grouped 人 · 机器 · 钱 · 发布 · 入口
// (EPIC #3923 C10). A page that has moved to the new console is a route here
// (`to`); one still on the old console links to its old address (`href`) until
// its own ticket (C11–C15) lands it and swaps the line to `to`.
import type { LucideIcon } from "lucide-react";
import { BarChart3, CreditCard, Inbox, Megaphone, OctagonAlert, QrCode, Rocket, ScrollText, Server, Settings, Users } from "lucide-react";
import type { MsgKey } from "./i18n";

// count: a read answering {pending: n}, drawn beside the item when n > 0
export type NavItem = { key: MsgKey; icon: LucideIcon; to?: string; href?: string; count?: string };
export type NavGroup = { key: MsgKey; items: NavItem[] };

export const NAV: NavGroup[] = [
  {
    key: "nav.people",
    items: [
      { key: "page.people", icon: Users, to: "/people" },
      // 申请 (claude-fleet#4052, EPIC #4048 C4), with how many wait
      { key: "page.requests", icon: Inbox, to: "/requests", count: "/v1/admin/requests?state=pending&count=1" },
      // 试用二维码 (claude-fleet MRGB): scan and follow, the trial starts
      { key: "page.trialCodes", icon: QrCode, to: "/trial-codes" },
      // 发通知 (claude-fleet#4063, EPIC #4048 R1)
      { key: "page.notices", icon: Megaphone, to: "/notices" },
    ],
  },
  { key: "nav.machines", items: [{ key: "page.machines", icon: Server, to: "/machines" }] },
  {
    key: "nav.money",
    items: [
      // with how many need a new sign-in (claude-fleet FKS6)
      { key: "page.pool", icon: CreditCard, to: "/pool", count: "/v1/admin/subscriptions/reauth" },
      { key: "page.usage", icon: BarChart3, to: "/usage" },
    ],
  },
  { key: "nav.release", items: [{ key: "page.release", icon: Rocket, to: "/release" }] },
  {
    key: "nav.entry",
    items: [
      { key: "page.settings", icon: Settings, to: "/settings" },
      { key: "page.audit", icon: ScrollText, to: "/audit" },
      // 紧急开关 (WACK C5): stop trials, a code, a person, a machine — one page
      { key: "page.emergency", icon: OctagonAlert, to: "/emergency" },
    ],
  },
];

