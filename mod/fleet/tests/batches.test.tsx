// The orchestrator's batches pane (issue #2833, EPIC #2831 C2). A mocked engine
// like panels.test.ts's: the version answers in range; `process.run` answers the
// window's @fleet_role and the strings dump, and records every other argv (the
// jump / open a press starts) with the exit code the test sets; an in-memory file
// map answers fs.*; `ui.open` / `ui.toast` record what the plugin asked.

import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, RenderPropsOf } from 'claude-code'

import { BATCHES_PANE, batchLine, jumpArgv, jumpToast, resetBatches } from '../hooks/batches'
import { bar, beatClock, foldBoard, splitRef } from '../hooks/batches-model'
import { isRoleRun, resetRole } from '../hooks/orchestrator'
import { SHEET_COMMAND, panelPaths, resetPanels } from '../hooks/panels'
import { parseMarks } from '../hooks/panels-model'
import { isStringsRun, takeStrings } from '../hooks/qd'
import { resetQueue } from '../hooks/queue'
import { SUPPORTED } from '../hooks/version'

const NOW = 1_000_000_000_000
const SEC = NOW / 1000
const P = panelPaths('/conf', 'fleet')
const ENV = { TMUX_PANE: '%7', TMUX: '/private/tmp/tmux-501/fleet,123,0', FLEET_CONF_DIR: '/conf', HOME: '/h' }
const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const HAND = { kind: 'composer' } as const
const DUMP = [
  'panel_batches_landed_fmt', '\u0001/\u0001',
  'panel_batches_beat_fmt', 'beat \u0001 \u0001m',
  'panel_batches_stale_fmt', 'stale \u0001 \u0001m',
  'panel_batches_parked_fmt', 'parked \u0001',
  'orch_queue_fmt', 'queued \u0001 · \u0001 · \u0001s', 'orch_queue_thinking', 'thinking',
].join('\0') + '\0'

// ---- fixtures: 3 marks (fresh / past ttl / no title) + a driver only the ledger has --------

function mark(epic: number, epoch: number, title = ''): string {
  return `epoch: ${epoch}\nttl: 2700\nepic: ${epic}\nrepo: o/r\nsession: fleet\ntick: 5\nlanded: 3\nmembers: 5\nlive: 1\ninflight: 2\n${
    title !== '' ? `title: ${title}\n` : ''}`
}

const MARKS = [
  { name: 'o-r-2831', text: mark(2831, SEC - 180, '面板') },
  { name: 'o-r-2770', text: mark(2770, SEC - 4000, '角色') },
  { name: 'o-r-2756', text: mark(2756, SEC - 60) },
]

function stateJson(items: Record<string, unknown> = {}): string {
  return JSON.stringify({
    v: 1, rows: {}, sheet: {},
    drivers: {
      'o/r#2831': 'o-r:scratch-14', 'o/r#2770': 'o-r:scratch-11', 'o/r#2756': 'o-r:scratch-10',
      'g/m#11900': 'g-m:scratch-20', 'o/r#2000': 'o-r:scratch-2',
    },
    todo: { desk: 'o/r#9', epics: { 'o/r#1999': { closed: SEC - 60, done: true }, 'o/r#1500': { closed: SEC - 3 * 86400 } }, items },
  })
}

const ITEMS = {
  a: { id: 'a', kind: 'stable', what: '挪稳定版', due: '', state: 'pending', sources: [{ epic: 'o/r#1999', url: 'https://x/1999' }] },
  b: { id: 'b', kind: 'human', what: '真机试一次', due: '2026-10-10', state: 'open', sources: [{ epic: 'o/r#1999', url: '' }] },
  c: { id: 'c', kind: 'human', what: '已办', due: '', state: 'done', sources: [] },
}

const LEDGER = [
  { seq: 1, child: 'g-m:scratch-20', state: 'WAITING', verdict: '' },
  { seq: 2, child: 'o-r:scratch-2', state: 'MERGED', verdict: '' },
].map(r => JSON.stringify(r)).join('\n') + '\n'

const PARK = JSON.stringify({ v: 1, parked: {
  'o/r#5': { at: 1, wait: [], key: 'o-r:issue-5', origin: 'o-r:scratch-14' },
  'o/r#6': { at: 2, wait: [], key: 'o-r:issue-6', origin: 'o-r:scratch-14' },
  'o/r#7': { at: 3, wait: [], key: 'o-r:issue-7', origin: 'o-r:scratch-99' },
} })

// ---- the pure half -------------------------------------------------------------------------

test('foldBoard: 3 marks + 1 ledger-only driver → 4 rows, the right driver, parked, title, freshness', () => {
  const b = foldBoard(parseMarks(MARKS, SEC), { state: stateJson(ITEMS), park: PARK, ledger: LEDGER }, NOW)
  expect(b.batches.map(x => x.ref)).toEqual(['o/r#2756', 'o/r#2831', 'o/r#2770', 'g/m#11900'])
  const [noTitle, fresh, stale, ledgerOnly] = b.batches
  expect(fresh).toMatchObject({ title: '面板', fresh: true, driver: 'o-r:scratch-14', parked: 2, noMark: false })
  expect(stale).toMatchObject({ title: '角色', fresh: false, driver: 'o-r:scratch-11', parked: 0 })
  expect(noTitle).toMatchObject({ title: '', fresh: true, driver: 'o-r:scratch-10' })
  expect(ledgerOnly).toMatchObject({ epic: 11900, repo: 'g/m', noMark: true, driver: 'g-m:scratch-20' })
  // the MERGED driver is no batch; the one closed today is a grey line, the old one none
  expect(b.done.map(d => d.ref)).toEqual(['o/r#1999'])
  // 待你动手: open rows by due, a done one left out
  expect(b.todo.map(i => i.id)).toEqual(['b', 'a'])
  expect(b.todo[1]).toMatchObject({ kind: 'stable', url: 'https://x/1999' })
})

test('the lines: a title or #N, the bar, 心跳 vs 心跳停了, 没写心跳', () => {
  takeStrings(DUMP)
  const b = foldBoard(parseMarks(MARKS, SEC), { state: stateJson(), park: PARK, ledger: LEDGER }, NOW)
  const by = (ref: string) => b.batches.find(x => x.ref === ref)!
  const f = batchLine(by('o/r#2831'), NOW)
  expect(f.stale).toBe(false)
  expect(f.text).toContain('#2831 面板')
  expect(f.text).toContain(`${bar(3, 5)} 3/5`)
  expect(f.text).toContain(`beat ${beatClock(SEC - 180, NOW).hhmm} 3m`)
  expect(f.text).toContain('parked 2')
  const s = batchLine(by('o/r#2770'), NOW)
  expect(s.stale).toBe(true)
  expect(s.text).toContain('stale ')
  expect(batchLine(by('o/r#2756'), NOW).text.startsWith('#2756  ')).toBe(true)
  expect(batchLine(by('g/m#11900'), NOW).text).toBe('#11900  panel_batches_nomark')
  expect(bar(0, 0)).toBe('')
  expect(splitRef('#12')).toEqual(['', 12])
  expect(splitRef('nope')).toBe(null)
})

test('jump: argv through fleet-panel-jump.sh; every non-zero exit says why, 0 says nothing', () => {
  expect(jumpArgv('/i/mod/fleet', 'o-r:scratch-14', '%7')).toEqual(['bash', '/i/mod/fleet/../../bin/fleet-panel-jump.sh', 'o-r:scratch-14', '--pane', '%7'])
  expect(jumpToast(0)).toBe('')
  expect(jumpToast(1)).toBe('panel_batches_jump_notfound')
  expect(jumpToast(2)).toBe('panel_batches_jump_ambiguous')
  expect(jumpToast(3)).toBe('panel_batches_jump_failed')
})

// ---- the pane, through the engine ----------------------------------------------------------

function engine(on: On, windowRole: string, items: Record<string, unknown> = ITEMS, extra: Record<string, string> = {}) {
  const files = new Map<string, { text: string; mtimeMs: number }>()
  let tick = 1
  const put = (path: string, text: string) => files.set(path, { text, mtimeMs: tick++ })
  const runs: string[][] = []
  const opened: string[] = []
  const toasts: string[] = []
  const commands: string[] = []
  const exit = { code: 0 }
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('process.run', (_$, e) => {
    if (/fleet-(panel-jump\.sh|open\.sh)$/.test(e.argv[1] ?? '')) runs.push([...e.argv])
    const stdout = isRoleRun(e.argv) ? `${windowRole}\n` : isStringsRun(e.argv) ? DUMP : ''
    const code = (e.argv[1] ?? '').endsWith('fleet-panel-jump.sh') ? exit.code : 0
    return { value: { exitCode: code, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.stat', (_$, e) => {
    const f = files.get(e.path)
    if (f !== undefined) return { value: { kind: 'file' as const, size: f.text.length, mtimeMs: f.mtimeMs, isLink: false } }
    const kids = [...files.entries()].filter(([p]) => p.startsWith(`${e.path}/`))
    if (kids.length === 0) throw new Error('ENOENT')
    return { value: { kind: 'directory' as const, size: 0, mtimeMs: Math.max(...kids.map(([, k]) => k.mtimeMs)), isLink: false } }
  })
  on('fs.list', (_$, e) => {
    const names = [...files.keys()].filter(p => p.startsWith(`${e.path}/`)).map(p => p.slice(e.path.length + 1))
    if (names.length === 0) throw new Error('ENOENT')
    return { value: names.map(name => ({ name, kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) }
  })
  on('fs.read', (_$, e) => {
    const f = files.get(e.path)
    if (f === undefined) throw new Error('ENOENT')
    return { value: f.text }
  })
  on('fs.write', (_$, e) => {
    put(e.path, e.text)
    return { value: undefined }
  })
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('command.run', (_$, e) => {
    commands.push(e.command)
    return { text: 'engine' }
  })
  on('ui.open', (_$, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('prompt.submit', (_$, e) => ({ text: e.text }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  mock.env(on, { ...ENV, ...extra })
  mock.store(on)
  mock.clock(on, { now: NOW })
  put(P.stamp, '1 1\n')
  put(P.state, stateJson(items))
  put(P.park, PARK)
  put(P.ledger, LEDGER)
  for (const m of MARKS) put(`${P.marks}/${m.name}`, m.text)
  return { runs, opened, toasts, commands, exit }
}

function paneProps(placement: 'dock' | 'inline' = 'dock'): RenderPropsOf['Pane'] {
  return { title: 'b', isFocused: false, bodyColumns: 90, placement, scroll: { offset: 0, bodyRows: 40 }, view: {} } as never
}

async function mountPane($: Engine, surface: 'terminal' | 'desktop', placement: 'dock' | 'inline' = 'dock') {
  return $.ui.mount({ plugin: 'fleet', surface, component: 'Pane', props: paneProps(placement), requestId: BATCHES_PANE } as never)
}

function fresh(): void {
  resetRole()
  resetPanels()
  resetQueue()
  resetBatches()
}

for (const surface of ['terminal', 'desktop'] as const) {
  test(`pane (${surface}): opened at start in the orchestrator; the rows; 到驱动 runs only when pressed`, async ($, on) => {
    fresh()
    const m = engine(on, 'orchestrator')
    await $.session.start(START)
    expect(m.opened).toEqual([BATCHES_PANE])
    const ui = await mountPane($, surface)
    expect((await ui.find({ key: 'fleet-batch-o/r#2831' }))?.text).toContain('#2831 面板')
    expect((await ui.find({ key: 'fleet-batch-g/m#11900' }))?.text).toContain('panel_batches_nomark')
    expect((await ui.find({ key: 'fleet-done-o/r#1999' }))?.text).toContain('panel_batches_done')
    expect((await ui.find({ key: 'fleet-todo-b' }))?.text).toContain('真机试一次')
    expect(await ui.find({ key: 'fleet-todo-b-open' })).toBeUndefined() // no source url: no 看
    // nothing ran on the way to the drawing
    expect(m.runs).toEqual([])
    await ui.press({ key: 'fleet-batch-o/r#2831-jump' })
    expect(m.runs.length).toBe(1)
    expect(m.runs[0]![1]!.endsWith('/bin/fleet-panel-jump.sh')).toBe(true)
    expect(m.runs[0]!.slice(2)).toEqual(['o-r:scratch-14', '--pane', '%7'])
    const t0 = m.toasts.length // the start's own 「扩展已加载」
    expect(m.toasts.slice(t0)).toEqual([])
    // NOTFOUND / AMBIGUOUS: a toast, nothing guessed
    m.exit.code = 2
    await ui.press({ key: 'fleet-batch-o/r#2770-jump' })
    expect(m.toasts.slice(t0)).toEqual(['panel_batches_jump_ambiguous'])
    // 看 opens the source on the person's computer
    await ui.press({ key: 'fleet-todo-a-open' })
    expect(m.runs[m.runs.length - 1]!.slice(-1)).toEqual(['https://x/1999'])
    expect(m.runs[m.runs.length - 1]![1]!.endsWith('fleet-open.sh')).toBe(true)
    // /qd from the pane
    await ui.press({ key: 'fleet-batches-qd' })
    expect(m.commands).toContain('qd')
    await ui.unmount()
  })
}

test('pane: todo.items empty → 「今天没有」; the queue line is fleet/queue\'s', async ($, on) => {
  fresh()
  engine(on, 'orchestrator', {})
  await $.session.start(START)
  let ui = await mountPane($, 'terminal')
  expect((await ui.find({ key: 'fleet-todo-none' }))?.text).toBe('panel_batches_todo_none')
  expect((await ui.find({ key: 'fleet-batches-queue' }))?.text).toContain('panel_batches_queue_none')
  await ui.unmount()
  // two prompts typed over a running turn: queue.ts counts them into fleet/queue
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.prompt.submit({ text: '再加一件', wait: false, origin: HAND, turnId: 't1' })
  await $.prompt.submit({ text: '还有一件', wait: false, origin: HAND, turnId: 't1' })
  ui = await mountPane($, 'terminal')
  expect((await ui.find({ key: 'fleet-batches-queue' }))?.text).toContain('queued 2')
  await ui.unmount()
})

test('pane: seated inline after an unasked open → one hint line; /sheet batches opens it asked', async ($, on) => {
  fresh()
  const m = engine(on, 'orchestrator')
  await $.session.start(START)
  let ui = await mountPane($, 'terminal', 'inline')
  expect((await ui.find({ key: 'fleet-batches' }))?.text).toBe('panel_batches_inline')
  expect(await ui.find({ text: 'panel_batches_running' })).toBeUndefined()
  await ui.unmount()
  const r = await $.command.run({ command: SHEET_COMMAND, args: 'batches', origin: { kind: 'composer' } } as never)
  expect(r.text).toBe('panel_batches_opened')
  expect(m.opened).toEqual([BATCHES_PANE, BATCHES_PANE])
  ui = await mountPane($, 'terminal', 'inline')
  expect(await ui.find({ text: 'panel_batches_running' })).toBeDefined()
  await ui.unmount()
})

for (const [what, role, env] of [
  ['a worker window', 'worker', {}],
  ['the steward window', 'steward', {}],
  ['FLEET_MOD_PANELS=0', 'orchestrator', { FLEET_MOD_PANELS: '0' }],
] as const) {
  test(`${what}: no batches pane opened, /sheet batches not ours`, async ($, on) => {
    fresh()
    const m = engine(on, role, ITEMS, env)
    await $.session.start(START)
    expect(m.opened).toEqual([])
    const r = await $.command.run({ command: SHEET_COMMAND, args: 'batches', origin: { kind: 'composer' } } as never)
    expect(r.text).not.toBe('panel_batches_opened')
    expect(m.runs).toEqual([])
  })
}
