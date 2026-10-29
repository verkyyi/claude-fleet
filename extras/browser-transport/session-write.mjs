// T944: the built session page keeps a draft through capability discovery and
// reconnects. Only an affirmative gate enables send; old services and tickets
// remain read-only. All traffic is intercepted, with a fresh browser per case.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'

const origin = 'http://127.0.0.1:18961'
const root = new URL('../web-console/dist/', import.meta.url)
const worker = '66666666-6666-4666-8666-666666666666/77777777-7777-4777-8777-777777777777'
const browser = await chromium.launch()
try {
  for (const agent of ['codex', 'claude']) {
    for (const kind of ['delayed', 'starting', 'old', 'ticket', 'identity']) {
      const context = await browser.newContext()
      try {
        const page = await context.newPage()
        if (kind === 'delayed' || kind === 'starting') await page.clock.install()
        let capability = kind === 'starting' ? false : kind === 'delayed' ? null : kind === 'old' ? undefined : true
        let identityReads = 0
        const sent = []
        // route.fulfill ends the response immediately. Use a real open stream:
        // a completed SSE response must now disable sending until reconnect.
        await page.addInitScript(({ agent, kind }) => {
          const real = window.fetch.bind(window)
          const enc = new TextEncoder()
          const test = window.__sessionView = { capability: kind === 'starting' ? false : kind === 'delayed' ? null : kind === 'old' ? undefined : true }
          test.emit = () => test.controller.enqueue(enc.encode(`data: ${JSON.stringify({ t: 'state', agent, session: 's1', busy: false,
            can_talk: test.capability, talk_reason: test.capability === null || (kind === 'starting' && !test.capability) ? 'checking' : '', queue: [] })}\n\n`))
          window.fetch = async (input, init) => {
            const url = new URL(String(input), location.origin)
            if (url.pathname !== '/v1/chat/view' || url.searchParams.has('cached')) return real(input, init)
            return new Response(new ReadableStream({ start(controller) {
              test.controller = controller
              init?.signal?.addEventListener('abort', () => controller.error(new DOMException('Aborted', 'AbortError')), { once: true })
              test.emit()
              controller.enqueue(enc.encode(`data: ${JSON.stringify({ t: 'items', replace: true, session: 's1', at: 10,
                items: [{ t: 'text', d: 'first reply' }] })}\n\n`))
            } }), { headers: { 'Content-Type': 'text/event-stream' } })
          }
        }, { agent, kind })
        await page.route('**/*', async route => {
          const url = new URL(route.request().url())
          assert.equal(url.origin, origin)
          const path = url.pathname
          const json = body => route.fulfill({ json: body })
          if (path === '/v1/me') {
            identityReads++
            if (kind === 'identity' && identityReads === 1) return route.fulfill({ status: 503, json: { error: 'temporary identity failure' } })
            return json({ person: 'test-person', name: 'Alice', role: 'user', read_only: kind === 'ticket' })
          }
          if (path === '/v1/fleet/tasks') return json({ tasks: [] })
          if (path.startsWith('/v1/fleet/tasks/')) return route.fulfill({ status: 404, json: {} })
          if (path === '/v1/fleet/sessions') return json({ sessions: [], fleets: [] })
          if (path === '/v1/chat/view') {
            assert(url.searchParams.has('cached'), 'live view uses the open stream')
            return json({ mirror: null })
          }
          if (path === '/v1/chat/say') {
            assert(['delayed', 'starting', 'identity'].includes(kind), 'read-only page must not send')
            assert.equal(capability, true, 'unknown permission must not send')
            sent.push(route.request().postDataJSON().text)
            return json({ delivery: `d${sent.length}`, state: 'queued' })
          }
          if (path.startsWith('/v1/')) return json({})
          const file = path.startsWith('/app/s/') ? 'app/index.html' : path.slice(1)
          try { await route.fulfill({ path: fileURLToPath(new URL(file, root)) }) }
          catch { await route.fulfill({ status: 404, body: '' }) }
        })
        await page.goto(`${origin}/app/s/${encodeURIComponent(worker)}`)
        const input = page.locator('textarea.aui-composer-input')
        await input.waitFor()
        if (kind === 'delayed' || kind === 'starting') {
          await input.fill('draft survives discovery')
          assert.match(await input.getAttribute('placeholder'), /Connecting|正在连接/)
          await input.press('Enter')
          assert.equal(sent.length, 0, 'Enter cannot send before the gate answers')
          // A silent stream never ends or errors. It must still recover once
          // three server heartbeats are missing; comments keep it alive.
          await page.clock.fastForward(30_000)
          await page.evaluate(() => window.__sessionView.controller.enqueue(new TextEncoder().encode(': ping\n\n')))
          await page.clock.fastForward(30_000)
          assert.equal(await page.locator('[data-testid=session-view]').getAttribute('data-access'), 'checking', 'a comment heartbeat keeps the stream alive')
          await page.clock.fastForward(15_001)
          await page.locator('[data-testid=session-view][data-access="offline"]').waitFor({ timeout: 2500 })
          assert.equal(await input.inputValue(), 'draft survives discovery')
          assert.equal(await input.isDisabled(), false, 'offline can keep drafting')
          assert.equal(await page.getByRole('button', { name: '发送', exact: true }).isDisabled(), true)
          capability = true
          await page.evaluate(() => { window.__sessionView.capability = true })
          // Run timers in order: fastForward may move the clock before the
          // aborted reader's microtask has scheduled its reconnect timeout.
          await page.clock.runFor(1100)
          await page.locator('[data-testid=session-view][data-talk]').waitFor()
          assert.match(await input.inputValue(), /draft survives discovery/)
          await page.evaluate(() => window.__sessionView.controller.error(new Error('controlled stream disconnect')))
          await page.locator('[data-testid=session-view][data-access="offline"]').waitFor({ timeout: 2500 })
          await page.clock.runFor(1100)
          await page.locator('[data-testid=session-view][data-talk]').waitFor()
          await page.getByRole('button', { name: '发送', exact: true }).click()
          await page.waitForFunction(() => document.querySelector('textarea.aui-composer-input')?.value === '')
          await input.fill('second turn')
          await page.getByRole('button', { name: '发送', exact: true }).click()
          await page.waitForFunction(() => document.querySelector('textarea.aui-composer-input')?.value === '')
          assert.deepEqual(sent, ['draft survives discovery', 'second turn'])
        } else if (kind === 'identity') {
          await input.fill('draft survives identity failure')
          assert.equal(await page.locator('[data-testid=session-view]').getAttribute('data-access'), 'checking')
          await input.press('Enter')
          assert.equal(sent.length, 0, 'a writable stream cannot substitute for unknown sign-in permissions')
          await page.locator('[data-testid=session-view][data-talk]').waitFor({ timeout: 5000 })
          assert(identityReads >= 2, 'temporary identity failure must be retried')
          assert.equal(await input.inputValue(), 'draft survives identity failure')
          await page.getByRole('button', { name: '发送', exact: true }).click()
          await page.waitForFunction(() => document.querySelector('textarea.aui-composer-input')?.value === '')
          assert.deepEqual(sent, ['draft survives identity failure'])
        } else {
          // The stream's state arrives after the input mounts. Wait for its
          // verdict rather than asserting against the initial checking state.
          await page.waitForFunction(() => document.querySelector('textarea.aui-composer-input')?.disabled === true)
          assert.equal(await input.isDisabled(), true, `${kind} input is read-only`)
          assert.equal(sent.length, 0)
        }
        console.log(`PASS session-write ${agent} ${kind}`)
      } finally { await context.close() }
    }
  }
} finally { await browser.close() }
