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
  const dependencies = { helpers: resolve("bin"), env: { ...process.env, FLEET_WEBCHAT_STATE: dir },
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
  console.log("PASS studio: concurrent open, restart, scope, CSRF, unconfirmed action");
} finally { rmSync(dir, { recursive: true, force: true }); }
