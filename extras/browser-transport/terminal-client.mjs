import assert from 'node:assert/strict'
import { createHmac, webcrypto } from 'node:crypto'
import { build } from 'esbuild'
globalThis.crypto ??= webcrypto
const bundle = await build({ entryPoints: ['../web-console/src/shared/terminal-client.ts'], bundle: true, write: false, format: 'esm' })
const { browserClient, safeBrowserURL } = await import('data:text/javascript;base64,' + Buffer.from(bundle.outputFiles[0].text).toString('base64'))
for (const value of ['javascript:alert(1)', 'data:text/html,boom', 'file:///tmp/a', 'http://localhost:3000', 'http://127.1:3000', 'http://[::1]:3000', 'https://u:p@example.com/']) assert.equal(safeBrowserURL(value), null, value)
assert.equal(safeBrowserURL('https://example.com/path'), 'https://example.com/path')
const key = 'test-only-action-key'
const sign = (id, action = {}) => {
  const payload = JSON.stringify({ id, lease: 'browser', ts: Math.floor(Date.now() / 1000), kind: 'open_url', url: 'https://example.com/', ...action })
  return { payload, sig: createHmac('sha256', key).update(payload).digest('hex') }
}
let polled = false
const requests = [], offers = []
globalThis.fetch = async (path, options) => {
  const req = JSON.parse(options.body); requests.push({ path, ...req })
  if (req.action === 'acquire') return Response.json({ state: 'active', lease: { id: 'browser' }, action_key: key })
  if (req.action === 'poll') {
    if (polled) return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted'))))
    polled = true
    return Response.json({ state: 'active', actions: [
      sign('safe'), sign('safe'), sign('script', { url: 'javascript:alert(1)' }), sign('file', { kind: 'show_file' }),
      sign('port', { rport: 3000 }), sign('oauth', { cport: 8765 }), sign('wrong-device', { lease: 'iterm' }),
      sign('expired', { ts: 1 }), { ...sign('forged'), sig: '0'.repeat(64) },
    ] })
  }
  return Response.json({ state: 'recorded' })
}
const client = browserClient(null, offer => offers.push(offer), () => assert.fail('unexpected lost lease'))
assert(await client.ready)
for (let i = 0; offers.length < 5 && i < 100; i++) await new Promise(r => setTimeout(r, 5))
assert.equal(offers.length, 5)
assert.equal(offers[0].url, 'https://example.com/')
assert(offers.slice(1).every(x => x.unsupported && !x.url))
const replies = requests.filter(r => r.action === 'done')
assert.equal(replies.length, 5)
assert.match(replies[0].result, /^offered:/)
assert(!replies[0].result.startsWith('opened'))
assert(replies.slice(1).every(r => !r.ok && r.result.startsWith('unsupported:')))
client.close()
assert(requests.some(r => r.action === 'release' && r.lease === 'browser'))
// A StrictMode unmount during admission must release the returned lease and
// must not begin polling or call the disposed page's callbacks.
let admission
globalThis.fetch = async (path, options) => {
  const req = JSON.parse(options.body)
  if (req.action === 'acquire') return new Promise(resolve => { admission = resolve })
  assert.equal(req.action, 'release')
  return Response.json({ state: 'released' })
}
const pending = browserClient(null, () => assert.fail('stale offer'), () => assert.fail('stale page callback'))
pending.close()
admission(Response.json({ state: 'active', lease: { id: 'late' }, action_key: key }))
assert.equal(await pending.ready, false)
console.log('PASS signed browser actions: safe links, unsupported actions, expired/forged/wrong-device rejection, no false opened receipt, admission cleanup')
