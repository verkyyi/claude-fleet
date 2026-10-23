import assert from 'node:assert/strict';
import { boardRows, buildRows, findRow, rowOf, rowWorker } from '../src/app/work.ts';
import { listStatus,rowRef } from '../src/app/session-list.ts';
import { displayCodes } from '../src/app/task-state.ts';
const F='11111111-1111-4111-8111-111111111111';
const old='3f2504e0-4f89-11d3-9a0c-0305e82c3301', current='22222222-2222-4222-8222-222222222222';
const task={id:'T42',fid:old,short:'FDMQ',title:'task',authority_version:1,state:'running',created_at:'2026-10-23T00:00:00Z',asked:'historical question',execution_endpoint:'ep',execution_owner:F+'/'+current,worker_id:F+'/'+old};
const sess=(id,state)=>({id:F+'/'+id,ident:id,state,title:id,key:id,ask:null});
const b={id:old,task:'T42',task_id:old,worker_id:F+'/'+old,tag:'waiting_you',state:'idle',group:'ask',words:['在等你','Waiting'],at:1};
const idle=boardRows({rows:[b]},[{...task,execution_endpoint:undefined,execution_owner:undefined}],[sess(old,'idle')])[0];
assert.equal(listStatus(idle).kind,null,'historical board tag is not a native question');
assert.equal(listStatus(rowOf(task,undefined,undefined,'FDMQ')).kind,null,'historical Asked is not a current native question');
const neighbor={...task,id:'T43',fid:'3f2504e0-0000-11d3-9a0c-0305e82c3301',short:'FDMP'};
for(const outcome of ['', 'succeeded','failed','cancelled','refused']) {
 assert.equal(displayCodes([task,{...neighbor,outcome}]).get(task),'FDMQ');
 assert.equal(displayCodes([{...task,outcome},neighbor]).values().next().value,'FDMQ');
}
for(const live of [[sess(old,'needs'),sess(current,'working')],[sess(current,'working'),sess(old,'needs')]]) {
 const rows=buildRows([task],live,[]);const r=findRow(rows,task.fid);
 assert.equal(r?.live?.id,task.execution_owner);
 assert.equal(rowWorker(r),task.execution_owner);
 assert.equal(rowRef(r),task.fid);
 assert.equal(findRow(rows,task.short)?.task?.id,task.id);
 const cached=boardRows({rows:[b,{...b,id:current,worker_id:task.execution_owner,task:undefined,task_id:undefined,tag:'working',state:'working',group:'work'}]},[task],live);
 assert.equal(findRow(cached,task.fid)?.live?.id,task.execution_owner,'old board order cannot override authoritative binding');
 const pending=buildRows([{...task,execution_owner:''}],live,[]);
 assert.equal(findRow(pending,task.fid)?.live,undefined,'unclaimed never selects historical worker');
 assert.equal(rowWorker({...findRow(pending,task.fid),origin:'terminal'}),'');
}
// Legacy cancel records keep their existing worker lookup; cancel is not a binding.
const legacy={...task,execution_endpoint:undefined,execution_owner:undefined,cancel_request:"stop",operation_id:"legacy-start"};
assert.equal(findRow(buildRows([legacy],[sess(old,"working")],[]),task.fid)?.live?.id,task.worker_id);
// Released controlled tasks retain history without resurrecting old live input.
const released={...task,execution_endpoint:'',execution_owner:'',cancel_request:'stop',operation_id:'old-start'};
const releasedRow=findRow(buildRows([released],[sess(old,'needs')],[]),task.fid);
assert.equal(releasedRow?.live,undefined);
assert.equal(rowWorker({...releasedRow,origin:'terminal'}),'');
assert.equal(rowWorker({...releasedRow,board:{history:{id:old}}}),'fid:'+old);
// A fresh unclaimed board request must preserve its explicit pending fact.
const pendingBoard={...b,worker_id:undefined,state:'',tag:'starting',pending_start:true};
const pendingRow=boardRows({rows:[pendingBoard]},[{...task,execution_owner:''}],[])[0];
assert.equal(listStatus(pendingRow).kind,'pending');
assert.equal(pendingRow.live,undefined);
for(const state of ['needs','blocked']) {
 const asking=boardRows({rows:[{...b,state,tag:'asking'}]},[{...task,execution_endpoint:undefined,execution_owner:undefined}],[sess(old,state)])[0];
 assert.equal(listStatus(asking).kind,'ask');
}
const duplicate=[rowOf(task,undefined,undefined,'FDMQ'),rowOf(neighbor,undefined,undefined,'FDMQ')];
assert.equal(findRow(duplicate,'FDMQ'),undefined,'ambiguous displayed aliases never select first');
console.log('PASS task current view: native question, stable code, current binding, ambiguity and unclaimed history');
