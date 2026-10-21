import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { chromium } from 'playwright'

const origin = process.env.FLEET_TEST_ORIGIN
const cookie = process.env.FLEET_TEST_COOKIE
const blocked = process.argv.includes('--deny-udp')
assert(origin && cookie)
const script = await build({ entryPoints: ['chat.ts'], bundle: true, write: false, format: 'esm', target: 'es2022' })
const browser = await chromium.launch({ args: blocked ? ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'] : [] })
let context
try {
  context = await browser.newContext()
  const eq = cookie.indexOf('=')
  await context.addCookies([{ name: cookie.slice(0, eq), value: cookie.slice(eq + 1), url: origin }])
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true })
  const page = await context.newPage()
  await page.exposeFunction('networkLoss', async () => {
    await context.setOffline(true)
    await new Promise(resolve => setTimeout(resolve, 5000))
    await context.setOffline(false)
  })
  await page.route('**/chat-test.mjs', route => route.fulfill({ contentType: 'application/javascript', body: script.outputFiles[0].text }))
  await page.goto(`${origin}/healthz`)
  const result = await page.evaluate(async ({ blocked }) => {
    const { chatRequest, fetchChat } = await import('/chat-test.mjs')
    const states = [], requests = []
    const Original = window.RTCPeerConnection, peers = []
    const OriginalSocket = window.WebSocket, sockets = []
    window.WebSocket = class extends OriginalSocket { constructor(...args) { super(...args); sockets.push(this) } }
    window.RTCPeerConnection = class extends Original { constructor(config) { super(config); peers.push(this) } }
    for (const target of ['conversation', 'turn', 'stop', 'answer']) {
      const requestId = crypto.randomUUID().replaceAll('-', '')
      requests.push(requestId)
      // Direct stays reachable when asked for (preferRelay: false); a chat
      // request's default is the relay, checked below (task V9DJ).
      const response = await chatRequest(target, target === 'conversation' ? '' : JSON.stringify({ text: '中文-once', turn: 't1', rid: 'r1' }), {
        requestId, preferRelay: blocked ? undefined : false, onState(s) { if (s.state === 'ready') states.push(s) },
      })
      if (!response.ok) throw new Error(`status ${response.status}`)
      const body = await response.text()
      if (!body) throw new Error('empty response')
      if (target === 'turn' && !body.includes('中文-once')) throw new Error('lost UTF-8 chunk')
      const duplicate = await chatRequest(target, '', { requestId })
      if (duplicate.status !== 409 || (await duplicate.json()).code !== 'duplicate') throw new Error('duplicate admitted')
    }
    // By default a chat request takes the relay at once: no peer connection is
    // even created, so no ICE gathering is waited for.
    const defaultModes = []
    {
      const before = peers.length
      const r = await chatRequest('conversation', '', { onState(s) { if (s.state === 'ready') defaultModes.push(s.mode) } })
      if (!r.ok || !(await r.text())) throw new Error('default conversation read failed')
      if (peers.length !== before) throw new Error('default chat request opened a peer connection')
      if (defaultModes[0] !== 'relay') throw new Error(`default chat request mode ${defaultModes[0]}`)
    }
    // The full allowed body must not overflow the node's bounded frame inbox.
    const large = JSON.stringify({ text: 'x'.repeat(1024 * 1024 - 32) })
    const big = await chatRequest('turn', large)
    if (!big.ok || !(await big.text()).includes('中文-once')) throw new Error('bounded large request failed')
    // fetchChat is the HTTP route, local or hosted: no discovery, no signaling,
    // each request sent exactly once (task V9DJ B).
    const nativeFetch = window.fetch, calls = []
    window.fetch = async (url, init) => {
      calls.push(String(url))
      if (url === '/v1/chat/home') return new Response(JSON.stringify({ state: 'ok' }))
      if (url === '/api/conversation') return new Response('{"local":true}')
      return nativeFetch(url, init)
    }
    if (!(await (await fetchChat('/api/conversation', {}, false)).json()).local) throw new Error('local mode lost')
    if (!(await fetchChat('/v1/chat/conversation')).ok) throw new Error('hosted HTTP route failed')
    window.fetch = nativeFetch
    if (calls.join(',') !== '/api/conversation,/v1/chat/conversation') throw new Error(`fetchChat calls ${calls.join(',')}`)
    {
      const response = await chatRequest('turn', '{"text":"disconnect-once"}')
      const reader = response.body.getReader()
      await reader.read()
      peers.at(-1)?.close()
      sockets.at(-1).close()
      let uncertain = false
      try { while (!(await reader.read()).done) {} } catch (e) { uncertain = e.message.includes('可能已送达') }
      if (!uncertain) throw new Error('lost submission was not visible')
      await window.networkLoss()
      const recovered = await chatRequest('conversation')
      if (!(await recovered.json()).session) throw new Error('conversation did not survive')
    }
    return { states, requests, calls, defaultModes }
  }, { blocked })
  console.log(JSON.stringify({ browser: browser.version(), udp: blocked ? 'denied' : 'allowed', ...result }))
  // A late selected-pair update can publish ready again for the same channel.
  assert.equal(new Set(result.states.map(s => s.connection)).size, 4)
  assert(result.states.every(s => s.mode === (blocked ? 'relay' : 'direct')))
  // Exercise the production chat page too: online only reads the transcript.
  await page.addInitScript(() => {
    window.__chatConnections = []
    for (const name of ['WebSocket', 'RTCPeerConnection']) {
      const Original = window[name]
      window[name] = class extends Original { constructor(...args) { super(...args); window.__chatConnections.push(this) } }
    }
  })
  await page.goto(`${origin}/app`)
  await page.getByRole('textbox', { name: '输入', exact: true }).fill('ui-once')
  await page.getByRole('button', { name: '发送', exact: true }).click()
  await page.getByText('中文-once', { exact: true }).waitFor()
  await context.setOffline(true)
  await page.evaluate(() => window.__chatConnections.forEach(c => c.close()))
  await new Promise(resolve => setTimeout(resolve, 5000))
  await context.setOffline(false)
  await page.getByText('recovered-ui-once', { exact: true }).waitFor()
  await page.reload()
  await page.getByText('recovered-ui-once', { exact: true }).waitFor()
  console.log('PASS production chat: 5s offline, online reads original conversation, reopen preserves transcript, no turn replay')
} finally {
  await context?.tracing.stop({ path: `chat-${blocked ? 'denied' : 'direct'}.zip` }).catch(() => {})
  await browser.close()
}
