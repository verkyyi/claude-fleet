// Deterministic production-page drill: a pre-turn snapshot arrives after the
// reply. All requests are intercepted; no listener or live account is used.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'

const origin = 'http://127.0.0.1:18961'
const browser = await chromium.launch()
try {
  // copy: the entry's copy (task V9DJ D) exists too and is held as long as the
  // home's read — a late copy must not erase the new turn either
  for (const [local, copy] of [[false, false], [true, false], [false, true]]) {
    const context = await browser.newContext()
    try {
      const page = await context.newPage()
      const root = new URL(local ? '../web-chat/ui/dist/' : '../web-console/dist/', import.meta.url)
      const api = local ? '/api' : '/v1/chat'
      let release, sawRead
      const held = new Promise(resolve => { release = resolve })
      const readStarted = new Promise(resolve => { sawRead = resolve })
      let turns = 0, reads = 0
      await page.route('**/*', async route => {
        const url = new URL(route.request().url())
        assert.equal(url.origin, origin, 'the page must remain same-origin')
        const path = url.pathname
        const json = body => route.fulfill({ json: body })
        // the entry's copy (task V9DJ D): none kept in this drill
        if (path === `${api}/conversation` && url.searchParams.get('cached') === '1') {
          if (!copy) return route.fulfill({ status: 404, json: { code: 'no_copy', error: 'no copy kept' } })
          await held
          return json({ session: 's1', items: [{ t: 'user', text: 'old-copy' }], busy: false, mirror: { at: '2026-10-20T00:00:00Z' } })
        }
        if (path === `${api}/conversation`) {
          reads++
          sawRead()
          await held
          return json({ session: 's1', items: [] })
        }
        if (path === `${api}/turn`) {
          turns++
          assert.equal(route.request().postDataJSON().text, 'ui-once')
          return route.fulfill({ contentType: 'application/x-ndjson', body: '{"t":"text","d":"中文-once"}\n{"t":"done"}\n' })
        }
        if (path === '/v1/chat/home') return json({ state: 'ok', direct: false })
        if (path === '/v1/me') return json({ person: 'test-person', name: 'Alice', role: 'member' })
        if (path.startsWith('/v1/') || path.startsWith('/api/')) return json({})
        const file = path === '/' ? 'index.html' : path === '/app' || path === '/app/' ? 'app/index.html' : path.slice(1)
        try {
          await route.fulfill({ path: fileURLToPath(new URL(file, root)) })
        } catch { await route.fulfill({ status: 404, body: '' }) }
      })
      await page.goto(origin + (local ? '/' : '/app'))
      await readStarted
      await page.getByRole('textbox', { name: '输入', exact: true }).fill('ui-once')
      await page.getByRole('button', { name: '发送', exact: true }).click()
      await page.getByText('中文-once', { exact: true }).waitFor()
      // Finish the turn first: checking only streaming.current cannot fence
      // a snapshot that arrives after the stream has already completed.
      await page.getByRole('button', { name: '发送', exact: true }).waitFor()
      release()
      await page.waitForLoadState('networkidle')
      assert.equal(await page.getByText('ui-once', { exact: true }).count(), 1, 'late history erased the user message')
      assert.equal(await page.getByText('中文-once', { exact: true }).count(), 1, 'late history erased the reply')
      assert.equal(turns, 1, 'a history race must never replay a turn')
      assert.equal(await page.getByText('old-copy', { exact: true }).count(), 0, 'a late copy came back over the new turn')
      assert.equal(reads, 1, 'the stale read must not trigger a retry loop')
      console.log(`PASS ${local ? 'local' : 'console'}${copy ? ' (late copy)' : ''}: late initial history preserves one user message and one Chinese reply after turn completion`)
    } finally { await context.close() }
  }
} finally { await browser.close() }
