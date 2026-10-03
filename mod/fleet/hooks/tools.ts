// The fleet's everyday operations as tools the model calls (issue #1340, EPIC #1334).
//
//   mcp__fleet__fleet_status  read-only: this window's binding/state + its children
//   mcp__fleet__fleet_spawn   issue [+ repo] → bin/dash-issue-session.sh
//   mcp__fleet__fleet_await   issue [+ repo, timeout] → bin/fleet-await.sh
//
// Typed arguments are the point: a script called by hand takes whatever argv the
// model remembers, and some of them swallow a stray argument and exit 0 (#1066).
// Here every call is checked against its schema FIRST — a missing, mistyped or
// unknown argument, or a repo this fleet does not host, is refused with the
// reason and nothing runs. A valid call then runs the script UNCHANGED via
// `$.process.run` and hands back its stdout, stderr and exit code as they came:
// the session caps, the cross-machine claim dedup, the agent guard — every rail
// the scripts carry — apply exactly as they do from a shell. No tool here writes
// code; fleet_spawn (and fleet_await, which spawns through the same choke point
// when no worker is live) is the only write.
//
// Registration happens in lifecycle.ts's onReady (the one session.start), from
// TOOL_SPECS below; the serving `tool.call` hooks live here, behind the gate.

import type { On, ProcessRunResult, ToolSpec } from 'claude-code'

import { isOpen } from './gate'

export const PLUGIN = 'fleet'

/** fleet-await.sh blocks; `$.process.run` allows ten minutes at most. */
export const AWAIT_MAX_S = 570
export const AWAIT_DEFAULT_S = 540
/** Head-room past the script's own --timeout before the run is abandoned. */
const AWAIT_SLACK_MS = 25_000
const SPAWN_TIMEOUT_MS = 120_000
const STATUS_TIMEOUT_MS = 30_000

const ISSUE = {
  type: 'integer',
  minimum: 1,
  description: 'The GitHub issue number (a positive integer, no "#").',
} as const
const REPO = {
  type: 'string',
  description:
    'owner/name of a repo THIS fleet hosts (fleet_status lists them). Omit for the fleet\'s default repo.',
} as const

export const TOOL_SPECS: readonly ToolSpec[] = [
  {
    name: 'fleet_status',
    description:
      'Read-only. This fleet window\'s binding (issue, repo, state) and every child session it spawned — ' +
      'ledger outcome, live state, PR — plus the repos this fleet hosts. Changes nothing.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'fleet_spawn',
    description:
      'Start a fleet worker session on a GitHub issue (its own worktree + window; it claims, implements and ' +
      'lands the issue itself). Runs bin/dash-issue-session.sh, so the session caps and the claim dedup apply. ' +
      'Exit 0 spawned (or the window already exists), 2 at capacity, 3 already claimed, 1 infrastructure. ' +
      'Returns at once — use fleet_await to wait for the outcome.',
    inputSchema: {
      type: 'object',
      properties: { issue: ISSUE, repo: REPO },
      required: ['issue'],
      additionalProperties: false,
    },
  },
  {
    name: 'fleet_await',
    description:
      'Hand an issue to a worker (spawning one if none is live) and BLOCK until it lands, blocks or is reaped; ' +
      'prints the verdict (MERGED / BLOCKED / FAILED / TIMEOUT / REAPED / NO-WORKER), PR and summary. ' +
      `Runs bin/fleet-await.sh. TIMEOUT (exit 3) means still running — call again to keep waiting (nothing ` +
      `spawns twice).`,
    inputSchema: {
      type: 'object',
      properties: {
        issue: ISSUE,
        repo: REPO,
        timeout: {
          type: 'integer',
          minimum: 1,
          maximum: AWAIT_MAX_S,
          description: `Seconds to wait before answering TIMEOUT (default ${AWAIT_DEFAULT_S}, at most ${AWAIT_MAX_S}).`,
        },
      },
      required: ['issue'],
      additionalProperties: false,
    },
  },
]

type Spec = { required: readonly string[]; props: Record<string, { type: string; minimum?: number; maximum?: number }> }

function specOf(name: string): Spec {
  const s = TOOL_SPECS.find(t => t.name === name)?.inputSchema as
    | { properties: Spec['props']; required?: string[] }
    | undefined
  return { required: s?.required ?? [], props: s?.properties ?? {} }
}

/** The reason `args` does not fit `tool`'s schema, or null when it does. */
export function checkArgs(tool: string, args: Record<string, unknown>): string | null {
  const { required, props } = specOf(tool)
  for (const key of Object.keys(args)) {
    if (!(key in props)) {
      const known = Object.keys(props)
      return `unknown argument "${key}" (${tool} takes ${known.length ? known.join(', ') : 'no arguments'})`
    }
  }
  for (const key of required) {
    if (args[key] === undefined || args[key] === null) return `missing required argument "${key}"`
  }
  for (const [key, p] of Object.entries(props)) {
    const v = args[key]
    if (v === undefined) continue
    if (p.type === 'integer') {
      if (typeof v !== 'number' || !Number.isInteger(v)) {
        return `"${key}" must be an integer, got ${JSON.stringify(v)}`
      }
      if (p.minimum !== undefined && v < p.minimum) return `"${key}" must be ≥ ${p.minimum}, got ${v}`
      if (p.maximum !== undefined && v > p.maximum) return `"${key}" must be ≤ ${p.maximum}, got ${v}`
    } else if (p.type === 'string') {
      if (typeof v !== 'string' || v === '') return `"${key}" must be a non-empty string, got ${JSON.stringify(v)}`
    }
  }
  if (typeof args.repo === 'string' && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(args.repo)) {
    return `"repo" must be owner/name, got ${JSON.stringify(args.repo)}`
  }
  return null
}

/** The repos `fleet-repo.sh list` prints (two-space-indented rows, repo first). */
export function parseRepoList(stdout: string): string[] {
  const out: string[] = []
  for (const line of stdout.split('\n')) {
    const m = /^ {2}(\S+\/\S+)\s/.exec(line)
    if (m?.[1] !== undefined) out.push(m[1])
  }
  return out
}

/** The install's bin/, from the plugin root (<install>/mod/fleet). */
export function binDir(root: string): string {
  const base = root.replace(/\/+$/, '').replace(/\/\.claude-plugin$/, '')
  return `${base}/../../bin`
}

/** The argv a validated call runs. */
export function commandFor(bin: string, tool: string, args: Record<string, unknown>): string[] {
  const repo = typeof args.repo === 'string' ? ['--repo', args.repo] : []
  if (tool === 'fleet_spawn') return [`${bin}/dash-issue-session.sh`, String(args.issue), ...repo]
  if (tool === 'fleet_await') {
    const t = typeof args.timeout === 'number' ? args.timeout : AWAIT_DEFAULT_S
    return [`${bin}/fleet-await.sh`, String(args.issue), '--timeout', String(t), ...repo]
  }
  return [`${bin}/fleet-children.sh`]
}

/** The script's own output, as the model reads it: exit code, stdout, stderr. */
export function report(argv: readonly string[], r: ProcessRunResult): string {
  const name = (argv[0] ?? '').replace(/^.*\//, '')
  const parts = [`exit ${r.exitCode} · ${name}`]
  if (r.stdout.trim() !== '') parts.push(r.stdout.replace(/\s+$/, ''))
  if (r.stderr.trim() !== '') parts.push(`[stderr]\n${r.stderr.replace(/\s+$/, '')}`)
  return parts.join('\n')
}

const TOOL_ARG_KEYS_RESERVED = new Set(['tool', 'tool_use_id', 'agentId', 'consent'])

function argsOf(e: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(e)) if (!TOOL_ARG_KEYS_RESERVED.has(k)) out[k] = v
  return out
}

/** Every tool this file serves, as the model calls it. */
const TOOL_RE = /^mcp__fleet__fleet_(status|spawn|await)$/

export function registerTools(on: On): void {
  on('tool.call', { tool: TOOL_RE }, async ($, e, next) => {
    const full = String(e.tool)
    const spec = TOOL_SPECS.find(t => `mcp__${PLUGIN}__${t.name}` === full)
    if (!isOpen() || spec === undefined) return next(e)
    try {
      const args = argsOf(e as unknown as Record<string, unknown>)
      const bad = checkArgs(spec.name, args)
      if (bad !== null) return { deny: `${full}: ${bad}. Nothing ran.` }
      const bin = binDir($.plugin.root)

      if (typeof args.repo === 'string') {
        const listed = await $.process.run([`${bin}/fleet-repo.sh`, 'list'], { timeoutMs: STATUS_TIMEOUT_MS })
        const repos = parseRepoList(listed.stdout)
        if (!repos.includes(args.repo)) {
          return {
            deny:
              `${full}: repo "${args.repo}" is not hosted by this fleet ` +
              `(hosted: ${repos.length ? repos.join(', ') : 'none could be read'}). Nothing ran.`,
          }
        }
      }

      const argv = commandFor(bin, spec.name, args)
      if (spec.name === 'fleet_status') {
        const pane = (await $.env.get('TMUX_PANE')) ?? ''
        const win =
          pane === ''
            ? null
            : await $.process.run(
                [
                  'tmux',
                  'display-message',
                  '-p',
                  '-t',
                  pane,
                  'window #{window_name} · issue=#{@issue} repo=#{@repo} state=#{@claude_state} lifecycle=#{@worker_lifecycle} origin=#{@origin}',
                ],
                { timeoutMs: STATUS_TIMEOUT_MS },
              )
        const kids = await $.process.run(argv, { timeoutMs: STATUS_TIMEOUT_MS })
        const repos = await $.process.run([`${bin}/fleet-repo.sh`, 'list'], { timeoutMs: STATUS_TIMEOUT_MS })
        const head = win === null ? 'window: (not in tmux)' : win.stdout.replace(/\s+$/, '')
        return { result: [head, report(argv, kids), repos.stdout.replace(/\s+$/, '')].join('\n\n') }
      }

      const timeoutMs =
        spec.name === 'fleet_await'
          ? Math.min(600_000, ((args.timeout as number | undefined) ?? AWAIT_DEFAULT_S) * 1000 + AWAIT_SLACK_MS)
          : SPAWN_TIMEOUT_MS
      const r = await $.process.run(argv, { timeoutMs })
      return { result: report(argv, r) }
    } catch (err) {
      // A script that cannot start or outlives its timeout: say so, never hang.
      return { result: `${full}: the run failed: ${err instanceof Error ? err.message : String(err)}` }
    }
  }).catch(($, e, next) => next(e))
}
