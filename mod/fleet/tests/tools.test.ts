// The fleet tools (issue #1340). Beneath the plugin the test's hooks stand for
// the engine: `process.run` records every argv and answers from a stub table
// (fleet-repo.sh list, the scripts' exit codes), so a test asserts exactly
// which command line a call ran and that its exit code + output come back.

import { expect, mock, test } from 'claude-code/testing'
import type { On, ProcessRunResult } from 'claude-code'

import { SUPPORTED } from '../hooks/version'
import { AWAIT_DEFAULT_S, AWAIT_MAX_S, TOOL_SPECS, binDir, checkArgs, parseRepoList } from '../hooks/tools'
import { isWhereRun } from '../hooks/where'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: false } as const

const REPO_LIST = [
  'fleet f hosts:',
  '  acme/app                             main=/x/app  base=main  [conf]',
  '  acme/lib                             main=/x/lib  base=main  [repos/acme-lib.conf]',
  '',
].join('\n')

function ran(exitCode: number, stdout = '', stderr = ''): ProcessRunResult {
  return { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false }
}

function engine(on: On, scripts: Record<string, ProcessRunResult> = {}) {
  const runs: string[][] = []
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    const argv = [...e.argv]
    if (!isWhereRun(argv)) runs.push(argv)
    const name = (argv[0] ?? '').replace(/^.*\//, '')
    if (name === 'fleet-repo.sh') return { value: ran(0, REPO_LIST) }
    return { value: scripts[name] ?? ran(0) }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  mock.env(on, { TMUX_PANE: '%7' })
  mock.clock(on, { now: 1_000_000_000_000 })
  /** The script runs only — not tmux, not the repo lookup. */
  const scriptRuns = () =>
    runs.filter(a => a[0] !== 'tmux' && !(a[0] ?? '').endsWith('/fleet-repo.sh'))
  return { runs, scriptRuns }
}

function textOf(r: { deny?: string; result?: unknown }): string {
  return r.deny ?? String(r.result)
}

test('schemas: every tool closes its arguments; issue is a required integer', () => {
  expect(TOOL_SPECS.map(t => t.name)).toEqual(['fleet_status', 'fleet_spawn', 'fleet_await'])
  for (const t of TOOL_SPECS) expect((t.inputSchema as { additionalProperties: boolean }).additionalProperties).toBe(false)
  expect(checkArgs('fleet_spawn', {})).toContain('missing required argument "issue"')
  expect(checkArgs('fleet_spawn', { issue: '12' })).toContain('must be an integer')
  expect(checkArgs('fleet_spawn', { issue: 1.5 })).toContain('must be an integer')
  expect(checkArgs('fleet_spawn', { issue: 0 })).toContain('≥ 1')
  expect(checkArgs('fleet_spawn', { issue: 12, force: true })).toContain('unknown argument "force"')
  expect(checkArgs('fleet_spawn', { issue: 12, repo: 7 })).toContain('non-empty string')
  expect(checkArgs('fleet_spawn', { issue: 12, repo: '--force' })).toContain('owner/name')
  expect(checkArgs('fleet_await', { issue: 12, timeout: AWAIT_MAX_S + 1 })).toContain(`≤ ${AWAIT_MAX_S}`)
  expect(checkArgs('fleet_status', { issue: 12 })).toContain('takes no arguments')
  expect(checkArgs('fleet_spawn', { issue: 12, repo: 'acme/app' })).toBe(null)
  expect(checkArgs('fleet_await', { issue: 12, timeout: 60 })).toBe(null)
  expect(checkArgs('fleet_status', {})).toBe(null)
})

test('helpers: repo list rows, bin/ beside mod/', () => {
  expect(parseRepoList(REPO_LIST)).toEqual(['acme/app', 'acme/lib'])
  expect(binDir('/i/mod/fleet')).toBe('/i/mod/fleet/../../bin')
  expect(binDir('/i/mod/fleet/.claude-plugin')).toBe('/i/mod/fleet/../../bin')
})

test('the three tools are registered at session.start', async ($, on) => {
  const names: string[] = []
  on('tool.register', (_$, e) => {
    names.push(e.name)
    return { value: { tool: `mcp__fleet__${e.name}` } }
  })
  engine(on)
  await $.session.start(START)
  expect(names).toEqual(['fleet_status', 'fleet_spawn', 'fleet_await'])
})

test('bad arguments are refused with the reason, and nothing runs', async ($, on) => {
  const { scriptRuns } = engine(on)
  await $.session.start(START)
  const cases: Array<[string, Record<string, unknown>, string]> = [
    ['fleet_spawn', {}, 'missing required argument "issue"'],
    ['fleet_spawn', { issue: 'abc' }, 'must be an integer'],
    ['fleet_spawn', { issue: 5, extra: 'x' }, 'unknown argument "extra"'],
    ['fleet_await', { issue: 5, timeout: '60' }, 'must be an integer'],
    ['fleet_spawn', { issue: 5, repo: 'other/repo' }, 'not hosted by this fleet'],
    ['fleet_await', { issue: 5, repo: 'other/repo' }, 'acme/app, acme/lib'],
  ]
  for (const [tool, args, why] of cases) {
    const r = await $.tool.call({ tool: `mcp__fleet__${tool}`, ...args })
    expect(r.deny ?? '').toContain(why)
  }
  expect(scriptRuns()).toEqual([])
})

test('fleet_spawn runs dash-issue-session.sh with exactly its argv; exit code passes through', async ($, on) => {
  const { scriptRuns } = engine(on, {
    'dash-issue-session.sh': ran(2, '', 'dash-issue-session: at capacity (8/8)\n'),
  })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_spawn', issue: 42, repo: 'acme/lib' })
  const runs = scriptRuns()
  expect(runs.length).toBe(1)
  expect(runs[0]?.[0]?.endsWith('/bin/dash-issue-session.sh')).toBe(true)
  expect(runs[0]?.slice(1)).toEqual(['42', '--repo', 'acme/lib'])
  expect(textOf(r)).toContain('exit 2 · dash-issue-session.sh')
  expect(textOf(r)).toContain('at capacity (8/8)')
})

test('fleet_await runs fleet-await.sh with the timeout; the verdict comes back', async ($, on) => {
  const { scriptRuns } = engine(on, {
    'fleet-await.sh': ran(0, 'MERGED\nissue: #9 · t\npr: #10\n'),
  })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_await', issue: 9, timeout: 60 })
  expect(scriptRuns()[0]?.slice(1)).toEqual(['9', '--timeout', '60'])
  expect(textOf(r)).toContain('exit 0 · fleet-await.sh\nMERGED')
  await $.tool.call({ tool: 'mcp__fleet__fleet_await', issue: 9 })
  expect(scriptRuns()[1]?.slice(1)).toEqual(['9', '--timeout', String(AWAIT_DEFAULT_S)])
})

test('fleet_status is read-only: window line + children + hosted repos', async ($, on) => {
  const { runs, scriptRuns } = engine(on, {
    'fleet-children.sh': ran(0, 'children of issue-1 · f\n0 children\n'),
  })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_status' })
  expect(scriptRuns().map(a => (a[0] ?? '').replace(/^.*\//, ''))).toEqual(['fleet-children.sh'])
  const tmux = runs.filter(a => a[0] === 'tmux' && a[1] === 'display-message')
  expect(tmux.length).toBe(1)
  expect(tmux[0]).toContain('%7')
  expect(textOf(r)).toContain('0 children')
  expect(textOf(r)).toContain('acme/lib')
})
