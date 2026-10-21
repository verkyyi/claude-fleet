import assert from 'node:assert/strict'
import { mkdir } from 'node:fs/promises'
import { chromium } from 'playwright'

const { FLEET_TEST_ORIGIN: origin, FLEET_TEST_COOKIE: cookie, FLEET_TEST_WORKER: worker, FLEET_TEST_FIXTURE: fixture } = process.env
const mode = process.argv[2]
const ELSEWHERE = 'This terminal is open in another tab. Click here to bring it back.'
const dir = `evidence/recovery-${mode}`
await mkdir(dir, { recursive: true })
const browser = await chromium.launch({ args: mode === 'relay' ? ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'] : [] })
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' })
const eq = cookie.indexOf('=')
const auth = { name: cookie.slice(0, eq), value: cookie.slice(eq + 1), url: origin }
await context.addCookies([auth, { name: 'cf_lang', value: 'en', url: origin }])
await context.tracing.start({ screenshots: true, snapshots: true, sources: true })
const observe = () => {
  window.__ready = []; window.__pairs = []; window.__attempts = 0; window.__sent = 0
  for (const proto of [WebSocket.prototype, RTCDataChannel.prototype]) {
    const send = proto.send
    proto.send = function(data) {
      if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) window.__sent += data.byteLength
      return send.call(this, data)
    }
  }
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
}
await context.addInitScript(observe)
const others = []
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
    const url = `${origin}/app/s/${target === 'worker' ? encodeURIComponent(worker) : 'shell'}?view=term`
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
    // Independent cookie/storage profile: another browser signed in as the same person.
    const other = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' })
    others.push({ context: other, target })
    await other.addCookies([auth, { name: 'cf_lang', value: 'en', url: origin }])
    await other.addInitScript(observe)
    await other.tracing.start({ screenshots: true, snapshots: true, sources: true })
    // RMVE: opening the page takes the terminal — no «Use here»; the page it
    // was taken from says so and does not take it back by itself.
    const second = await other.newPage(); await second.goto(url)
    const taken = await ready(second)
    assert(taken.epoch > reloaded.epoch)
    await page.getByText(ELSEWHERE, { exact: true }).waitFor()
    assert(await page.getByRole('button', { name: 'Fleet menu', exact: true }).isDisabled())
    await new Promise(r => setTimeout(r, 1500))
    assert.equal((await ready(second)).epoch, taken.epoch, 'the page taken from took it back by itself')
    await page.close() // old cleanup must not close or resize the winner
    assert.equal((await ready(second)).epoch, taken.epoch)
    const pairs = await second.evaluate(() => window.__pairs)
    assert(pairs.some(p => p.mode === mode))
    if (mode === 'direct') assert(pairs.some(p => p.pair && p.pair !== 'hub'))
    await second.screenshot({ path: `${dir}/${target}.png` })
    assert.equal((await state()).commands.split('\n').filter(v => v === tag).length, 1, 'reopen or takeover replayed input')
    evidence.push({ independentBrowserProfiles: true, target, first, resumed, taken, commandCount: 1, homePID: snapshot.home_pid, workerPID: snapshot.worker_pid, pairs })
    if (target === 'personal') {
      const directEntry = await context.newPage()
      await directEntry.goto(`${origin}/app/s/${encodeURIComponent(worker)}?view=term`)
      await ready(directEntry)
      await second.getByText(ELSEWHERE, { exact: true }).waitFor()
      await directEntry.close()
    }
    await second.close()
  }
  let page = await context.newPage()
  await page.goto(`${origin}/app/s/shell?view=term`)
  // Reopening takes the terminal (RMVE) — never restarts the shell.
  const before = await ready(page)
  assert.equal(before.gen, evidence[0].first.gen, 'closing all pages and reopening must keep the generation')
  const reopened = await state()
  assert.equal(reopened.home_pid, reopened.initial_pid)
  assert.equal(reopened.worker_pid, reopened.initial_worker_pid)
  for (const target of ['personal', 'worker']) assert.equal(reopened.commands.split('\n').filter(v => v === `once_${mode}_${target}`).length, 1)
  await context.request.post(`${fixture}/relay`)
  await page.getByText('Reconnecting…', { exact: true }).waitFor()
  assert.equal((await ready(page)).gen, before.gen, 'relay restart must preserve terminal generation')
  // Keep the personal home independent while the worker process is replaced.
  await page.getByRole('button', { name: 'Open shell', exact: true }).click()
  await wait(async () => { const s = await state(); return s.views.split('\n').some(v => v.includes('@view-') && v.endsWith(`|${s.home_window}`)) })
  const processPage = await context.newPage()
  await processPage.goto(`${origin}/app/s/${encodeURIComponent(worker)}?view=term`)
  const oldProcess = await ready(processPage)
  assert.equal(oldProcess.gen, evidence[1].first.gen, 'reopening the worker must keep its generation')
  await context.request.post(`${fixture}/worker-respawn`)
  // RMVE: the replaced process is the current one — connected, and said, no button
  await processPage.getByText('This session restarted — connected to the current one.', { exact: true }).waitFor({ timeout: 30000 })
  assert.notEqual((await ready(processPage)).gen, oldProcess.gen, 'the current process must be the one connected')
  const processAttempts = await processPage.evaluate(() => window.__attempts)
  await new Promise(r => setTimeout(r, 2000))
  assert.equal(await processPage.evaluate(() => window.__attempts), processAttempts, 'a connected page kept reconnecting')
  await processPage.close()
  // Real shell bytes through the built console, hub, node and native tmux.
  // Open shell selects the persistent home; an explicitly nested sh returns
  // to it, while exiting that outer shell ends the personal terminal.
  const command = async (p, text) => {
    await p.locator('.xterm-helper-textarea').pressSequentially(text)
    await p.locator('.xterm-helper-textarea').press('Enter')
  }
  const nestedGeneration = (await ready(page)).gen
  for (const end of ['exit', 'Control+d']) {
    await command(page, 'sh')
    if (end === 'exit') await command(page, 'exit')
    else await page.locator('.xterm-helper-textarea').press(end)
    const tag = `nested_${mode}_${end}`
    await command(page, `printf '%s\\n' '${tag}' >> "$HOME/commands"`)
    await wait(async () => (await state()).commands.includes(tag))
    assert.equal((await ready(page)).gen, nestedGeneration)
  }
  const liveWorkerPID = (await state()).worker_pid
  for (const end of ['exit', 'Control+d']) {
    const old = await ready(page)
    const oldInput = await page.locator(".xterm-helper-textarea").elementHandle()
    const oldPage = page
    if (end === 'exit') await command(page, 'exit')
    else await page.locator('.xterm-helper-textarea').press(end)
    // RMVE: the personal terminal really ended — a new one is opened by itself
    // (one renew of that generation), and the page says so; no button.
    await page.getByText("Your previous terminal ended, so we opened a new one. Commands that had exited won't restart.", { exact: true }).waitFor({ timeout: 30000 })
    const current = await ready(page)
    assert.equal(current.term, old.term)
    assert.equal(Number(current.gen.split(':')[1]), Number(old.gen.split(':')[1]) + 1)
    assert.equal(await page.getByRole('button', { name: 'Reopen terminal', exact: true }).count(), 0)
    const attempts = await page.evaluate(() => window.__attempts)
    await new Promise(r => setTimeout(r, 1500))
    assert.equal(await page.evaluate(() => window.__attempts), attempts, 'a renewed terminal kept reconnecting')
    // A fresh page takes the renewed terminal; it never renews it again.
    const rival = await context.newPage()
    await rival.goto(`${origin}/app/s/shell?view=term`)
    assert.equal((await ready(rival)).gen, current.gen, 'a second page renewed again')
    await page.getByText(ELSEWHERE, { exact: true }).waitFor()
    await page.getByText(ELSEWHERE, { exact: true }).click()
    assert.equal((await ready(page)).gen, current.gen)
    await rival.getByText(ELSEWHERE, { exact: true }).waitFor()
    const sent = await oldPage.evaluate(() => window.__sent)
    await oldInput.dispatchEvent('compositionstart', {data:'未提交'})
    await oldInput.dispatchEvent('compositionend', {data:'未提交'})
    assert.equal(await oldPage.evaluate(() => window.__sent), sent, 'disposed CJK composition replayed')
    await oldInput.dispose()
    await rival.close()
    assert.equal((await state()).worker_pid, liveWorkerPID, "renew restarted worker")
    const tag = `renewed_${mode}_${end}`
    await command(page, `printf '%s\\n' '${tag}' >> "$HOME/commands"`)
    await wait(async () => (await state()).commands.includes(tag))
    // Old-generation connects and renews are both refused, even with a valid
    // cookie; no uncertain command is replayed across the generation boundary.
    for (const renew of [false, true]) {
      const result = await page.evaluate(({gen, renew}) => new Promise((resolve, reject) => {
        const q = new URLSearchParams({service:'term', target:'personal', controller:'1', term_resume:gen, ...(renew ? {renew:'1'} : {})})
        const ws = new WebSocket(`${location.origin.replace('http','ws')}/v1/attachment/connect?${q}`)
        const timeout = setTimeout(() => { ws.close(); reject(new Error('stale request timeout')) }, 15000)
        ws.onmessage = event => {
          const m = JSON.parse(event.data)
          if (m.t === 'config') { ws.send(JSON.stringify({t:'relay'})); ws.send(JSON.stringify({t:'select', mode:'relay'})) }
          if (m.t === 'error') { clearTimeout(timeout); ws.close(); resolve(m.error) }
        }
      }), {gen:old.gen, renew})
      assert.equal(result, 'interrupted')
    }
    await context.setOffline(true)
    await page.getByText('Reconnecting…', { exact: true }).waitFor()
    await context.setOffline(false)
    assert.equal((await ready(page)).gen, current.gen, 'network recovery renewed again')
    assert.equal((await state()).commands.split('\n').filter(v => v === tag).length, 1)
    await page.screenshot({path:`${dir}/renew-${end.replace('+','-')}.png`})
    evidence.push({personalRenew:end, old:old.gen, current:current.gen, automatic:true})
  }
  await page.getByRole('button', { name: 'Fleet menu', exact: true }).click()
  await new Promise(r => setTimeout(r, 500))
  await page.locator('.xterm-helper-textarea').pressSequentially('Browser worker')
  await page.locator('.xterm-helper-textarea').press('Enter')
  await wait(async () => { const s = await state(); return s.views.split('\n').some(v => v.includes('@view-') && v.endsWith(`|${s.worker_window}`)) })
  await page.getByRole('button', { name: 'Open shell', exact: true }).click()
  await wait(async () => { const s = await state(); return s.views.split('\n').some(v => v.includes('@view-') && v.endsWith(`|${s.home_window}`)) })
  const endedWorker = await context.newPage()
  await endedWorker.goto(`${origin}/app/s/${encodeURIComponent(worker)}?view=term`)
  await ready(endedWorker)
  await command(endedWorker, 'exit')
  // RMVE: a session's terminal that ended takes you to your own, saying so
  await endedWorker.getByText('That session has ended — switched to your terminal.', { exact: true }).waitFor({ timeout: 30000 })
  assert(new URL(endedWorker.url()).pathname === '/app/s/shell', 'still on the ended session')
  await ready(endedWorker)
  assert.equal((await state()).worker_dead, '1', 'ended worker restarted')
  await endedWorker.close()
  // the page it was taken from: once that page is gone the lease is free and
  // its own reconnect gets it back; else it is clicked back (RMVE)
  await page.waitForFunction((t) => [...document.querySelectorAll('button')].some(b => (b.textContent === 'Fleet menu' && !b.disabled) || b.textContent === t), ELSEWHERE, { timeout: 30000 })
  if (await page.getByText(ELSEWHERE, { exact: true }).isVisible()) await page.getByText(ELSEWHERE, { exact: true }).click()
  await ready(page)
  await context.request.post(`${origin}/logout`, { headers: { Origin: origin } })
  await page.getByRole('link', { name: 'Sign in', exact: true }).waitFor({ timeout: 20000 })
  const attempts = await page.evaluate(() => window.__ready.length)
  await new Promise(r => setTimeout(r, 2000))
  assert.equal(await page.evaluate(() => window.__ready.length), attempts, 'revoked authentication retried')
  await context.addCookies([{ ...auth, value: process.env.FLEET_TEST_FRESH_COOKIE }, { name: 'cf_lang', value: 'en', url: origin }])
  await page.reload(); await ready(page)
  const hostGen = (await ready(page)).gen
  await context.request.post(`${fixture}/host`)
  // RMVE: the home's tmux went with everything in it — a new terminal is
  // opened by itself (the fixture brings the fleet back), no replay, no button
  await page.getByText("Your previous terminal ended, so we opened a new one. Commands that had exited won't restart.", { exact: true }).waitFor({ timeout: 30000 })
  assert.notEqual((await ready(page)).gen, hostGen)
  const hostAttempts = await page.evaluate(() => window.__attempts)
  await new Promise(r => setTimeout(r, 2000))
  assert.equal(await page.evaluate(() => window.__attempts), hostAttempts, 'host loss kept retrying after it came back')
  await page.close()
  console.log(JSON.stringify({ browser: browser.version(), mode, evidence, closeReopen: 'same PID and generation', relayRestart: 'same generation', authExpiry: 'stopped', hostLoss: 'renewed by itself; no replay', safari: 'pending', osIME: 'pending' }))
} catch (error) {
  for (const [i, page] of [context, ...others.map(o => o.context)].flatMap(c => c.pages()).entries()) {
    console.error('page', i, page.url(), await page.locator('body').innerText());
    await page.screenshot({ path: `${dir}/failure-${i}.png` });
  }
  console.error('fixture', await state());
  throw error;
} finally {
  await context.tracing.stop({ path: `${dir}/trace.zip` })
  for (const other of others) {
    await other.context.tracing.stop({ path: `${dir}/trace-controller-${other.target}.zip` })
    await other.context.close()
  }
  await context.close(); await browser.close()
}
