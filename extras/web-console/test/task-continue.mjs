import assert from 'node:assert/strict';
import { canContinueRow, requestRowContinue } from '../src/app/task-continue.ts';
const stop='11111111-1111-4111-8111-111111111111', exit='22222222-2222-4222-8222-222222222222';
const row={task:{id:'T970',authority_version:1,execution_owner:'',generation:2,cancel_request:stop},code:'TEST'};
const reply={task:'T970',agent:'claude',authorized_generation:3,exit_operation_id:exit,
  operation:{operation_id:'33333333-3333-4333-8333-333333333333',action:'worker_start'}};
const writes=[];
let answer={ok:true,data:reply};
const io={post:async (url,body)=>{writes.push({url,body});return answer;}};
assert.equal(canContinueRow(row),true);
for (const variant of [{live:{id:'old'}},{task:{...row.task,execution_owner:'fleet/current'}},
  {task:{...row.task,execution_owner:undefined}},{task:{...row.task,cancel_request:''}},
  {task:{...row.task,generation:1}},{board:{task:'T971'}}]) {
  assert.equal(canContinueRow({...row,...variant}),false);
  assert.equal((await requestRowContinue({...row,...variant},io)).ok,false);
}
assert.equal(writes.length,0,'ordinary idle/history/unknown bindings never launch');
assert.equal((await requestRowContinue(row,io)).ok,true);
answer={ok:false,status:503,error:'unavailable'};
assert.equal((await requestRowContinue(row,io)).ok,false);
answer={ok:true,data:reply};
assert.equal((await requestRowContinue(row,io)).ok,true);
assert.deepEqual(writes[0],writes[1]);assert.deepEqual(writes[1],writes[2]);
assert.equal(writes[0].url,'/v1/fleet/tasks/T970/continue');
assert.equal(writes[0].body.expected_generation,2);
assert.equal(writes[0].body.expected_stop_operation_id,stop);
const unclaimed={...reply,stop_operation_id:stop};delete unclaimed.exit_operation_id;
answer={ok:true,data:unclaimed};assert.equal((await requestRowContinue(row,io)).ok,true);
answer={ok:true,data:{...reply,agent:'codex'}};
assert.equal((await requestRowContinue(row,io,'codex')).ok,true);
assert.notEqual(writes.at(-1).body.idempotency_key,writes[0].body.idempotency_key);
assert.equal(writes.at(-1).body.agent,'codex');
for (const data of [{...reply,task:'T971'},{...reply,authorized_generation:5},
  {...reply,stop_operation_id:stop},{...reply,stop_operation_id:''},
  {...unclaimed,stop_operation_id:exit},{...reply,operation:{...reply.operation,action:'worker_stop'}},
  {...reply,exit_operation_id:undefined}]) {
  answer={ok:true,data};assert.equal((await requestRowContinue(row,io)).ok,false);
}
answer={ok:false,status:409,error:'task_fence'};
assert.equal((await requestRowContinue(row,io)).status,409);
assert.equal((await requestRowContinue(row,{post:async()=>{throw Error('lost');}})).ok,false);
console.log('PASS explicit Task continue: exact stop/generation, stable retry key, both proofs, provider choice, no fallback');
