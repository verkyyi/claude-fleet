// api.ts — the admin side's one road to the hub: same-origin fetch of the
// existing /v1 reads and writes (EPIC #3923 rule 7). A refusal throws ApiError
// with the hub's own words. A demo build (VITE_DEMO=1, the clickable prototype
// of rule 14) answers from demo.ts instead and never touches a network.
import { demoApi } from "./demo";

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

export type ApiInit = { method?: string; json?: unknown };

const DEMO = import.meta.env.VITE_DEMO === "1";

export async function api<T = any>(url: string, init: ApiInit = {}): Promise<T> {
  if (DEMO) return demoApi(url, init) as Promise<T>;
  const req: RequestInit = { credentials: "same-origin", headers: { Accept: "application/json" }, method: init.method };
  if (init.json !== undefined) {
    req.method = init.method || "POST";
    req.headers = { Accept: "application/json", "Content-Type": "application/json" };
    req.body = JSON.stringify(init.json);
  }
  const r = await fetch(url, req);
  const text = await r.text();
  let body: any = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  if (!r.ok) {
    // a fleet tool's refusal is {error: {code, message}} (claude-fleet#2527)
    const why = body && (body.error && typeof body.error === "object" ? body.error.message : body.error || body.message);
    throw new ApiError(why || `${r.status} ${r.statusText}`.trim(), r.status);
  }
  return body as T;
}

// The shapes this side reads, field for field as the hub writes them.

export type PersonLogin = { hostname: string; login: string; state: string; home?: boolean; kind: "node" | "client" };

export type HubUser = {
  principal_id: string;
  principal: string;
  github_id: number;
  login: string;
  role: "user" | "admin";
  machine_login?: string;
  added_by?: string;
  added_at?: string;
  last_seen?: string;
  deploy?: boolean;
  logins: PersonLogin[];
  via?: string[];
};

// Organizations and pools (task PNWW): /v1/fleet/orgs · /orgs/members · /pools
export type Org = {
  org_id: string;
  name: string;
  kind: "platform" | "trial" | "customer";
  status: "active" | "disabled";
  allow_platform_pool: boolean;
  members: number;
  pools: number;
  budget?: string;
  manage: boolean;
};
export type OrgMember = { principal: string; login: string; org_id: string; org_role: "admin" | "member"; on_list: boolean };
export type OrgPool = {
  pool_id: string;
  name: string;
  owner_kind: "platform" | "org" | "person";
  owner_id: string;
  priority: number;
  enabled: boolean;
  implicit?: boolean;
  credentials: number;
  manage: boolean;
};

export type DeployAdmin = { login: string; github_id?: number; pinned: boolean; logins: PersonLogin[] };
export type UsersList = { users: HubUser[]; admins: DeployAdmin[]; added?: string; github_id?: number; removed?: string; devices_revoked?: number };

export type Invite = {
  id: string;
  github_login?: string;
  email?: string;
  created_by?: string;
  created_at: string;
  expires_at: string;
  used_at?: string;
  used_by?: string;
  revoked_at?: string;
  state: "active" | "used" | "revoked" | "expired";
};
export type InviteCreated = Invite & { code: string; url: string; command: string };

export type PersonBudget = {
  principal: string;
  display_name?: string;
  limit_5h?: number;
  limit_week?: number;
  used_5h?: number;
  used_week?: number;
  over?: boolean;
  window?: string; // 5h | week | trial | trial_tokens | trial_usd, when over
  // a trial member's limits (claude-fleet T789 / T796)
  trial_until?: string;
  trial_since?: string;
  trial_tokens?: number;
  trial_used_tokens?: number;
  trial_usd?: number;
  trial_spent_usd?: number;
  trial_sessions?: number;
  upgrade_asked?: string;
};

export type NodeMachine = { hostname?: string; spare?: number; spare_target?: number; logins_used?: number; login_cap?: number };

// reach (claude-fleet#4057 C9): absent while the official account road is off
export type Me = { role?: string; person?: string; name?: string; login?: string; reach?: { wechat: boolean } };

// cred-policy (claude-fleet#3713): who may use which subscription.
export type PolicyEntry = { id: string; allow: string[]; all?: boolean; error?: string };
// services: the service principals (svc:<name>) a list can be written for —
// their lists are users entries keyed svc:<name> (claude-fleet#4085).
export type PolicyService = { id: string; name: string; enabled: boolean };
export type PolicyView = { mode?: "legacy" | "strict"; users?: PolicyEntry[]; nodes?: PolicyEntry[]; services?: PolicyService[] };
export type Credential = { provider: string; account: string; account_uuid?: string; credential_id?: string; principal_id?: string };
export type Limits = { per_account?: { account_uuid?: string; limits?: Record<string, any> }[] };

// The release ledger (GET /v1/fleet/release/stats, claude-fleet#3870): every
// run of the train, its stages, the hub's bottleneck line, and the two lanes.
export type TrainStage = { name: string; offset_secs: number; secs: number; budget_secs: number; queue_secs?: number; result?: string; off_path?: boolean };
export type TrainRun = {
  run_id: string;
  run_url?: string;
  sha: string;
  conclusion: "success" | "failure" | "cancelled" | "superseded" | string;
  started_at: string;
  ended_at: string;
  total_secs: number;
  merges: { sha: string; merged_at: string; subject?: string }[];
  stages: TrainStage[];
  bottleneck: { stage: string; secs: number; why: string } | null;
  mac?: { conclusion: string; secs: number; after_secs: number };
};
export type ReleaseStats = {
  days: number;
  merge_to_stable_n: number;
  merge_to_stable_p50: number | null;
  merge_to_stable_p95: number | null;
  runs_started: number;
  runs_shipped: number;
  run_p50_secs: number | null;
  runs_slow: number;
  runs_slow_said: number;
  lanes: { stable?: string; stable_macos?: string };
  runs: TrainRun[];
};

// GET /version (public): what Linux machines and Macs follow.
export type HubVersion = {
  version: string;
  commit: string;
  stable?: string;
  client_version: string;
  client_version_macos?: string;
  stable_macos_behind?: number;
  stable_macos_behind_since?: string;
};

// GET /v1/fleet/release/keys (claude-fleet#3937): ids and roles, no private material.
export type ReleaseKeys = {
  repo?: string;
  signer: "hub" | "train";
  anchor?: string;
  root: boolean;
  stable?: string;
  stable_key?: string;
  stable_key_trusted: boolean;
  stable_key_revoked: boolean;
  trusted: { id: string; role: string; by?: string }[];
  revoked: number;
  revoked_version: number;
  overlap: boolean;
};
// 全队用量 (claude-fleet#3936): /v1/admin/usage is each person read as their
// own /v1/me/usage reads them; ?principal= is that whole answer.
export type MeUsageLimit = {
  set: boolean;
  limit_week?: number;
  used_week: number;
  remaining_week?: number;
  reset_week?: string;
  limit_5h?: number;
  used_5h: number;
  remaining_5h?: number;
  reset_5h?: string;
  over?: boolean;
  window?: string;
};
export type UsagePerson = { principal: string; name: string; today: number; week: number; limit: MeUsageLimit };
export type UsageModel = { name: string; provider: string; tokens: number };
export type UsageMachine = { node: string; today: number; week: number; people: number };
export type SvcUsageBudget = { used_day: number; used_week: number; limit_day: number; limit_week: number; over: boolean };
export type UsageService = { principal: string; tenant: string; enabled: boolean; budget: SvcUsageBudget; service_budget: SvcUsageBudget };
export type TeamUsage = { services?: UsageService[]; people: UsagePerson[]; models: UsageModel[]; machines: UsageMachine[] };
// /v1/admin/usage/trial: one Beijing day of the trial identities (WACK C6) —
// the same count as /v1/admin/usage, split by where it was spent.
export type TrialSpendPerson = {
  principal: string;
  name: string;
  kind?: string;
  trial_day: number;
  tokens: number;
  pool: number;
  byo: number;
  new: boolean;
  active: boolean;
  over: boolean;
};
export type TrialSpend = {
  day: string;
  new: number;
  active: number;
  tokens: number;
  pool: number;
  byo: number;
  by_source: Record<string, number>;
  over: number;
  all_over: boolean;
  line: { person_day: number; all_day: number; daily: boolean };
  machines: { node: string; load_pct: number }[];
  people: TrialSpendPerson[];
};
export type UsageSession = { kind?: string; worker_id?: string; key?: string; repo?: string; issue?: number; today: number; week: number };
export type MeUsage = { range: string; today: number; week: number; total: number; limit: MeUsageLimit; models: UsageModel[]; by_session: UsageSession[] };

// /v1/admin/overview: who is on what, their sessions and logins.
export type OverviewPerson = {
  principal: string;
  name: string;
  today: number;
  week: number;
  doing?: { repo: string; issue?: number; tokens: number } | null;
  sessions: number;
  running: number;
  logins: [string, string][];
  subs: string[];
};
export type OverviewSub = { account: string; label: string };
export type FleetNode = { machine_name: string; availability: string; disabled?: string };
export type Overview = {
  people: OverviewPerson[];
  pool: OverviewSub[];
  nodes: FleetNode[];
  totals: { tokens: number; tokens_today: number; sessions: number; running: number; machines: number; machines_online: number };
};

// /v1/admin/sessions: fleet_sessions, every person's.
export type FleetWorker = {
  worker_id?: string;
  key?: string;
  name?: string;
  repo?: string;
  title?: string;
  state?: string;
  needs?: string;
  status_kind?: string;
  status_msg?: string;
  detail?: string;
  agent?: string;
  worktree?: string;
  born?: number | string;
};
export type FleetSession = {
  worker_id?: string | null;
  machine_name: string;
  os_user: string;
  availability: string;
  observed_at?: string;
  tokens_today?: number;
  worker: FleetWorker;
};
export type FleetSessions = { sessions: FleetSession[]; nodes?: FleetNode[] };
// 入口设置 · 审计 · 反馈 (EPIC #3923 C15).

// /v1/fleet/settings: every hub setting with what applies and where it comes from.
export type HubSetting = { key: string; value: string; source: "set" | "legacy" | "deploy" | "default"; help?: string };
export type SettingsAnswer = { settings?: Record<string, string>; hub?: HubSetting[] };

// /v1/access (read-only here): which ways in the deploy configured.
export type AccessAnswer = { hub?: { github?: boolean; github_admins?: number; wechat?: boolean; email?: boolean } };

// /v1/fleet/team-bundle?history=1: the team layer and its versions.
export type TeamVersion = { version: number; prev: number; actor?: string; note?: string; created?: string };
export type TeamBundle = { version: number; prev: number; actor?: string; note?: string; created?: string; bundle?: Record<string, any>; history?: TeamVersion[] };

// /v1/admin/audit: the merged audit, newest first.
export type AuditKind = "sub" | "mach" | "dev" | "user" | "set" | "sess";
export type AuditEvent = { at: string; kind: AuditKind; source: string; actor: string; action: string; target?: string; outcome?: string; detail?: string };
export type AuditAnswer = { events: AuditEvent[]; counts: Record<string, number>; days: number; total: number };

// 申请 (GET /v1/admin/requests, claude-fleet#4052): what a person the list
// does not name asked for at /apply, and the admin's decision.
export type AccessRequest = {
  id: string;
  kind: string; // github · email · wechat · wechat-mp
  subject: string;
  display: string;
  use: string;
  team: string;
  referrer: string;
  notify_channel: "wechat" | "email" | "page" | string;
  notify_addr: string;
  state: "pending" | "approved" | "rejected" | "withdrawn";
  reason: string;
  cooldown_until: string;
  decided_by: string;
  created_at: string;
  decided_at: string;
  person?: string;
  trial: boolean;
};
export type RequestsList = {
  requests: AccessRequest[];
  pending: number;
  oldest_pending?: string;
  decided_7d: number;
  approved_7d: number;
  cooldown_days: number;
};
export type RequestDetail = AccessRequest & {
  signins: { count: number; first?: string; last?: string };
  trial_of?: { state: string; started_at: string; placed_at?: string; last_seen?: string; reclaimed_at?: string; minutes: number; messages?: number; ended?: string };
  convo_until?: string;
  earlier: AccessRequest[];
};

// 发通知 (GET/POST /v1/admin/notices, claude-fleet#4063): an admin's service
// notices to members, and how each one's copies went.
export type NoticeReach = "wechat" | "email" | "none";
export type NoticeMember = { principal_id: string; login: string; role: "user" | "admin"; reach: NoticeReach };
export type ServiceNotice = {
  id: string;
  body: string;
  link?: string;
  audience: "all" | "some";
  recipients: string[];
  created_by: string;
  created_at: string;
  delivery: { pending: number; sent: number; undelivered: number; via: Record<string, number> };
};
export type NoticesList = { notices: ServiceNotice[]; today: number; limit: number; members: NoticeMember[] };

// 试用二维码 (claude-fleet MRGB): /v1/admin/trial-codes
export type TrialFunnel = {
  scans: number;
  follows: number;
  granted: number;
  queued: number;
  pending: number;
  first: number;
  next_day: number; // accepted message on the Beijing day after admission
  converted: number;
  p50_secs: number; // scan → first line in the chat, median (0 = none yet)
};
export type TrialCode = {
  id: string;
  scene: number;
  channel: string;
  terms: string; // "" = fleet.apply.trial
  terms_words: string;
  terms_words_en: string;
  cap: number; // 0 = no cap
  until: string; // zero time = no end
  approval: boolean;
  kind: "limit" | "temp";
  state: "live" | "stopped" | "paused";
  paused_why?: string;
  url: string;
  image: string;
  created_by: string;
  created_at: string;
  funnel: TrialFunnel;
};
export type TrialCodePerson = {
  principal: string;
  login: string;
  state: "granted" | "queued" | "pending";
  member: boolean;
  scanned_at: string;
  granted_at: string;
  first_at: string;
};
export type TrialCodeDetail = TrialCode & { people: TrialCodePerson[] };
export type TrialCodesList = {
  codes: TrialCode[];
  totals: TrialFunnel;
  days: number;
  ready: boolean;
  terms: string;
  terms_words: string;
  terms_words_en: string;
  cap: number;
  daily: number;
  today: number;
  burst: number;
  temp_days_max: number;
};

// 紧急开关 (WACK C5): GET / POST /v1/admin/emergency {action, target?, reason?}
export type EmergencyAction = "trial_stop" | "trial_resume" | "code_disable" | "person_stop" | "machine_pause";
export type EmergencyView = {
  trial: { stopped: boolean; by?: string; at?: string; reason?: string; saw: number; trying: number };
  codes: { id: string; channel: string; state: "live" | "stopped" | "paused"; granted: number }[];
  people: { principal: string; login: string; role?: string; trial?: boolean; sessions: number }[];
  stopped: { principal: string; login: string; by?: string; at?: string; sessions: number }[];
  machines: { hostname: string; status: string; paused: boolean; sessions: number; since?: string; by?: string }[];
  done?: { action: EmergencyAction; target?: string; outcome: string; sessions?: number; stopped?: number; devices?: number };
};
