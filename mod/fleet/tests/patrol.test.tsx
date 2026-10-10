// The steward's patrol panel (issue #2834, EPIC #2831 C3). A mocked engine as
// panels.test.ts's: the window's @fleet_role from `process.run`, the books from an
// in-memory file map; the fixture is the shape of 2026-10-09's real
// steward.state.json / steward.delta.json (the words replaced), at beat 3.

import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import { isRoleRun, resetRole } from '../hooks/orchestrator'
import { panelPaths, resetPanels } from '../hooks/panels'
import { parseState, rowBy, firstSentence } from '../hooks/panels-model'
import { PATROL_PANE, clockOf, offsetOf, patrolModel, resetPatrol } from '../hooks/patrol'
import { isStringsRun, takeStrings } from '../hooks/qd'
import { SUPPORTED } from '../hooks/version'

const S = '\u0001'
const ZH: Record<string, string> = {
  panel_patrol_pane: '巡检',
  panel_patrol_title_fmt: `第 ${S} 拍 · ${S} · ${S}`,
  panel_patrol_calm: '平静',
  panel_patrol_changed: '有变化',
  panel_patrol_seen: '这一拍看了',
  panel_patrol_seen_fmt: `批次驱动 ${S} · 开着的提问 ${S}`,
  panel_patrol_delta_fmt: `回报 ${S} · 新问 ${S} · 关掉 ${S}`,
  panel_patrol_park_fmt: `停放 ${S}`,
  panel_patrol_parked_fmt: `${S} · 等 ${S} · 从 ${S} 起`,
  panel_patrol_park_none: '没有卡住的会话',
  panel_patrol_answers: '自答 / 默认拍板',
  panel_patrol_answers_fmt: `今天自答 ${S} · 按默认 ${S} · 交给你 ${S} 件`,
  panel_patrol_health_fmt: `健康 ${S}`,
  panel_patrol_next_fmt: `下一拍 ${S}`,
  panel_patrol_night: '夜里一小时一拍',
  panel_patrol_foot_fmt: `这一拍写单 ${S}/${S} · 叫模型 ${S} 次 · 延后 ${S}`,
  panel_patrol_to_orch: '到编排会话',
  panel_patrol_to_sheet: '看决定单',
  panel_patrol_jump_none: '找不到编排会话',
  panel_patrol_opened: '巡检面板在右边',
}
const DUMP = Object.entries(ZH).map(([k, v]) => `${k}\0${v}\0`).join('')

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const ENV = { TMUX_PANE: '%7', TMUX: '/private/tmp/tmux-501/fleet,123,0', FLEET_CONF_DIR: '/conf', HOME: '/h' }
const P = panelPaths('/conf', 'fleet')
const NOW = Date.parse('2026-10-09T14:48:00-07:00')
// 2026-10-09T15:07:12-07:00
const NEXT = Date.parse('2026-10-09T15:07:12-07:00') / 1000

const STATE = JSON.stringify({
  v: 1,
  beat: { at: '2026-10-09T14:47:12-07:00', changed: false, n: 3, writes: 0 },
  counts: { '2026-10-09': { person: 2 } },
  deferred: [],
  drivers: { 'o/r#2482': 'o-r:scratch-4', 'o/r#2756': 'o-r:scratch-10', 'o/r#2770': 'o-r:scratch-11' },
  health: {
    active: {
      'account:5fac3dec': { kind: 'doctor', level: 'WARN', msg: 'a.conf: no LIMIT_TTL= line — ignored', row: 'account' },
      'account:61580ec3': { kind: 'doctor', level: 'WARN', msg: 'b.conf: no LIMIT_TTL= line — ignored', row: 'account' },
      'alerts:1dc2e1a6': { kind: 'doctor', level: 'WARN', msg: '✖ 2 alarm(s). Then more.\n✖ daemon · stale', row: 'alerts' },
      'credsep:293c8bf8': { kind: 'doctor', level: 'WARN', msg: 'separated on its own proxy', row: 'credsep' },
    },
    issues: { 'alerts:1dc2e1a6': { url: 'https://github.com/o/r/issues/9', at: '2026-10-09T12:00:00-07:00' } },
  },
  model_calls: 8,
  next_at: NEXT,
  page: { url: 'http://page.example/d/1/' },
  parked: [],
  rows: {
    a: { id: 'a', state: 'open', src: 'gh:o/b#11958', asked: '2026-10-09T14:19:25-07:00', item: 'x' },
    b: { id: 'b', state: 'open', src: 'gh:o/b#11958', asked: '2026-10-09T14:20:00-07:00', item: 'x', group: 'g1' },
    c: { id: 'c', state: 'open', src: 'gh:o/b#11958', asked: '2026-10-09T14:21:00-07:00', item: 'x', group: 'g1' },
    d: { id: 'd', state: 'answered', by: 'steward', src: 'gh:o/r#1', asked: '2026-10-09T09:00:00-07:00', closed_at: '2026-10-09T10:00:00-07:00' },
    e: { id: 'e', state: 'defaulted', src: 'gh:o/r#2', asked: '2026-10-09T06:00:00-07:00', closed_at: '2026-10-09T10:00:00-07:00' },
    f: { id: 'f', state: 'answered', by: 'person', src: 'gh:o/r#3', asked: '2026-10-09T11:00:00-07:00', closed_at: '2026-10-09T11:30:00-07:00' },
    g: { id: 'g', state: 'answered', by: 'steward', src: 'gh:o/r#4', asked: '2026-10-08T09:00:00-07:00', closed_at: '2026-10-08T10:00:00-07:00' },
  },
  sheet: { at: '2026-10-09T14:28:00-07:00', id: 's1', rows: ['a', 'b', 'c', 'd'], sent: true },
})
const DELTA = JSON.stringify({
  v: 1, session: 'fleet', at: '2026-10-09T14:47:12-07:00',
  events: [{ parent: 'orchestrator', child: 'o-r:scratch-9', state: 'REAPED' }], new_asks: [], closed: [], defaulted: [],
})

const PANE = (surface: string) => ({
  title: '巡检', isFocused: false, bodyColumns: 56, placement: surface === 'terminal' ? 'dock' : 'dock',
  scroll: { offset: 0, bodyRows: 40 },
}) as never

function engine(on: On, windowRole: string, env: Record<string, string> = ENV) {
  const files = new Map<string, { text: string; mtimeMs: number }>()
  const opened: string[] = []
  const runs: string[][] = []
  const toasts: string[] = []
  const stats: string[] = []
  let tick = 1
  const put = (path: string, text: string) => files.set(path, { text, mtimeMs: tick++ })
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('process.run', (_$, e) => {
    if (/\/fleet-(panel-jump|open)\.sh$/.test(e.argv[1] ?? '')) runs.push([...e.argv])
    const stdout = isRoleRun(e.argv) ? `${windowRole}\n` : isStringsRun(e.argv) ? DUMP : ''
    const exitCode = (e.argv[1] ?? '').endsWith('/fleet-panel-jump.sh') ? 1 : 0
    return { value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.stat', (_$, e) => {
    stats.push(e.path)
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
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('command.run', () => ({ text: 'engine' }))
  on('ui.open', (_$, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  // what the engine draws when the plugin passes
  on('ui.render', { component: 'Pane' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box key="engine" />
  })
  mock.env(on, env)
  mock.clock(on, { now: NOW })
  put(P.stamp, '1 1000\n')
  put(P.state, STATE)
  put(P.delta, DELTA)
  return { opened, runs, toasts, stats }
}

function fresh(): void {
  resetRole()
  resetPanels()
  resetPatrol()
}

async function texts($: Engine, surface: 'terminal' | 'desktop'): Promise<string[]> {
  const ui = await $.ui.mount({ plugin: 'fleet', surface, component: 'Pane', requestId: PATROL_PANE, props: PANE(surface) })
  const out = (await ui.findAll({ type: 'Text' })).map(el => el.text ?? '')
  await ui.unmount()
  return out
}

// ---- pure ---------------------------------------------------------------------

test('patrol: who closed a row — `by`, else read off an old row\'s state', () => {
  expect(rowBy({ state: 'answered', by: 'steward' })).toBe('steward')
  expect(rowBy({ state: 'defaulted' })).toBe('default')
  expect(rowBy({ state: 'answered' })).toBe('person')
  expect(rowBy({ state: 'open' })).toBe('')
  expect(firstSentence('✖ 2 alarm(s). Then more.\nline 2')).toBe('✖ 2 alarm(s).')
  expect(firstSentence('一句。两句')).toBe('一句。')
  expect(offsetOf('2026-10-09T14:47:12-07:00')).toBe(-420)
  expect(offsetOf('2026-10-09T14:47:12Z')).toBe(0)
  expect(clockOf(NEXT, -420, '10-09')).toBe('15:07')
  expect(clockOf(NEXT, -420, '10-08')).toBe('10-09 15:07')
})

test('patrol: the state file folds to beat 3 · 14:47 · calm, next 15:07, parked 0, health 4', () => {
  takeStrings(DUMP)
  const st = parseState(STATE).patrol
  expect(st.bySteward).toBe(1) // d today; g was yesterday
  expect(st.byDefault).toBe(1) // e: an old row with no `by`
  expect(st.groups).toBe(2) // a alone, b + c one group; d is closed
  expect(st.health).toBe(4)
  expect(st.healthTop).toBe('✖ 2 alarm(s).')
  const m = patrolModel({ ...st, events: 1 }, 20)
  expect(m.title).toBe('第 3 拍 · 14:47 · 平静')
  expect(m.sections.map(s => s.head)).toEqual(['这一拍看了', '停放 0', '自答 / 默认拍板', '健康 4', '下一拍 15:07'])
  expect(m.sections[1]?.lines).toEqual(['没有卡住的会话'])
  expect(m.foot).toBe('这一拍写单 0/20 · 叫模型 8 次 · 延后 0')
  // an older state file (no beat yet, no health) still reads
  expect(patrolModel(parseState('{"v":1,"rows":{}}').patrol, 20).title).toBe('panel_patrol_none')
})

// ---- drawn ----------------------------------------------------------------------

test('patrol: the steward draws it — terminal and desktop alike', async ($, on) => {
  fresh()
  engine(on, 'steward')
  await $.session.start(START)
  for (const surface of ['terminal', 'desktop'] as const) {
    expect(await texts($, surface)).toEqual([
      '第 3 拍 · 14:47 · 平静',
      '这一拍看了',
      '批次驱动 3 · 开着的提问 3',
      '回报 1 · 新问 0 · 关掉 0',
      '停放 0',
      '没有卡住的会话',
      '自答 / 默认拍板',
      '今天自答 1 · 按默认 1 · 交给你 2 件',
      '健康 4',
      '✖ 2 alarm(s).',
      '下一拍 15:07',
      '夜里一小时一拍',
      '这一拍写单 0/20 · 叫模型 8 次 · 延后 0',
    ])
  }
})

test('patrol: a parked session says what it waits for and since when', async ($, on) => {
  fresh()
  engine(on, 'steward')
  await $.session.start(START)
  const parked = JSON.parse(STATE) as Record<string, unknown>
  const st = parseState(JSON.stringify({ ...parked, parked: [{ at: NEXT - 3600, ref: 'o/b#11899', wait: ['reply:o/b#11899'] }] })).patrol
  const m = patrolModel(st, 20)
  expect(m.sections[1]?.head).toBe('停放 1')
  expect(m.sections[1]?.lines).toEqual(['o/b#11899 · 等 reply:o/b#11899 · 从 14:07 起'])
})

test('patrol: the buttons run a process only when pressed; a missing orchestrator is said', async ($, on) => {
  fresh()
  const { runs, toasts } = engine(on, 'steward')
  await $.session.start(START)
  const ui = await $.ui.mount({ plugin: 'fleet', surface: 'terminal', component: 'Pane', requestId: PATROL_PANE, props: PANE('terminal') })
  expect(runs).toEqual([])
  await ui.press({ key: 'patrol-orch' })
  expect(runs.length).toBe(1)
  expect(runs[0]?.[1]).toMatch(/\/fleet-panel-jump\.sh$/)
  expect(runs[0]?.[2]).toBe('orchestrator')
  expect(toasts).toContain('找不到编排会话')
  await ui.press({ key: 'patrol-sheet' })
  expect(runs[1]?.[1]).toMatch(/\/fleet-open\.sh$/)
  expect(runs[1]?.[2]).toBe('http://page.example/d/1/')
  await ui.unmount()
})

test('patrol: /sheet in the steward opens it; a fullscreen band opens it once unasked', async ($, on) => {
  fresh()
  const { opened } = engine(on, 'steward')
  await $.session.start(START)
  const band = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 200, scroll: { offset: 0, bodyRows: 10 }, view: {} }
  const mainScreen = await $.ui.mount({
    plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band as never,
    viewport: { columns: 200, rows: 50, isFullscreen: false },
  } as never)
  await mainScreen.unmount()
  expect(opened).toEqual([])
  for (let i = 0; i < 2; i++) {
    const ui = await $.ui.mount({
      plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt', props: band as never,
      viewport: { columns: 200, rows: 50, isFullscreen: true },
    } as never)
    await ui.unmount()
  }
  expect(opened).toEqual([PATROL_PANE])
  const r = await $.command.run({ command: 'sheet', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } } as never)
  expect(r.text).toBe('巡检面板在右边')
  expect(opened).toEqual([PATROL_PANE, PATROL_PANE])
})

for (const role of ['orchestrator', 'worker']) {
  test(`patrol: the ${role} opens no patrol and draws none`, async ($, on) => {
    fresh()
    const { opened } = engine(on, role)
    await $.session.start(START)
    const ui = await $.ui.mount({
      plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt',
      props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 200, scroll: { offset: 0, bodyRows: 10 }, view: {} } as never,
      viewport: { columns: 200, rows: 50, isFullscreen: true },
    } as never)
    await ui.unmount()
    // the orchestrator opens its own batches pane (issue #2833), never the patrol
    expect(opened).not.toContain(PATROL_PANE)
    expect(await texts($, 'terminal')).toEqual([])
  })
}

test('patrol: FLEET_MOD_PANELS=0 — the steward opens nothing, stats nothing', async ($, on) => {
  fresh()
  const { opened, stats } = engine(on, 'steward', { ...ENV, FLEET_MOD_PANELS: '0' })
  await $.session.start(START)
  const ui = await $.ui.mount({
    plugin: 'fleet', surface: 'terminal', component: 'AbovePrompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 200, scroll: { offset: 0, bodyRows: 10 }, view: {} } as never,
    viewport: { columns: 200, rows: 50, isFullscreen: true },
  } as never)
  await ui.unmount()
  expect(opened).toEqual([])
  expect(stats).toEqual([])
})
