// Task authority, session observation and code landing are independent facts.
// This adapter consumes /v1/fleet/tasks; it never infers a result from inventory.
export type Task = {
  id: string; title: string; via?: string; device?: string; repo?: string;
  session_key?: string; worker_id?: string; state?: string; task_state?: string;
  issue?: string; ticket_ref?: string; parked?: string; asked?: string;
  created_at: string; updated_at?: string; authority_version?: number;
  generation?: number; outcome?: string; cancel_request?: string;
  task_blockers?: { version: number; generation: number; items: TaskBlocker[] };
  requested_agent?: string; resolved_agent?: string; actual_agent?: string;
  pr?: string; pr_state?: string;
  live?: { key?: string; state?: string; needs?: string; status_kind?: string;
    observed_at?: string; source?: string; stale?: boolean } | null;
};
export type TaskBlocker = {
  blocker_id: string; state: "active" | "resolved" | "revoked";
  reason?: string; created_at?: string; resolved_at?: string; revoked_at?: string;
};

// Display the authority's items verbatim. This is not blocker_projection or a
// second eligibility adapter; resolved/revoked items remain visible as history.
export function taskBlockerItems(t: Task): TaskBlocker[] | null {
  const b = t.task_blockers;
  return t.authority_version === 1 && b?.version === 1 && b.generation === t.generation
    && Array.isArray(b.items) && b.items.every((item) => item && typeof item.blocker_id === "string"
      && ["active", "resolved", "revoked"].includes(item.state)) ? b.items : null;
}
export type TasksResponse = { tasks: Task[]; observed_at?: string; stale?: boolean };

const terminal = new Set(["succeeded", "failed", "cancelled", "refused"]);
export function taskStatus(t: Task): string {
  if (t.authority_version === 1) {
    if (terminal.has(t.outcome || "")) return t.outcome!;
    const state = t.task_state || t.state || "";
    return ["accepted", "starting", "running", "waiting"].includes(state) ? state : "unknown";
  }
  // Old placement records have no committed work outcome, even if a retained
  // session says done/idle/working or the placement operation succeeded.
  return t.state === "placing" ? "starting" : t.state === "refused" ? "refused" : "unknown";
}

export function agentMismatch(t: Task): boolean {
  return !!((t.actual_agent && t.resolved_agent && t.actual_agent !== t.resolved_agent)
    || (t.requested_agent && t.resolved_agent && t.requested_agent !== t.resolved_agent));
}

// A task's ticket is a GitHub issue (claude-fleet#4898, T477: the hub's own
// tickets are gone): its accepted ticket_ref `gh:<repo>#<N>`, else the issue the
// record carries.
export function taskTicket(t: Task): { repo: string; n: number } | null {
  if (t.ticket_ref) {
    const m = /^gh:([^\s:#]+)#([1-9][0-9]*)$/.exec(t.ticket_ref);
    return m ? { repo: m[1], n: Number(m[2]) } : null;
  }
  const m = /^([^\s:#]+)#([1-9][0-9]*)$/.exec(t.issue || "");
  return m ? { repo: m[1], n: Number(m[2]) } : null;
}

// PR numbers in the committed report are scoped by the task's repository.
// Never send an arbitrary URL in a response to GitHub.
export function taskPR(t: Task): { repo: string; n: string; url: string } | null {
  const raw = t.pr || "";
  const m = /^(?:https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/|([\w.-]+\/[\w.-]+)#)?([1-9][0-9]*)$/.exec(raw);
  const repo = m?.[1] || m?.[2] || t.repo;
  return m && repo && /^[\w.-]+\/[\w.-]+$/.test(repo)
    ? { repo, n: m[3], url: `https://github.com/${repo}/pull/${m[3]}` } : null;
}

export function taskLanding(t: Task): string {
  if (t.authority_version !== 1) return "unverified";
  // Only the API's fenced landing projection can confirm this, not issue
  // closure, an unavailable GitHub read, or a successful work outcome.
  if (t.pr_state === "none") return "none";
  return taskPR(t) && ["waiting", "merged"].includes(t.pr_state || "") ? t.pr_state! : "unverified";
}

export type TaskRead = { data: TasksResponse | null; failed: boolean };
export function taskRead(previous: TaskRead, response: TasksResponse | null, now: string): TaskRead {
  if (!response || !Array.isArray(response.tasks) || response.tasks.some((t) => !t
    || typeof t.id !== "string" || typeof t.title !== "string" || typeof t.created_at !== "string")) {
    return { data: previous.data, failed: true };
  }
  if (response.stale && previous.data) {
    // An incomplete remote answer cannot turn missing rows into a zero count,
    // nor replace a newer generation with an old cached event.
    return { data: { ...previous.data, stale: true }, failed: false };
  }
  return { data: { ...response, observed_at: response.observed_at || (response.stale ? undefined : now) }, failed: false };
}
