import assert from 'node:assert/strict';
import { canStopRow, requestRowStop, stopTaskRef } from '../src/app/task-stop.ts';
const fid='11111111-1111-4111-8111-111111111111';
const reply={stop_requested:true, execution_exit_confirmed:false,
  operation:{operation_id:fid, action:'worker_stop',status:'succeeded'}};
const controlled={board:{task:'T42',task_id:fid,execution_endpoint:'offline',tag:'not_seen',lost:true}};
const live={board:{task:'T42'},live:{id:'fleet/worker'}};
function io(overrides={}) {
  const calls=[];
  return {calls,
    read:async url=>{calls.push(['read',url]);return {id:'T42',title:'Task',created_at:'2026-10-23T00:00:00Z'};},
    post:async (url,body)=>{calls.push(['post',url,body]);return {ok:true,data:reply};},
    legacy:async worker=>{calls.push(['legacy',worker]);return null;},...overrides};
}
assert.equal(canStopRow(controlled),true);
let transport=io();
assert.deepEqual(await requestRowStop(controlled,transport),{ok:true,exitConfirmed:false,neverStarted:false});
assert.equal(transport.calls.length,1);
assert.equal(transport.calls[0][1],'/v1/fleet/tasks/T42/stop');
assert.equal(transport.calls[0][2].owner,undefined);
assert.match(transport.calls[0][2].idempotency_key,/^task-stop:/);
transport=io();
assert.equal((await requestRowStop(live,transport)).legacy,true);
assert.deepEqual(transport.calls.map(c=>c[0]),['read','legacy']);
for(const read of [async()=>null,async()=>({id:'T43'}),async()=>{throw Error('offline');}]) {
  transport=io({read});
  assert.equal((await requestRowStop(live,transport)).ok,false);
  assert.equal(transport.calls.length,0);
}
for(const post of [async()=>({ok:false,error:'refused'}),async()=>{throw Error('offline');}]) {
  transport=io({post});
  assert.equal((await requestRowStop(controlled,transport)).ok,false);
  assert.equal(transport.calls.length,0);
}
for(const data of [{operation:reply.operation},{...reply,execution_exit_confirmed:true},
  {...reply,execution_exit_confirmed:'true'},{...reply,operation:{...reply.operation,operation_id:'bad'}}]) {
  assert.equal((await requestRowStop(controlled,io({post:async()=>({ok:true,data})}))).ok,false);
}
assert.equal((await requestRowStop(controlled,io({post:async()=>({ok:true,data:{...reply,execution_exit_confirmed:true,scope:'native_session'}})}))).exitConfirmed,true);
const never=await requestRowStop(controlled,io({post:async()=>({ok:true,data:{...reply,execution_never_started:true}})}));
assert.equal(never.neverStarted,true);
assert.equal(never.exitConfirmed,false);
const pending={board:{task:'T42',pending_start:true,tag:'queued',execution_endpoint:'ep'}};
assert.equal(canStopRow(pending),false);
transport=io();
assert.equal((await requestRowStop(pending,transport)).ok,false);
assert.equal(transport.calls.length,0);
for(const task of [{id:'T43',fid},{id:'T42',fid:'22222222-2222-4222-8222-222222222222'}]) {
  const conflict={...controlled,task};
  assert.equal(stopTaskRef(conflict),'');
  transport=io();
  assert.equal((await requestRowStop(conflict,transport)).ok,false);
  assert.equal(transport.calls.length,0);
}
transport=io({read:async()=>({id:'T42',execution_endpoint:'ep'})});
assert.equal((await requestRowStop(live,transport)).ok,true);
assert.deepEqual(transport.calls.map(c=>c[0]),['post']);
assert.equal(canStopRow({board:{task:'T42'}}),false);
// A node-shaped wrapper must never silently classify a browser task as legacy.
transport=io({read:async()=>({task:{id:'T42'}})});
assert.equal((await requestRowStop(live,transport)).ok,false);
assert.equal(transport.calls.length,0);
console.log('PASS Task stop: controlled offline, legacy classification, refusal, identity, pending, and proof scope');
