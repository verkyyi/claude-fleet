// Context + quota, reported by the session itself (issue #1338, EPIC #1334).
//
// The engine pushes `session.measure` after every main-thread turn and when a
// rate-limit window moves a whole point — rendered or not, watched or not. So a
// background window nobody looks at still reports, where conf/statusline.sh
// (the other writer of the same options) only writes when the status line
// redraws. Both write the SAME window options on the same scale; the newer
// write wins:
//
//   @ctx_pct @ctx_limit      the context fill (integer %) and window size
//                            (bin/fleet-context.sh, the auto-handoff nudge)
//   @rl5h @rl7d @rl_reset @rl_ts
//                            the account's 5h/7d % used, "<5h-reset> <7d-reset>"
//                            epoch seconds, and when (issue #1267: the quota
//                            watch merges them per @cc_account)
//   @rl_src mod              who stamped the @rl_* set; the status line unsets
//                            it, so absent = the status line (bin/usage-lib.sh)
//
// A fresh `mod` stamp on every pool account lets the quota watch skip its
// ccquota fetch for a tick (bin/fleet-quotawatch.sh). Rate limits are stamped
// only when BOTH windows have a reading — the watch reads a half stamp as none.

import type { EngineInterface, On, SessionMeasureInput } from 'claude-code'

import { isOpen } from './gate'
import { TMUX_TIMEOUT_MS, windowOptionsArgv } from './tmux'

/** ISO 8601 → epoch seconds as a string; `-` when absent or unreadable. */
function epoch(iso: string | undefined): string {
  const ms = iso === undefined ? NaN : Date.parse(iso)
  return Number.isFinite(ms) ? String(Math.floor(ms / 1000)) : '-'
}

/** The window options one measurement sets; empty when it carries nothing to say. */
export function usageOptions(e: Pick<SessionMeasureInput, 'context' | 'rateLimits'>, nowMs: number): Record<string, string> {
  const out: Record<string, string> = {}
  const { percent, window } = e.context
  if (percent !== undefined && Number.isFinite(percent)) {
    out['@ctx_pct'] = String(Math.round(percent))
    if (Number.isFinite(window) && window > 0) out['@ctx_limit'] = String(Math.floor(window))
  }
  const five = e.rateLimits.find(r => r.kind === 'five_hour')
  const seven = e.rateLimits.find(r => r.kind === 'seven_day')
  if (five !== undefined && seven !== undefined && Number.isFinite(five.percentUsed) && Number.isFinite(seven.percentUsed)) {
    out['@rl5h'] = String(Math.max(0, Math.floor(five.percentUsed)))
    out['@rl7d'] = String(Math.max(0, Math.floor(seven.percentUsed)))
    out['@rl_reset'] = `${epoch(five.resetsAt)} ${epoch(seven.resetsAt)}`
    out['@rl_ts'] = String(Math.floor(nowMs / 1000))
    out['@rl_src'] = 'mod'
  }
  return out
}

async function report($: EngineInterface, e: SessionMeasureInput): Promise<void> {
  const pane = await $.env.get('TMUX_PANE')
  if (pane === undefined || pane === '') return
  const argv = windowOptionsArgv(pane, usageOptions(e, await $.clock.now()))
  if (argv !== null) await $.process.run(argv, { timeoutMs: TMUX_TIMEOUT_MS })
}

export function registerUsage(on: On): void {
  on('session.measure', async ($, e, next) => {
    if (!isOpen()) return next(e)
    if (e.changed.includes('context') || e.changed.includes('rateLimits')) {
      try {
        await report($, e)
      } catch {
        // A missed report leaves the last one standing; the status line still writes.
      }
    }
    return next(e)
  }).catch(($, e, next) => next(e))
}
