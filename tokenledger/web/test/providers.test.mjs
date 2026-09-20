import test from 'node:test';
import assert from 'node:assert/strict';
import {selectLive, windowName, pricingCoverage, loginLabel, accountGroups, SOURCE_LABEL, quotaAccounts, hasQuotaWindow} from '../dist/lib/providers.js';
import {fmtCost} from '../dist/lib/format.js';

test('missing costs stay unknown across bucket and session totals',()=>{
  assert.equal(fmtCost({events:19,unpriced_events:19,cost_usd:0}),'—');
  assert.equal(fmtCost({turns:19,unpriced_events:19,cost_usd:0}),'—');
  assert.match(fmtCost({events:20,unpriced_events:19,cost_usd:1}),/^≥ \$/);
  assert.equal(fmtCost({events:1,unpriced_events:0,cost_usd:0}),'$0.00');
});

test('source/account/chips filter every live aggregate', () => {
  const snap={sessions:[
    {source:'claude',account:'c',endpoint_id:'a',input_tokens:800,tokens_per_min:80},
    {source:'codex',account:'x',endpoint_id:'b',input_tokens:100,output_tokens:20,tokens_per_min:12,cost_unknown:true},
    {source:'codex',account:'y',endpoint_id:'c',input_tokens:500,tokens_per_min:50}
  ],active_sessions:3,session_tokens:1420,tokens_per_min:142};
  const got=selectLive(snap,{source:'codex'},'x');
  assert.equal(got.active_sessions,1);assert.equal(got.session_tokens,120);assert.equal(got.tokens_per_min,12);assert.equal(got.endpoints,1);assert.equal(got.unpriced_sessions,1);
  assert.equal(selectLive(snap,{source:'codex',machine:'a'}).session_tokens,0);
});
test('a primary quota may be a seven day window',()=>{
  assert.match(windowName({minutes:10080,limit_id:'codex'}),/7-day/);
  assert.match(windowName({minutes:300,limit_id:'codex'}),/5-hour/);
});

test('pricing percentage counts requests and preserves unknown or empty totals',()=>{
  const d=pricingCoverage({events:14325,unpriced_events:533,tokens:1657472520});
  assert.equal(d.percent,'96.28%'); assert.equal(d.priced,13792);
  assert.equal(pricingCoverage({events:0}).percent,'—');
  assert.equal(pricingCoverage({events:10,unpriced_events:10}).percent,'0.00%');
});

test('expired access, retryable refresh and revoked login remain distinct',()=>{
  assert.match(loginLabel({state:'access_expired'}),/renewal pending/);
  assert.match(loginLabel({state:'retry_pending'}),/retry scheduled/);
  assert.equal(loginLabel({state:'reauth_required'}),'Sign-in required');
});

// On claude/codex an account is a subscription. On gateway it is a calling
// application — the shipper maps one APISIX consumer to one account. One
// control labelled "subscription" is wrong for half its own options.
test('accounts group by what an account MEANS for its source', () => {
  const g = accountGroups([
    { account_uuid: 'a', source: 'claude', email: 'x@y.z', subscription_type: 'max' },
    { account_uuid: 'b', source: 'gateway', display_name: 'AI 网关 · aicall' },
    { account_uuid: 'c', source: 'codex', email: 'q@r.s', subscription_type: 'prolite' },
  ]);
  assert.deepEqual(g.map((x) => x.label), ['Subscriptions', 'Calling applications']);
  assert.deepEqual(g[0].options.map((o) => o.value), ['a', 'c']);
  assert.deepEqual(g[1].options.map((o) => o.value), ['b']);
});

test('a single-kind hub gets one group, not an empty second one', () => {
  const g = accountGroups([{ account_uuid: 'a', source: 'claude', email: 'x@y.z' }]);
  assert.equal(g.length, 1);
});

test('no accounts yields no groups', () => {
  assert.deepEqual(accountGroups([]), []);
});

// A stored row predating the source column reads as Claude, so it is a
// subscription — not an unclassified option in neither group.
test('a blank source counts as a subscription', () => {
  const g = accountGroups([{ account_uuid: 'a', email: 'x@y.z' }]);
  assert.equal(g[0].label, 'Subscriptions');
  assert.equal(g[0].options.length, 1);
});

// vendor_bill is an invoice, not something anyone signs into. It is a billing
// relationship, so it belongs with the subscriptions rather than with the
// applications that call the gateway.
test('vendor_bill sits with the subscriptions, not the applications', () => {
  const g = accountGroups([
    { account_uuid: 'v', source: 'vendor_bill', display_name: 'ark bill' },
    { account_uuid: 'b', source: 'gateway', display_name: 'aicall' },
  ]);
  assert.deepEqual(g.find((x) => x.label === 'Subscriptions').options.map((o) => o.value), ['v']);
});

test('an account with no name falls back to its uuid', () => {
  const g = accountGroups([{ account_uuid: 'bare-uuid', source: 'claude' }]);
  assert.equal(g[0].options[0].text, 'bare-uuid');
});

// A voice account is the application that reported the call, not a bill: the
// source exists because the invoice knows nothing about those sessions. So it
// groups with the gateway's callers, opposite vendor_bill.
test('voice sits with the applications, not the subscriptions', () => {
  const g = accountGroups([
    { account_uuid: 'v', source: 'voice', display_name: 'lingsheng agent' },
    { account_uuid: 'b', source: 'gateway', display_name: 'aicall' },
    { account_uuid: 'i', source: 'vendor_bill', display_name: 'ark bill' },
  ]);
  // Order inside a group is the caller's list order, not this function's
  // business; what is asserted is WHICH group each account lands in.
  assert.deepEqual(g.find((x) => x.label === 'Calling applications').options.map((o) => o.value).sort(), ['b', 'v']);
  assert.deepEqual(g.find((x) => x.label === 'Subscriptions').options.map((o) => o.value), ['i']);
});

// An unlabelled source falls through to its bare identifier in the picker,
// which is a silent failure: nothing goes red, the control just reads `voice`
// beside "Claude Code". web/embed_test.go holds the same line against
// model.Sources so a source added in Go cannot ship unnamed here.
test('every source this build offers has a human name', () => {
  for (const s of ['claude', 'codex', 'gateway', 'vendor_bill', 'voice']) {
    assert.equal(typeof SOURCE_LABEL[s], 'string', `${s} has no label`);
    assert.notEqual(SOURCE_LABEL[s], s);
  }
});

// --- the wall card lists subscriptions, not callers (#50) -----------------
//
// /v1/limits answers for every account the hub has ingested, because the
// accounts table is upserted on every batch whatever its source. That is right
// for an API consumer and wrong for a card whose title is a question: a
// gateway caller has no ceiling, so it used to occupy a heading and a line of
// "no reading available" — a gap that cannot be closed, next to real gauges.

const ACCOUNTS = [
  { account_uuid: 'sub-a', source: 'claude' },
  { account_uuid: 'sub-b', source: 'codex' },
  { account_uuid: 'legacy', source: '' },
  { account_uuid: 'app-1', source: 'gateway' },
  { account_uuid: 'voice-1', source: 'voice' },
  { account_uuid: 'bill-1', source: 'vendor_bill' },
];
const entries = (...uuids) => uuids.map((u) => ({ account_uuid: u, label: u, limits: {} }));

test('only accounts that can have a ceiling reach the wall card', () => {
  const { shown, metered } = quotaAccounts(
    entries('sub-a', 'app-1', 'sub-b', 'bill-1', 'voice-1'), ACCOUNTS);
  assert.deepEqual(shown.map((e) => e.account_uuid), ['sub-a', 'sub-b']);
  // Kept, not discarded: the card needs to know the list was filtered down to
  // nothing so it can say why instead of rendering a blank.
  assert.deepEqual(metered.map((e) => e.account_uuid), ['app-1', 'bill-1', 'voice-1']);
});

// A vendor invoice is not a caller — accountGroups files it with the
// subscriptions, and correctly, since it IS a billing relationship. It still
// has no quota window. The two axes are different questions and this is the
// one case where they disagree.
test('a vendor invoice groups with subscriptions but still has no window', () => {
  assert.equal(hasQuotaWindow('vendor_bill'), false);
  assert.equal(accountGroups([{ account_uuid: 'i', source: 'vendor_bill' }])[0].label, 'Subscriptions');
});

// A row stored before the source column existed is Claude, here as in Go.
test('an empty source keeps its gauges', () => {
  assert.equal(hasQuotaWindow(''), true);
  assert.equal(hasQuotaWindow(undefined), true);
  assert.deepEqual(quotaAccounts(entries('legacy'), ACCOUNTS).shown.map((e) => e.account_uuid), ['legacy']);
});

// An allow-list, mirroring model.HasQuotaWindow: a source nobody has
// classified goes missing from the card, which somebody notices, rather than
// living on it forever claiming a collector gap.
test('an unclassified source has no window', () => {
  assert.equal(hasQuotaWindow('some_future_source'), false);
});

// The account list and /v1/limits are two fetches; they can disagree for a
// minute after an account appears. Hiding a real subscription from "am I about
// to hit the wall?" is the dangerous direction, so an unresolvable entry is
// shown — and the server's own reason on it now says "billed per call" anyway.
test('an account the hub has not listed yet is shown, not hidden', () => {
  const { shown, metered } = quotaAccounts(entries('brand-new'), ACCOUNTS);
  assert.deepEqual(shown.map((e) => e.account_uuid), ['brand-new']);
  assert.deepEqual(metered, []);
});

test('an empty or missing list is not an error', () => {
  assert.deepEqual(quotaAccounts([], ACCOUNTS), { shown: [], metered: [] });
  assert.deepEqual(quotaAccounts(undefined, undefined), { shown: [], metered: [] });
  // No account list at all cannot mean "hide everything": boot stops when
  // /v1/accounts fails, so this is only ever a transient.
  assert.deepEqual(quotaAccounts(entries('sub-a'), []).shown.length, 1);
});
