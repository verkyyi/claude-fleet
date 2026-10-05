// The task-progress band (issue #1339), down to the PR segment alone (#1527). The test's own hooks stand for the
// engine and the machine: `process.run` answers the one tmux call from a
// fixture (this window + list-windows), `fs.read` answers the dash's caches
// from a map (a path not in it rejects, as a missing file does), `ui.toast`
// records each toast, and the mocked clock moves only when the test moves it.

import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, RenderPropsOf } from 'claude-code'

import { PROGRESS_MS, bandText, segments } from '../hooks/progress-model'
import { SUPPORTED } from '../hooks/version'
import type { ProgressSnapshot } from '../types'
import { isWhereRun } from '../hooks/where'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const TMP = '/var/folders/xx/T/'
const DASH = '/var/folders/xx/T/.claude-dash/fleets/verkyyi-claude-fleet'
const CONF = '/Users/me/.config/claude-fleet/fleets/fleet-x/children'

type Win = { id: string; state: string; issue?: string; worktree?: string; origin?: string; loop?: string; name?: string }

function selfLine(issue: string, worktree: string): string {
  return ['S', 'fleet-x', '@1', issue, 'verkyyi/claude-fleet', '', worktree, worktree, 'me'].join('\t')
}
function winLine(w: Win): string {
  return ['W', 'fleet-x', w.id, w.state, '', w.loop ?? '', w.issue ?? '', w.worktree ?? '', w.origin ?? '', w.worktree ?? '/x', w.name ?? 'w'].join('\t')
}

const WORKER = selfLine('1339', '/wt/claude-fleet-issue-1339')
const KIDS: Win[] = [
  { id: '@1', state: 'working', issue: '1339' }, // itself: never its own child
  { id: '@2', state: 'needs', issue: '1400', origin: 'issue-1339' },
  { id: '@3', state: 'working', issue: '1401', origin: 'verkyyi-claude-fleet:issue-1339' },
  { id: '@4', state: 'working', issue: '1500', origin: 'issue-77' }, // someone else's
  { id: '@5', state: 'done', name: 'dash' }, // a panel
]
const FILES: Record<string, string> = {
  [`${DASH}/prmap`]: 'issue-1338\t#1359\tOPEN\t✗\t\t\nissue-1339\t#1360\tOPEN\t✓\tconflict\t\n',
  [`${CONF}/issue-1339.ndjson`]:
    '{"seq": 1, "ts": "2026-10-03T08:00:00Z", "child": "issue-1402", "state": "WAITING", "pr": "", "verdict": ""}\n' +
    '{"seq": 2, "ts": "2026-10-03T08:10:00Z", "child": "issue-1402", "state": "MERGED", "pr": "1410", "verdict": "merged"}\n',
}

/** What the engine draws when the plugin passes: an empty band. */
function engineBand(on: On): void {
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
}

function machine(on: On, opts: { self?: string; windows?: Win[]; files?: Record<string, string> } = {}) {
  const files = { ...(opts.files ?? FILES) }
  const toasts: string[] = []
  const tmux = { self: opts.self ?? WORKER, windows: opts.windows ?? KIDS }
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    const stdout = e.argv.includes('display-message')
      ? [tmux.self, ...tmux.windows.map(winLine)].join('\n') + '\n'
      : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', (_$, e) => {
    const text = files[e.path]
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('ui.toast', (_$, e) => {
    if (!e.text.startsWith('fleet 扩展已加载')) toasts.push(e.text) // lifecycle's own
    return { value: undefined }
  })
  engineBand(on)
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  mock.env(on, { TMUX_PANE: '%7', TMPDIR: TMP, HOME: '/Users/me' })
  const clock = mock.clock(on, { now: 1_000_000_000_000 })
  return { files, toasts, tmux, clock }
}

function band(columns: number): RenderPropsOf['AbovePrompt'] {
  return { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: columns, scroll: { offset: 0, bodyRows: 10 }, view: {} }
}

async function drawn($: Engine, columns: number): Promise<string | undefined> {
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band(columns) })
  const text = (await ui.find({ key: 'fleet-progress' }))?.text
  await ui.unmount()
  return text
}

const FULL = 'PR #1360 ✓ 冲突!'

test('a worker draws its PR and nothing the corner or the sidebar already shows', async ($, on) => {
  machine(on)
  await $.session.start(START)
  for (const cols of [160, 30]) {
    const text = await drawn($, cols)
    expect(text).toBe(FULL)
    for (const gone of ['#1339 ·', 'EPIC', '子任务', '上下文']) expect(text).not.toContain(gone)
  }
})

test('a band drawn before session.start redraws when the first refresh lands', async ($, on) => {
  machine(on)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band(160) })
  expect(await ui.find({ key: 'fleet-progress' })).toBeUndefined()
  await $.session.start(START)
  expect((await ui.find({ key: 'fleet-progress' }))?.text).toBe(FULL)
  await ui.unmount()
})

test('the pure band: PR state, checks and readiness; no PR → nothing', () => {
  const s: ProgressSnapshot = {
    issue: 1339,
    pr: { number: 1360, state: 'OPEN', ci: '✓', ready: 'ready' },
    needsKids: ['issue-1400'],
  }
  expect(bandText(s)).toBe('PR #1360 ✓')
  expect(bandText({ ...s, pr: { ...s.pr!, ci: '✗' } })).toBe('PR #1360 ✗!')
  expect(bandText({ ...s, pr: { ...s.pr!, ci: '…', ready: 'behind' } })).toBe('PR #1360 … 落后')
  expect(bandText({ ...s, pr: { ...s.pr!, state: 'MERGED' } })).toBe('PR #1360 已合并')
  expect(segments({ ...s, pr: { ...s.pr!, ready: 'conflict' } })[0]?.color).toBe('red')
  expect(bandText({ ...s, pr: null })).toBe('')
  expect(segments({ ...s, pr: null })).toEqual([])
})

test('a child at needs toasts once, stays quiet while it stands, re-arms once it clears', async ($, on) => {
  const m = machine(on)
  await $.session.start(START)
  await drawn($, 160)
  await m.clock.advance(PROGRESS_MS)
  await m.clock.advance(PROGRESS_MS)
  expect(m.toasts.filter(t => t.includes('#1400'))).toEqual(['子任务 #1400 需要你处理'])
  m.tmux.windows = KIDS.map(w => (w.issue === '1400' ? { ...w, state: 'working' } : w))
  await m.clock.advance(PROGRESS_MS)
  m.tmux.windows = KIDS
  await m.clock.advance(PROGRESS_MS)
  expect(m.toasts.filter(t => t.includes('#1400')).length).toBe(2)
})

test('the PR turning red toasts once; back to green and red again toasts again', async ($, on) => {
  const m = machine(on, { windows: [] })
  await $.session.start(START)
  await drawn($, 160)
  expect(m.toasts).toEqual([])
  m.files[`${DASH}/prmap`] = 'issue-1339\t#1360\tOPEN\t✗\t\t\n'
  await m.clock.advance(PROGRESS_MS)
  await m.clock.advance(PROGRESS_MS)
  expect(m.toasts).toEqual(['PR #1360 检查变红了'])
  expect(await drawn($, 160)).toContain('PR #1360 ✗!')
  m.files[`${DASH}/prmap`] = 'issue-1339\t#1360\tOPEN\t…\t\t\n'
  await m.clock.advance(PROGRESS_MS)
  m.files[`${DASH}/prmap`] = 'issue-1339\t#1360\tOPEN\t✗\t\t\n'
  await m.clock.advance(PROGRESS_MS)
  expect(m.toasts).toEqual(['PR #1360 检查变红了', 'PR #1360 检查变红了'])
})

test('every cache missing: no error, nothing drawn', async ($, on) => {
  machine(on, { files: {}, windows: [] })
  await $.session.start(START)
  expect(await drawn($, 160)).toBeUndefined()
})

test('hub and scratch windows: no band, but a child at needs still toasts', async ($, on) => {
  const m = machine(on, {
    self: selfLine('', '/Users/me'),
    windows: [
      { id: '@2', state: 'needs', issue: '1400' }, // hub-spawned: no @origin
      { id: '@3', state: 'done', issue: '1401' },
      { id: '@4', state: 'working', issue: '1402', origin: 'issue-1400' },
    ],
  })
  await $.session.start(START)
  expect(await drawn($, 160)).toBeUndefined()
  expect(m.toasts).toEqual(['子任务 #1400 需要你处理'])
  m.tmux.self = selfLine('', '/wt/claude-fleet-scratch-6')
  m.tmux.windows = [{ id: '@2', state: 'needs', issue: '1500', origin: 'verkyyi-claude-fleet:scratch-6' }]
  await m.clock.advance(PROGRESS_MS)
  expect(await drawn($, 160)).toBeUndefined()
  expect(m.toasts).toEqual(['子任务 #1400 需要你处理', '子任务 #1500 需要你处理'])
})

test('a looping child is not done: it never toasts, a needs one does', async ($, on) => {
  const m = machine(on, {
    files: {},
    windows: [
      { id: '@2', state: 'done', issue: '1400', origin: 'issue-1339', loop: 'next=2000000000' },
      { id: '@3', state: 'failed', issue: '1401', origin: 'issue-1339' },
    ],
  })
  await $.session.start(START)
  expect(m.toasts).toEqual(['子任务 #1401 需要你处理'])
})

test('outside tmux: nothing drawn, no tmux call', async ($, on) => {
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  const runs: string[][] = []
  on('process.run', (_$, e) => {
    if (!isWhereRun(e.argv)) runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  engineBand(on)
  on('ui.toast', () => ({ value: undefined }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  mock.env(on, {})
  mock.clock(on, { now: 0 })
  await $.session.start(START)
  expect(await drawn($, 160)).toBeUndefined()
  expect(runs).toEqual([])
})
