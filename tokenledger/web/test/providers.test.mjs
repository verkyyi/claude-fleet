import test from 'node:test';
import assert from 'node:assert/strict';
import {selectLive, windowName, pricingCoverage, loginLabel} from '../dist/lib/providers.js';
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
