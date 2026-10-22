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
    for (const kind of ['delayed', 'old', 'ticket']) {
      const context = await browser.newContext()
      try {
        const page = await context.newPage()
        let capability = kind === 'delayed' ? null : kind === 'ticket' ? true : undefined
        const sent = []
        await page.route('**/*', async route => {
          const url = new URL(route.request().url())
          assert.equal(url.origin, origin)
          const path = url.pathname
          const json = body => route.fulfill({ json: body })
          if (path === '/v1/me') return json({ person: 'test-person', name: 'Alice', role: 'user', read_only: kind === 'ticket' })
          if (path === '/v1/fleet/tasks') return json({ tasks: [] })
          if (path.startsWith('/v1/fleet/tasks/')) return route.fulfill({ status: 404, json: {} })
          if (path === '/v1/fleet/sessions') return json({ sessions: [], fleets: [] })
          if (path === '/v1/chat/view') {
            if (url.searchParams.has('cached')) return json({ mirror: null })
            const frames = [
              { t: 'state', agent, session: 's1', busy: false, can_talk: capability,
                talk_reason: capability === null ? 'checking' : '', queue: [] },
              { t: 'items', replace: true, session: 's1', at: 10, items: [{ t: 'text', d: 'first reply' }] },
            ]
            return route.fulfill({ contentType: 'text/event-stream', body: frames.map(f => `data: ${JSON.stringify(f)}\n\n`).join('') })
          }
          if (path === '/v1/chat/say') {
            assert.equal(kind, 'delayed', 'read-only page must not send')
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
        if (kind === 'delayed') {
          await input.fill('draft survives discovery')
          assert.match(await input.getAttribute('placeholder'), /Connecting|正在连接/)
          await input.press('Enter')
          assert.equal(sent.length, 0, 'Enter cannot send before the gate answers')
          capability = true
          await page.locator('[data-testid=session-view][data-talk]').waitFor()
          assert.match(await input.inputValue(), /draft survives discovery/)
          await page.getByRole('button', { name: '发送', exact: true }).click()
          await page.waitForFunction(() => document.querySelector('textarea.aui-composer-input')?.value === '')
          await input.fill('second turn')
          await page.getByRole('button', { name: '发送', exact: true }).click()
          await page.waitForFunction(() => document.querySelector('textarea.aui-composer-input')?.value === '')
          assert.deepEqual(sent, ['draft survives discovery', 'second turn'])
        } else {
          assert.equal(await input.isDisabled(), true, `${kind} input is read-only`)
          assert.equal(sent.length, 0)
        }
        console.log(`PASS session-write ${agent} ${kind}`)
      } finally { await context.close() }
    }
  }
} finally { await browser.close() }
