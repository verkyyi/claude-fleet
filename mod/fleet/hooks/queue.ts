// What waits behind a busy orchestrator (issue #2617, EPIC #2615 C2).
//
// Whatever the person types while the orchestrator's turn runs is queued by the
// engine, and until now all they saw was one grey line under the prompt — no
// count, no idea when it would be read, so they said it again. This file counts
// it: a prompt typed by hand over a running turn (`prompt.submit` carrying that
// turn's id, not dropped by a hook beneath — /qd's `派：` prefix, the exit
// guard) is +1; it is back to 0 as soon as the engine folds the queue in, which
// is at the NEXT main-loop model request (`turn.step`: measured, the queued
// input joins the running turn once the current tool call ends — not at the
// turn's end), at a new `turn.start`, and at `turn.complete`.
//
// Two readers, one count:
// - the band above the prompt: progress.tsx draws 「排队 N 条 · 在忙 X（已 M 秒）·
//   /qd 直接派」 in the same AbovePrompt tree as the PR segment (one site, one
//   tree), plus a button that opens /qd; idle (no turn, nothing waits) a dim
//   「说一句即派 · /qd 或 ⌘T 快速派单」 there instead (issue #2753);
// - the window option `@orch_queue` (0 at the start, so a counting orchestrator
//   always says a number), which fleet-control-read.sh carries as the inventory's
//   `orchq=` and fleet-hub-sessions.sh as `orch_<sess>`'s 7th column — the
//   client's 「新任务」 row ends in 「排队 N」.
//
// Only the orchestrator's window (orchestrator.ts's start-up read): every hook
// here passes straight through anywhere else. The strings are qd.tsx's table
// (bin/fleet-ui-lang.sh's `orch_` keys ride the same dump).

import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'

import type { OrchQueue } from '../types'
import { byHand } from './exit-guard'
import { isOpen } from './gate'
import { isOrchestrator } from './orchestrator'
import { t } from './qd'
import { TMUX_TIMEOUT_MS, windowOptionsArgv } from './tmux'

export const QUEUE_OPTION = '@orch_queue'
/** How often the band's 「已 M 秒」 moves while something waits. */
export const TICK_MS = 1000

export const QUEUE_IDLE: OrchQueue = { n: 0, since: 0, what: '', now: 0 }
// progress.tsx spells the same `fleet/queue` atom to draw it (the state scan reads one per file).
const queue = atom({ plugin: 'fleet', key: 'queue' } as const, QUEUE_IDLE)

// Module state: a reload is a fresh module.
let ticker: Timer | undefined
let stamped: string | undefined

/** The band's line, '' when nothing waits. */
export function queueText(q: OrchQueue): string {
  if (q.n <= 0) return ''
  const secs = q.since > 0 && q.now >= q.since ? String(Math.floor((q.now - q.since) / 1000)) : '0'
  return t('orch_queue_fmt', String(q.n), q.what !== '' ? q.what : t('orch_queue_thinking'), secs)
}

/** The idle line (issue #2753): no turn running, nothing waits — say how to
 *  dispatch in one go (a line ↵ here, or /qd · ⌘T past the model); '' otherwise. */
export function idleText(q: OrchQueue): string {
  return q.n <= 0 && q.since === 0 ? t('orch_queue_idle') : ''
}

/** A submission that counts: typed by hand over a running turn, not /qd itself. */
export function counts(e: { turnId?: string; origin: Parameters<typeof byHand>[0]; text: string }): boolean {
  return e.turnId !== undefined && byHand(e.origin) && !/^\s*\/qd(\s|$)/.test(e.text)
}

/** Stamp `@orch_queue` on this pane's window — only when it changed. */
async function stamp($: EngineInterface, n: number): Promise<void> {
  const value = String(n)
  if (value === stamped) return
  const pane = await $.env.get('TMUX_PANE')
  if (pane === undefined || pane === '') return
  const argv = windowOptionsArgv(pane, { [QUEUE_OPTION]: value })
  if (argv === null) return
  try {
    const r = await $.process.run(argv, { timeoutMs: TMUX_TIMEOUT_MS })
    if (r.exitCode === 0) stamped = value
  } catch {
    // The next change writes it again.
  }
}

/** Back to 0: the engine took what waited (or the turn is over). */
async function clear($: EngineInterface, patch: Partial<OrchQueue> = {}): Promise<void> {
  ticker?.cancel()
  ticker = undefined
  const was = (await read($, queue)).n
  await update($, queue, v => ({ ...v, ...patch, n: 0 }))
  // Nothing waited: the window already says 0 (lifecycle.ts stamps it at the start).
  if (was > 0) await stamp($, 0)
}

/** Tests: forget the module's state. */
export function resetQueue(): void {
  ticker?.cancel()
  ticker = undefined
  stamped = undefined
}

export function registerQueue(on: On): void {
  on('prompt.submit', { origin: { kind: ['composer', 'bridge'] } }, async ($, e, next) => {
    if (!isOpen() || !isOrchestrator() || !counts(e)) return next(e)
    const result = await next(e)
    if ('drop' in result && result.drop !== undefined) return result
    const now = await $.clock.now()
    const q = await update($, queue, v => ({ ...v, n: v.n + 1, since: v.since > 0 ? v.since : now, now }))
    await stamp($, q.n)
    if (ticker === undefined) {
      ticker = $.clock.every(TICK_MS, () => {
        void (async () => {
          const at = await $.clock.now()
          await update($, queue, v => ({ ...v, now: at }))
        })().catch(() => undefined)
      })
    }
    return result
  }).catch(($, e, next) => next(e))

  on('turn.start', { turnId: /./ }, async ($, e, next) => {
    if (isOpen() && isOrchestrator()) await clear($, { since: await $.clock.now(), what: '' })
    return next(e)
  }).catch(($, e, next) => next(e))

  // A main-loop request about to go: what waited has just been folded into it.
  // Observe and pass, as usage.ts does: the clear runs beside the stream.
  on('turn.step', { index: /^\d+$/ }, async function* ($, e, next) {
    if (isOpen() && isOrchestrator() && e.agentId === undefined) {
      await (async () => {
        if ((await read($, queue)).n > 0) await clear($, { what: '' })
        else await update($, queue, v => (v.what === '' ? v : { ...v, what: '' }))
      })().catch(() => undefined)
    }
    return yield* next(e)
  }).catch(async function* ($, e, next) {
    return yield* next(e)
  })

  // What it is busy with: the main loop's tool call while it runs.
  on('tool.call', { tool: /./ }, async ($, e, next) => {
    if (!isOpen() || !isOrchestrator() || e.agentId !== undefined) return next(e)
    await update($, queue, v => ({ ...v, what: e.tool }))
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', { turnId: /./ }, async ($, e, next) => {
    if (isOpen() && isOrchestrator() && e.agentId === undefined) await clear($, { since: 0, what: '' })
    return next(e)
  }).catch(($, e, next) => next(e))
}
