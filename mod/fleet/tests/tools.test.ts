// The fallback tools (issue #2057). Beneath the plugin the test's hooks stand for
// the engine: `process.run` records every argv and answers from a stub table —
// `fleet-mcp.py --spec` prints the service's specs, `--call` what the service
// answered — so a test asserts exactly which command line a call ran, that its
// text comes back, and what the model reads when the forward itself cannot run.

import { expect, mock, test } from 'claude-code/testing'
import type { On, ProcessRunResult } from 'claude-code'

import {
  AWAIT_DEFAULT_S,
  FALLBACK,
  RUN_MAX_MS,
  SPAWN_TIMEOUT_MS,
  STATUS_TIMEOUT_MS,
  binDir,
  callArgv,
  fallbackSpecs,
  isToolsRun,
  specArgv,
  timeoutFor,
  unreachable,
} from '../hooks/tools'
import { SUPPORTED } from '../hooks/version'
import { isWhereRun } from '../hooks/where'

const START = { cwd: '/tmp', surface: 'terminal', isInteractive: false } as const

/** What `fleet-mcp.py --spec status spawn await` prints (the service's own specs). */
const SPECS = JSON.stringify([
  { name: 'status', description: 'Read-only. This fleet window…', inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
  {
    name: 'spawn',
    description: 'Start a fleet worker session…',
    inputSchema: {
      type: 'object',
      properties: { issue: { type: 'integer', minimum: 1 }, repo: { type: 'string' }, reap: { type: 'string' } },
      required: ['issue'],
      additionalProperties: false,
    },
  },
  {
    name: 'await',
    description: 'Hand an issue to a worker…',
    inputSchema: {
      type: 'object',
      properties: { issue: { type: 'integer', minimum: 1 }, repo: { type: 'string' }, timeout: { type: 'integer' } },
      required: ['issue'],
      additionalProperties: false,
    },
  },
])

function ran(exitCode: number, stdout = '', stderr = ''): ProcessRunResult {
  return { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false }
}

type Stub = (argv: string[]) => ProcessRunResult | Error

/** env null = outside tmux (no TMUX_PANE at all); else the pane plus `env`. */
function engine(on: On, env: Record<string, string> | null = {}, stub?: Stub) {
  const runs: string[][] = []
  const registered: Array<{ name: string; description?: string; inputSchema?: unknown }> = []
  on('session.version', () => ({ value: { version: SUPPORTED.min, base: SUPPORTED.min } }))
  on('process.run', (_$, e) => {
    const argv = [...e.argv]
    if (!isWhereRun(argv)) runs.push(argv)
    if (!isToolsRun(argv)) return { value: ran(0) }
    const custom = stub?.(argv)
    if (custom instanceof Error) throw custom
    if (custom !== undefined) return { value: custom }
    if (argv[2] === '--spec') return { value: ran(0, SPECS + '\n') }
    return { value: ran(0, `exit 0 · ${argv[3]}\nok\n`) }
  })
  on('tool.register', (_$, e) => {
    registered.push(e as unknown as { name: string; description?: string; inputSchema?: unknown })
    return { value: { tool: `mcp__fleet__${e.name}` } }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  mock.env(on, env === null ? {} : { TMUX_PANE: '%7', ...env })
  mock.clock(on, { now: 1_000_000_000_000 })
  const service = () => runs.filter(isToolsRun)
  return { runs, registered, service }
}

function textOf(r: { deny?: string; result?: unknown }): string {
  return r.deny ?? String(r.result)
}

test('pure: bin/ beside mod/, the --spec and --call argv, the timeouts, the specs, the retreat', () => {
  expect(binDir('/i/mod/fleet')).toBe('/i/mod/fleet/../../bin')
  expect(binDir('/i/mod/fleet/.claude-plugin')).toBe('/i/mod/fleet/../../bin')
  expect(specArgv('/b')).toEqual(['python3', '/b/fleet-mcp.py', '--spec', 'status', 'spawn', 'await'])
  expect(callArgv('/b', 'spawn', { issue: 42, repo: 'acme/lib' })).toEqual([
    'python3', '/b/fleet-mcp.py', '--call', 'spawn', '{"issue":42,"repo":"acme/lib"}',
  ])
  expect(callArgv('/b', 'status', {})).toEqual(['python3', '/b/fleet-mcp.py', '--call', 'status', '{}'])
  expect(isToolsRun(['python3', '/b/fleet-mcp.py', '--call', 'status', '{}'])).toBe(true)
  expect(isToolsRun(['tmux', 'display-message'])).toBe(false)
  // Past the service's own timeouts (120 / 30 / t+25), capped at ten minutes.
  expect(timeoutFor('spawn', {})).toBe(SPAWN_TIMEOUT_MS)
  expect(SPAWN_TIMEOUT_MS).toBeGreaterThan(120_000)
  expect(timeoutFor('status', {})).toBe(STATUS_TIMEOUT_MS)
  expect(timeoutFor('await', { timeout: 60 })).toBe(95_000)
  expect(timeoutFor('await', {})).toBe((AWAIT_DEFAULT_S + 35) * 1000)
  expect(timeoutFor('await', { timeout: 570 })).toBe(RUN_MAX_MS)
  // The service's specs become fleet_<name>, schema untouched, a fallback note first.
  const specs = fallbackSpecs(SPECS)
  expect(specs.map(s => s.name)).toEqual(['fleet_status', 'fleet_spawn', 'fleet_await'])
  expect(specs.map(s => s.name)).toEqual(FALLBACK.map(n => `fleet_${n}`))
  expect((specs[1]?.inputSchema as { required: string[] }).required).toEqual(['issue'])
  expect((specs[1]?.inputSchema as { properties: Record<string, unknown> }).properties).toHaveProperty('reap')
  expect(specs[1]?.description?.startsWith('[fallback')).toBe(true)
  expect(specs[1]?.description).toContain('Start a fleet worker session')
  expect(() => fallbackSpecs('{"not":"a list"}')).toThrow()
  expect(() => fallbackSpecs('[{"description":"no name"}]')).toThrow()
  // The retreat names the two ways out and the script for THIS tool.
  const msg = unreachable('mcp__fleet__fleet_spawn', 'spawn', 'python3 could not start')
  expect(msg).toContain('mcp__fleet__fleet_spawn')
  expect(msg).toContain('python3 could not start')
  expect(msg).toContain('/fleet-handoff')
  expect(msg).toContain('claude --resume')
  expect(msg).toContain('~/.claude/fleet/bin/dash-issue-session.sh <N> --repo <owner/name>')
  expect(unreachable('mcp__fleet__fleet_await', 'await', 'x')).toContain('fleet-await.sh <N>')
  expect(unreachable('mcp__fleet__fleet_status', 'status', 'x')).toContain('fleet-children.sh')
})

test('no tool service (FLEET_MCP_SERVER unset): the three are registered at session.start, from the service\'s specs', async ($, on) => {
  const { registered, service, runs } = engine(on)
  await $.session.start(START)
  expect(service().length).toBe(1)
  expect(service()[0]?.[0]).toBe('python3')
  expect(service()[0]?.[1]?.endsWith('/bin/fleet-mcp.py')).toBe(true)
  expect(service()[0]?.slice(2)).toEqual(['--spec', 'status', 'spawn', 'await'])
  expect(registered.map(r => r.name)).toEqual(['fleet_status', 'fleet_spawn', 'fleet_await'])
  expect((registered[1]?.inputSchema as { additionalProperties: boolean }).additionalProperties).toBe(false)
  // Everything else still starts: the heartbeat is written.
  expect(runs.some(a => a.includes('@mod_alive'))).toBe(true)
})

test('the tool service mounted (FLEET_MCP_SERVER=1, #1807): no spec read, nothing registered', async ($, on) => {
  const { registered, service } = engine(on, { FLEET_MCP_SERVER: '1' })
  await $.session.start(START)
  expect(service()).toEqual([])
  expect(registered).toEqual([])
})

test('outside tmux: no pane, no spec read, nothing registered', async ($, on) => {
  const { registered, runs } = engine(on, null)
  await $.session.start(START)
  expect(runs).toEqual([])
  expect(registered).toEqual([])
})

test('a spec read that exits non-zero registers nothing and costs nothing else', async ($, on) => {
  const { registered, runs } = engine(on, {}, argv => (argv[2] === '--spec' ? ran(2, '', 'usage') : undefined))
  await $.session.start(START)
  expect(registered).toEqual([])
  expect(runs.some(a => a.includes('@mod_alive'))).toBe(true)
})

test('a spec read that prints no list registers nothing', async ($, on) => {
  const { registered } = engine(on, {}, argv => (argv[2] === '--spec' ? ran(0, 'not json') : undefined))
  await $.session.start(START)
  expect(registered).toEqual([])
})

test('fleet_spawn forwards to fleet-mcp.py --call spawn <json>, once; the service\'s text comes back as the result', async ($, on) => {
  const { service } = engine(on, {}, argv =>
    argv[2] === '--call' ? ran(0, 'exit 2 · dash-issue-session.sh\nspawned issue-42\n[stderr]\nat capacity (8/8)\n') : undefined,
  )
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_spawn', issue: 42, repo: 'acme/lib' })
  const calls = service().filter(a => a[2] === '--call')
  expect(calls.length).toBe(1)
  expect(calls[0]?.slice(2)).toEqual(['--call', 'spawn', '{"issue":42,"repo":"acme/lib"}'])
  expect(r.deny).toBe(undefined)
  expect(textOf(r)).toBe('exit 2 · dash-issue-session.sh\nspawned issue-42\n[stderr]\nat capacity (8/8)')
})

test('fleet_await and fleet_status forward with their own arguments; the reserved call fields never travel', async ($, on) => {
  const { service } = engine(on)
  await $.session.start(START)
  await $.tool.call({ tool: 'mcp__fleet__fleet_await', issue: 9, timeout: 60 })
  await $.tool.call({ tool: 'mcp__fleet__fleet_status' })
  const calls = service().filter(a => a[2] === '--call').map(a => a.slice(3))
  expect(calls).toEqual([
    ['await', '{"issue":9,"timeout":60}'],
    ['status', '{}'],
  ])
})

test('the service refuses (exit 1): its reason is the deny, nothing of ours is added', async ($, on) => {
  engine(on, {}, argv =>
    argv[2] === '--call' ? ran(1, 'fleet.spawn: repo "other/repo" is not hosted by this fleet (hosted: acme/app). Nothing ran.\n') : undefined,
  )
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_spawn', issue: 5, repo: 'other/repo' })
  expect(r.deny).toBe('fleet.spawn: repo "other/repo" is not hosted by this fleet (hosted: acme/app). Nothing ran.')
})

test('the forward itself fails (B): a usage exit, no python3, a silent exit 1 → the one actionable message', async ($, on) => {
  const stubs: Record<string, ProcessRunResult> = {}
  engine(on, {}, argv => (argv[2] === '--call' ? stubs[argv[3] ?? ''] : undefined))
  await $.session.start(START)
  stubs.spawn = ran(2, '', 'usage: fleet-mcp.py [--mount codex | …]')
  let r = await $.tool.call({ tool: 'mcp__fleet__fleet_spawn', issue: 5 })
  expect(r.deny).toBe(undefined)
  expect(textOf(r)).toContain('exited 2 (usage: fleet-mcp.py')
  expect(textOf(r)).toContain('/fleet-handoff')
  expect(textOf(r)).toContain('claude --resume')
  expect(textOf(r)).toContain('dash-issue-session.sh <N> --repo <owner/name>')
  stubs.await = ran(127, '', 'python3: command not found')
  r = await $.tool.call({ tool: 'mcp__fleet__fleet_await', issue: 5 })
  expect(textOf(r)).toContain('exited 127 (python3: command not found)')
  expect(textOf(r)).toContain('fleet-await.sh <N>')
  // exit 1 with nothing printed is not a refusal with a reason: the retreat too.
  stubs.status = ran(1, '', '')
  r = await $.tool.call({ tool: 'mcp__fleet__fleet_status' })
  expect(r.deny).toBe(undefined)
  expect(textOf(r)).toContain('exited 1')
  expect(textOf(r)).toContain('fleet-children.sh')
})

test('the forward throws (the run never started): the retreat, never a hang', async ($, on) => {
  engine(on, {}, argv => (argv[2] === '--call' ? new Error('spawn python3 ENOENT') : undefined))
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_spawn', issue: 5 })
  expect(r.deny).toBe(undefined)
  expect(textOf(r)).toContain('mcp__fleet__fleet_spawn: 这个会话启动于 fleet 工具服务')
  expect(textOf(r)).toContain('/fleet-handoff')
})

test('an old session: the listed tool is answered even when this start registered nothing', async ($, on) => {
  // The spec read fails (nothing registered by THIS start), but the session's tool
  // list — made at its own start, before the reload — still carries fleet_spawn.
  engine(on, {}, argv => (argv[2] === '--spec' ? ran(1) : undefined))
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_spawn', issue: 7 })
  expect(textOf(r)).toBe('exit 0 · spawn\nok')
})

test('gate shut (out-of-range engine): the call is handed on, nothing runs', async ($, on) => {
  const runs: string[][] = []
  on('session.version', () => ({ value: { version: '9.0.0', base: '9.0.0' } }))
  on('process.run', (_$, e) => {
    runs.push([...e.argv])
    return { value: ran(0) }
  })
  on('tool.call', () => ({ result: 'the engine answered' as never, isAborted: false, turnId: 't1' }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  mock.env(on, { TMUX_PANE: '%7' })
  mock.clock(on, { now: 1_000_000_000_000 })
  await $.session.start(START)
  const r = await $.tool.call({ tool: 'mcp__fleet__fleet_spawn', issue: 7 })
  expect(runs.filter(isToolsRun)).toEqual([])
  expect(r.result).toBe('the engine answered')
})
