// Run by the Go browseracceptance test (TestAttachmentDoorChromium) against its
// real hub, node + PTY adapter and a real door (agent/door's pipe on TLS, a
// throwaway certificate). XX79: a door that answers faster than the hub carries
// the terminal; a door that is down costs one attempt and the hub carries it.
// Every identity, command and hub is disposable; no live fleet is contacted.
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { chromium } from 'playwright'

const origin = process.env.FLEET_TEST_ORIGIN
const cookie = process.env.FLEET_TEST_COOKIE
const target = process.env.FLEET_TEST_WORKER
// --door-down: the browser reaches the door but the home cannot (tried, then
// the hub); --door-dead: the door answers nobody (its probe fails: never tried)
const down = process.argv.includes('--door-down')
const dead = process.argv.includes('--door-dead')
assert(origin && cookie && target)
const script = await build({ entryPoints: ['attachment.ts'], bundle: true, write: false, format: 'esm', target: 'es2022' })
// No UDP: the direct path is not what this measures.
const browser = await chromium.launch({ args: ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'] })
try {
  const context = await browser.newContext({ ignoreHTTPSErrors: true })
  const eq = cookie.indexOf('=')
  await context.addCookies([{ name: cookie.slice(0, eq), value: cookie.slice(eq + 1), url: origin }])
  const page = await context.newPage()
  await page.route('**/attachment-test.mjs', route => route.fulfill({ contentType: 'application/javascript', body: script.outputFiles[0].text }))
  await page.goto(`${origin}/healthz`)
  // The hub is made to look far away (as Shenzhen is from California); the
  // door, on another origin, is not touched.
  await page.route(`${origin}/healthz`, async route => { await new Promise(r => setTimeout(r, 80)); await route.continue() })
  const result = await page.evaluate(async ({ target }) => {
    const { connectAttachment, utf8Stream } = await import('/attachment-test.mjs')
    let connection, output = '', sent = false, done = false
    const states = [], decode = utf8Stream(), started = Date.now()
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { connection?.close(); reject(new Error(`browser timeout: ${JSON.stringify(states)}`)) }, 40000)
      const fail = error => { clearTimeout(timer); connection?.close(); reject(error) }
      connection = connectAttachment({
        url: `/v1/attachment/connect?service=term&worker=${encodeURIComponent(target)}`,
        onState(state) {
          states.push(state)
          if (state.state === 'closed' && !done) fail(new Error(`closed: ${JSON.stringify(state)}`))
          if (state.state !== 'ready' || sent) return
          sent = true
          const bytes = new TextEncoder().encode('中文-through-once\n')
          connection.send(bytes.slice(0, 1)); connection.send(bytes.slice(1, 4)); connection.send(bytes.slice(4))
        },
        onData(data) {
          if (typeof data === 'string') return
          output += decode(data)
          if (output.includes('got:中文-through-once')) {
            clearTimeout(timer)
            const ready = states.filter(s => s.state === 'ready')
            resolve({ states: [...states], ready, output, milliseconds: Date.now() - started })
            done = true
            connection.close()
          }
        },
      })
    })
  }, { target })
  assert.equal((result.output.match(/got:中文-through-once/g) ?? []).length, 1)
  assert.equal(result.ready.length, 1)
  if (dead) {
    assert.equal(result.ready[0].mode, 'relay')
    assert(!result.states.some(s => s.mode === 'door'), 'a dead door was tried')
  } else if (down) {
    assert.equal(result.ready[0].mode, 'relay', 'a dead door must leave the hub to carry it')
    assert(result.states.some(s => s.mode === 'door'), 'the door was never tried')
    assert(result.milliseconds < 12000, `the fallback took ${result.milliseconds} ms`)
  } else {
    assert.equal(result.ready[0].mode, 'door')
    assert.equal(result.ready[0].door, '美国门')
  }
  console.log(JSON.stringify({ browser: browser.version(), door: dead ? 'dead' : down ? 'down' : 'up', ready: result.ready, milliseconds: result.milliseconds }))
  await context.close()
} finally {
  await browser.close()
}
