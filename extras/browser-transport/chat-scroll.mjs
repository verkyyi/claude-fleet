// Deterministic production-page drill (task JDHN): opening the conversation
// lands on its newest message, and stays there while the page grows under it —
// the entry's copy (cached=1) shown first and then replaced by the home's longer
// answer, images that load after the first scroll, a narrower viewport (a phone
// keyboard). Once the person scrolls up the page stops following and offers the
// 到最新 button. The thread's turnAnchor="top" made assistant-ui default
// autoScroll to off, so only the very first frame was scrolled: the view stayed
// at the old bottom — the middle of the conversation. All requests intercepted.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'

// https: assistant-ui keeps an image part only at an https:, blob: or data: URL
const origin = 'https://chat.example'
const root = new URL('../web-console/dist/', import.meta.url)
const api = '/v1/chat'
const browser = await chromium.launch()
// a 1×1 png; served as a tall picture by its intrinsic size below
const png = (w, h) => `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="#8ab"/></svg>`

async function open(viewport, { conv, copy, pic }) {
  const context = await browser.newContext({ viewport })
  const page = await context.newPage()
  await page.route('**/*', async route => {
    const url = new URL(route.request().url())
    assert.equal(url.origin, origin, 'the page must remain same-origin')
    const path = url.pathname
    const json = body => route.fulfill({ json: body })
    if (path === `${api}/conversation` && url.searchParams.get('cached') === '1') return json(await copy())
    if (path === `${api}/conversation`) return json(await conv())
    if (path === `${api}/file`) { await pic(); return route.fulfill({ contentType: 'image/svg+xml', body: png(600, 900) }) }
    if (path === '/v1/chat/home') return json({ state: 'ok', direct: false })
    if (path === '/v1/me') return json({ person: 'test-person', name: 'Alice', role: 'member' })
    if (path.startsWith('/v1/') || path.startsWith('/api/')) return json({})
    const file = path === '/' ? 'index.html' : path === '/app' || path === '/app/' || path === '/app/chat' ? 'app/index.html' : path.slice(1)
    try { await route.fulfill({ path: fileURLToPath(new URL(file, root)) }) } catch { await route.fulfill({ status: 404, body: '' }) }
  })
  return { context, page }
}

const turns = (n, withPics) => Array.from({ length: n }, (_, i) => [
  { t: 'user', text: `q-${i}` },
  { t: 'text', d: `a-${i} ` + 'long answer text '.repeat(30) },
  ...(withPics && i >= n - 3 ? [{ t: 'image', ref: `${String(i).padStart(32, '0')}.png` }] : []),
]).flat()
const convo = (n, withPics) => ({ session: 's1', items: turns(n, withPics) })

const gap = page => page.evaluate(() => {
  const v = document.querySelector('[data-slot="aui_thread-viewport"]')
  return Math.round(v.scrollHeight - v.scrollTop - v.clientHeight)
})
const atBottom = async (page, why) => {
  // the library follows within a frame of each resize; allow a moment
  for (let i = 0; i < 20; i++) { if (await gap(page) <= 2) return; await page.waitForTimeout(100) }
  assert.fail(`${why}: ${await gap(page)}px above the bottom`)
}

try {
  for (const viewport of [{ width: 390, height: 844 }, { width: 1440, height: 900 }]) {
    const tag = `${viewport.width}px`
    let releaseHome, releasePics
    const home = new Promise(r => { releaseHome = r })
    const pics = new Promise(r => { releasePics = r })
    const { context, page } = await open(viewport, {
      copy: async () => ({ ...convo(12, false), busy: false, mirror: { at: '2026-10-21T00:00:00Z' } }),
      conv: async () => { await home; return convo(30, true) },
      pic: () => pics,
    })
    try {
      await page.goto(origin + '/app/chat')
      // 1. the copy alone: at its bottom
      await page.getByText('q-11', { exact: true }).waitFor()
      await atBottom(page, `${tag} copy shown`)
      // 2. the home's longer answer replaces it: still at the (new) bottom
      releaseHome()
      await page.getByText('q-29', { exact: true }).waitFor()
      await atBottom(page, `${tag} home replaced the copy`)
      // 3. the images load after that and push the page taller: followed
      const before = await page.evaluate(() => document.querySelector('[data-slot="aui_thread-viewport"]').scrollHeight)
      releasePics()
      await page.waitForFunction(() => [...document.querySelectorAll('img')].filter(i => i.complete && i.naturalHeight > 0).length >= 3)
      await page.waitForTimeout(300) // the placeholder gives way on the next render
      const after = await page.evaluate(() => document.querySelector('[data-slot="aui_thread-viewport"]').scrollHeight)
      assert.ok(after > before + 200, `${tag}: the images must have grown the page (${before} → ${after})`)
      await atBottom(page, `${tag} images loaded late`)
      // 4. a shorter viewport (a phone keyboard opening): still at the bottom
      await page.setViewportSize({ width: viewport.width, height: Math.round(viewport.height * 0.55) })
      await atBottom(page, `${tag} viewport shrank`)
      await page.setViewportSize(viewport)
      await atBottom(page, `${tag} viewport restored`)
      // 5. the person scrolls up: the page stops following, the button shows
      await page.mouse.move(viewport.width / 2, viewport.height / 3)
      await page.mouse.wheel(0, -1500)
      await page.waitForTimeout(400)
      const up = await gap(page)
      assert.ok(up > 500, `${tag}: a scroll up must leave the bottom (${up}px)`)
      await page.evaluate(() => {
        const g = document.querySelector('[data-slot="aui_message-group"]')
        const d = document.createElement('div'); d.style.height = '400px'; g.appendChild(d)
      })
      await page.waitForTimeout(400)
      assert.ok(await gap(page) >= up, `${tag}: growth after a scroll up must not pull the page down`)
      const btn = page.locator('.aui-thread-scroll-to-bottom')
      assert.ok(await btn.isEnabled(), `${tag}: the 到最新 button must be offered`)
      await btn.click()
      await atBottom(page, `${tag} 到最新 pressed`)
      console.log(`ok ${tag}: copy → home → late images → keyboard → scroll up → 到最新`)
    } finally { await context.close() }
  }
  console.log('chat-scroll: ok')
} finally { await browser.close() }
