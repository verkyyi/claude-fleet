import assert from "node:assert/strict";
import { subscriptions, room, withOverview, stateOf } from "./pool.ts";
import { planName } from "./plan.ts";

// Re-reporting a historical account must not repopulate the managed pool;
// the input history remains available to the usage page.
const per_account = [
  { account_uuid: "managed", limits: { five_hour: { utilization: 50 }, plan: "max", observed_at: "2026-10-14T00:00:00Z" } },
  { account_uuid: "old-icloud", limits: { five_hour: { utilization: 80 } } },
  { account_uuid: "codex:old", limits: { five_hour: { utilization: 30 } } },
  { account_uuid: "unknown", limits: {} },
  { account_uuid: "no-login", limits: {} },
];
const credentials = [
  { principal_id: "pool", provider: "claude", account: "team", credential_id: "cred:pool", account_uuid: "managed", limits: per_account[0].limits },
  { principal_id: "member", provider: "claude", account: "team", credential_id: "cred:personal", limits: { available: false, read_status: "unknown" } },
];
const input = { limits: { per_account }, creds: { credentials } };
const rows = subscriptions(input);
assert.equal(rows.length, 2);
assert.equal(per_account.length, 5);
assert.equal(subscriptions({ ...input, limits: { per_account: [...per_account, { account_uuid: "re-reported", limits: {} }] } }).length, 2);
assert(rows.every(r => r.managed));
assert.equal(rows.find(r => r.owner)?.owner, "member");
assert.equal(rows.find(r => !r.owner)?.id, "cred:pool");
assert.equal(rows.find(r => !r.owner)?.plan, "max");
assert.equal(rows.find(r => !r.owner)?.planSource, "provider");
assert.equal(rows.find(r => !r.owner)?.planAt, "2026-10-14T00:00:00Z");
const manual = subscriptions({ creds: { credentials: [{ principal_id: "pool", provider: "codex", account: "manual", credential_id: "cred:manual", plan: "prolite", plan_source: "admin" }] } })[0];
assert.equal(manual.plan, "prolite");
assert.equal(manual.planSource, "admin");
assert.equal(manual.planAt, "");
// A personal row with the same label may not receive the pool's overview.
const over = withOverview(rows, [{ owner: "pool", provider: "claude", account: "team", used_5h_pct: 75 }]);
assert.equal(over.find(r => r.owner)?.h5, null);
const own = { ...rows.find(r => r.owner), h5: { p: 99, resets: null } };
assert.equal(room([own], "h5"), null);
assert.equal(room([rows.find(r => !r.owner), own], "h5").left, 50);
assert.equal(stateOf({ ...own, h5: null, h7: null }, 85), "unread");

assert.equal(planName("claude", "max"), "Max");
assert.equal(planName("claude", "max", "default_claude_max_5x"), "Max 5×");
assert.equal(planName("claude", "max", "default_claude_max_20x"), "Max 20×");
assert.equal(planName("claude", "max", "Charlie_20X"), "Max");
assert.equal(planName("codex", " PLUS "), "Plus");
assert.equal(planName("codex", "prolite"), null);
assert.equal(planName("claude", "future_plan"), null);
console.log("PASS managed inventory, historical re-report, personal isolation, unknown quota, plan labels");
