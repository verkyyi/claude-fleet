import assert from 'node:assert/strict'
import { mkdir } from 'node:fs/promises'
import { chromium } from 'playwright'

const { FLEET_TEST_ORIGIN: origin, FLEET_TEST_COOKIE: cookie, FLEET_TEST_WORKER: worker, FLEET_TEST_FIXTURE: fixture } = process.env
const mode = process.argv[2]
const dir = `evidence/recovery-${mode}`
await mkdir(dir, { recursive: true })
const browser = await chromium.launch({ args: mode === 'relay' ? ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'] : [] })
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' })
const eq = cookie.indexOf('=')
const auth = { name: cookie.slice(0, eq), value: cookie.slice(eq + 1), url: origin }
await context.addCookies([auth, { name: 'cf_lang', value: 'en', url: origin }])
await context.tracing.start({ screenshots: true, snapshots: true, sources: true })
await context.addInitScript(() => {
  window.__ready = []; window.__pairs = []; window.__attempts = 0
  const frame = event => {
    if (typeof event.data !== 'string') return
    try {
      const c = JSON.parse(event.data)
      if (c.t === 'ready') window.__ready.push(c)
      if (c.t === 'selected') window.__pairs.push(c)
    } catch {}
  }
  const WS = window.WebSocket
  window.WebSocket = class extends WS { constructor(...a) { super(...a); if (String(a[0]).includes('/v1/attachment/connect')) window.__attempts++; this.addEventListener('message', frame) } }
  const create = RTCPeerConnection.prototype.createDataChannel
  RTCPeerConnection.prototype.createDataChannel = function(...a) { const dc = create.apply(this, a); dc.addEventListener('message', frame); return dc }
})
const evidence = []
const state = async () => (await context.request.get(`${fixture}/state`)).json()
const ready = async page => {
  await page.waitForFunction(() => [...document.querySelectorAll('button')].some(b => b.textContent === 'Fleet menu' && !b.disabled), { timeout: 30000 })
  return page.evaluate(() => window.__ready.at(-1))
}
const wait = async predicate => {
  const until = Date.now() + 12000
  while (!await predicate()) { if (Date.now() > until) throw new Error('fixture assertion timed out'); await new Promise(r => setTimeout(r, 100)) }
}
try {
  for (const target of ['personal', 'worker']) {
    const page = await context.newPage()
    const url = `${origin}/app/terminal${target === 'worker' ? `?worker=${encodeURIComponent(worker)}` : ''}`
    await page.goto(url)
    const first = await ready(page)
    assert(first?.term && first.gen && first.epoch, 'ready must carry logical identity and controller epoch')
    const tag = `once_${mode}_${target}`
    await page.locator('.xterm-helper-textarea').pressSequentially(`printf '%s\\n' ${tag} >> "$HOME/commands"`)
    await page.locator('.xterm-helper-textarea').press('Enter')
    await wait(async () => (await state()).commands.includes(tag))
    await context.setOffline(true)
    await page.getByText('Reconnecting…', { exact: true }).waitFor()
    assert(await page.getByRole('button', { name: 'Fleet menu', exact: true }).isDisabled())
    await new Promise(r => setTimeout(r, 5000))
    await context.setOffline(false)
    const resumed = await ready(page)
    assert.equal(resumed.gen, first.gen); assert.equal(resumed.term, first.term)
    assert(resumed.epoch > first.epoch)
    const snapshot = await state()
    assert.equal(snapshot.commands.split('\n').filter(v => v === tag).length, 1)
    assert.equal(snapshot.home_pid, snapshot.initial_pid)
    assert.equal(snapshot.worker_pid, snapshot.initial_worker_pid)
    await page.reload(); const reloaded = await ready(page)
    assert.equal(reloaded.gen, first.gen)
    if (target === 'personal') {
      await page.getByRole('button', { name: 'Fleet menu', exact: true }).click()
      await new Promise(r => setTimeout(r, 500))
      await page.locator('.xterm-helper-textarea').pressSequentially('Browser worker')
      await page.locator('.xterm-helper-textarea').press('Enter')
      await wait(async () => { const s = await state(); return s.views.includes(`|${s.worker_window}`) })
      await page.getByRole('button', { name: 'Open shell', exact: true }).click()
      await wait(async () => { const s = await state(); return s.views.split('\n').some(v => v.includes('@view-') && v.endsWith(`|${s.home_window}`)) })
      await page.getByRole('button', { name: 'Open shell', exact: true }).click()
      await wait(async () => { const s = await state(); return s.views.split('\n').some(v => v.includes('@view-') && v.endsWith(`|${s.worker_window}`)) })
    }
    const second = await context.newPage(); await second.goto(url)
    await second.getByRole('button', { name: 'Use here', exact: true }).waitFor()
    assert(await second.getByRole('button', { name: 'Fleet menu', exact: true }).isDisabled())
    await second.getByRole('button', { name: 'Use here', exact: true }).click()
    const taken = await ready(second)
    assert(taken.epoch > reloaded.epoch)
    await page.getByRole('button', { name: 'Use here', exact: true }).waitFor()
    await page.close() // old cleanup must not close or resize the winner
    assert.equal((await ready(second)).epoch, taken.epoch)
    const pairs = await second.evaluate(() => window.__pairs)
    assert(pairs.some(p => p.mode === mode))
    if (mode === 'direct') assert(pairs.some(p => p.pair && p.pair !== 'hub'))
    await second.screenshot({ path: `${dir}/${target}.png` })
    evidence.push({ target, first, resumed, taken, commandCount: 1, homePID: snapshot.home_pid, workerPID: snapshot.worker_pid, pairs })
    if (target === 'personal') {
      const directEntry = await context.newPage()
      await directEntry.goto(`${origin}/app/terminal?worker=${encodeURIComponent(worker)}`)
      await directEntry.getByRole('button', { name: 'Use here', exact: true }).waitFor()
      await directEntry.getByRole('button', { name: 'Use here', exact: true }).click()
      await ready(directEntry)
      await second.getByRole('button', { name: 'Use here', exact: true }).waitFor()
      await directEntry.close()
    }
    await second.close()
  }
  const page = await context.newPage()
  await page.goto(`${origin}/app/terminal`); const before = await ready(page)
  await context.request.post(`${fixture}/relay`)
  await page.getByText('Reconnecting…', { exact: true }).waitFor()
  assert.equal((await ready(page)).gen, before.gen, 'relay restart must preserve terminal generation')
  // Keep the personal home independent while the worker process is replaced.
  await page.getByRole('button', { name: 'Open shell', exact: true }).click()
  await wait(async () => { const s = await state(); return s.views.split('\n').some(v => v.includes('@view-') && v.endsWith(`|${s.home_window}`)) })
  const processPage = await context.newPage()
  await processPage.goto(`${origin}/app/terminal?worker=${encodeURIComponent(worker)}`)
  const oldProcess = await ready(processPage)
  await context.request.post(`${fixture}/worker-respawn`)
  await processPage.getByRole('alert').waitFor({ timeout: 30000 })
  assert(await processPage.getByRole('button', { name: 'Fleet menu', exact: true }).isDisabled())
  const processAttempts = await processPage.evaluate(() => window.__attempts)
  await new Promise(r => setTimeout(r, 2000))
  assert.equal(await processPage.evaluate(() => window.__attempts), processAttempts, 'process replacement kept retrying')
  await processPage.getByRole('button', { name: 'Connect current session', exact: true }).click()
  assert.notEqual((await ready(processPage)).gen, oldProcess.gen, 'explicit action must admit the current process')
  await processPage.close()
  await context.request.post(`${origin}/logout`, { headers: { Origin: origin } })
  await page.getByRole('link', { name: 'Sign in', exact: true }).waitFor({ timeout: 20000 })
  const attempts = await page.evaluate(() => window.__ready.length)
  await new Promise(r => setTimeout(r, 2000))
  assert.equal(await page.evaluate(() => window.__ready.length), attempts, 'revoked authentication retried')
  await context.addCookies([{ ...auth, value: process.env.FLEET_TEST_FRESH_COOKIE }, { name: 'cf_lang', value: 'en', url: origin }])
  await page.reload(); await ready(page)
  await context.request.post(`${fixture}/host`)
  await page.getByRole('alert').waitFor({ timeout: 30000 })
  assert(await page.getByRole('button', { name: 'Fleet menu', exact: true }).isDisabled())
  const hostAttempts = await page.evaluate(() => window.__attempts)
  await new Promise(r => setTimeout(r, 2000))
  assert.equal(await page.evaluate(() => window.__attempts), hostAttempts, 'host loss kept retrying')
  await page.close()
  console.log(JSON.stringify({ browser: browser.version(), mode, evidence, relayRestart: 'same generation', authExpiry: 'stopped', hostLoss: 'ended; no replay', safari: 'pending', osIME: 'pending' }))
} catch (error) {
  for (const [i, page] of context.pages().entries()) {
    console.error('page', i, page.url(), await page.locator('body').innerText());
    await page.screenshot({ path: `${dir}/failure-${i}.png` });
  }
  console.error('fixture', await state());
  throw error;
} finally {
  await context.tracing.stop({ path: `${dir}/trace.zip` })
  await context.close(); await browser.close()
}
