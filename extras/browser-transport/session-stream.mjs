// T944: a real HTTP SSE connection can stop carrying bytes without ending or
// throwing. Missing three 15-second heartbeats must reconnect the same view,
// preserve its cursor/draft, and never send that draft by itself.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { chromium } from 'playwright'

const root = new URL('../web-console/dist/', import.meta.url)
const worker = '66666666-6666-4666-8666-666666666666/77777777-7777-4777-8777-777777777777'
let active
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  const json = body => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(body)) }
  if (url.pathname === '/v1/me') return json({ person: 'test-person', name: 'Alice', role: 'user', read_only: active.ticket })
  if (url.pathname === '/v1/chat/view') {
    if (url.searchParams.has('cached')) return json({ mirror: null })
    const owner = active
    owner.requests.push(url.search)
    const first = owner.requests.length === 1
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' })
    res.write(`data: ${JSON.stringify({ t: 'state', agent: 'codex', session: 's1', busy: false,
      can_talk: first ? active.capability : true, talk_reason: first && active.capability === null ? 'checking' : '', queue: [] })}\n\n`)
    res.write(`data: ${JSON.stringify({ t: 'items', replace: first, session: 's1', at: 10,
      items: first ? [{ t: 'text', d: 'first reply' }] : [] })}\n\n`)
    owner.streams.add(res)
    res.on('close', () => owner.streams.delete(res))
    // Deliberately leave the HTTP response open and silent. There is no EOF,
    // socket error, fetch interception or route.fulfill to cause recovery.
    return
  }
  if (url.pathname === '/__ping') {
    for (const stream of active.streams) stream.write(': ping\n\n')
    return json({ ok: true })
  }
  if (req.method === 'POST') { active.posts++; return json({}) }
  if (url.pathname === '/v1/fleet/tasks') return json({ tasks: [] })
  if (url.pathname === '/v1/fleet/sessions') return json({ sessions: [], fleets: [] })
  if (url.pathname.startsWith('/v1/')) return json({})
  const file = url.pathname.startsWith('/app/s/') ? 'app/index.html' : url.pathname.slice(1)
  if (file.includes('..')) { res.writeHead(404); return res.end() }
  try {
    const bytes = await readFile(new URL(file, root))
    res.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html')
    res.end(bytes)
  } catch { res.writeHead(404); res.end() }
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
const origin = `http://127.0.0.1:${server.address().port}`
const browser = await chromium.launch()
try {
  for (const kind of ['checking', 'readonly', 'writable', 'ticket']) {
    active = { capability: kind === 'checking' ? null : kind !== 'readonly', ticket: kind === 'ticket', requests: [], streams: new Set(), posts: 0 }
    const context = await browser.newContext()
    try {
      const page = await context.newPage()
      await page.clock.install()
      await page.goto(`${origin}/app/s/${encodeURIComponent(worker)}`, { timeout: 10_000 })
      const access = value => page.locator(`[data-testid=session-view][data-access="${value}"]`)
      const input = page.locator('textarea.aui-composer-input')
      await access(kind === 'ticket' ? 'readonly' : kind).waitFor()
      const draft = `retained ${kind} draft`
      if (kind === 'checking' || kind === 'writable') await input.fill(draft)
      await page.clock.fastForward(30_000)
      // A comment heartbeat counts even when no state or transcript changes.
      await page.evaluate(async () => { await fetch('/__ping') })
      await page.clock.fastForward(30_000)
      assert.equal(active.requests.length, 1, 'a heartbeat keeps a quiet conversation connected')
      const reconnected = page.waitForResponse(r => r.url().includes('/v1/chat/view?') && r.url().includes('at=10'), { timeout: 5000 })
      // Attach a handler before asserting offline so a red assertion cannot
      // leave a rejected response waiter behind during browser cleanup.
      reconnected.catch(() => {})
      await page.clock.fastForward(15_001)
      if (kind !== 'ticket') await access('offline').waitFor({ timeout: 2500 })
      await page.clock.fastForward(1001)
      await reconnected
      if (kind === 'ticket') {
        await page.locator('[data-testid=session-view][data-live][data-access="readonly"]').waitFor({ timeout: 2500 })
      } else await access('writable').waitFor({ timeout: 2500 })
      assert.equal(active.requests.length, 2, 'silent stream reconnects once')
      assert.match(active.requests[1], /at=10&s=s1/, 'recovery uses the existing conversation and cursor')
      if (kind === 'checking' || kind === 'writable') assert.equal(await input.inputValue(), draft)
      if (kind === 'ticket') assert.equal(await input.isDisabled(), true, 'a recovered stream cannot widen ticket permissions')
      assert.equal(active.posts, 0, 'recovery never posts a draft')
      console.log(`PASS session-stream ${kind}: heartbeat, silent-stream recovery, cursor, draft, no automatic send`)
    } finally {
      await context.close()
      for (const stream of active.streams) stream.destroy()
    }
  }
} finally {
  await browser.close()
  server.closeAllConnections()
  await new Promise(resolve => server.close(resolve))
}
