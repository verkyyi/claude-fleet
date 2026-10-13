// machines/demo.ts — 机器与 pod's part of the prototype's hub (EPIC #3923
// rule 14; C11): the real reads' shapes with made-up machines, answering in
// memory. Only a VITE_DEMO=1 build reaches it (../demo.ts asks it first);
// DemoEventSource stands in for the hub's log stream there.
import type { ApiInit } from "../api";
import type { CIRunner, FleetDevice, MachineView, NodeDetail, NodeView, NodesSnapshot, ServiceStatus, SpotNodeView } from "./model";

const now = Date.now();
const ago = (min: number) => new Date(now - min * 60_000).toISOString();
const STABLE = "fa76175e2b9c41d8a0f3c6e15b7d2a9c4e810b36";
const OLD = "ddb7739a51c2e04f9b8d7e6c3a2f1b0e9d8c7b6a";
const GiB = 1 << 30;

const wave = (base: number, amp: number, n = 24, seed = 1) =>
  Array.from({ length: n }, (_, i) => Math.max(0, +(base + amp * Math.sin((i + seed) / 3.1) + amp * 0.4 * Math.sin((i * seed) / 1.7)).toFixed(2)));

type DemoMachine = MachineView & { _logins: { user: string; sessions: number; max: number; admit?: boolean; why?: string }[]; _comps?: Record<string, string> };

const svc = (login: string, name: string, kind: "service" | "task", state: string, line: string, extra: Partial<ServiceStatus> = {}): ServiceStatus => ({
  login,
  name,
  kind,
  state,
  last_log_line: line,
  started_at: ago(60 * 26),
  ...extra,
});

let maint: Record<string, { reason: string; since: string; by: string } | undefined> = {
  "mac-b": { reason: "换内存条", since: ago(95), by: "zhouning (gh:1001)" },
};
let spotOn = true;
const retired = new Set<string>();

function machines(): DemoMachine[] {
  const all: DemoMachine[] = [
    {
      hostname: "mac-a",
      status: "online",
      sessions: 9,
      load1: 0.42 * 10,
      ncpu: 10,
      mem_free_bytes: 9 * GiB,
      mem_total_bytes: 32 * GiB,
      last_heartbeat: ago(0.2),
      fleet_version: STABLE,
      versions: { runtime: STABLE },
      role: "host",
      kind: "fixed",
      links: 1,
      load_hist: wave(0.4, 0.15, 24, 2),
      spare: 3,
      spare_target: 4,
      logins_used: 5,
      login_cap: 8,
      door: { state: "open", port: 22022 },
      services: [
        svc("zhouning", "doc-preview", "service", "running", "GET /d/0d734e 200 12ms"),
        svc("zhouning", "daily-report", "task", "ok", "published 2026-10-13 · 18 items", { last_run: ago(60 * 9), next_run: new Date(now + 15 * 3600_000).toISOString() }),
        svc("linxiao", "webchat", "service", "idle", "idle 2h, exited 75"),
      ],
      services_at: ago(0.5),
      _logins: [
        { user: "zhouning", sessions: 6, max: 8 },
        { user: "linxiao", sessions: 3, max: 6 },
      ],
      _comps: { ccquota: "0.94.2", claude: "2.1.301", codex: "0.61.0", tmux: "3.5a" },
    },
    {
      hostname: "mac-b",
      status: "maintenance",
      sessions: 0,
      load1: 0.05 * 8,
      ncpu: 8,
      mem_free_bytes: 13 * GiB,
      mem_total_bytes: 16 * GiB,
      last_heartbeat: ago(0.4),
      fleet_version: STABLE,
      versions: { runtime: STABLE },
      role: "host",
      kind: "fixed",
      links: 1,
      load_hist: wave(0.08, 0.05, 24, 5),
      spare: 2,
      spare_target: 2,
      logins_used: 3,
      login_cap: 6,
      door: { state: "open", port: 22022 },
      services: [svc("amei", "nightly-backup", "task", "failed", "rsync: connection unexpectedly closed (code 12)", { last_rc: 12, last_run: ago(60 * 7), next_run: new Date(now + 17 * 3600_000).toISOString() })],
      services_at: ago(0.6),
      _logins: [
        { user: "amei", sessions: 0, max: 6 },
        { user: "chenyu", sessions: 0, max: 4 },
      ],
      _comps: { ccquota: "0.94.2", claude: "2.1.301", codex: "0.61.0", tmux: "3.5a" },
    },
    {
      hostname: "linux-a",
      status: "online",
      sessions: 6,
      load1: 0.81 * 16,
      ncpu: 16,
      mem_free_bytes: 11 * GiB,
      mem_total_bytes: 64 * GiB,
      last_heartbeat: ago(0.1),
      fleet_version: STABLE,
      versions: { runtime: STABLE },
      role: "host",
      kind: "fixed",
      links: 2,
      load_hist: wave(0.75, 0.2, 24, 3),
      door: { state: "off" },
      services: [svc("chenyu", "ci-runner", "service", "running", "job 4412 · shard 7/14 · ok")],
      services_at: ago(0.3),
      _logins: [
        { user: "chenyu", sessions: 4, max: 4, admit: false, why: "memory: 2.1 GB free < 4 GB" },
        { user: "laozhou", sessions: 2, max: 4 },
      ],
      _comps: { ccquota: "0.94.2", claude: "2.1.301", codex: "0.61.0", tmux: "3.4" },
    },
    {
      hostname: "pod-3f2a",
      status: "online",
      sessions: 2,
      load1: 0.3 * 4,
      ncpu: 4,
      mem_free_bytes: 5 * GiB,
      mem_total_bytes: 8 * GiB,
      last_heartbeat: ago(0.2),
      fleet_version: STABLE,
      versions: { runtime: STABLE },
      role: "host",
      kind: "ephemeral",
      links: 1,
      load_hist: wave(0.3, 0.1, 9, 4),
      door: { state: "off" },
      _logins: [{ user: "spot", sessions: 2, max: 4 }],
    },
    {
      hostname: "pod-9c11",
      status: "online",
      sessions: 0,
      load1: 0,
      ncpu: 4,
      mem_free_bytes: 7 * GiB,
      mem_total_bytes: 8 * GiB,
      last_heartbeat: ago(0.3),
      fleet_version: OLD,
      versions: { runtime: OLD },
      role: "host",
      kind: "ephemeral",
      links: 1,
      load_hist: wave(0.02, 0.02, 14, 6),
      door: { state: "off" },
      _logins: [{ user: "spot", sessions: 0, max: 4 }],
    },
    {
      hostname: "u-7c1e9a",
      status: "online",
      sessions: 1,
      load1: 0.12 * 2,
      ncpu: 2,
      mem_free_bytes: 2 * GiB,
      mem_total_bytes: 4 * GiB,
      last_heartbeat: ago(0.5),
      fleet_version: STABLE,
      versions: { runtime: STABLE },
      role: "host",
      kind: "fixed",
      links: 1,
      load_hist: wave(0.12, 0.06, 24, 7),
      door: { state: "cluster" },
      _logins: [{ user: "linxiao", sessions: 1, max: 2 }],
    },
    {
      hostname: "zhouning-ipad",
      status: "online",
      sessions: 0,
      load1: 0,
      ncpu: 0,
      last_heartbeat: ago(42),
      role: "client",
      kind: "fixed",
      load_hist: [],
      _logins: [{ user: "zhouning", sessions: 0, max: 0 }],
    },
  ];
  return all
    .filter((m) => !retired.has(m.hostname))
    .map((m) => {
      const mt = maint[m.hostname];
      return { ...m, maintenance: mt ? { machine: m.hostname, ...mt } : undefined, status: mt ? "maintenance" : m.status === "maintenance" ? "online" : m.status };
    });
}

const nodesOf = (m: DemoMachine): NodeView[] =>
  m._logins.map((l, i) => ({
    hostname: m.hostname,
    os_user: l.user,
    endpoint_id: `ep_${m.hostname}_${i}`,
    status: m.status,
    last_heartbeat: m.last_heartbeat,
    sessions: l.sessions,
    max_sessions: l.max,
    admit: l.admit,
    admit_why: l.why,
    agent_version: "0.94.2",
    fleet_version: m.fleet_version,
    trust: m.role === "client" ? undefined : "trusted",
    trust_source: m.kind === "ephemeral" ? "join_code" : "machine",
    desired: m.hostname === "pod-9c11" ? { want: 41, reached: 40, release: OLD, want_release: STABLE } : undefined,
  }));

function spotNodes(): SpotNodeView[] {
  return [
    { id: "sp_3f2a", pod_name: "fleet-spot-3f2a", state: "online", created_at: ago(140), hostname: "pod-3f2a", idle_sec: 0, age_sec: 140 * 60, peak_sessions: 3 },
    { id: "sp_9c11", pod_name: "fleet-spot-9c11", state: "online", created_at: ago(85), hostname: "pod-9c11", idle_sec: 1260, age_sec: 85 * 60, peak_sessions: 1 },
    { id: "sp_x7k2", pod_name: "fleet-spot-x7k2", state: "provisioning", created_at: ago(1), age_sec: 60 },
  ].filter((s) => !s.hostname || !retired.has(s.hostname));
}

function snapshot(): NodesSnapshot {
  const ms = machines();
  return {
    at: new Date().toISOString(),
    machines: ms.map(({ _logins, _comps, ...m }) => m),
    nodes: ms.flatMap(nodesOf),
    spot: { enabled: spotOn, max: 4, idle_minutes: 30, nodes: spotNodes(), history: [] },
  };
}

function detail(host: string): NodeDetail | null {
  const m = machines().find((x) => x.hostname === host);
  if (!m) return null;
  const { _logins, _comps, ...mv } = m;
  const names = ["issue-3934", "issue-3935", "scratch-30", "issue-3936", "issue-3929", "scratch-12", "issue-3941", "issue-3933", "issue-3940"];
  const titles = ["机器与 pod", "订阅池", "批次驱动 · EPIC #3923", "全队用量和全部会话", "用量：还剩多少", "看一下 nightly 为什么红", "帮助文档先讲怎么用", "管理侧的骨架", "官网讲成一个服务"];
  const states = ["working", "working", "needs", "working", "done", "idle", "working", "done", "working"];
  const sessions = Array.from({ length: m.sessions || 0 }, (_, i) => ({
    machine_name: host,
    os_user: _logins[i % _logins.length].user,
    worker: { key: names[i % names.length], title: titles[i % titles.length], state: states[i % states.length], repo: "acme/web", born: Math.floor((now - (i + 1) * 23 * 60_000) / 1000) },
  }));
  const behind = m.fleet_version === OLD;
  return {
    at: new Date().toISOString(),
    machine: mv,
    logins: nodesOf(m),
    logins_at: ago(0.2),
    services: m.services || [],
    services_at: m.services_at || null,
    version: {
      agent: "0.94.2",
      fleet: m.fleet_version,
      runtime: m.versions?.runtime,
      ...(behind ? { want: 41, reached: 40, release: OLD, want_release: STABLE, phase: "verify", result: "waiting", reason: "machine doctor running" } : { want: 41, reached: 41, release: STABLE, want_release: STABLE, result: "ok" }),
      components: _comps,
      want_components: _comps ? { ..._comps, tmux: "3.5a" } : undefined,
      at: ago(0.5),
    },
    load: { now: m.load1, ncpu: m.ncpu, hist: m.load_hist, hist_step_sec: 300, at: ago(0.2) },
    mem: { used: (m.mem_total_bytes || 0) - (m.mem_free_bytes || 0), total: m.mem_total_bytes || 0, pressure: m.mem_total_bytes ? 1 - (m.mem_free_bytes || 0) / m.mem_total_bytes : null, at: ago(0.2) },
    sessions,
    sessions_at: ago(0.2),
  };
}

let devices: FleetDevice[] = [
  { fingerprint: "SHA256:q3Vn8pX2bL0eTzR4kW9mYc7fJ1sH6aD5uG2iO8nE4vQ", principal_id: "gh:1001", name: "zhouning-MacBook-Air", registered_at: ago(60 * 24 * 40), last_used_at: ago(2), last_machine: "mac-a", renewals: 37 },
  { fingerprint: "SHA256:Lm4Rt7Yb2Nc9Kx1Wq6Zp3Vf8Hd5Js0Ga2Ue7Io4Pe1A", principal_id: "p:7c1e", name: "linxiao-MacBook-Air", registered_at: ago(60 * 24 * 21), last_used_at: ago(3), last_machine: "u-7c1e9a", renewals: 19 },
  { fingerprint: "SHA256:Tx8Kd2Fw5Bn1Mq7Rv4Jz9Ls3Hc6Gy0Pe8Ua5Wi2Oe7B", principal_id: "p:7c1e", name: "linxiao-iPhone (Termius)", registered_at: ago(60 * 24 * 9), last_used_at: ago(60 * 48), last_machine: "u-7c1e9a", renewals: 4 },
  { fingerprint: "SHA256:Hb5Nz1Qw8Xe4Vr7Ty2Uk6Io9Pa3Sd0Fg5Hj8Kl1Zx4C", principal_id: "gh:2002", name: "chenyu-thinkpad", registered_at: ago(60 * 24 * 60), last_used_at: ago(60 * 24 * 12), last_machine: "linux-a", renewals: 22, revoked_at: ago(60 * 24 * 11), revoked_by: "zhouning (gh:1001)" },
  { fingerprint: "SHA256:Mk2Ws9Ex5Rc1Tv8Yb4Un7Iq3Op6Az0Sx2Dc9Fv5Gb1H", principal_id: "gh:1001", name: "mac-a", registered_at: ago(60 * 24 * 90), last_used_at: ago(1), last_machine: "mac-a", renewals: 88, host: true },
];

const runners: CIRunner[] = [
  { machine: "mac-a", online: true, heard_at: ago(0.3), runner: { state: "idle", runs: 214, failed: 9, since: ago(12) } },
  { machine: "linux-a", online: true, heard_at: ago(0.2), runner: { state: "busy", runs: 1302, failed: 41, since: ago(3) } },
  { machine: "mac-b", online: true, heard_at: ago(0.4), runner: { state: "paused", why: "maintenance", runs: 77, failed: 2 } },
];

let joinLabel = "";
let joinAt = 0;

// demoMachines answers the reads and writes of 机器与 pod; undefined = not ours.
export function demoMachines(method: string, u: URL, body: Record<string, any>, empty: boolean, init: ApiInit): unknown | undefined {
  const p = u.pathname;
  if (method === "GET" && p === "/v1/nodes") {
    const s = snapshot();
    return empty ? { ...s, machines: s.machines.filter((m) => m.hostname === "mac-a"), nodes: s.nodes.filter((n) => n.hostname === "mac-a"), spot: { ...s.spot!, nodes: [] } } : s;
  }
  if (method === "GET" && p.startsWith("/v1/nodes/") && !p.includes("/services/")) {
    const d = detail(decodeURIComponent(p.slice("/v1/nodes/".length)));
    if (!d) throw Object.assign(new Error("no such machine"), { status: 404 });
    return d;
  }
  if (method === "HEAD" && p.includes("/services/") && p.endsWith("/log")) return null;
  if (method === "GET" && p === "/version") return { version: "prod-fa76175", stable: STABLE, client_version: STABLE };
  if (method === "GET" && p === "/v1/fleet/ci-runners") return { runners, idle: 1, online: 3 };
  if (method === "GET" && p === "/v1/fleet/settings") return { hub: [{ key: "fleet.spot", value: spotOn ? "on" : "off" }] };
  if (method === "PUT" && p === "/v1/fleet/settings") {
    const key = String(body.key || "");
    if (key === "fleet.spot") spotOn = body.value === "on";
    else if (key.startsWith("fleet.node_maintenance.")) {
      const m = key.slice("fleet.node_maintenance.".length);
      maint = { ...maint, [m]: body.value ? { reason: String(body.value), since: new Date().toISOString(), by: "zhouning (gh:1001)" } : undefined };
    }
    return { key, value: body.value };
  }
  if (method === "POST" && p === "/v1/fleet/nodes/retire") {
    const host = String(body.endpoint_id || "").replace(/^ep_/, "").replace(/_\d+$/, "");
    retired.add(host);
    return { retired: body.endpoint_id };
  }
  if (method === "POST" && p === "/v1/fleet/nodes/join-codes") {
    joinLabel = String(body.label || "");
    joinAt = Date.now();
    const code = "J7Q-" + Math.random().toString(36).slice(2, 6).toUpperCase() + "-" + Math.random().toString(36).slice(2, 6).toUpperCase();
    return { code, label: joinLabel, expires_at: new Date(Date.now() + 30 * 60_000).toISOString(), command: `curl -fsSL https://fleet.example.cn/install/node | sudo sh -s -- --join ${code}` };
  }
  if (method === "GET" && p === "/v1/fleet/join-codes") {
    // the prototype's machine joins twelve seconds after the code is shown
    const used = joinLabel && Date.now() - joinAt > 12_000;
    return { codes: joinLabel ? [{ label: joinLabel, ...(used ? { used_at: new Date().toISOString(), joined_host: "mac-studio" } : {}) }] : [] };
  }
  if (method === "GET" && p === "/v1/admin/devices") return { mine: false, idle_sec: 2592000, devices: empty ? [] : devices, audit: [] };
  if (method === "POST" && p === "/v1/fleet/devices/revoke") {
    devices = devices.map((d) => (d.fingerprint === body.fingerprint ? { ...d, revoked_at: new Date().toISOString(), revoked_by: "zhouning (gh:1001)" } : d));
    return { revoked: body.fingerprint };
  }
  if (method === "POST" && p === "/v1/fleet/service_control") return { status: body.action === "run_now" ? "succeeded" : "running", op_id: "op_" + Date.now().toString(36) };
  if (method === "GET" && p === "/v1/fleet/cred-policy" && u.searchParams.get("endpoint_id")) {
    const host = String(u.searchParams.get("endpoint_id")).replace(/^ep_/, "").replace(/_\d+$/, "");
    return { effective: { machine: "m:" + host } };
  }
  void init;
  return undefined;
}

// DemoEventSource is the log stream's stand-in: the recent lines at once,
// then a line every couple of seconds, a ping in between.
export class DemoEventSource {
  onerror: ((e: Event) => void) | null = null;
  private hs: Record<string, ((e: MessageEvent) => void)[]> = {};
  private timers: number[] = [];
  constructor(url: string) {
    const name = decodeURIComponent(url.split("/").slice(-2)[0] || "service");
    const base = Date.now() - 200 * 7000;
    const say = (i: number) => ({ ts: new Date(base + i * 7000).toISOString(), text: line(name, i) });
    this.timers.push(window.setTimeout(() => this.emit("lines", { lines: Array.from({ length: 60 }, (_, i) => say(i + 140)), from: 0, start: false }), 300));
    let i = 200;
    this.timers.push(window.setInterval(() => this.emit("lines", { lines: [{ ts: new Date().toISOString(), text: line(name, i++) }] }), 2200));
  }
  addEventListener(kind: string, fn: (e: MessageEvent) => void) {
    (this.hs[kind] ||= []).push(fn);
  }
  private emit(kind: string, data: unknown) {
    for (const fn of this.hs[kind] || []) fn(new MessageEvent(kind, { data: JSON.stringify(data) }));
  }
  close() {
    this.timers.forEach((t) => clearTimeout(t));
  }
}

function line(name: string, i: number): string {
  if (name === "nightly-backup") return i % 9 === 0 ? "rsync: connection unexpectedly closed (code 12)" : `sending incremental file list · ${(i * 37) % 900} files`;
  if (name === "ci-runner") return `job ${4300 + Math.floor(i / 3)} · shard ${(i % 14) + 1}/14 · ${i % 11 === 0 ? "retry" : "ok"}`;
  if (name === "daily-report") return `step ${(i % 6) + 1}/6 · ${["fetch issues", "fetch PRs", "summarise", "render", "publish", "push wechat"][i % 6]}`;
  return `GET /d/${(i * 7919).toString(16).slice(0, 6)} 200 ${(i * 13) % 40}ms`;
}
