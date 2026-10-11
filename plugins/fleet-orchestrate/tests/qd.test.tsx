// /qd, quick dispatch (issue #2618), as the fleet-orchestrate plugin carries it
// (issue #3114) — retired by issue #3328 into ⌘P, kept one version as a forward
// (compat-1v: 下一批删): its Enter runs ⌘P's ⚡ send. A mocked engine: `process.run`
// answers the window read (@issue|@fleet_role), the `qd_` strings dump,
// `fleet-mcp.py --call repos` and `fleet-quick-dispatch.py send` (each send recorded
// with its title and repo);
// `command.register`, `ui.open`, `ui.close` and `ui.toast` beneath the plugin
// record what the plugin asked.

import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import {
  QD_COMMAND, QD_PANE, binDir, mayDispatch, parseReport, parseRepos, pickRepo, sendArgv, takeStrings, t,
} from '../hooks/qd'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const
const PRESENT = { layout: 'main', columns: 80 } as never
const HAND = { kind: 'composer' } as const

const DUMP = [
  'qd_title', '快速派发', 'qd_desc', '快速派发说明', 'qd_empty', '标题是空的', 'qd_norepo', '读不到仓库',
  'qd_failed_fmt', '没派出去：\u0001', 'qd_hint', '↵ 派出', 'qd_moved', '/qd 已并进 ⌘P',
].join('\0') + '\0'

const REPOS = 'exit 0 · fleet-repo.sh\nfleet fleet hosts:\n' +
  '  verkyyi/claude-fleet                 main=/x  base=master  [repos/a.conf]\n' +
  '  acme/web main=/y  base=main  [repos/b.conf]'

const SENT = '已发出：首页加载变慢\n'

type Filed = Record<string, unknown>

function engine(
  on: On, windowRead: string,
  answer: () => { exitCode: number; stdout: string } = () => ({ exitCode: 0, stdout: SENT }),
) {
  const filed: Filed[] = []
  const registered: { name: string; immediate?: true }[] = []
  const opened: string[] = []
  const closed: string[] = []
  const toasts: string[] = []
  const entered: string[] = []
  on('process.run', (_$, e) => {
    let out = { exitCode: 0, stdout: '' }
    if (e.argv[0] === 'tmux') out.stdout = `${windowRead}\n`
    else if (e.argv[0] === 'sh' && (e.argv[1] ?? '').endsWith('/fleet-ui-lang.sh')) out.stdout = DUMP
    else if (e.argv.includes('--call') && e.argv.includes('repos')) out.stdout = REPOS
    else if ((e.argv[1] ?? '').endsWith('/fleet-quick-dispatch.py') && e.argv[2] === 'send') {
      const at = (k: string) => (e.argv.indexOf(k) >= 0 ? e.argv[e.argv.indexOf(k) + 1] : undefined)
      filed.push({ title: at('--title'), repo: at('--repo') })
      out = answer()
    }
    else if (e.argv.includes('--call') && e.argv.includes('file_issue')) filed.push({ road: 'file_issue' })
    return { value: { ...out, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.register', (_$, e) => {
    registered.push(e)
    return { value: { command: e.name } }
  })
  on('command.run', () => ({ text: 'engine' }))
  on('ui.open', (_$, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    closed.push(e.id)
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('prompt.submit', (_$, e) => {
    entered.push(e.text)
    return { text: e.text }
  })
  mock.store(on)
  return { filed, registered, opened, closed, toasts, entered }
}

const PANE = {
  title: '快速派发', isFocused: true, bodyColumns: 70, placement: 'inline', scroll: { offset: 0, rows: 6 },
} as never
const ENV = { TMUX: '/tmp/s,1,0', TMUX_PANE: '%7', HOME: '/h' }

async function openQd($: Parameters<Parameters<typeof test>[1]>[0]) {
  await $.command.run({ command: QD_COMMAND, args: '', origin: HAND, presentation: PRESENT })
  return $.ui.mount({ plugin: 'fleet-orchestrate', surface: 'terminal', component: 'Pane', requestId: QD_PANE, props: PANE })
}

test('qd: the report, the repo list, ⌘P\'s send, the window gate', () => {
  expect(parseReport('exit 3 · fleet-issue-file.sh\nout\n[stderr]\nerr')).toEqual({ exit: 3, stdout: 'out', stderr: 'err' })
  expect(parseReport('fleet.file_issue: no. Nothing ran.').exit).toBe(null)
  expect(parseRepos(REPOS)).toEqual(['verkyyi/claude-fleet', 'acme/web'])
  expect(sendArgv('/b', '修登录', 'acme/web')).toEqual(['python3', '/b/fleet-quick-dispatch.py', 'send', '--title', '修登录', '--repo', 'acme/web'])
  expect(pickRepo(['a/b', 'c/d'], 'c/d')).toBe('c/d')
  expect(pickRepo(['a/b', 'c/d'], 'gone/x')).toBe('a/b')
  expect(binDir(undefined, '/h')).toBe('/h/.claude/fleet/bin')
  expect(binDir('/dev/bin', '/h')).toBe('/dev/bin')
  expect(mayDispatch('|worker')).toBe(true)
  expect(mayDispatch('|orchestrator')).toBe(true)
  expect(mayDispatch('12|worker')).toBe(false)
  expect(mayDispatch('|home')).toBe(false)
  expect(mayDispatch('|')).toBe(false)
  takeStrings(DUMP)
  expect(t('qd_failed_fmt', 'x')).toBe('没派出去：x')
  expect(t('qd_nope')).toBe('qd_nope')
})

test('qd: a window bound to an issue has no /qd', async ($, on) => {
  const { registered } = engine(on, '42|worker')
  mock.env(on, ENV)
  await $.session.start(START)
  expect(registered.map(c => c.name)).not.toContain(QD_COMMAND)
})

test('qd: outside tmux there is no /qd', async ($, on) => {
  const { registered } = engine(on, '|worker')
  mock.env(on, { HOME: '/h' })
  await $.session.start(START)
  expect(registered.map(c => c.name)).not.toContain(QD_COMMAND)
})

test('qd: in a window with no issue, /qd mid-turn opens the dialog saying it moved into ⌘P; Enter sends exactly once through ⌘P\'s send', async ($, on) => {
  const { registered, opened, closed, toasts, filed } = engine(on, '|worker')
  mock.env(on, ENV)
  await $.session.start(START)
  const qd = registered.find(c => c.name === QD_COMMAND)
  expect(qd?.immediate).toBe(true)
  const ui = await openQd($)
  expect(opened).toEqual([QD_PANE])
  expect((await ui.find({ key: 'qd-repo' }))).toBeDefined()
  await ui.select({ key: 'qd-repo', value: 'acme/web' })
  await ui.input({ key: 'qd-title', text: '首页加载变慢' })
  expect(await ui.find({ text: /已并进 ⌘P/ })).toBeDefined()
  expect(filed).toEqual([{ title: '首页加载变慢', repo: 'acme/web' }])
  expect(closed).toEqual([QD_PANE])
  expect(toasts).toEqual(['已发出：首页加载变慢'])
  await ui.unmount()
})

test('qd: an empty title dispatches nothing and says so', async ($, on) => {
  const { filed, closed } = engine(on, '|worker')
  mock.env(on, ENV)
  await $.session.start(START)
  const ui = await openQd($)
  await ui.input({ key: 'qd-title', text: '   ' })
  expect(filed).toEqual([])
  expect(closed).toEqual([])
  expect(await ui.find({ text: /标题是空的/ })).toBeDefined()
  await ui.unmount()
})

test('qd: a refused dispatch keeps the dialog, the title and the reason', async ($, on) => {
  const { filed, closed } = engine(on, '|worker', () => ({
    exitCode: 1, stdout: '没派出去：placement refused (issue #2960)',
  }))
  mock.env(on, ENV)
  await $.session.start(START)
  const ui = await openQd($)
  await ui.input({ key: 'qd-title', text: '修登录' })
  expect(filed.length).toBe(1)
  expect(closed).toEqual([])
  expect(await ui.find({ text: /没派出去：.*#2960/ })).toBeDefined()
  expect((await ui.find({ key: 'qd-title' }))?.props.value).toBe('修登录')
  await ui.unmount()
})

test('qd: the 派： prefix is off by default; on, a mid-turn one is dropped and dispatched', async ($, on) => {
  const { filed, entered } = engine(on, '|worker')
  mock.env(on, { ...ENV, FLEET_ORCH_QD_PREFIX: '1' })
  await $.session.start(START)
  await $.prompt.submit({ text: '派：修登录', wait: false, origin: HAND })
  expect(filed).toEqual([])
  await $.prompt.submit({ text: '派：修登录', wait: false, origin: HAND, turnId: 't1' })
  expect(filed).toEqual([{ title: '修登录', repo: 'verkyyi/claude-fleet' }])
  expect(entered).toEqual(['派：修登录'])
})

test('qd: without FLEET_ORCH_QD_PREFIX the 派： prefix just queues', async ($, on) => {
  const { filed, entered } = engine(on, '|worker')
  mock.env(on, ENV)
  await $.session.start(START)
  await $.prompt.submit({ text: '派：修登录', wait: false, origin: HAND, turnId: 't1' })
  expect(filed).toEqual([])
  expect(entered).toEqual(['派：修登录'])
})
