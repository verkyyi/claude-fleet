import assert from "node:assert/strict";
import { subscriptions, room, withOverview, stateOf } from "./pool.ts";
import { planName, monthlyLabel } from "./plan.ts";
import { windowsOf, reauthReason } from "./pool.ts";

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
assert.equal(planName("claude", "max", "default_claude_max_5x"), "Max");
assert.equal(planName("claude", "max", "default_claude_max_20x"), "Ultra");
assert.equal(planName("claude", "max", "Charlie_20X"), "Max");
assert.equal(planName("codex", " PLUS "), "Plus");
assert.equal(planName("codex", "prolite"), "Pro Lite");
assert.equal(planName("codex", "promax"), "Pro Max");
assert.equal(planName("codex", "pro_ultra"), null);

// Every percent is whole (claude-fleet EEJD): a vault credential's reading
// arrives as 7.000000000000001 and is shown as 7.
const pw = windowsOf({ five_hour: { utilization: 7.000000000000001 }, seven_day: { utilization: 52.5 } }, true);
assert.equal(pw.h5.p, 7);
assert.equal(pw.h7.p, 53);
assert.equal(windowsOf({ five_hour: { utilization: 0.236 } }).h5.p, 24);
// A Codex weekly-only window named "primary" is the weekly one, by its length.
const cw = windowsOf({ windows: [{ id: "primary", minutes: 10080, utilization: 29 }] }, true);
assert.equal(cw.h5, null);
assert.equal(cw.h7.p, 29);
assert.equal(windowsOf({ windows: [{ id: "primary", utilization: 10 }] }, true).h5.p, 10);
// An admin-set plan carries its tier and the hub's monthly price.
const charlie = subscriptions({ creds: { credentials: [{ principal_id: "pool", provider: "claude", account: "Charlie_20X", credential_id: "cred:c",
  plan: "max", plan_source: "admin", plan_tier: "default_claude_max_20x", monthly_cost: 200, currency: "USD" }] } })[0];
assert.equal(planName(charlie.prov, charlie.plan, charlie.planTier), "Ultra");
assert.equal(charlie.monthly, 200);
assert.equal(monthlyLabel(charlie.monthly, charlie.currency), "$200/mo");
assert.equal(monthlyLabel(99.5, "EUR", "/月"), "99.50 EUR/月");
assert.equal(monthlyLabel(null), "");
assert.equal(manual.monthly, null);
assert.equal(planName("claude", "future_plan"), null);
console.log("PASS managed inventory, historical re-report, personal isolation, unknown quota, plan labels");

// FKS6: a credential the quota reader marked says why in one sentence, and
// its row reads reauth.
{
  const c = { principal_id: "pool", provider: "claude", account: "Charlie_20X", credential_id: "cred:c", reauth_required: true,
    refresh_error: "quota reads refused: 3 in a row since 2026-10-22T01:00:00Z (limits unavailable: HTTP 401 from the messages endpoint)" };
  assert.deepEqual(reauthReason(c), { key: "quota", n: 3, code: "401" });
  assert.equal(reauthReason({ refresh_error: "upstream rejected the setup token: token_revoked" }).key, "session");
  assert.equal(reauthReason({ refresh_error: "invalid_grant" }).key, "refresh");
  assert.equal(reauthReason(null).key, "other");
  const [row] = subscriptions({ creds: { credentials: [c] } });
  assert.equal(stateOf(row, 85), "reauth");
}

// A provider plan can carry its own separately registered tier. Historical
// account metadata must not override the credential's current registration.
const detectedTier = subscriptions({ accounts: [{ account_uuid: "codex:fixture", rate_limit_tier: "obsolete" }], creds: { credentials: [{ principal_id: "pool", provider: "codex", account: "example", account_uuid: "codex:fixture", plan: "pro", plan_source: "provider", plan_tier: "verified-tier" }] } })[0];
assert.equal(detectedTier.planTier, "verified-tier");
const clearedTier = subscriptions({ accounts: [{ account_uuid: "codex:fixture", rate_limit_tier: "obsolete" }], creds: { credentials: [{ principal_id: "pool", provider: "codex", account: "example", account_uuid: "codex:fixture", plan: "pro", plan_source: "provider" }] } })[0];
assert.equal(clearedTier.planTier, "");

// A subscription's pool (task PNWW) rides the overview row onto the table row.
{
  const [withPool] = withOverview(rows, [{ owner: "pool", provider: "claude", account: "team", credential_id: "cred:pool",
    pool: "acme-pro", pool_name: "Acme Pro", pool_owner: "org:acme" }]);
  assert.equal(withPool.pool, "acme-pro");
  assert.equal(withPool.poolName, "Acme Pro");
  assert.equal(withPool.poolOwner, "org:acme");
  assert.equal(rows[0].pool, undefined, "no overview, no pool");
}
