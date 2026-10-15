// Run by the Go browseracceptance test against its actual node + PTY adapter.
// Every identity, command and hub is disposable; no live fleet is contacted.
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { chromium } from 'playwright'

const origin = process.env.FLEET_TEST_ORIGIN
const cookie = process.env.FLEET_TEST_COOKIE
const target = process.env.FLEET_TEST_WORKER
const blocked = process.argv.includes('--deny-udp')
assert(origin && cookie && target)
const script = await build({ entryPoints: ['attachment.ts'], bundle: true, write: false, format: 'esm', target: 'es2022' })
const browser = await chromium.launch({ args: blocked ? ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'] : [] })
try {
  const context = await browser.newContext()
  const eq = cookie.indexOf('=')
  await context.addCookies([{ name: cookie.slice(0, eq), value: cookie.slice(eq + 1), url: origin }])
  const page = await context.newPage()
  await page.route('**/attachment-test.mjs', route => route.fulfill({ contentType: 'application/javascript', body: script.outputFiles[0].text }))
  await page.goto(`${origin}/healthz`)
  const result = await page.evaluate(async ({ target, blocked }) => {
    const { connectAttachment, utf8Stream } = await import('/attachment-test.mjs')
    const Original = window.RTCPeerConnection
    const peers = []
    window.RTCPeerConnection = class extends Original {
      constructor(config) { super(config); peers.push(this) }
    }
    let connection
    let output = ''
    let phase = 0
    const states = []
    const decode = utf8Stream()
    const started = Date.now()
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { connection?.close(); reject(new Error(`browser timeout: ${JSON.stringify(states)}`)) }, 35000)
      const fail = error => { clearTimeout(timer); connection?.close(); reject(error) }
      connection = connectAttachment({
        url: `/v1/attachment/connect?service=term&worker=${encodeURIComponent(target)}`,
        onState(state) {
          states.push(state)
          if (state.state === 'closed' && phase < 3) fail(new Error(`closed: ${JSON.stringify(state)}`))
          if (state.state !== 'ready') return
          if (phase === 0) {
            if (state.mode !== (blocked ? 'relay' : 'direct')) { fail(new Error('wrong initial path')); return }
            phase = 1
            // The CJK scalar is split between DataChannel/WebSocket frames.
            const bytes = new TextEncoder().encode('中文-first-once\n')
            connection.send(bytes.slice(0, 1)); connection.send(bytes.slice(1, 4)); connection.send(bytes.slice(4))
          } else if (phase === 2 && state.mode === 'relay') {
            connection.send(new TextEncoder().encode('after-fallback-once\n'))
          }
        },
        onData(data) {
          if (typeof data === 'string') return
          output += decode(data)
          if (phase === 1 && output.includes('got:中文-first-once')) {
            if (!blocked) {
              phase = 2
              // Close the real peer after a successful uncertain write. Only a
              // new ready may accept input; the transport never replays it.
              peers[0].close()
              return
            }
            phase = 3
          } else if (phase === 2 && output.includes('got:after-fallback-once')) phase = 3
          if (phase === 3) {
            clearTimeout(timer)
            connection.close()
            resolve({ states, output, milliseconds: Date.now() - started })
          }
        },
      })
      let refused = false
      try { connection.send(new TextEncoder().encode('must-not-send-before-ready\n')) } catch { refused = true }
      if (!refused) fail(new Error('input accepted before ready'))
    })
  }, { target, blocked })
  assert.equal((result.output.match(/got:中文-first-once/g) ?? []).length, 1)
  assert(!result.output.includes('must-not-send-before-ready'))
  const ready = result.states.filter(s => s.state === 'ready')
  assert.equal(new Set(ready.map(s => s.generation)).size, 1)
  assert(ready.every(s => s.target === target))
  if (blocked) assert(result.milliseconds < 20000, 'fallback exceeded bound')
  else {
    assert.equal((result.output.match(/got:after-fallback-once/g) ?? []).length, 1)
    assert(ready.some(s => s.mode === 'direct'))
    assert(ready.some(s => s.mode === 'relay'))
  }
  console.log(JSON.stringify({ browser: browser.version(), udp: blocked ? 'denied-by-browser-policy' : 'allowed', ready, milliseconds: result.milliseconds }))
  await context.close()
} finally {
  await browser.close()
}
