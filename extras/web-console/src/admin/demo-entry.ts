// demo-entry.ts — the prototype's hub for 入口设置 · 审计 · 反馈 (EPIC #3923
// C15): the real reads' shapes with made-up rows, answering in memory, so a
// setting changed and changed back leaves its two audit rows, and a team
// version restored is a new version plus one. demo.ts asks it first; only a
// VITE_DEMO=1 build reaches either.
import type { AuditEvent, Feedback, FeedbackDetail, HubSetting, TeamBundle, TeamVersion } from "./api";

const now = Date.now();
const ago = (min: number) => new Date(now - min * 60_000).toISOString();
const ZERO = "0001-01-01T00:00:00Z";
const ME = "zhouning (gh:1001)";

const settings: HubSetting[] = [
  { key: "fleet.auto_assign", value: "mac-mini", source: "set" },
  { key: "fleet.machine_names", value: "mac-mini.local=mac-mini, mac-studio.local=mac-studio", source: "set" },
  { key: "fleet.spare_max", value: "2", source: "default" },
  { key: "fleet.spares", value: "on", source: "set" },
  { key: "hub.public_badges", value: "off", source: "default" },
  { key: "hub.public_meter", value: "on", source: "set" },
  { key: "pool.move_when_full", value: "on", source: "set" },
  { key: "pool.skip_pct", value: "90", source: "set" },
];

const audit: AuditEvent[] = [
  { at: ago(18), kind: "sub", source: "hub", actor: ME, action: "setting", target: "pool.paused.max-c", outcome: "ok", detail: "(default) → on" },
  { at: ago(41), kind: "user", source: "hub", actor: ME, action: "invite", target: "designer@example.com", outcome: "ok" },
  { at: ago(42), kind: "sess", source: "fleet", actor: "release-train", action: "fleet_release", target: "fa76175", outcome: "ok" },
  { at: ago(95), kind: "user", source: "hub", actor: ME, action: "user.remove", target: "test-drill-06", outcome: "ok", detail: "devices revoked: 1" },
  { at: ago(60 * 3), kind: "dev", source: "device", actor: "林晓", action: "revoke", target: "p:7c1e · SHA256:x2Lq…iPhone", detail: "iPhone · Termius (旧)" },
  { at: ago(60 * 5), kind: "set", source: "hub", actor: ME, action: "setting", target: "fleet.auto_assign", outcome: "ok", detail: "least-busy → mac-mini" },
  { at: ago(60 * 9), kind: "mach", source: "fleet", actor: "mac-studio", action: "node_join", target: "mac-studio", outcome: "ok" },
  { at: ago(60 * 12), kind: "user", source: "fleet", actor: ME, action: "view_as", target: "person:p:linxiao", outcome: "OK", detail: "/app/sessions" },
  { at: ago(60 * 15), kind: "user", source: "fleet", actor: "test-drill-07 (gh:3003)", action: "role_denied", target: "/admin/people", outcome: "refused" },
  { at: ago(60 * 26), kind: "sub", source: "credential", actor: ME, action: "add", target: "claude · pool-max-2 · pool", detail: "by zhouning (gh:1001)" },
  { at: ago(60 * 30), kind: "sess", source: "fleet", actor: "阿梅 (p:9a2d)", action: "spawn", target: "issue-412", outcome: "ok" },
  { at: ago(60 * 24 * 2), kind: "set", source: "fleet", actor: ME, action: "team_bundle_put", outcome: "ok" },
  { at: ago(60 * 24 * 3), kind: "user", source: "hub", actor: "chenyu-dev (gh:2002)", action: "signin", target: "github", outcome: "ok" },
  { at: ago(60 * 24 * 6), kind: "user", source: "hub", actor: ME, action: "user.remove", target: "old-intern", outcome: "ok", detail: "devices revoked: 2" },
  { at: ago(60 * 24 * 11), kind: "set", source: "hub", actor: ME, action: "setting", target: "pool.skip_pct", outcome: "ok", detail: "85 → 90" },
  { at: ago(60 * 24 * 15), kind: "mach", source: "hub", actor: ME, action: "setting", target: "fleet.node_cap.mac-mini", outcome: "ok", detail: "(default) → 6" },
  { at: ago(60 * 24 * 21), kind: "sub", source: "fleet", actor: "linux-01", action: "session_cred", target: "chenyu", outcome: "error" },
  { at: ago(60 * 24 * 30), kind: "set", source: "hub", actor: ME, action: "setting", target: "hub.public_meter", outcome: "ok", detail: "off → on" },
  { at: ago(60 * 24 * 44), kind: "user", source: "hub", actor: "deploy", action: "pin", target: "zhouning", outcome: "ok" },
];

const bundles: Record<number, Record<string, any>> = {
  10: { mcp: { context7: {}, playwright: {} }, claude_settings: { theme: "dark" } },
  11: { mcp: { context7: {}, playwright: {}, github: {} }, claude_settings: { theme: "dark" } },
  12: {
    mcp: { context7: {}, playwright: {}, github: {} },
    hooks: { PreToolUse: [{ matcher: "Bash", command: "~/.claude/fleet/bin/fleet-hook-run.sh bash-guard" }] },
    skills: { "doc-preview": {} },
    codex_config: { model_reasoning_effort: "high" },
  },
};
let history: TeamVersion[] = [
  { version: 12, prev: 11, actor: ME, note: "Published team-v12.json", created: ago(60 * 24 * 2) },
  { version: 11, prev: 10, actor: ME, note: "Published team-v11.json", created: ago(60 * 24 * 9) },
  { version: 10, prev: 0, actor: "deploy", note: "first team layer", created: ago(60 * 24 * 40) },
];

const feedback: (Feedback & { ctx?: Record<string, string>; attach?: FeedbackDetail["attach"] })[] = [
  { id: "F14", text: "手机上回答问题时，键盘挡住了选项", state: "received", who: "林晓", principal: "p:7c1e", login: "linxiao", host: "mac-mini", machine_kind: "managed-mac", agent: "claude", attachments: 1, created_at: ago(40),
    ctx: { window: "issue-88", cc_session: "6f1c…a20e", worker_id: "c3f1…/9b2e", fleet_version: "fa76175" }, attach: [{ name: "screen.png", size: 184_320, url: "/v1/admin/feedback/F14/attach/screen.png" }] },
  { id: "F13", text: "用量页想按项目看", state: "filed", who: "阿梅", principal: "p:9a2d", login: "amei", host: "mac-studio", machine_kind: "managed-mac", agent: "claude", attachments: 0, gh_number: 4012, gh_url: "https://github.com/verkyyi/claude-fleet/issues/4012", filed_at: ago(60 * 23), created_at: ago(60 * 24),
    ctx: { window: "scratch-3", fleet_version: "fa76175" } },
  { id: "F12", text: "重新连上以后会话列表空了一下", state: "closed", who: "chenyu-dev", principal: "gh:2002", login: "chenyu", host: "linux-01", machine_kind: "managed-linux", agent: "codex", attachments: 1, gh_number: 3990, gh_url: "https://github.com/verkyyi/claude-fleet/issues/3990",
    reply: "已在 fa76175 修好：重连时先留着旧的列表。", replied_at: ago(60 * 30), filed_at: ago(60 * 24 * 3), closed_at: ago(60 * 30), created_at: ago(60 * 24 * 3),
    ctx: { window: "issue-77", worker_id: "c3f1…/77aa", fleet_version: "e3ccdc1" }, attach: [{ name: "session.log", size: 3_480, url: "/v1/admin/feedback/F12/attach/session.log" }] },
];

const scenario = () => (window as any).__DEMO_SCENARIO || new URLSearchParams(location.search).get("demo") || "";

function team(): TeamBundle {
  const cur = history[0];
  return { version: cur.version, prev: cur.prev, actor: cur.actor, note: cur.note, created: cur.created, bundle: bundles[cur.version], history };
}

function put(v: number, bundle: Record<string, any>, note: string) {
  bundles[v] = bundle;
  history = [{ version: v, prev: history[0].version, actor: ME, note, created: new Date().toISOString() }, ...history];
  audit.unshift({ at: new Date().toISOString(), kind: "set", source: "fleet", actor: ME, action: "team_bundle_put", outcome: "ok" });
}

// entryDemo answers one request, or undefined when it is not one of C15's.
export function entryDemo(method: string, u: URL, body: Record<string, any>): unknown {
  const empty = scenario() === "empty";
  switch (`${method} ${u.pathname}`) {
    case "GET /v1/fleet/settings":
      return { settings: Object.fromEntries(settings.filter((s) => s.source === "set").map((s) => [s.key, s.value])), hub: settings };
    case "PUT /v1/fleet/settings": {
      let s = settings.find((x) => x.key === body.key);
      if (!s) settings.push((s = { key: String(body.key), value: "", source: "default" }));
      if (s.key === "pool.skip_pct" && !/^\d+$/.test(body.value)) throw Object.assign(new Error("pool.skip_pct is a whole percent"), { status: 400 });
      const old = s.value;
      if (old !== body.value) {
        audit.unshift({ at: new Date().toISOString(), kind: s.key.startsWith("pool.") ? "sub" : s.key.startsWith("fleet.node_") ? "mach" : "set", source: "hub", actor: ME, action: "setting", target: s.key, outcome: "ok", detail: `${old || "(default)"} → ${body.value || "(default)"}` });
      }
      Object.assign(s, { value: body.value, source: body.value ? "set" : "default" });
      return { ok: true };
    }
    case "GET /v1/access":
      return { hub: { github: true, github_admins: 1, wechat: true, email: true } };
    case "GET /v1/fleet/team-bundle":
      if (empty) throw Object.assign(new Error("no team layer"), { status: 404 });
      return team();
    case "PUT /v1/fleet/team-bundle": {
      if (body.base !== history[0].version) throw Object.assign(new Error("the team layer changed since you read it"), { status: 409 });
      const v = history[0].version + 1;
      if (body.restore) put(v, bundles[body.restore], `Restored v${body.restore}`);
      else put(v, body.bundle || {}, body.note || "");
      return team();
    }
    case "GET /v1/admin/audit": {
      const rows = empty ? [] : audit;
      const counts: Record<string, number> = {};
      for (const e of rows) counts[e.kind] = (counts[e.kind] || 0) + 1;
      const kind = u.searchParams.get("kind");
      return { events: rows.filter((e) => !kind || kind === "all" || e.kind === kind), counts, days: 60, total: rows.length };
    }
    case "GET /v1/admin/feedback": {
      const rows = empty ? [] : feedback;
      const counts: Record<string, number> = {};
      for (const f of rows) counts[f.state] = (counts[f.state] || 0) + 1;
      return { feedback: rows.map(({ ctx: _c, attach: _a, ...f }) => f), counts };
    }
  }
  const m = /^\/v1\/admin\/feedback\/(F\d+)(\/duplicate)?$/.exec(u.pathname);
  if (m) {
    const f = feedback.find((x) => x.id === m[1]);
    if (!f) throw Object.assign(new Error(`没有这条反馈：${m[1]}`), { status: 404 });
    if (m[2] && method === "POST") {
      const of = String(body.of || "").toUpperCase();
      if (!feedback.some((x) => x.id === of)) throw Object.assign(new Error(`没有这条反馈：${of}`), { status: 404 });
      Object.assign(f, { state: "closed", reply: `和 ${of} 是同一件事，跟进在那一条。`, closed_at: new Date().toISOString(), replied_at: ZERO });
      return { reply: f.reply };
    }
    const { ctx, attach, ...row } = f;
    return { ...row, ctx: ctx || {}, attach: attach || [] };
  }
  return undefined;
}
