// Execute the built page: signed-in visitors must get a login QR even in trial mode.
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
(async () => {
  for (const rel of ['index.html', 'en/index.html', 'apply/index.html', 'apply/en/index.html']) {
    const html = readFileSync(process.argv[2] + '/' + rel, 'utf8');
    const js = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];
    const purpose = html.match(/id="qr" data-p="([^"]+)"/)[1];
    for (const signedIn of [false, true]) {
      for (const phone of [false, true]) {
        const nodes = new Map();
        const element = (s) => {
          if (!nodes.has(s)) nodes.set(s, {dataset: s === '#qr' ? {p: purpose} : {}, classList: {add(){}, remove(){}, toggle(){}}, hidden: false});
          return nodes.get(s);
        };
        const calls = [], polls = [];
        const fetch = async (url, opts) => {
          if (url === '/v1/me') return {ok: signedIn, json: async () => signedIn ? {name:'Test', can_logout:true} : null};
          if (url === '/auth/wechat/qr') { calls.push(opts.body); return {ok:true, json:async () => ({qr:'<svg/>', s:'test'})}; }
          polls.push(url); return {ok:true, json:async()=>({s:'waiting'})};
        };
        const sandbox = {document:{documentElement:element('root'), querySelector:element, querySelectorAll:()=>[], hidden:false},
          navigator:{userAgent:phone?'iPhone Mobile':'Browser', language:rel.includes('en/')?'en':'zh'},
          location:{pathname:rel.includes('en/')?'/en/':'/', search:'?still=1', hash:''},
          localStorage:{getItem:()=> 'set',setItem(){}}, sessionStorage:{}, fetch,
          matchMedia:()=>({matches:true,addEventListener(){}}),setTimeout(){},clearTimeout(){},
          setInterval(fn){polls.push(fn);return 1},clearInterval(){}};
        sandbox.window=sandbox;
        vm.runInNewContext(js,sandbox);
        await new Promise(setImmediate);
        if (phone) { assert.deepEqual(calls,[]); element('#orqr').onclick(); await new Promise(setImmediate); }
        assert.deepEqual(calls,['purpose='+(signedIn?'login':purpose)], rel+' signedIn='+signedIn+' phone='+phone);
        for (const fn of polls.filter(x=>typeof x==='function')) fn();
        await new Promise(setImmediate);
        assert(polls.some(x=>typeof x==='string' && x==='/auth/wechat/poll?s=test'+(!signedIn&&purpose==='trial'?'&p=trial':'')), 'QR still polls in the correct mode');
      }
    }
  }
  console.log('PASS homepage QR: trial/apply, zh/en, signed in/out, phone/desktop');
})().catch(e=>{console.error(e);process.exitCode=1});
