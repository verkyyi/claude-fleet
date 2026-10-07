// The fleet's three in-session tools, kept as the FALLBACK for a session launched
// before the fleet tool service (issue #2057; the tools: issue #1340, retired as
// the primary road in #1812).
//
//   mcp__fleet__fleet_status / mcp__fleet__fleet_spawn / mcp__fleet__fleet_await
//
// bin/fleet-claude.sh mounts bin/fleet-mcp.py as the MCP server `fleet` on every
// new session and exports FLEET_MCP_SERVER=1 (issue #1807): there the mod registers
// NOTHING — status / spawn / await are the service's own tools. A session launched
// before that (`--plugin-dir` only, no `--mcp-config`) has no service, and its tool
// list — registered once at ITS start — still carries the mod's three: a hot reload
// swaps the code, never the list. Mod 0.4.0 dropped the handler, so every such call
// died with «no tool.call hook answered». Hence, one implementation, two roads:
//
//   - registration (lifecycle.ts onReady, FLEET_MCP_SERVER not 1 — the engine
//     follows `$` only within one file, so the run lives there and the argv and
//     the parse live here): the three are registered from the SERVICE's own specs
//     — `fleet-mcp.py --spec status spawn await` — so a schema lives once; a
//     re-register on a reload costs nothing;
//   - serving (the tool.call hook below): every call is forwarded to `fleet-mcp.py
//     --call <tool> <json>` — the same identity check, argument check, repo check,
//     script run and call log (road=call) as a tools/call. This file knows the
//     argv and the timeout, no more: nothing here parses an argument or names a
//     script;
//   - the retreat (the issue's B): when the FORWARD itself fails — no python3, the
//     install's bin/ gone, a usage exit, a timeout — the answer is one actionable
//     message: reopen the session (/fleet-handoff, or `claude --resume`) so it
//     mounts the service, or run the script by hand meanwhile.

import type { On, ToolSpec } from 'claude-code'

import { isOpen } from './gate'

export const PLUGIN = 'fleet'
// FLEET_MCP_SERVER=1 (set by bin/fleet-claude.sh, #1807) says the service is
// mounted; lifecycle.ts reads it by its literal name, as the engine requires.
// bin/fleet-oldcfg-replay.py reads the two below (issue #2075): FALLBACK is «the tools
// this version registers», TOOL_RE «the names the tool.call hook answers». Rename
// either and teach the replay the new spelling, or the release gate goes red.
/** The service's tools the fallback carries, in registration order. */
export const FALLBACK = ['status', 'spawn', 'await'] as const
export type Fallback = (typeof FALLBACK)[number]

/** Every tool this file serves, as the model calls it. */
export const TOOL_RE = /^mcp__fleet__fleet_(status|spawn|await)$/

// Timeouts stand a little past fleet-mcp.py's own (SPAWN_TIMEOUT_S 120, STATUS 30,
// await = timeout + 25), so the service's «did not answer within» is what the model
// reads, not a cut from here; `$.process.run` allows ten minutes at most.
export const AWAIT_DEFAULT_S = 540
const AWAIT_SLACK_S = 25
const HEADROOM_S = 10
export const SPEC_TIMEOUT_MS = 30_000
export const STATUS_TIMEOUT_MS = (3 * 30 + HEADROOM_S) * 1000
export const SPAWN_TIMEOUT_MS = (120 + HEADROOM_S) * 1000
export const RUN_MAX_MS = 600_000

/** The install's bin/, from the plugin root (<install>/mod/fleet). */
export function binDir(root: string): string {
  const base = root.replace(/\/+$/, '').replace(/\/\.claude-plugin$/, '')
  return `${base}/../../bin`
}

function service(bin: string): string[] {
  return ['python3', `${bin}/fleet-mcp.py`]
}

/** The argv that prints the three specs. */
export function specArgv(bin: string): string[] {
  return [...service(bin), '--spec', ...FALLBACK]
}

/** The argv that makes one call — the arguments travel as one JSON word. */
export function callArgv(bin: string, tool: string, args: Record<string, unknown>): string[] {
  return [...service(bin), '--call', tool, JSON.stringify(args)]
}

/** True for a run of this file's (a test's recorder filters them, like where.ts's). */
export function isToolsRun(argv: readonly string[]): boolean {
  return argv[0] === 'python3' && (argv[1] ?? '').endsWith('/fleet-mcp.py')
}

/** How long a forwarded call may take, by tool (await: its own timeout + slack). */
export function timeoutFor(tool: string, args: Record<string, unknown>): number {
  if (tool === 'await') {
    const t = typeof args.timeout === 'number' ? args.timeout : AWAIT_DEFAULT_S
    return Math.min(RUN_MAX_MS, (t + AWAIT_SLACK_S + HEADROOM_S) * 1000)
  }
  return tool === 'spawn' ? SPAWN_TIMEOUT_MS : STATUS_TIMEOUT_MS
}

const NOTE =
  '[fallback — this session was launched before the fleet tool service; the call is forwarded to ' +
  'bin/fleet-mcp.py. A reopened session (/fleet-handoff, or claude --resume) has the service\'s own tools.] '

/** The `--spec` output as the tools to register: `fleet_` + name, the note, the schema as is. */
export function fallbackSpecs(stdout: string): ToolSpec[] {
  const rows = JSON.parse(stdout) as unknown
  if (!Array.isArray(rows)) throw new Error('--spec did not print a list')
  return rows.map(row => {
    const r = row as { name?: unknown; description?: unknown; inputSchema?: unknown }
    if (typeof r.name !== 'string' || r.inputSchema === undefined) throw new Error('--spec row without name/schema')
    return {
      name: `fleet_${r.name}`,
      description: NOTE + (typeof r.description === 'string' ? r.description : ''),
      inputSchema: r.inputSchema,
    } as ToolSpec
  })
}

/** The one message when the forward itself cannot run (the issue's B). */
export function unreachable(full: string, tool: string, detail: string): string {
  const script =
    tool === 'spawn' ? 'dash-issue-session.sh <N> --repo <owner/name>'
    : tool === 'await' ? 'fleet-await.sh <N> --repo <owner/name>'
    : 'fleet-children.sh'
  return [
    `${full}: 这个会话启动于 fleet 工具服务（bin/fleet-mcp.py）之前，mod 的兜底转调失败：${detail}。`,
    '请 /fleet-handoff，或退出后用 `claude --resume` 重开 — 新会话挂上 fleet 工具服务（mcp__fleet__status / spawn / await）。',
    `临时可以用 Bash 调 ~/.claude/fleet/bin/${script}。`,
  ].join('\n')
}

const RESERVED = new Set(['tool', 'tool_use_id', 'agentId', 'consent'])

function argsOf(e: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(e)) if (!RESERVED.has(k)) out[k] = v
  return out
}

export function registerTools(on: On): void {
  // Unconditional past the gate: a call arrives only where a tool is listed, and
  // that list is the session's own — so answer it, served or not.
  on('tool.call', { tool: TOOL_RE }, async ($, e, next) => {
    const full = String(e.tool)
    const m = TOOL_RE.exec(full)
    if (!isOpen() || m === null) return next(e)
    const tool = m[1] as Fallback
    const args = argsOf(e as unknown as Record<string, unknown>)
    try {
      const r = await $.process.run(callArgv(binDir($.plugin.root), tool, args), { timeoutMs: timeoutFor(tool, args) })
      const text = r.stdout.replace(/\s+$/, '')
      if (r.exitCode === 0) return { result: text }
      if (r.exitCode === 1 && text !== '') return { deny: text }   // the service refused or faulted, with its reason
      const err = r.stderr.replace(/\s+$/, '')
      return { result: unreachable(full, tool, `fleet-mcp.py --call exited ${r.exitCode}${err ? ` (${err})` : ''}`) }
    } catch (err) {
      // No python3, no bin/, a timeout: say what to do, never hang.
      return { result: unreachable(full, tool, err instanceof Error ? err.message : String(err)) }
    }
  }).catch(($, e, next) => next(e))
}
