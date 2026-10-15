import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { chromium } from 'playwright'

const origin = process.env.FLEET_TEST_ORIGIN
const cookie = process.env.FLEET_TEST_COOKIE
const blocked = process.argv.includes('--deny-udp')
assert(origin && cookie)
const script = await build({ entryPoints: ['chat.ts'], bundle: true, write: false, format: 'esm', target: 'es2022' })
const browser = await chromium.launch({ args: blocked ? ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'] : [] })
try {
  const context = await browser.newContext()
  const eq = cookie.indexOf('=')
  await context.addCookies([{ name: cookie.slice(0, eq), value: cookie.slice(eq + 1), url: origin }])
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true })
  const page = await context.newPage()
  await page.route('**/chat-test.mjs', route => route.fulfill({ contentType: 'application/javascript', body: script.outputFiles[0].text }))
  await page.goto(`${origin}/healthz`)
  const result = await page.evaluate(async ({ blocked }) => {
    const { chatRequest, fetchChat } = await import('/chat-test.mjs')
    const states = [], requests = []
    const Original = window.RTCPeerConnection, peers = []
    window.RTCPeerConnection = class extends Original { constructor(config) { super(config); peers.push(this) } }
    for (const target of ['conversation', 'turn', 'stop', 'answer']) {
      const requestId = crypto.randomUUID().replaceAll('-', '')
      requests.push(requestId)
      const response = await chatRequest(target, target === 'conversation' ? '' : JSON.stringify({ text: '中文-once', turn: 't1', rid: 'r1' }), {
        requestId, onState(s) { if (s.state === 'ready') states.push(s) },
      })
      if (!response.ok) throw new Error(`status ${response.status}`)
      const body = await response.text()
      if (!body) throw new Error('empty response')
      if (target === 'turn' && !body.includes('中文-once')) throw new Error('lost UTF-8 chunk')
      const duplicate = await chatRequest(target, '', { requestId })
      if (duplicate.status !== 409 || (await duplicate.json()).code !== 'duplicate') throw new Error('duplicate admitted')
    }
    // Local mode never performs discovery/signaling. Old-node discovery must
    // select the legacy HTTP route before sending, exactly once.
    const nativeFetch = window.fetch, calls = []
    window.fetch = async (url, init) => {
      calls.push(String(url))
      if (url === '/v1/chat/home') return new Response(JSON.stringify({ state: 'ok' }))
      if (url === '/api/conversation') return new Response('{"local":true}')
      return nativeFetch(url, init)
    }
    if (!(await (await fetchChat('/api/conversation', {}, false)).json()).local) throw new Error('local mode lost')
    if (!(await fetchChat('/v1/chat/conversation')).ok) throw new Error('old-node fallback failed')
    window.fetch = nativeFetch
    if (calls.join(',') !== '/api/conversation,/v1/chat/home,/v1/chat/conversation') throw new Error('fallback re-submitted')
    if (!blocked) {
      const response = await chatRequest('turn', '{"text":"disconnect-once"}')
      const reader = response.body.getReader()
      await reader.read()
      peers.at(-1).close()
      let uncertain = false
      try { while (!(await reader.read()).done) {} } catch (e) { uncertain = e.message.includes('可能已送达') }
      if (!uncertain) throw new Error('lost submission was not visible')
      await new Promise(resolve => setTimeout(resolve, 500))
      const recovered = await chatRequest('conversation')
      if (!(await recovered.json()).session) throw new Error('conversation did not survive')
    }
    return { states, requests, calls }
  }, { blocked })
  assert.equal(result.states.length, 4)
  assert(result.states.every(s => s.mode === (blocked ? 'relay' : 'direct')))
  console.log(JSON.stringify({ browser: browser.version(), udp: blocked ? 'denied' : 'allowed', ...result }))
  await context.tracing.stop({ path: `chat-${blocked ? 'denied' : 'direct'}.zip` })
  await context.close()
} finally { await browser.close() }
