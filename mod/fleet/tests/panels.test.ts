// The panels follow the books (issue #2835, EPIC #2831 C4). A mocked engine:
// the version answers in range; `process.run` answers the window's @fleet_role;
// an in-memory file map with per-path mtime/size answers fs.stat / fs.list /
// fs.read / fs.write, counting every stat and read; `command.register` records
// what the plugin asked for.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { INBOX_MS } from '../hooks/inbox'
import { isRoleRun, resetRole } from '../hooks/orchestrator'
import {
  PANELS_FULL_MS, SHEET_COMMAND, panelPaths, panelsWanted, resetPanels, sessionOf, statsText, watched,
} from '../hooks/panels'
import { foldPanels, parseMark, parseMarks, parsePark, parseQueue, parseState, percentile } from '../hooks/panels-model'
import { isStringsRun } from '../hooks/qd'
import { SUPPORTED } from '../hooks/version'

const DUMP = ['panel_summary_fmt', 'open=\u0001 live=\u0002 parked=\u0003 beat=\u0004', 'panel_empty', 'empty']
  .join('\0').replace(/\u0002|\u0003|\u0004/g, '\u0001') + '\0'
const RUN = { origin: { kind: 'composer' }, presentation: { layout: 'fullscreen', columns: 200 } } as never

/** What the panels hold now, as bare `/sheet` says it. */
async function summary($: { command: { run: (i: never) => Promise<{ text?: string }> } }): Promise<string> {
  return (await $.command.run({ command: SHEET_COMMAND, args: '', ...(RUN as object) } as never)).text ?? ''
}

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: false } as const
const ENV = { TMUX_PANE: '%7', TMUX: '/private/tmp/tmux-501/fleet,123,0', FLEET_CONF_DIR: '/conf', HOME: '/h' }
const P = panelPaths('/conf', 'fleet')
const NOW = 1_000_000_000_000

// ---- fixtures: 30 sheet rows, 7 batch marks, 50 ledger rows ------------------

function stateJson(n = 30, sheetAt = '2001-09-09T01:46:30Z', sheetId = 's1'): string {
  const rows: Record<string, unknown> = {}
  const ids: string[] = []
  for (let i = 0; i < n; i++) {
    const id = `row-${i}`
    ids.push(id)
    rows[id] = {
      id, item: `第 ${i} 件：要不要先发 20 家？`.repeat(3), suggest: '20 家', default: '20 家', due: '2026-10-10T09:00:00Z',
      kind: 'normal', src: `gh:o/r#${100 + i}`, url: `https://github.com/o/r/issues/${100 + i}`, state: i % 5 === 0 ? 'answered' : 'open',
      asked: '2026-10-09T17:00:00Z',
    }
  }
  return JSON.stringify({
    v: 1, rows, sheet: { at: sheetAt, id: sheetId, rows: ids, sent: true, where: '/conf/fleets/fleet/steward/decision.md' },
    beat: { at: '2026-10-09T19:13:06-07:00', changed: true, n: 23, writes: 2 }, next_at: 1791598986,
    card: ['steward · beat 23', 'new questions 0'], model_calls: 5, todo_open: 2, todo: { desk: 'o/r#9' },
    parked: [{ at: 1, ref: 'o/r#1', wait: ['reply:o/r#1'] }],
  }, null, 1)
}

function mark(epic: number, epoch = NOW / 1000 - 60): string {
  return `epoch: ${epoch}\niso: x\nttl: 2700\nepic: ${epic}\nrepo: o/r\nsession: fleet\ntick: 5\nlanded: 3\nmembers: 6\nlive: 1\ninflight: 1\n`
}

function ledger(n = 50): string {
  const out: string[] = []
  for (let i = 0; i < n; i++) out.push(JSON.stringify({ seq: i, child: `o-r:issue-${200 + (i % 12)}`, state: i % 3 ? 'MERGED' : 'BLOCKED', verdict: '' }))
  return `${out.join('\n')}\n`
}

const PARK = JSON.stringify({ v: 1, parked: { 'o/r#7': { at: 5, wait: ['answer:x'], key: 'o-r:issue-7' }, 'o/r#3': { at: 2, wait: [], key: '' } } })
const DELTA = JSON.stringify({ at: 'x', new_asks: [{}, {}], closed: [{}], defaulted: [] })

type File = { text: string; mtimeMs: number }

function engine(on: On, windowRole: string, env: Record<string, string> = ENV) {
  const files = new Map<string, File>()
  const stats: string[] = []
  const reads: string[] = []
  const registered: string[] = []
  let tick = 1
  const put = (path: string, text: string) => files.set(path, { text, mtimeMs: tick++ })
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('process.run', (_$, e) => {
    const stdout = isRoleRun(e.argv) ? `${windowRole}\n` : isStringsRun(e.argv) ? DUMP : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.stat', (_$, e) => {
    stats.push(e.path)
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
    reads.push(e.path)
    const f = files.get(e.path)
    if (f === undefined) throw new Error('ENOENT')
    return { value: f.text }
  })
  on('fs.write', (_$, e) => {
    put(e.path, e.text)
    return { value: undefined }
  })
  on('command.register', (_$, e) => {
    registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  mock.env(on, env)
  const clock = mock.clock(on, { now: NOW })
  return { files, stats, reads, registered, put, clock }
}

function seed(put: (p: string, t: string) => void): void {
  put(P.stamp, '1 1000\n')
  put(P.state, stateJson())
  put(P.delta, DELTA)
  put(P.park, PARK)
  put(P.ledger, ledger())
  for (let i = 0; i < 7; i++) put(`${P.marks}/o-r-${2800 + i}`, mark(2800 + i))
}

function fresh(): void {
  resetRole()
  resetPanels()
}

// ---- the role gate -----------------------------------------------------------

test('panels: a worker window stats nothing and registers no /sheet (panel-wrong-window)', async ($, on) => {
  fresh()
  const { stats, registered, put, clock } = engine(on, 'worker')
  seed(put)
  await $.session.start(START)
  await clock.advance(PANELS_FULL_MS * 2)
  expect(stats).toEqual([])
  expect(registered).not.toContain(SHEET_COMMAND)
})

test('panels: FLEET_MOD_PANELS=0 — the orchestrator stats nothing, no /sheet, as today', async ($, on) => {
  fresh()
  const { stats, reads, registered, put, clock } = engine(on, 'orchestrator', { ...ENV, FLEET_MOD_PANELS: '0' })
  seed(put)
  await $.session.start(START)
  await clock.advance(PANELS_FULL_MS * 2)
  expect(stats).toEqual([])
  expect(reads.filter(p => p.startsWith('/conf/global') || p.includes('/children/'))).toEqual([])
  expect(registered).not.toContain(SHEET_COMMAND)
})

test('panelsWanted: orchestrator and steward only, a fleet session, not switched off', () => {
  expect(panelsWanted('orchestrator', undefined, 'fleet')).toBe(true)
  expect(panelsWanted('steward', '1', 'fleet')).toBe(true)
  expect(panelsWanted('other', undefined, 'fleet')).toBe(false)
  expect(panelsWanted('orchestrator', '0', 'fleet')).toBe(false)
  expect(panelsWanted('orchestrator', undefined, undefined)).toBe(false)
  expect(sessionOf(ENV.TMUX)).toBe('fleet')
  expect(sessionOf(undefined)).toBe(undefined)
  expect(watched(P).length).toBe(4)
})

// ---- the stamp ---------------------------------------------------------------

test('panels: an unchanged stamp reads nothing; a moved stamp reads once and updates the state', async ($, on) => {
  fresh()
  // the orchestrator: in the steward's window bare /sheet opens the patrol (patrol.tsx)
  const { stats, reads, registered, put, clock } = engine(on, 'orchestrator')
  seed(put)
  await $.session.start(START)
  expect(registered).toContain(SHEET_COMMAND)
  // 30 rows, every fifth answered; 7 fresh batches; 2 parked
  expect(await summary($)).toBe('open=24 live=7 parked=2 beat=2026-10-09T19:13:06-07:00')
  // every tick stats the four paths, never more
  const s0 = stats.length
  const r0 = reads.filter(p => p === P.state).length
  await clock.advance(INBOX_MS * 3)
  expect(stats.length - s0).toBe(12)
  expect(new Set(stats.slice(s0))).toEqual(new Set(watched(P)))
  expect(reads.filter(p => p === P.state).length).toBe(r0)
  // the steward saves: state + stamp move; the next tick reads exactly once
  put(P.state, stateJson(3, '2001-09-09T01:46:39Z', 's2'))
  put(P.stamp, '2 2000\n')
  await clock.advance(INBOX_MS)
  expect(reads.filter(p => p === P.state).length).toBe(r0 + 1)
  expect(await summary($)).toContain('open=2 ')
  await clock.advance(INBOX_MS * 2)
  expect(reads.filter(p => p === P.state).length).toBe(r0 + 1)
})

test('panels: a writer that forgets the stamp is drawn within the full read (panel-stale)', async ($, on) => {
  fresh()
  const { put, clock, files } = engine(on, 'orchestrator')
  seed(put)
  await $.session.start(START)
  // the state changes in place, the stamp and its mtime do not
  const stamp = files.get(P.stamp)
  files.set(P.state, { text: stateJson(4, '2001-09-09T01:46:35Z', 's3'), mtimeMs: 999 })
  expect(files.get(P.stamp)).toBe(stamp)
  await clock.advance(INBOX_MS * 3)
  expect(await summary($)).toContain('open=24 ')
  await clock.advance(PANELS_FULL_MS)
  expect(await summary($)).toContain('open=3 ')
})

test('panels: each read is timed into logs/panel.ndjson; a new sheet logs 写出→看见; /sheet --stats prints them', async ($, on) => {
  fresh()
  const { put, clock, files } = engine(on, 'orchestrator')
  seed(put)
  put(P.log, `${JSON.stringify({ kind: 'answer', ts: 1, row: 'r', how: 'suggest', presses: 1 })}\n`)
  await $.session.start(START)
  // the sheet is written 4 s before the clock; it is seen on the next tick
  put(P.state, stateJson(5, new Date(NOW - 4000).toISOString(), 's9'))
  put(P.stamp, '3 3000\n')
  await clock.advance(INBOX_MS)
  const log = files.get(P.log)?.text ?? ''
  const rows = log.trim().split('\n').map(l => JSON.parse(l) as { kind: string; s?: number; ms?: number })
  expect(rows[0]?.kind).toBe('answer') // another writer's row is kept
  const refresh = rows.filter(r => r.kind === 'refresh')
  expect(refresh.length).toBeGreaterThan(0)
  // the fixture's whole tick (stat + read + fold), ≤ 50 ms with the test box's 2× slack
  expect(refresh.every(r => (r.ms ?? 999) < 100)).toBe(true)
  const seen = rows.filter(r => r.kind === 'seen')
  expect(seen.length).toBe(1)
  expect(seen[0]?.s).toBe(5)
  const out = await $.command.run({ command: SHEET_COMMAND, args: '--stats', ...(RUN as object) } as never)
  expect(out.text ?? '').toContain('panel_stats_fmt')
  expect(out.text ?? '').toContain('panel_seen_fmt')
})

// ---- the pure model ----------------------------------------------------------

test('panels-model: state, marks, park, ledger parse; torn input is empty, never fatal', () => {
  const st = parseState(stateJson())
  expect(st.sheet?.rows.length).toBe(30)
  expect(st.sheet?.rows[1]?.suggest).toBe('20 家')
  expect(st.todo).toEqual({ open: 2, desk: 'o/r#9' })
  expect(st.patrol.beat).toBe(23)
  expect(st.patrol.parked.length).toBe(1)
  expect(parseState('{not json').sheet).toBe(null)
  const b = parseMark(mark(2831, 100), 200)
  expect(b?.epic).toBe(2831)
  expect(b?.fresh).toBe(true)
  expect(parseMark(mark(2831, 100), 100 + 2701)?.fresh).toBe(false)
  expect(parseMark('epoch: 1\n', 2)).toBe(null)
  expect(parseMark('epic: 5\n', 2)?.live).toBe(null)
  expect(parseMarks([{ name: 'a', text: mark(1, 10) }, { name: 'b', text: mark(2, 20) }, { name: '.tmp', text: mark(3, 30) }], 40).map(x => x.epic)).toEqual([2, 1])
  expect(parsePark(PARK).map(p => p.ref)).toEqual(['o/r#3', 'o/r#7'])
  expect(parsePark('')).toEqual([])
  const q = parseQueue(ledger())
  expect(q.length).toBe(12)
  expect(parseQueue('torn\n{"child":"x","state":"MERGED"}\n').length).toBe(1)
  const v = foldPanels({ state: stateJson(), delta: DELTA, marks: [], park: PARK, ledger: '' }, NOW, 1)
  expect(v.patrol.newAsks).toBe(2)
  expect(v.patrol.parked.length).toBe(2)
  expect(percentile([5, 1, 3, 2, 4], 50)).toBe(3)
  expect(percentile([], 95)).toBe(0)
  expect(statsText('')).toContain('panel_stats_none')
})

test('panels-model: the fixture (30 sheet rows · 7 marks · 50 ledger rows) folds p95 ≤ 50 ms (×2 on a test box)', () => {
  const src = {
    state: stateJson(), delta: DELTA, park: PARK, ledger: ledger(),
    marks: Array.from({ length: 7 }, (_, i) => ({ name: `m${i}`, text: mark(2800 + i) })),
  }
  const ms: number[] = []
  for (let i = 0; i < 100; i++) {
    const t0 = performance.now()
    foldPanels(src, NOW, 0)
    ms.push(performance.now() - t0)
  }
  expect(percentile(ms, 95)).toBeLessThan(100)
})
