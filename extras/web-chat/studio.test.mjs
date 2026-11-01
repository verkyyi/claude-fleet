import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { studioHandlers } from "./studio.mjs";

const dir = mkdtempSync(join(tmpdir(), "fleet-studio-test-"));
const fid = "12345678-1234-4234-8234-123456789abc";
let starts = 0;
try {
  const dependencies = { previewOrigin: "https://space.example.com", helpers: resolve("bin"), env: { ...process.env, FLEET_WEBCHAT_STATE: dir },
    readJson: async req => req.body, send: (res, status, body) => Object.assign(res, { status, body }),
    spawn: async (text, agent, profile) => {
      assert.equal(profile, "livepage-studio"); assert.equal(agent, "codex"); assert.match(text, /hold/);
      starts++; await new Promise(r => setTimeout(r, 30)); return { fid };
    }, gate: async () => { throw Error("must not deliver without confirmation"); }, pending: () => {} };
  let handler = studioHandlers(dependencies);
  const open = () => handler({ method: "POST", headers: { "x-fleet-webchat": "1" }, body: {
    key: "new-test", text: "a sample page", agent: "codex", embed_origin: "https://hub.example.com" } }, {}, "/api/studio/open");
  const both = await Promise.all([open(), open()]);
  assert.equal(starts, 1); assert.equal(both[0].body.fid, fid); assert.equal(both[1].body.reused, true);
  handler = studioHandlers(dependencies); // service restart, binding from disk
  assert.equal((await open()).body.fid, fid); assert.equal(starts, 1);
  const unknown = await handler({ method: "POST", headers: { "x-fleet-webchat": "1" }, body: {
    key: "another", proposal_id: "not-in-workspace", agent: "codex", embed_origin: "https://hub.example.com" } }, {}, "/api/studio/open");
  assert.equal(unknown.status, 400); assert.equal(starts, 1);
  const denied = await handler({ method: "POST", headers: {}, body: {} }, {}, "/api/studio/open");
  assert.equal(denied.status, 403);
  const action = await handler({ method: "POST", headers: { "x-fleet-webchat": "1" }, body: { fid, action: "publish" } }, {}, "/api/studio/action");
  assert.equal(action.status, 400);
  execFileSync("python3", [resolve("bin/fleet_studio.py"), "show"], { env: dependencies.env,
    input: JSON.stringify({ fid, proposal_id: "sample", title: "Sample" }) });
  handler = studioHandlers({ ...dependencies, gate: async () => ({ j: { state: "returned", why: "session gone" } }) });
  const returned = await handler({ method: "POST", headers: { "x-fleet-webchat": "1" }, body: {
    fid, id: "87654321-1234-4234-8234-123456789abc", action: "analytics" } }, {}, "/api/studio/action");
  assert.equal(returned.status, 409); assert.equal(returned.body.error, "session gone");
  const leaseKey = "a".repeat(43);
  const args = { fid, proposal_id: "sample", version_id: "v1" };
  execFileSync("python3", [resolve("bin/fleet_studio.py"), "show"], { env: dependencies.env,
    input: JSON.stringify({ ...args, status: "hold", embed_url: "https://space.example.com/embed/v1/old",
      embed_expires: new Date(Date.now() - 1000).toISOString(), embed_renewal_key: leaseKey,
      embed_renewal_expires: new Date(Date.now() + 86400000).toISOString() }) });
  let renewals = 0;
  handler = studioHandlers({ ...dependencies, previewFetch: async (url, init) => {
    renewals++;
    assert.equal(url, "https://space.example.com/preview/v1/renew");
    assert.equal(JSON.parse(init.body).key, leaseKey);
    await new Promise(r => setTimeout(r, 20));
    return Response.json({ url: "https://space.example.com/embed/v1/new", version_id: "v1", proposal_id: "sample",
      origin: "https://hub.example.com", expires_at: new Date(Date.now() + 3600000).toISOString() });
  }});
  const req = { method: "POST", headers: { "x-fleet-webchat": "1" }, body: args };
  const replies = await Promise.all([handler(req, {}, "/api/studio/preview"), handler(req, {}, "/api/studio/preview")]);
  assert.equal(renewals, 1, "two tabs renew once, with no Agent turn");
  assert.ok(replies.every(r => r.body.state === "ready"));
  const projection = await handler({ method: "GET" }, {}, "/api/studio");
  assert.ok(!JSON.stringify(projection).includes(leaseKey), "renewal key stays on the node");
  assert.match(projection.body.sessions["new-test"].versions[0].embed, /new$/);
  // A lost send response must become unknown, and retrying the same action cannot resend it.
  let sends = 0;
  handler = studioHandlers({ ...dependencies, gate: async () => { sends++; throw Error("lost response"); } });
  const command = { ...args, id: "99999999-1234-4234-8234-123456789abc", action: "publish", confirmed: true };
  const call = () => handler({ ...req, body: command }, {}, "/api/studio/action");
  assert.equal((await call()).body.state, "unknown");
  assert.equal((await call()).body.state, "unknown");
  assert.equal(sends, 1);
  // The Bubble Cloud profile (APVZ): its own agent definition and binding; the store's ops only.
  const bcFid = "abcdef12-1234-4234-8234-123456789abc";
  handler = studioHandlers({ ...dependencies, spawn: async (text, agent, profile) => {
    assert.equal(profile, "bubble-cloud-deck"); assert.match(text, /客户卡 = c-google/); assert.match(text, /bc_config/); return { fid: bcFid };
  } });
  const bcOpen = await handler({ method: "POST", headers: { "x-fleet-webchat": "1" }, body: { key: "new-bc", text: "deck", agent: "claude",
    embed_origin: "https://hub.example.com", profile: "bubble-cloud", client: "c-google", template: "../x" } }, {}, "/api/studio/open");
  assert.equal(bcOpen.body.profile, "bubble-cloud"); assert.equal(bcOpen.body.client, "c-google"); assert.equal(bcOpen.body.template, "");
  const bcCall = (body) => handler({ method: "POST", headers: { "x-fleet-webchat": "1" }, body }, {}, "/api/studio/bc");
  assert.equal((await bcCall({ op: "read" })).body.config.rev, 1);
  assert.equal((await bcCall({ op: "run", ids: [] })).status, 400, "run is the service's own, never the page's");
  assert.equal((await bcCall({ op: "generate", prompt: "x" })).status, 400, "a batch names its proposal");
  assert.equal((await handler({ method: "POST", headers: {}, body: { op: "read" } }, {}, "/api/studio/bc")).status, 403);
  console.log("PASS studio: concurrent open, restart, scope, CSRF, unconfirmed action, Bubble Cloud profile");
} finally { rmSync(dir, { recursive: true, force: true }); }
