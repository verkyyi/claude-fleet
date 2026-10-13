// tickets.ts — a person's tickets as /v1/fleet/tickets answers them (the hub's
// own tickets, claude-fleet#2677, and the GitHub ones it knows of): the row,
// its page's address under 任务, its state in words.
import { tr } from "@/shared/i18n";

export type Ticket = {
  id: string; repo: string; number: number; owner: string;
  backend: "hub" | "gh" | string; url?: string;
  title: string; body: string; state: "open" | "closed" | string; state_reason?: string;
  labels: string[]; assignee?: string; created_at: string; updated_at: string;
  comments?: number; // the list's: how long its thread is
};

export type TicketComment = { id: number; author: string; body: string; source: string; created_at: string };

// A ticket's page, inside the member side (react-router, under /app).
export const ticketPath = (repo: string, n: number | string) => `/tasks/tickets/${repo}/${n}`;

// "owner/name#N" — how a task record names its issue.
export function parseRef(ref: string | undefined): { repo: string; n: number } | null {
  const m = /^([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)#([1-9][0-9]*)$/.exec(ref || "");
  return m ? { repo: m[1], n: Number(m[2]) } : null;
}

// The words and colour of a ticket's state.
export function ticketState(t: Pick<Ticket, "state" | "state_reason">): { label: string; tone: string } {
  if (t.state !== "closed") return { label: tr("进行中", "Open"), tone: "" };
  if (t.state_reason === "not_planned") return { label: tr("不做了", "Not planned"), tone: "text-muted-foreground" };
  return { label: tr("已关闭", "Closed"), tone: "text-muted-foreground" };
}

// A ticket whose home is GitHub is read here and written there.
export const onGitHub = (t: Pick<Ticket, "backend">) => t.backend !== "hub";
