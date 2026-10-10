// The decision sheet's pane (issue #2832, EPIC #2831 C1). A mocked engine: the
// version answers in range; `process.run` answers the window's @fleet_role, the
// strings dump, and `fleet-steward-tick.sh answer` (each recorded with its row and
// words, its exit code the test's); an in-memory file map answers fs.* (the books:
// steward.state.json as the steward writes it, with its `groups`); ui.open /
// ui.panes / ui.close / ui.toast beneath the plugin record what it asked.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { INBOX_MS } from '../hooks/inbox'
import { isRoleRun, resetRole } from '../hooks/orchestrator'
import { SHEET_COMMAND, panelPaths, resetPanels } from '../hooks/panels'
import { isStringsRun } from '../hooks/qd'
import { SHEET_OPTION, SHEET_PANE, UNDO_MS, answerArgv, closedText, isAnswerRun, resetSheet, splitGroups } from '../hooks/sheet'
import { parseState } from '../hooks/panels-model'
import { SUPPORTED } from '../hooks/version'
import { SHEET_STATE } from './sheet-fixture'

const DUMP = [
  'panel_sheet_defaulted_fmt', '已按默认 \u0001', 'panel_sheet_answered_fmt', '已答（\u0001）\u0001',
  'panel_sheet_pending_fmt', '已答：\u0001 · 10 秒内可撤回', 'panel_sheet_failed_fmt', '没写回去：\u0001',
  'panel_sheet_take', '按建议', 'panel_sheet_opened', '摆好了', 'panel_sheet_closed', '收起了',
].join('\0') + '\0'
const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const ENV = { TMUX_PANE: '%7', TMUX: '/private/tmp/tmux-501/fleet,123,0', FLEET_CONF_DIR: '/conf', HOME: '/h' }
const P = panelPaths('/conf', 'fleet')
const NOW = 1_791_000_000_000
const RUN = { origin: { kind: 'composer' }, presentation: { layout: 'fullscreen', columns: 200 } } as never
const PANE = {
  title: '决定单', isFocused: true, bodyColumns: 56, placement: 'dock', scroll: { offset: 0, rows: 40 },
} as never

type Answered = { row: string; text: string; session: string }

function engine(on: On, windowRole: string, opts: { exit?: number; env?: Record<string, string> } = {}) {
  const files = new Map<string, { text: string; mtimeMs: number }>()
  const answered: Answered[] = []
  const options: string[] = []
  const opened: string[] = []
  const closed: string[] = []
  const toasts: string[] = []
  const registered: string[] = []
  let tick = 1
  const put = (path: string, text: string) => files.set(path, { text, mtimeMs: tick++ })
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('process.run', (_$, e) => {
    let stdout = ''
    let exitCode = 0
    if (isRoleRun(e.argv)) stdout = `${windowRole}\n`
    else if (isStringsRun(e.argv)) stdout = DUMP
    else if (isAnswerRun(e.argv)) {
      const at = (k: string) => e.argv[e.argv.indexOf(k) + 1] as string
      answered.push({ row: at('--row'), text: at('--text'), session: e.argv.includes('--session') ? at('--session') : '' })
      exitCode = opts.exit ?? 0
      stdout = exitCode === 0 ? 'answered' : ''
    } else if (e.argv[0] === 'tmux' && e.argv.includes(SHEET_OPTION)) {
      options.push(e.argv.includes('-u') ? 'unset' : (e.argv[e.argv.length - 1] as string))
    }
    return { value: { exitCode, stdout, stderr: exitCode === 0 ? '' : 'gh: rate limited', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.stat', (_$, e) => {
    const f = files.get(e.path)
    if (f === undefined) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: f.text.length, mtimeMs: f.mtimeMs, isLink: false } }
  })
  on('fs.list', () => {
    throw new Error('ENOENT')
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
  on('command.register', (_$, e) => {
    registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('command.run', () => ({ text: 'engine' }))
  let placed = false
  on('ui.open', (_$, e) => {
    // the other panes of the window (batches.tsx) are theirs to test
    if (e.id !== SHEET_PANE) return { value: { isPlaced: true } }
    opened.push(e.id)
    placed = true
    return { value: { isPlaced: true } }
  })
  on('ui.panes', () => ({
    value: placed ? [{ id: SHEET_PANE, title: '决定单', isShown: true, isFocused: false, isPlaced: true }] : [],
  }))
  on('ui.close', (_$, e) => {
    closed.push(e.id)
    placed = false
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  // what the engine draws when the plugin passes
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  mock.env(on, { ...ENV, ...(opts.env ?? {}) })
  const clock = mock.clock(on, { now: NOW })
  put(P.stamp, '1 1000\n')
  put(P.state, JSON.stringify(SHEET_STATE))
  return { files, answered, options, opened, closed, toasts, registered, put, clock }
}

type T$ = Parameters<Parameters<typeof test>[1]>[0]

async function start($: T$): Promise<void> {
  resetRole()
  resetPanels()
  resetSheet()
  await $.session.start(START)
}

const BAND = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 200, scroll: { offset: 0, bodyRows: 10 }, view: {} }

/** One band drawn: fullscreen (the pane docks beside the transcript) or the main screen. */
async function band($: T$, isFullscreen: boolean): Promise<void> {
  const ui = await $.ui.mount({
    plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: BAND as never,
    viewport: { columns: 200, rows: 50, isFullscreen },
  } as never)
  await ui.unmount()
}

test('sheet: the steward\'s six asks of the day draw as 2 groups — five on one ticket are one line', () => {
  const st = parseState(JSON.stringify(SHEET_STATE))
  const { open, closed } = splitGroups(st.groups, { pending: {}, editing: '', expanded: '', sending: [], presses: {} })
  expect(Object.keys(SHEET_STATE.rows).filter(k => (SHEET_STATE.rows as Record<string, { state: string }>)[k]?.state === 'open').length).toBe(6)
  expect(open.length).toBe(2)
  expect(open[0]?.ids.length).toBe(5)
  expect(open[0]?.item).toBe('真机演练第 5 次：可以开始吗？')
  expect(open[0]?.from).toContain('问了 5 次')
  expect(closed.map(g => g.gid)).toEqual(['rnever', 'rdef'])
  expect(answerArgv('/x/mod/fleet', 'fleet', 'r1', '开始')).toEqual(
    ['bash', '/x/mod/fleet/../../bin/fleet-steward-tick.sh', 'answer', '--row', 'r1', '--text', '开始', '--by', 'person', '--session', 'fleet'])
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`sheet (${surface}): open on top, answered dim below; a defaulted line says 已按默认 + its time, a never one never does`, async ($, on) => {
    engine(on, 'orchestrator')
    await start($)
    const ui = await $.ui.mount({ plugin: 'fleet', surface, component: 'Pane', requestId: SHEET_PANE, props: PANE })
    expect(await ui.find({ text: /1\. 真机演练第 5 次/ })).toBeDefined()
    expect(await ui.find({ text: /2\. 小程序试点选哪家商户/ })).toBeDefined()
    expect(await ui.find({ text: /3\./ })).toBeUndefined()
    expect(await ui.find({ key: 'take:r2139-4' })).toBeDefined()
    // no suggestion: no 按建议 button, the other button answers instead
    expect(await ui.find({ key: 'take:r11958' })).toBeUndefined()
    expect(await ui.find({ key: 'turn:r11958' })).toBeDefined()
    expect(await ui.find({ key: 'take:rdef' })).toBeUndefined()
    expect(await ui.find({ text: /日志留几天.*已按默认 12:01/ })).toBeDefined()
    expect(await ui.find({ text: /要不要开云机器[^✓]*已按默认/ })).toBeUndefined()
    expect(await ui.find({ text: /要不要开云机器.*已答（person）不开/ })).toBeDefined()
    await ui.unmount()
  })
}

test('sheet: y → 10 s later exactly one answer per row of the group (5), the same words; then one answer row in panel.ndjson', async ($, on) => {
  const { answered, files, clock } = engine(on, 'orchestrator')
  await start($)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'Pane', requestId: SHEET_PANE, props: PANE })
  await ui.press({ key: 'take:r2139-4' })
  expect(await ui.find({ text: /已答：开始/ })).toBeDefined()
  await clock.advance(UNDO_MS - 100)
  expect(answered).toEqual([])
  await clock.advance(200)
  expect(answered.map(a => a.row)).toEqual(['r2139-0', 'r2139-1', 'r2139-2', 'r2139-3', 'r2139-4'])
  expect(new Set(answered.map(a => `${a.text}|${a.session}`))).toEqual(new Set(['开始|fleet']))
  await clock.advance(INBOX_MS)
  const log = (files.get(P.log)?.text ?? '').split('\n').filter(l => l.includes('"answer"'))
  expect(log.length).toBe(1)
  const row = JSON.parse(log[0] as string) as { gid: string; how: string; presses: number }
  expect([row.gid, row.how, row.presses]).toEqual(['r2139-4', 'take', 1])
  const stats = await $.command.run({ command: SHEET_COMMAND, args: '--stats', ...(RUN as object) } as never)
  expect((stats as { text?: string }).text).toContain('panel_answer_stats_fmt')
  await ui.unmount()
})

test('sheet: u within 10 s takes it back — zero answers', async ($, on) => {
  const { answered, clock } = engine(on, 'orchestrator')
  await start($)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'Pane', requestId: SHEET_PANE, props: PANE })
  await ui.press({ key: 'take:r2139-4' })
  await clock.advance(3000)
  await ui.press({ key: 'undo:r2139-4' })
  await clock.advance(UNDO_MS * 2)
  expect(answered).toEqual([])
  expect(await ui.find({ key: 'take:r2139-4' })).toBeDefined()
  await ui.unmount()
})

test('sheet: 翻案 opens a field; ↵ sends its words after the undo window', async ($, on) => {
  const { answered, clock } = engine(on, 'orchestrator')
  await start($)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'Pane', requestId: SHEET_PANE, props: PANE })
  await ui.press({ key: 'turn:r11958' })
  await ui.input({ key: 'input:r11958', text: '选甲，先小后大' })
  await clock.advance(UNDO_MS + 10)
  expect(answered).toEqual([{ row: 'r11958', text: '选甲，先小后大', session: 'fleet' }])
  await ui.unmount()
})

test('sheet: a failed write-back puts the line back and toasts why', async ($, on) => {
  const { answered, toasts, clock } = engine(on, 'orchestrator', { exit: 1 })
  await start($)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'Pane', requestId: SHEET_PANE, props: PANE })
  await ui.press({ key: 'take:r2139-4' })
  await clock.advance(UNDO_MS + 10)
  expect(answered.length).toBe(1)
  expect(toasts.some(x => x.includes('没写回去：gh: rate limited'))).toBe(true)
  expect(await ui.find({ key: 'take:r2139-4' })).toBeDefined()
  await ui.unmount()
})

test('sheet: the first fullscreen band opens it once and stamps @sheet_pane 1; /sheet closes (0) and reopens (1); an exit unsets it', async ($, on) => {
  const { opened, closed, options } = engine(on, 'orchestrator')
  await start($)
  expect(opened).toEqual([])
  await band($, true)
  await band($, true)
  expect(opened).toEqual([SHEET_PANE])
  expect(options).toEqual(['1'])
  const run = (args = '') => $.command.run({ command: SHEET_COMMAND, args, ...(RUN as object) } as never) as Promise<{ text?: string }>
  expect((await run()).text).toBe('收起了')
  expect(closed).toEqual([SHEET_PANE])
  expect((await run()).text).toBe('摆好了')
  expect(options.slice(-1)).toEqual(['1'])
  expect((await run('--summary')).text).toContain('panel_summary_fmt')
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's', resume: { id: 's' } })
  expect(options.slice(-1)).toEqual(['unset'])
})

test('sheet: the main screen opens nothing unasked and stamps nothing — the steward keeps sending the whole sheet', async ($, on) => {
  const { opened, options } = engine(on, 'orchestrator')
  await start($)
  await band($, false)
  expect(opened).toEqual([])
  expect(options).toEqual([])
})

test('sheet: a worker window opens no sheet, stamps no @sheet_pane and draws nothing of it (panel-wrong-window)', async ($, on) => {
  const { opened, options, registered } = engine(on, 'worker')
  await start($)
  await band($, true)
  expect(opened).toEqual([])
  expect(options).toEqual([])
  expect(registered).not.toContain(SHEET_COMMAND)
})

test('sheet: the steward\'s window has the panels but not the decision sheet', async ($, on) => {
  const { opened, options, registered } = engine(on, 'steward')
  await start($)
  expect(registered).toContain(SHEET_COMMAND)
  expect(opened).toEqual([])
  expect(options).toEqual([])
  const g = parseState(JSON.stringify(SHEET_STATE)).groups.find(x => x.gid === 'rdef')
  expect(g === undefined ? '' : closedText({ ...g, never: true })).not.toContain('已按默认')
})
