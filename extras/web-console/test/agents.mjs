// agents.mjs — 我的 · Agent and the OAuth consent page (T4DN, src/app/agents.ts):
// read is always granted and cannot be unticked; answer is never ticked unless
// asked; the default is read + talk; the hub's order is kept; the expiry
// choices hold the server's default; each agent gets its own snippet, else the
// generic one; the consent query goes back verbatim; both pages are wired.
// Run: node --experimental-strip-types test/agents.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DAYS, DEFAULT_DAYS, DEFAULT_PERMS, PERMS, consentPerms, dayChoices, expiresText, initialPerms, permLabel, rawQuery, redirectHost, snippetFor, togglePerm } from '../src/app/agents.ts';

assert.deepEqual(PERMS, ['read', 'talk', 'start', 'stop', 'answer']);
assert.deepEqual(DEFAULT_PERMS, ['read', 'talk']);
assert.deepEqual(initialPerms(undefined), ['read', 'talk'], 'nothing asked: read + talk');
assert.deepEqual(initialPerms([]), ['read', 'talk']);
assert.deepEqual(initialPerms(['talk']), ['read', 'talk'], 'read is always in');
assert.deepEqual(initialPerms(['answer', 'read', 'start']), ['read', 'start', 'answer'], 'asked by name, in the hub\'s order');
assert.ok(!initialPerms(['read', 'talk', 'start', 'stop']).includes('answer'), 'answer never ticked unless asked');
assert.deepEqual(initialPerms(['read', 'talk', 'x']), ['read', 'talk'], 'a word the hub does not list is dropped');
assert.deepEqual(initialPerms(['read', 'x'], [...PERMS, 'x']), ['read', 'x'], 'a newer hub word is kept when listed');

assert.deepEqual(togglePerm(['read', 'talk'], 'read', false), ['read', 'talk'], 'read cannot be unticked');
assert.deepEqual(togglePerm(['read', 'talk'], 'answer', true), ['read', 'talk', 'answer']);
assert.deepEqual(togglePerm(['read', 'talk', 'answer'], 'talk', false), ['read', 'answer']);
assert.deepEqual(togglePerm(['talk'], 'start', true), ['read', 'talk', 'start'], 'read back in on any change');

assert.deepEqual([...DAYS], [1, 7, 30, 90, 365]);
assert.equal(DEFAULT_DAYS, 30);
assert.deepEqual(dayChoices(30), [1, 7, 30, 90, 365]);
assert.deepEqual(dayChoices(14), [1, 7, 14, 30, 90, 365], 'a server default off the list is still offered');
assert.deepEqual(dayChoices(30, 30), [1, 7, 30], 'nothing past the hub\'s cap');

// an unverified (self-registered) agent starts at read alone; a verified one at what it asked
assert.deepEqual(consentPerms(['read', 'talk', 'start'], false), ['read'], 'unverified: write boxes start unticked');
assert.deepEqual(consentPerms(undefined, false), ['read']);
assert.deepEqual(consentPerms(['read', 'talk', 'start'], true), ['read', 'talk', 'start'], 'verified: what it asked');
assert.deepEqual(redirectHost('http://127.0.0.1:53111/callback'), { host: '127.0.0.1:53111', local: true });
assert.deepEqual(redirectHost('http://localhost:4000/cb'), { host: 'localhost:4000', local: true });
assert.deepEqual(redirectHost('http://[::1]:4000/cb'), { host: '[::1]:4000', local: true });
assert.deepEqual(redirectHost('https://evil.example/cb'), { host: 'evil.example', local: false });
assert.deepEqual(redirectHost('nope'), { host: '', local: false });

const snips = { 'claude-code': 'claude mcp add …', codex: '[mcp_servers.tokenman]', generic: '{"url": …}' };
assert.equal(snippetFor('claude-code', snips), 'claude mcp add …');
assert.equal(snippetFor('codex', snips), '[mcp_servers.tokenman]');
assert.equal(snippetFor('other', snips), '{"url": …}', 'other: the generic one');
assert.equal(snippetFor('gemini', snips), '{"url": …}', 'missing: the generic one');
assert.equal(snippetFor('codex', undefined), '');

const now = Date.parse('2026-11-03T00:00:00Z');
assert.match(expiresText('2026-12-03T00:00:00Z', now), /30/);
assert.match(expiresText('2026-11-02T00:00:00Z', now), /过期|expired/);
assert.equal(expiresText(undefined, now), '');
assert.ok(permLabel('answer').length > 0 && permLabel('zzz') === 'zzz');

// verbatim: never re-encoded
const q = '?response_type=code&client_id=https%3A%2F%2Fclaude.ai%2Fx&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&scope=read%20talk&state=a%2Bb&code_challenge=AbC-_&code_challenge_method=S256';
assert.equal(rawQuery(q), q.slice(1));
assert.equal(rawQuery(''), '');

// the pages: 我的 · Agent is a tab; the consent card is drawn outside the shell
const read = (f) => readFileSync(new URL(`../src/app/${f}`, import.meta.url), 'utf8');
assert.match(read('routes.tsx'), /id: "agents", path: "\/me\/agents"/);
assert.match(read('pages/me.tsx'), /grid-cols-5/, 'five tabs, five columns');
const main = read('main.tsx');
assert.match(main, /"\/app\/oauth\/authorize"/);
assert.ok(main.indexOf('OAUTH_CONSENT_PATH) {') < main.indexOf('<BrowserRouter'), 'the consent page renders before (outside) the shell');
const agents = read('pages/agents.tsx');
for (const s of ['"/v1/me/agents"', '"/v1/me/agents/revoke"']) assert.ok(agents.includes(s), s);
const consent = read('pages/oauth-consent.tsx');
for (const s of ['/v1/me/oauth/request?${query}', '"/v1/me/oauth/approve"', '{ query, permissions: perms, days, approve }', 'window.location.assign(r.data.redirect)']) assert.ok(consent.includes(s), s);
// an unverified agent: the notice, the redirect host leads, the cap is passed on
for (const s of ['consentPerms(ask.permissions, isVerified(ask)', 'Unverified app', 'max={ask.max_days}', 'asked={verified ? undefined : ask.permissions}']) assert.ok(consent.includes(s), s);
console.log('agents: ok');
