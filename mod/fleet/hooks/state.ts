// The session reports its own state (issue #1336, EPIC #1334 C2).
//
// Until now `@claude_state` came from settings hooks (PreToolUse / PostToolUse /
// Stop / Notification) plus a screen classifier that read the pane with a model
// call to tell `done` from "waiting on you" and "a Loop is pending". The engine
// knows all three outright, so the mod says them as they happen:
//
//   turn.start              → working
//   turn.complete           → done, or `looping` when @loop says a Loop is pending
//   tool.call AskUserQuestion → needs/ask while the question is open, working after
//   tool.call ScheduleWakeup | CronCreate | CronDelete → @loop, after the call
//
// Every write goes through the fleet's own writers, never a tmux call of ours:
// bin/set-claude-state.sh (`--via mod`: the state write alone — the Stop hook keeps
// the auto-handoff / compaction / parent-report side of a clean stop) and
// bin/fleet_loop_mark.py's PostToolUse entry, fed the same payload the hook gets, so
// whichever of the two writers arrives first, @loop reads the same. The settings
// hooks are not removed: they still fire, and write the same values.
//
// (The screen classifier that stood down for a live mod retired with issue #2543.)
// Subagent turns and calls (`agentId`) are not this pane's state and are passed straight on.

import type { EngineInterface, On } from 'claude-code'

import { isOpen } from './gate'

/** How long one fleet-script write may take before it is abandoned. */
export const WRITE_TIMEOUT_MS = 10_000

const LOOP_TOOLS = new Set(['ScheduleWakeup', 'CronCreate', 'CronDelete'])

// Only accepted C3 executions publish observations. Old sessions keep their
// display hooks; missing turn/native identity means unknown to the reader.
let runtimeSequence = 0
let runtimeTurn: string | undefined
let runtimeObservation: { state: string; turn_id: string } | undefined
// A session.end (a /clear, a /resume) since the last turn: that turn's id no
// longer names the conversation a prompt would enter (accept.ts, #4618).
let runtimeBoundary = false

/** The last main turn finished as `expected` (idle), none runs, no session boundary since. */
export function runtimeIdle(expected: string): boolean {
  return runtimeTurn === undefined && !runtimeBoundary && runtimeObservation?.turn_id === expected
    && runtimeObservation.state === 'idle'
}

/** The main turn running now, as turn.start named it. */
export function runtimeTurnNow(): string | undefined {
  return runtimeTurn
}

/** lifecycle.ts session.end: no earlier turn is the one a prompt would follow. */
export function noteSessionBoundary(): void {
  runtimeBoundary = true
}

/** An on-demand reply from this native module, never a renewed disk cache. */
export function runtimeQuery(request: Record<string, unknown>, context: string | undefined, now: number): Record<string, unknown> {
  const launch = context ? JSON.parse(context) as Record<string, unknown> : undefined
  const expected = request.launch as Record<string, unknown> | undefined
  if (!isOpen() || !launch || !expected || typeof expected !== 'object'
      || Object.keys(launch).length !== Object.keys(expected).length
      || !Object.keys(launch).every(k => launch[k] === expected[k]) || !runtimeObservation
      || typeof request.nonce !== 'string' || !/^[a-f0-9]{32}$/.test(request.nonce)
      || typeof request.deadline !== 'number' || now >= request.deadline || request.deadline - now > 5) {
    throw new Error('runtime query unavailable or expired')
  }
  return { ...runtimeObservation, start: false, sequence: ++runtimeSequence,
    observed_at: now, query_id: request.nonce }
}

async function runtimeEvent($: EngineInterface, state: string, turn: string | undefined, start = false): Promise<void> {
  // Allocate at the native edge, before any await can reorder publishers.
  const sequence = ++runtimeSequence
  if (turn && (start || (runtimeObservation?.turn_id === turn
      && !['idle', 'interrupted'].includes(runtimeObservation.state)))) runtimeObservation = { state, turn_id: turn }
  try {
    if (!turn || !(await $.env.get('FLEET_LAUNCH_CONTEXT'))) return
    const bin = await fleetBin($)
    if (bin === undefined) return
    const payload = { state, turn_id: turn, start, sequence,
      observed_at: (await $.clock.now()) / 1000 }
    await $.process.run(['python3', `${bin}/fleet_runtime.py`, 'event'], {
      stdin: JSON.stringify(payload), timeoutMs: WRITE_TIMEOUT_MS,
    })
  } catch {
    // An absent/failed observation expires; it never authorizes an action.
  }
}

/** The fleet's bin/ beside this plugin (<install>/mod/fleet → <install>/bin), or
 * undefined outside tmux, where there is no window to write. */
async function fleetBin($: EngineInterface): Promise<string | undefined> {
  const pane = await $.env.get('TMUX_PANE')
  if (pane === undefined || pane === '') return undefined
  return `${$.plugin.root}/../../bin`
}

/** `set-claude-state.sh --via mod <verb>`; a failed write leaves the hooks' value.
 * `stdin`: the hook payload's shape, for a verb that reads one (`ask`'s question). */
async function setState($: EngineInterface, verb: 'working' | 'done' | 'ask', stdin = ''): Promise<void> {
  try {
    const bin = await fleetBin($)
    if (bin === undefined) return
    await $.process.run(['sh', `${bin}/set-claude-state.sh`, '--via', 'mod', verb], {
      stdin,
      timeoutMs: WRITE_TIMEOUT_MS,
    })
  } catch {
    // The settings hooks still write the same state; nothing to undo.
  }
}

/** Hand fleet_loop_mark.py the PostToolUse payload of a Loop tool call. */
async function markLoop($: EngineInterface, payload: Record<string, unknown>): Promise<void> {
  try {
    const bin = await fleetBin($)
    if (bin === undefined) return
    await $.process.run(['python3', `${bin}/fleet_loop_mark.py`, 'hook'], {
      stdin: JSON.stringify(payload),
      timeoutMs: WRITE_TIMEOUT_MS,
    })
  } catch {
    // The PostToolUse hook writes the same @loop.
  }
}

/** The tool's own arguments: the call's input minus the envelope keys. */
function toolInput(e: Record<string, unknown>): Record<string, unknown> {
  const { tool: _t, tool_use_id: _id, agentId: _a, consent: _c, ...rest } = e
  return rest
}

export function registerState(on: On): void {
  on('turn.start', async ($, e, next) => {
    if (isOpen()) {
      if ((e as { agentId?: string }).agentId === undefined) {
        runtimeTurn = e.turnId
        runtimeBoundary = false
        await runtimeEvent($, 'active', e.turnId, true)
      }
      await setState($, 'working')
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    // set-claude-state.sh's done branch turns this into `looping` when @loop (or a
    // loop ledger) says a Loop is pending — the one place that decides it.
    if (isOpen() && e.agentId === undefined) {
      await runtimeEvent($, e.isAborted || e.reason !== 'answer' ? 'interrupted' : 'idle', e.turnId)
      if (runtimeTurn === e.turnId) runtimeTurn = undefined
      await setState($, 'done')
    }
    return result
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (!isOpen() || e.agentId !== undefined) return next(e)
    const turn = runtimeTurn
    await runtimeEvent($, 'ask', turn)
    // The question's own words ride along (issue #1951): @claude_needs_detail.
    await setState($, 'ask', JSON.stringify({ tool_name: 'AskUserQuestion', tool_input: toolInput(e) }))
    try {
      return await next(e)
    } finally {
      await runtimeEvent($, 'active', turn)
      // Answered, declined or interrupted: the question is no longer open.
      await setState($, 'working')
    }
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    if (!isOpen() || e.agentId !== undefined || !LOOP_TOOLS.has(e.tool)) return next(e)
    const result = await next(e)
    if (result.deny === undefined && !result.isError) {
      await markLoop($, {
        tool_name: e.tool,
        tool_input: toolInput(e as unknown as Record<string, unknown>),
        tool_response: result.result,
      })
    }
    return result
  }).catch(($, e, next) => next(e))
}
