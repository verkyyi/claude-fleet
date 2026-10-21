// Deterministic production-page drill (task Y393): the conversation a page
// shows never goes back to an older version. The console reads the entry's
// copy (cached=1, task V9DJ D) and the home's answer side by side; whichever
// lands last used to win, so a copy slower than the home put the old
// conversation back on screen, marked 同步中, until the next read. And a second
// browser of the same person picks up what the first one did — on focus, and
// by itself while it is on screen. All requests are intercepted; no listener or
// live account is used.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'

const origin = 'http://127.0.0.1:18962'
const root = new URL('../web-console/dist/', import.meta.url)
const api = '/v1/chat'
const browser = await chromium.launch()

// serve: the console with its chat answered by conv() (the home) and copy()
// (the entry's copy, null = none kept); each may wait on a promise first.
async function open(context, { conv, copy }) {
  const page = await context.newPage()
  const seen = { reads: 0, copies: 0 }
  await page.route('**/*', async route => {
    const url = new URL(route.request().url())
    assert.equal(url.origin, origin, 'the page must remain same-origin')
    const path = url.pathname
    const json = body => route.fulfill({ json: body })
    if (path === `${api}/conversation` && url.searchParams.get('cached') === '1') {
      seen.copies++
      const c = await copy()
      return c ? json(c) : route.fulfill({ status: 404, json: { code: 'no_copy', error: 'no copy kept' } })
    }
    if (path === `${api}/conversation`) { seen.reads++; return json(await conv()) }
    if (path === '/v1/chat/home') return json({ state: 'ok', direct: false })
    if (path === '/v1/me') return json({ person: 'test-person', name: 'Alice', role: 'member' })
    if (path.startsWith('/v1/') || path.startsWith('/api/')) return json({})
    const file = path === '/' ? 'index.html' : path === '/app' || path === '/app/' || path === '/app/chat' ? 'app/index.html' : path.slice(1)
    try { await route.fulfill({ path: fileURLToPath(new URL(file, root)) }) } catch { await route.fulfill({ status: 404, body: '' }) }
  })
  return { page, seen }
}

const convo = (...lines) => ({ session: 's1', items: lines.flatMap(([u, a]) => [{ t: 'user', text: u }, { t: 'text', d: a }]) })

try {
  // 1. the home answers first, the copy arrives after it: the home's stays
  {
    const context = await browser.newContext()
    try {
      let release
      const late = new Promise(resolve => { release = resolve })
      const { page } = await open(context, {
        conv: async () => convo(['q-old', 'a-old'], ['q-new', 'a-new']),
        copy: async () => { await late; return { ...convo(['q-old', 'a-old']), busy: false, mirror: { at: '2026-10-20T00:00:00Z' } } },
      })
      await page.goto(origin + '/app/chat')
      await page.getByText('a-new', { exact: true }).waitFor()
      release()
      await page.waitForLoadState('networkidle')
      await page.waitForTimeout(300)
      assert.equal(await page.getByText('a-new', { exact: true }).count(), 1, 'a late copy put the older conversation back over the home\'s answer')
      assert.equal(await page.getByText('同步中').count(), 0, 'the page still says 同步中 after the home answered')
      console.log('PASS late copy: the home\'s answer stays, the older copy never comes back')
    } finally { await context.close() }
  }

  // 2. two browsers of one person: what the first did reaches the second — on
  //    focus at once, and by itself while it stays on screen
  {
    const context = await browser.newContext()
    try {
      let state = convo(['q1', 'a1'])
      await context.clock.install()
      const { page, seen } = await open(context, { conv: async () => state, copy: async () => null })
      await page.goto(origin + '/app/chat')
      await page.getByText('a1', { exact: true }).waitFor()
      // the other browser's turn lands at the home
      state = convo(['q1', 'a1'], ['q2', 'a2'])
      await page.evaluate(() => window.dispatchEvent(new Event('focus')))
      await page.getByText('a2', { exact: true }).waitFor({ timeout: 5000 })
      state = convo(['q1', 'a1'], ['q2', 'a2'], ['q3', 'a3'])
      const before = seen.reads
      await context.clock.runFor(31_000)
      await page.getByText('a3', { exact: true }).waitFor({ timeout: 5000 })
      assert.ok(seen.reads > before, 'the page never read the home again while on screen')
      console.log('PASS second browser: another browser\'s turn shows on focus and by itself within 30 s')
    } finally { await context.close() }
  }
} finally { await browser.close() }
