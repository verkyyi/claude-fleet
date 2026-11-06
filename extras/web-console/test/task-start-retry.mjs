import assert from 'node:assert/strict';
import { retryStartRef } from '../src/app/task-cancel.ts';
const row = {task:{id:'T42'},board:{tag:'queued',start_retry:true}};
assert.equal(retryStartRef(row),'T42');
assert.equal(retryStartRef({...row,board:{...row.board,tag:'start_failed'}}),'T42');
for (const extra of [{live:{id:'live'}},{board:{tag:'queued'}},{board:{tag:'starting',start_retry:true}},
  {board:{tag:'not_seen',start_retry:true}},{board:{tag:'queued',start_retry:false}}]) {
  assert.equal(retryStartRef({...row,...extra}),'');
}
console.log('task-start-retry: explicit Hub eligibility only');
