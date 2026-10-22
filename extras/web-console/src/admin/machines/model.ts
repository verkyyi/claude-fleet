// machines/model.ts — 机器与 pod with no DOM (EPIC #3923 C11): the hub's reads,
// field for field as it writes them, made into the rows the page draws. One
// row per machine (/v1/nodes' machines, its logins folded in; its door is the
// roster's `door`, which C11 added — the hub's own reach table, the one read
// the old pages lacked) and "behind" against /version's stable. The
// old pages' own rules are kept: a client device is never a machine row
// (claude-fleet#2795), a lost machine sorts last, a name is the hostname's
// first label (what the maintenance setting and retire are keyed by).

// ---- the hub's shapes -----------------------------------------------------

export type Maintenance = { machine: string; reason?: string; since: string; by?: string };
export type ServiceStatus = {
  name: string;
  kind: string;
  login: string;
  state: string;
  why?: string;
  started_at?: string;
  last_run?: string;
  next_run?: string;
  last_rc?: number;
  restarts?: number;
  last_log_line?: string;
};
// A machine's 「安装」 (claude-fleet#2697): its runtime and every heard login's
// install, client shell and client install, each judged against the stable
// the hub follows (at_stable null = not known); behind_secs is how long it
// has trailed that stable, when the machine knows.
export type InstallItem = {
  version: string;
  kind?: "link" | "dir" | string;
  follows?: boolean;
  source?: "hub" | "runtime" | "github" | "dev" | "?" | string;
  at_stable: boolean | null;
  behind_secs?: number;
};
export type LoginInstall = { login: string; install?: InstallItem; shell?: InstallItem; client?: InstallItem };
export type Installs = { lane?: string; stable?: string; at?: string; runtime?: InstallItem; logins?: LoginInstall[] };

export type MachineView = import("./ParkSummary").ParkReading & {
  hostname: string;
  alias?: string;
  status: "online" | "maintenance" | "lost" | string;
  logins_online?: number;
  logins?: number;
  links?: number;
  sessions: number | null;
  load1: number;
  ncpu: number;
  mem_free_bytes?: number;
  mem_total_bytes?: number;
  last_heartbeat: string | null;
  fleet_version?: string;
  installs?: Installs;
  versions?: { runtime?: string; actual?: Record<string, string>; want?: Record<string, string>; daemon?: string };
  role: "host" | "client" | string;
  maintenance?: Maintenance;
  load_hist: number[];
  logins_refused?: Record<string, string>;
  services?: ServiceStatus[];
  services_at?: string;
  spare?: number;
  logins_used?: number;
  login_cap?: number;
  spare_target?: number;
  door?: { state: "open" | "cluster" | "off"; port?: number };
};
export type DesiredView = { want: number; reached: number; release?: string; want_release?: string; diff?: string };
export type NodeView = {
  hostname: string;
  role?: string;
  os_user?: string;
  endpoint_id?: string;
  machine_link?: boolean;
  status: string;
  last_heartbeat?: string | null;
  sessions?: number | null;
  max_sessions?: number;
  admit?: boolean;
  admit_why?: string;
  agent_version?: string;
  fleet_version?: string;
  trust?: string;
  installs?: Installs;
  trust_source?: string;
  desired?: DesiredView;
  logins_refused?: Record<string, string>;
};
export type NodesSnapshot = { at: string; machines: MachineView[]; nodes: NodeView[] };
export type CIRunner = { machine: string; online: boolean; heard_at?: string; runner: { state: string; why?: string; since?: string; runs: number; failed: number } };
export type VersionInfo = { version?: string; stable?: string; client_version?: string; client_version_macos?: string };
export type SettingsView = { hub?: { key: string; value: string }[] };
export type FleetDevice = {
  fingerprint: string;
  principal_id: string;
  name: string;
  registered_at: string;
  last_used_at: string;
  last_machine?: string;
  renewals: number;
  revoked_at?: string | null;
  revoked_by?: string;
  host?: boolean;
};
export type DevicesResponse = { devices: FleetDevice[] };
export type JoinCode = { code: string; command: string; expires_at: string; label?: string };
export type JoinCodes = { codes: { label?: string; used_at?: string; joined_host?: string }[] };

// /v1/nodes/<host>
export type FleetSession = {
  machine_name?: string;
  os_user?: string;
  worker?: { key?: string; name?: string; title?: string; repo?: string; state?: string; born?: number; worker_id?: string };
};
export type NodeDetail = {
  at: string;
  machine: MachineView;
  logins: NodeView[];
  other_logins?: number;
  logins_at: string | null;
  services: ServiceStatus[];
  services_at: string | null;
  version: {
    agent?: string;
    fleet?: string;
    release?: string;
    want_release?: string;
    want?: number;
    reached?: number;
    diff?: string;
    runtime?: string;
    components?: Record<string, string>;
    want_components?: Record<string, string>;
    phase?: string;
    result?: string;
    reason?: string;
    at: string | null;
    // a person's pod against stable (claude-fleet#4174): releases behind (-1 = a runtime
    // the ledger does not know) and the hub's last roll
    roll?: { stable?: string; behind?: number; last?: { stable: string; at: string; done: boolean; pending?: boolean; result?: string } };
  };
  load: { now: number; ncpu: number; hist: number[]; hist_step_sec: number; unread?: string[]; at: string | null };
  mem: { used: number; total: number; pressure: number | null; at: string | null };
  sessions: FleetSession[];
  sessions_at: string | null;
};

// ---- rows -----------------------------------------------------------------

export type Kind = "fixed" | "person";
export type Status = "online" | "maintenance" | "lost";
export type Door = { state: "open" | "cluster" | "off" | "unknown"; port?: number };

export type MachineRow = {
  id: string; // the hostname's first label: the row's address and the setting's key
  host: string;
  label: string;
  kind: Kind;
  status: Status;
  loadCore: number | null;
  sessions: number | null;
  cap: number | null;
  version: string; // short sha, or the install's word
  behind: boolean;
  stableShort: string; // what "behind" was measured against
  door: Door;
  seen: string | null;
  maintenance: Maintenance | null;
  eps: string[]; // endpoint ids — what 移除 retires
  policyEps: string[]; // compute endpoints only; a client may retain an older enrollment name
  logins: string[];
  m?: MachineView;
};

export const short = (v?: string) => (v ? (/^[0-9a-f]{12,}$/i.test(v) ? v.slice(0, 7) : v) : "");
export const firstLabel = (h?: string) => String(h || "").split(".")[0];
const sameHost = (a?: string, b?: string) => !!a && !!b && firstLabel(a).toLowerCase() === firstLabel(b).toLowerCase();

// A person's pod is named u-<nonce> (render.py's USER_POD_RE; fleet_door.go isUserPodName).
export const isPersonPod = (h?: string) => /^u-[a-z0-9]{4,20}$/.test(firstLabel(h).toLowerCase());

export const doorOf = (m: MachineView): Door => (m.door ? { state: m.door.state, port: m.door.port } : { state: "unknown" });

// sameVersion: a machine's runtime / install sha against stable's (either
// may be short).
const sameVersion = (a: string, b: string) => !!a && !!b && (a.startsWith(b) || b.startsWith(a));

// Compare installed releases, not the bundle's synthetic git HEAD or a
// personal client's heartbeat. Different login installs remain visible.
export function runtimeVersions(m: MachineView, nodes: NodeView[]): string[] {
  const shared = m.versions?.runtime || m.installs?.runtime?.version;
  if (shared) return [shared];
  const live = nodes.filter((n) => n.role !== "client" && n.status !== "lost" && !n.machine_link);
  const versions = live.map((n) => {
    const login = n.os_user;
    return n.installs?.runtime?.version
      || n.installs?.logins?.find((l) => l.login === login)?.install?.version
      || m.installs?.logins?.find((l) => l.login === login)?.install?.version
      || n.fleet_version || "";
  }).filter(Boolean);
  return [...new Set(versions.length ? versions : nodes.length ? [] : [m.fleet_version || ""].filter(Boolean))];
}

export function machineRows(snap: NodesSnapshot, ver: VersionInfo | null): MachineRow[] {
  const stables = [ver?.stable || ver?.client_version || "", ver?.client_version_macos || ""].filter(Boolean);
  const byHost = new Map<string, NodeView[]>();
  for (const n of snap.nodes || []) {
    const k = firstLabel(n.hostname).toLowerCase();
    byHost.set(k, [...(byHost.get(k) || []), n]);
  }

  const rows: MachineRow[] = (snap.machines || [])
    .filter((m) => m.role !== "client")
    .map((m) => {
      const id = firstLabel(m.hostname);
      const nodes = byHost.get(id.toLowerCase()) || [];
      const kind: Kind = isPersonPod(m.hostname) ? "person" : "fixed";
      const installed = runtimeVersions(m, nodes);
      const offStable = installed.some((v) => /^[0-9a-f]{7,}$/i.test(v) && stables.length > 0 && !stables.some((s) => sameVersion(v, s)));
      const status: Status = m.status === "maintenance" ? "maintenance" : m.status === "online" ? "online" : "lost";
      // A retired login's last heartbeat is history, not current capacity.
      // A resource-admitted login has no fixed count ceiling: adding only its
      // bounded neighbours would incorrectly present their sum as a machine cap.
      const caps = nodes.filter((n) => n.status === "online" && n.role !== "client" && !n.machine_link)
        .map((n) => n.max_sessions || 0);
      const cap = caps.length > 0 && caps.every((c) => c > 0) ? caps.reduce((a, b) => a + b, 0) : null;
      return {
        id,
        host: m.hostname,
        label: m.alias || id,
        kind,
        status,
        loadCore: m.ncpu && m.status !== "lost" ? m.load1 / m.ncpu : null,
        sessions: m.sessions,
        cap,
        version: installed.map(short).join(" / "),
        // Configuration convergence is shown separately in the detail card;
        // an unacknowledged config revision is not an outdated runtime.
        behind: offStable,
        stableShort: short(stables[0]),
        door: doorOf(m),
        seen: m.last_heartbeat,
        maintenance: m.maintenance || null,
        eps: [...new Set(nodes.map((n) => n.endpoint_id || "").filter(Boolean))],
        policyEps: [...new Set(nodes.filter((n) => n.role !== "client").map((n) => n.endpoint_id || "").filter(Boolean))],
        logins: [...new Set(nodes.filter((n) => !n.machine_link && n.os_user).map((n) => n.os_user!))].sort(),
        m,
      };
    });
  const rank: Record<string, number> = { online: 0, maintenance: 2, lost: 4 };
  return rows.sort((a, b) => (rank[a.status] ?? 5) - (rank[b.status] ?? 5) || a.label.localeCompare(b.label));
}

// ---- clients --------------------------------------------------------------

export type ClientRow = {
  id: string; // a device's fingerprint, or "machine:<host>"
  name: string;
  owner: string;
  registered: string | null;
  lastUsed: string | null;
  lastMachine: string;
  renewals: number | null;
  revoked: boolean;
  revokedBy?: string;
  kind: "device" | "machine";
  d?: FleetDevice;
};

// clientRows is /v1/admin/devices without a `fleet login` on a service node
// (host), plus the client computers of /v1/nodes (role client) no device
// already names. owners maps a principal to the person's name.
export function clientRows(devs: DevicesResponse | null, snap: NodesSnapshot | null, owners: Map<string, string>): ClientRow[] {
  const list = (devs?.devices || []).filter((d) => !d.host);
  const rows: ClientRow[] = list.map((d) => ({
    id: d.fingerprint,
    name: d.name || d.fingerprint,
    owner: owners.get(d.principal_id) || d.principal_id || "",
    registered: d.registered_at,
    lastUsed: d.last_used_at,
    lastMachine: d.last_machine || "",
    renewals: Number(d.renewals) || 0,
    revoked: !!d.revoked_at,
    revokedBy: d.revoked_by,
    kind: "device",
    d,
  }));
  const named = new Set(list.filter((d) => !d.revoked_at).map((d) => firstLabel(d.name).toLowerCase()));
  for (const m of snap?.machines || []) {
    if (m.role !== "client" || named.has(firstLabel(m.hostname).toLowerCase())) continue;
    const logins = [...new Set((snap?.nodes || []).filter((n) => sameHost(n.hostname, m.hostname) && n.os_user).map((n) => n.os_user!))];
    rows.push({
      id: "machine:" + m.hostname,
      name: m.alias || firstLabel(m.hostname),
      owner: logins.join(", "),
      registered: null,
      lastUsed: m.last_heartbeat,
      lastMachine: "",
      renewals: null,
      revoked: false,
      kind: "machine",
    });
  }
  return rows.sort((a, b) => Number(a.revoked) - Number(b.revoked) || Date.parse(b.lastUsed || "0") - Date.parse(a.lastUsed || "0"));
}

// ---- services -------------------------------------------------------------

export const FAILED = ["down", "failed", "invalid", "no_login"];
export const SVC_STATES = ["running", "stopped", "down", "failed", "invalid", "no_login", "scheduled", "retrying", "ok", "idle"];

export type ServiceRow = {
  id: string;
  host: string;
  login: string;
  name: string;
  kind: "service" | "task";
  state: string;
  failed: boolean;
  lastRun: string | null;
  nextRun: string | null;
  line: string;
  why: string;
  restarts: number;
  rc: number | null;
};

export function serviceRows(host: string, svcs: ServiceStatus[]): ServiceRow[] {
  return (svcs || [])
    .filter((s) => s && s.name)
    .map((s) => ({
      id: `${s.login}/${s.name}`,
      host,
      login: s.login || "",
      name: s.name,
      kind: (s.kind === "task" ? "task" : "service") as "service" | "task",
      state: s.state || "unknown",
      failed: FAILED.includes(s.state),
      lastRun: s.last_run || s.started_at || null,
      nextRun: s.next_run || null,
      line: s.last_log_line || "",
      why: s.why || "",
      restarts: s.restarts || 0,
      rc: typeof s.last_rc === "number" ? s.last_rc : null,
    }))
    .sort((a, b) => a.kind.localeCompare(b.kind) || a.login.localeCompare(b.login) || a.name.localeCompare(b.name));
}

// actionsFor is a row's service_control actions (lib/services.js): a stopped
// entry starts; a service restarts or stops; a task runs now, takes a new
// schedule or stops. An entry the daemon will not run has none.
export function actionsFor(r: ServiceRow): string[] {
  if (r.state === "invalid" || r.state === "no_login") return [];
  if (r.state === "stopped") return ["start"];
  return r.kind === "task" ? ["run_now", "set_schedule", "stop"] : ["restart", "stop"];
}

export function svcRequest(r: ServiceRow, action: string, extra: Record<string, string> = {}) {
  const rnd = Math.random().toString(36).slice(2, 8);
  return { machine: r.host, login: r.login, name: r.name, action, ...extra, idempotency_key: `web-${action}-${Date.now().toString(36)}-${rnd}` };
}

export const logPath = (host: string, login: string, name: string) =>
  `/v1/nodes/${encodeURIComponent(host)}/services/${encodeURIComponent(login)}/${encodeURIComponent(name)}/log`;

// ---- detail ---------------------------------------------------------------

export type SessionState = "working" | "needs" | "done" | "idle" | "unknown";
export const sessionState = (s?: string): SessionState =>
  s === "working" ? "working" : s === "waiting" || s === "blocked" || s === "needs" ? "needs" : s === "done" ? "done" : s === "idle" ? "idle" : "unknown";

export type CompRow = { name: string; have: string; want: string; off: boolean };
export function components(v: NodeDetail["version"]): CompRow[] {
  const have = v.components || {};
  const want = v.want_components || {};
  return [...new Set([...Object.keys(have), ...Object.keys(want)])].sort().map((k) => ({ name: k, have: have[k] || "", want: want[k] || "", off: !!want[k] && have[k] !== want[k] }));
}

export const gb = (b?: number) => (Number(b) > 0 ? Number(b) / (1 << 30) : 0);
