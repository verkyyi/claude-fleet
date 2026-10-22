// Execute the production connection state machine with a controllable transport
// boundary and clock. No real identity, socket or terminal is used.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const requests = [];
class Attachment {
  constructor(options) { this.options = options; requests.push(this); }
  close() {}
  send() { assert.fail('recovery must not replay terminal input'); }
  state(state) { this.options.onState(state); }
}
const retryURL = new URL('../src/shared/terminal-retry.ts', import.meta.url).href;
const source = readFileSync(new URL('../src/shared/terminal.ts', import.meta.url), 'utf8')
  .replace(/^import .* from "\.\.\/\.\.\/\.\.\/browser-transport\/attachment";/m,
    'const { BrowserAttachment, BUFFER_MAX, FRAME_MAX } = globalThis.__terminalTransport;')
  .replace('"./terminal-retry"', JSON.stringify(retryURL));
globalThis.__terminalTransport = { BrowserAttachment: Attachment, BUFFER_MAX: 262144, FRAME_MAX: 32768 };
const { connectTerminal } = await import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
delete globalThis.__terminalTransport;

const saved = new Map(['window', 'document', 'navigator', 'sessionStorage', 'setTimeout', 'clearTimeout', 'fetch'].map(k => [k, Object.getOwnPropertyDescriptor(globalThis, k)]));
let next = 0;
const timers = new Map();
const install = (key, value) => Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
install('window', new EventTarget());
install('document', Object.assign(new EventTarget(), { visibilityState: 'visible' }));
install('navigator', { onLine: true });
install('sessionStorage', { getItem: () => null, setItem() {}, removeItem() {} });
install('setTimeout', callback => { timers.set(++next, callback); return next; });
install('clearTimeout', id => timers.delete(id));
install('fetch', async () => Response.json({ state: 'online' }));
const tick = () => {
  const [id, callback] = timers.entries().next().value || [];
  assert(callback, 'recovery stopped instead of scheduling the next attempt');
  timers.delete(id); callback();
};
const latest = () => requests.at(-1);
const query = () => new URL(latest().options.url, 'http://example.test').searchParams;
const ready = gen => latest().state({ state: 'ready', terminalGeneration: gen, controllerEpoch: 1 });
try {
  for (const refusal of ['rate', 'too_many', 'connection_closed']) {
    const states = [];
    const connection = connectTerminal(null, { signal: new AbortController().signal, onState: s => states.push(s), onBytes: () => assert.fail('unexpected output'), onExit: () => assert.fail('personal terminal left') });
    await Promise.resolve();
    ready('terminal:1');
    latest().options.onData(JSON.stringify({ t: 'exit' }));
    tick();
    assert.equal(query().has('renew'), false);
    latest().state({ state: 'closed', error: 'ended', terminalGeneration: 'terminal:1' });
    tick();
    assert.equal(query().get('renew'), '1');
    latest().state({ state: 'closed', error: refusal });
    tick();
    if (refusal === 'connection_closed') {
      // An answer lost after dispatch is uncertain: inspect the generation,
      // never blindly repeat a renewal that may already have succeeded.
      assert.equal(query().has('renew'), false);
      latest().state({ state: 'closed', error: 'interrupted' });
      tick();
      assert.equal(query().has('renew'), false);
    } else {
      assert.equal(query().get('renew'), '1', `${refusal} refused admission, so renewal must still be pending`);
      assert.equal(query().get('term_resume'), 'terminal:1');
    }
    ready('terminal:2');
    assert.equal(states.at(-1).state, 'ready');
    assert.equal(states.at(-1).notice, 'renewed');
    assert.equal(timers.size, 0, 'a recovered terminal must stop retrying');
    connection.close();
  }
  console.log('PASS terminal renewal: admission refusal retries; an uncertain answer only reconnects; no input replay');
} finally {
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete globalThis[key];
  }
}
