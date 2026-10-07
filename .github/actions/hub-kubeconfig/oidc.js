#!/usr/bin/env node
// GitHub OIDC → Aliyun STS → ACK short-lived kubeconfig (EPIC #1982 C1, issue #1983).
//
// Ported from 24haowan-monorepo's .github/actions/prod-kubeconfig/oidc.js. Three
// steps, Node's standard library only (ubuntu-latest has node 20; no aliyun CLI):
//   ① ask GitHub for this job's OIDC token (`permissions: id-token: write`); its
//      sub is `repo:verkyyi/claude-fleet:environment:prod` only for a job in the
//      prod environment, which admits master only;
//   ② sts:AssumeRoleWithOIDC (anonymous — no access key anywhere) for STS; the
//      RAM role trusts that sub + this audience only;
//   ③ cs:DescribeClusterUserKubeconfig (TemporaryDurationMinutes) with the STS
//      for a certificate kubeconfig that expires on its own. In the cluster the
//      user name is the RAM role's ID.
//
// Output: the kubeconfig in --out (0600); stdout gets one credential-free line.
// No token, STS or certificate is ever printed.
//
// Usage:
//   node oidc.js --role-arn <arn> --provider-arn <arn> --cluster <id> --out <file> [--minutes 60] [--region cn-shenzhen]
//   node oidc.js --selftest
'use strict';

const crypto = require('crypto');
const fs = require('fs');

const AUDIENCE = 'sts.aliyuncs.com';

function parseArgs(argv) {
  const o = { minutes: 60, region: 'cn-shenzhen', selftest: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const v = () => argv[++i];
    if (a === '--role-arn') o.roleArn = v();
    else if (a === '--provider-arn') o.providerArn = v();
    else if (a === '--cluster') o.cluster = v();
    else if (a === '--out') o.out = v();
    else if (a === '--minutes') o.minutes = Number(v());
    else if (a === '--region') o.region = v();
    else if (a === '--selftest') o.selftest = true;
    else throw new Error(`unknown arg: ${a}`);
  }
  return o;
}

// RFC 3986 percent-encoding as Aliyun's signers expect (encodeURIComponent leaves !'()*).
function pct(s) {
  return encodeURIComponent(String(s)).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}

function sha256hex(s) {
  return crypto.createHash('sha256').update(s, 'utf8').digest('hex');
}

// ACS3-HMAC-SHA256 (Aliyun V3 signature). Returns every header to send. Pure:
// the caller passes nonce and date, so the selftest can pin it.
function signV3({ method, host, path, query, action, version, ak, sk, stsToken, date, nonce, body = '' }) {
  const headers = {
    host,
    'x-acs-action': action,
    'x-acs-version': version,
    'x-acs-date': date,
    'x-acs-signature-nonce': nonce,
    'x-acs-content-sha256': sha256hex(body),
  };
  if (stsToken) headers['x-acs-security-token'] = stsToken;
  const names = Object.keys(headers).sort();
  const canonicalHeaders = names.map((n) => `${n}:${String(headers[n]).trim()}\n`).join('');
  const signedHeaders = names.join(';');
  const canonicalQuery = Object.keys(query).sort().map((k) => `${pct(k)}=${pct(query[k])}`).join('&');
  const canonicalUri = path.split('/').map(pct).join('/');
  const canonicalRequest = [method, canonicalUri, canonicalQuery, canonicalHeaders, signedHeaders, headers['x-acs-content-sha256']].join('\n');
  const stringToSign = `ACS3-HMAC-SHA256\n${sha256hex(canonicalRequest)}`;
  const sig = crypto.createHmac('sha256', sk).update(stringToSign, 'utf8').digest('hex');
  headers.authorization = `ACS3-HMAC-SHA256 Credential=${ak},SignedHeaders=${signedHeaders},Signature=${sig}`;
  return { headers, canonicalQuery, canonicalRequest };
}

async function githubOidcToken() {
  const url = process.env.ACTIONS_ID_TOKEN_REQUEST_URL;
  const bearer = process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
  if (!url || !bearer) {
    throw new Error('no GitHub OIDC request env — the job lacks `permissions: id-token: write`');
  }
  const r = await fetch(`${url}&audience=${pct(AUDIENCE)}`, { headers: { authorization: `bearer ${bearer}` } });
  if (!r.ok) throw new Error(`GitHub OIDC token request: HTTP ${r.status}`);
  const j = await r.json();
  if (!j.value) throw new Error('GitHub OIDC token response has no value');
  return j.value;
}

// Only the payload's sub / aud go to the log — which identity asked, never the token.
function oidcClaims(jwt) {
  try {
    const p = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
    return { sub: p.sub, aud: p.aud, ref: p.ref };
  } catch {
    return {};
  }
}

async function assumeRoleWithOidc({ region, roleArn, providerArn, oidcToken, durationSeconds = 900 }) {
  // AssumeRoleWithOIDC is anonymous (unsigned). No retry: no STS ⇒ red.
  const body = new URLSearchParams({
    Action: 'AssumeRoleWithOIDC',
    Version: '2015-04-01',
    Format: 'JSON',
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    RoleArn: roleArn,
    OIDCProviderArn: providerArn,
    OIDCToken: oidcToken,
    RoleSessionName: `gha-${process.env.GITHUB_RUN_ID || 'local'}-${process.env.GITHUB_RUN_ATTEMPT || '0'}`.slice(0, 64),
    DurationSeconds: String(durationSeconds),
  });
  const r = await fetch(`https://sts.${region}.aliyuncs.com/`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.Credentials) {
    const e = new Error(`AssumeRoleWithOIDC: HTTP ${r.status} ${j.Code || ''} ${j.Message || ''}`.trim());
    e.denied = r.status >= 400 && r.status < 500;
    throw e;
  }
  return j.Credentials; // { AccessKeyId, AccessKeySecret, SecurityToken, Expiration }
}

async function describeUserKubeconfig({ region, cluster, minutes, creds }) {
  const host = `cs.${region}.aliyuncs.com`;
  const path = `/k8s/${cluster}/user_config`;
  // A GitHub-hosted runner reaches the cluster's public endpoint.
  const query = { TemporaryDurationMinutes: String(minutes), PrivateIpAddress: 'false' };
  const { headers, canonicalQuery } = signV3({
    method: 'GET', host, path, query,
    action: 'DescribeClusterUserKubeconfig', version: '2015-12-15',
    ak: creds.AccessKeyId, sk: creds.AccessKeySecret, stsToken: creds.SecurityToken,
    date: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    nonce: crypto.randomUUID(),
  });
  const r = await fetch(`https://${host}${path}?${canonicalQuery}`, { headers });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.config) throw new Error(`DescribeClusterUserKubeconfig: HTTP ${r.status} ${j.code || j.Code || ''} ${j.message || j.Message || ''}`.trim());
  return j; // { config, expiration }
}

function selftest() {
  const assert = require('assert');
  assert.strictEqual(pct("a b!'()*~"), 'a%20b%21%27%28%29%2A~');
  const args = {
    method: 'GET', host: 'cs.cn-shenzhen.aliyuncs.com', path: '/k8s/c1/user_config',
    query: { TemporaryDurationMinutes: '60', PrivateIpAddress: 'false' },
    action: 'DescribeClusterUserKubeconfig', version: '2015-12-15',
    ak: 'AK', sk: 'SK', stsToken: 'TOK', date: '2026-10-03T00:00:00Z', nonce: 'n1',
  };
  const s = signV3(args);
  assert.strictEqual(s.canonicalQuery, 'PrivateIpAddress=false&TemporaryDurationMinutes=60');
  assert.match(s.headers.authorization, /^ACS3-HMAC-SHA256 Credential=AK,SignedHeaders=host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-security-token;x-acs-signature-nonce;x-acs-version,Signature=[0-9a-f]{64}$/);
  // Deterministic: same input, same signature; another secret, another signature.
  assert.strictEqual(signV3(args).headers.authorization, s.headers.authorization);
  assert.notStrictEqual(signV3({ ...args, sk: 'SK2' }).headers.authorization, s.headers.authorization);
  const jwt = ['x', Buffer.from(JSON.stringify({ sub: 'repo:o/r:environment:prod', aud: AUDIENCE })).toString('base64url'), 'y'].join('.');
  assert.deepStrictEqual(oidcClaims(jwt), { sub: 'repo:o/r:environment:prod', aud: AUDIENCE, ref: undefined });
  assert.strictEqual(parseArgs(['--role-arn', 'r', '--minutes', '30']).minutes, 30);
  console.log('hub-kubeconfig oidc selftest: ok');
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.selftest) return selftest();
  if (!o.roleArn || !o.providerArn) throw new Error('--role-arn and --provider-arn are required');
  if (!o.cluster || !o.out) throw new Error('--cluster and --out are required');
  if (!(o.minutes >= 15 && o.minutes <= 4320)) throw new Error('--minutes must be 15..4320');

  const oidcToken = await githubOidcToken();
  const claims = oidcClaims(oidcToken);
  console.log(`oidc: sub=${claims.sub} aud=${claims.aud}`);
  const creds = await assumeRoleWithOidc({ region: o.region, roleArn: o.roleArn, providerArn: o.providerArn, oidcToken });
  for (const v of [creds.AccessKeyId, creds.AccessKeySecret, creds.SecurityToken]) console.log(`::add-mask::${v}`);
  const kc = await describeUserKubeconfig({ region: o.region, cluster: o.cluster, minutes: o.minutes, creds });
  fs.writeFileSync(o.out, kc.config, { mode: 0o600 });
  fs.chmodSync(o.out, 0o600);
  console.log(`kubeconfig: role=${o.roleArn.split('/').pop()} expires=${kc.expiration || `+${o.minutes}m`}`);
}

if (require.main === module) {
  main().catch((e) => { console.error(`::error::hub-kubeconfig oidc: ${e.message}`); process.exit(1); });
}

module.exports = { signV3, pct, oidcClaims, parseArgs, githubOidcToken, assumeRoleWithOidc };
