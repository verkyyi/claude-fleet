#!/usr/bin/env node
// GitHub OIDC → Aliyun STS → ACR (personal edition) temporary login (EPIC #1982 C1, issue #1983).
//
// Ported from 24haowan-monorepo's .github/actions/acr-credentials/acr.js, with the
// role fixed: ① this job's OIDC token; ② anonymous AssumeRoleWithOIDC as
// gha-claudefleet-deploy (shared with ../hub-kubeconfig/oidc.js); ③ with the
// STS, cr:GetAuthorizationToken (personal edition 2016-06-07 `GET /tokens`) for
// `cr_temp_user` + a password that lives as long as the STS. What it may push is
// the role's policy: 24haowan/ccquota only.
//
// Output: the auth for both registry endpoints merged into ~/.docker/config.json
// (other entries kept; buildx reads it). Nothing is printed but masked values.
//
// Usage: node acr.js [--duration 3600]
//        node acr.js --selftest
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { githubOidcToken, assumeRoleWithOidc, oidcClaims, signV3 } = require('../hub-kubeconfig/oidc.js');

const ACCOUNT = '1720148580188583';
const REGION = 'cn-shenzhen';
const ROLE = 'gha-claudefleet-deploy';
const PROVIDER = `acs:ram::${ACCOUNT}:oidc-provider/github-actions`;
const ENDPOINTS = [`registry.${REGION}.aliyuncs.com`, `registry-vpc.${REGION}.aliyuncs.com`];

function parseArgs(argv) {
  const o = { duration: 3600 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--duration') o.duration = Number(argv[++i]);
    else if (a === '--selftest') o.selftest = true;
    else throw new Error(`unknown arg: ${a}`);
  }
  return o;
}

/** Merge both ACR endpoints' auth into a docker config (pure). */
function mergeDockerConfig(existing, user, pass) {
  const cfg = existing && typeof existing === 'object' ? { ...existing } : {};
  cfg.auths = { ...(cfg.auths || {}) };
  const auth = Buffer.from(`${user}:${pass}`).toString('base64');
  for (const host of ENDPOINTS) cfg.auths[host] = { auth };
  return cfg;
}

async function getAuthorizationToken(creds) {
  const host = `cr.${REGION}.aliyuncs.com`;
  const { headers } = signV3({
    method: 'GET', host, path: '/tokens', query: {},
    action: 'GetAuthorizationToken', version: '2016-06-07',
    ak: creds.AccessKeyId, sk: creds.AccessKeySecret, stsToken: creds.SecurityToken,
    date: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    nonce: crypto.randomUUID(),
  });
  const r = await fetch(`https://${host}/tokens`, { headers });
  const j = await r.json().catch(() => ({}));
  const d = j.data || {};
  if (!r.ok || !d.authorizationToken) {
    throw new Error(`GetAuthorizationToken: HTTP ${r.status} ${j.code || j.Code || ''} ${j.message || j.Message || ''}`.trim());
  }
  return { user: d.tempUserName, pass: d.authorizationToken, expires: new Date(d.expireDate).toISOString() };
}

function selftest() {
  const assert = require('assert');
  assert.deepStrictEqual(parseArgs(['--duration', '1200']), { duration: 1200 });
  const cfg = mergeDockerConfig({ auths: { 'ghcr.io': { auth: 'x' } }, credsStore: 'desktop' }, 'cr_temp_user', 'p');
  assert.strictEqual(cfg.auths['ghcr.io'].auth, 'x', 'other registries are kept');
  assert.strictEqual(cfg.credsStore, 'desktop');
  for (const h of ENDPOINTS) assert.strictEqual(Buffer.from(cfg.auths[h].auth, 'base64').toString(), 'cr_temp_user:p');
  assert.deepStrictEqual(Object.keys(mergeDockerConfig(null, 'u', 'p').auths), ENDPOINTS);
  console.log('hub-acr selftest: ok');
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.selftest) return selftest();
  if (!(o.duration >= 900 && o.duration <= 7200)) throw new Error('--duration must be 900..7200');

  const oidcToken = await githubOidcToken();
  console.log(`oidc: sub=${oidcClaims(oidcToken).sub} → role ${ROLE}`);
  let creds;
  try {
    creds = await assumeRoleWithOidc({
      region: REGION, roleArn: `acs:ram::${ACCOUNT}:role/${ROLE}`, providerArn: PROVIDER,
      oidcToken, durationSeconds: o.duration,
    });
  } catch (e) {
    if (e.denied) throw new Error(`${e.message} — only a job in \`environment: prod\` (master only) gets push credentials`);
    throw e;
  }
  for (const v of [creds.AccessKeyId, creds.AccessKeySecret, creds.SecurityToken]) console.log(`::add-mask::${v}`);
  const tok = await getAuthorizationToken(creds);
  console.log(`::add-mask::${tok.pass}`);

  const dir = path.join(os.homedir(), '.docker');
  const file = path.join(dir, 'config.json');
  fs.mkdirSync(dir, { recursive: true });
  let existing = null;
  try { existing = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* none or unreadable ⇒ write fresh */ }
  fs.writeFileSync(file, JSON.stringify(mergeDockerConfig(existing, tok.user, tok.pass)) + '\n', { mode: 0o600 });
  console.log(`acr: role=${ROLE} user=${tok.user} endpoints=${ENDPOINTS.join(',')} expires=${tok.expires}`);
}

if (require.main === module) {
  main().catch((e) => { console.error(`::error::hub-acr: ${e.message}`); process.exit(1); });
}

module.exports = { mergeDockerConfig, parseArgs, ENDPOINTS };
