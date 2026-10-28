import assert from 'node:assert/strict';
import { scheduleReceipt, scheduleReceiptRef } from '../src/shared/schedule-receipt.ts';
const response={action:'create',schedule:{spec:{id:'schedule-abc',name:'Notes',at:'07:00',timezone:'Asia/Shanghai',agent:'claude',delivery:{wechat:true,livepage:false}},sync_state:'pending',observed:{}}};
const receipt=scheduleReceipt('mcp__fleet__schedule',JSON.stringify(response));
assert.equal(receipt.id,'schedule-abc');
assert.equal(receipt.synced,false,'pending registration is not scheduled');
assert.equal(receipt.next,undefined,'do not invent a first run');
assert.equal(receipt.agent,'claude');
for(const result of [response,JSON.stringify(response),[{type:'text',text:JSON.stringify(response)}],{content:[{type:'text',text:JSON.stringify(response)}]},{structuredContent:response}]) assert.deepEqual(scheduleReceipt('mcp__fleet.schedule',result),receipt);
for(const result of [{...response,action:'update'},{...response,action:'list'},{...response,action:undefined},{isError:true,structuredContent:response},'{"action":"create",',{action:'create',schedule:{spec:{id:'../../oops'}}}]) assert.equal(scheduleReceipt('schedule',result),null);
assert.equal(scheduleReceipt('Bash',response),null);
console.log('PASS schedule receipt: create only, pending registration, native envelopes, partial and failed results');

const prefix=JSON.stringify({action:'create',schedule_id:'schedule-abc'});
assert.equal(scheduleReceiptRef('fleet.schedule',prefix+'\n'+JSON.stringify(response).slice(0,100)+'…'),'schedule-abc');
assert.equal(scheduleReceiptRef('Bash',prefix),null);
assert.equal(scheduleReceiptRef('fleet.schedule',prefix.slice(0,20)),null);
const {rolloutRead}=await import('../../web-chat/codex.mjs');
const native={type:'event_msg',payload:{type:'item_completed',item:{type:'McpToolCall',id:'native-create',server:'fleet',tool:'schedule',status:'completed',result:{content:[{type:'text',text:prefix+'\n'+JSON.stringify(response)}]}}}};
const replay=rolloutRead(JSON.stringify(native));
assert.equal(replay.items[1].t,'tool_result');
assert.equal(scheduleReceiptRef(replay.items[0].name,replay.items[1].text.slice(0,160)),'schedule-abc');
native.payload.item.result={isError:true,content:[{type:'text',text:'no permission'}]};
assert.equal(rolloutRead(JSON.stringify(native)).items[1].error,true);
console.log('PASS native Codex receipt replay and bounded preview reference');

const once={action:'create',job:{...response.schedule,spec:{...response.schedule.spec,at:undefined,once_at:1793142000}}};
assert.equal(scheduleReceipt('fleet.dispatch',once).once_at,1793142000);
assert.equal(scheduleReceiptRef('mcp__fleet__dispatch','{"action":"create","schedule_id":"schedule-abc"}'),'schedule-abc');
