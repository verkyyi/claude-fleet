import assert from 'node:assert/strict';
import { firstUserMessage } from '../src/app/chat/first-message.ts';
const held = { at: 900, session: 'native-one', older: 500 };
const latest = [{ t: 'user', text: 'latest message, never prefill this' }];
const seen=[];
const first=await firstUserMessage(held,latest,async before=>{
 seen.push(before);
 return before===500 ? {session:'native-one',older:100,items:[{t:'user',text:'middle'}]} : {session:'native-one',older:0,items:[{t:'user',text:'original task'},{t:'user',text:'second'}]};
});
assert.equal(first,'original task');
assert.deepEqual(seen,[500,100]);
assert.equal(held.older,500); // reading for a form must not move the transcript
assert.equal(await firstUserMessage({...held,older:0},latest,()=>assert.fail()),latest[0].text);
for (const bad of [
 {session:'different',older:0,items:[]}, {session:'native-one',older:500,items:[]},
 {session:'native-one',items:[]}, {session:'native-one',older:-1,items:[]}
]) await assert.rejects(()=>firstUserMessage(held,latest,async()=>bad));
await assert.rejects(()=>firstUserMessage({...held,at:-1},latest,()=>assert.fail()));
await assert.rejects(()=>firstUserMessage({...held,older:0},[{t:'user',text:'',images:[{}]}],()=>assert.fail()));
await assert.rejects(()=>firstUserMessage(held,latest,async()=>{throw Error('offline')}));
console.log('PASS schedules: first-message pagination, session fences, unavailable history and attachments');
