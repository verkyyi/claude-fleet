#!/usr/bin/env python3
# selftest-entry
"""Execute the shipped subscription script against SDK/open-tag event orders."""
from pathlib import Path
import subprocess

source = (Path(__file__).resolve().parents[1] / "tokenledger/hub/api/request_subscribe.go").read_text()
script = source.split('const applySubscribeJS = `', 1)[1].split('`', 1)[0]
subprocess.run(["node", "-e", r"""
const vm = require('node:vm'), assert = require('node:assert/strict');
const source = require('node:fs').readFileSync(0, 'utf8');
function page({ua='MicroMessenger', sdk=true, config='{}', throws=false}={}) {
 const events={}, docEvents={}; let ready, error;
 const box={hidden:true,dataset:{config}}, tag={addEventListener:(n,f)=>events[n]=f};
 const wx={ready:f=>ready=f,error:f=>error=f,config:()=>{if(throws)throw Error('config');}};
 vm.runInNewContext(source,{document:{getElementById:id=>({'review-subscribe':box,'review-subscribe-tag':tag,'review-subscribe-status':{}}[id]),addEventListener:(n,f)=>docEvents[n]=f},window:{wx:sdk?wx:null},wx,navigator:{userAgent:ua}});
 return {box,events,docEvents,ready:()=>ready?.(),error:()=>error?.()};
}
for(const options of [{sdk:false},{ua:'Firefox'},{config:'invalid'},{throws:true}]) {
 const p=page(options); p.ready(); p.events.ready?.(); assert.equal(p.box.hidden,true);
}
for(const first of ['sdk','tag']) {
 const p=page(); assert.equal(p.box.hidden,true);
 (first==='sdk'?p.ready:p.events.ready)(); assert.equal(p.box.hidden,true);
 (first==='sdk'?p.events.ready:p.ready)(); assert.equal(p.box.hidden,false);
 p.error(); assert.equal(p.box.hidden,true);
 p.ready(); p.events.ready(); assert.equal(p.box.hidden,true);
}
for(const error of ['sdk','tag','document']) {
 const p=page();
 if(error==='sdk')p.error();
 if(error==='tag')p.events.error();
 if(error==='document')p.docEvents.WeixinOpenTagsError();
 p.ready(); p.events.ready(); assert.equal(p.box.hidden,true);
}
console.log('PASS subscription entry stays hidden until SDK and tag are ready; errors stay hidden');
"""], input=script, text=True, check=True)
