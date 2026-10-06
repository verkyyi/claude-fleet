// Context, quota, model and effort, reported by the session itself (issue #1338,
// EPIC #1334; model/effort + the bus feed, issue #1459).
//
// The engine pushes `session.measure` after every main-thread turn and when a
// rate-limit window moves a whole point — rendered or not, watched or not. So a
// background window nobody looks at still reports, where Claude Code's status
// line (conf/statusline.sh) only runs when the status line redraws — and once a
// login turns that status line OFF (`bin/fleet-statusline.sh off`, which gives the
// pane its bottom row back) this is the ONLY reporter.
//
// One writer: everything here goes through conf/statusline.sh itself, run as
//
//   bash <install>/conf/statusline.sh --from mod key=value …
//
// so the window options, their rounding and the @ctx_band thresholds are that
// one file's whoever feeds it — Claude Code's JSON or this mod's argv. The
// options it stamps for us:
//
//   @ctx_pct @ctx_limit @ctx_band  the context fill (integer %), window size and
//                                  the fleet's handoff band (fleet-context.sh, the
//                                  auto-handoff nudge, the pane header's colour)
//   @ctx_src mod                   this mod fed the bus at least once; the Claude
//                                  path never touches it, so a window keeps the
//                                  mark — fleet-statusline.sh counts them
//   @model @effort                 the model's display name and effort level (the
//                                  pane header; fleet-model-switch.sh verifies a
//                                  /model off @model, so it must flip without a
//                                  turn — hence the poll)
//   @rl5h @rl7d @rl_reset @rl_ts   the account's 5h/7d % used and resets (issue
//   @rl_src mod                    #1267; a fresh `mod` stamp lets the quota watch
//                                  skip its ccquota fetch, bin/fleet-quotawatch.sh)
//
// Three sources, one target:
//   session.measure  context + rate limits, when `changed` names either (here)
//   turn.step        the model id and effort of each main-thread model request,
//                    fed only when the pair changed — observe-and-pass, the
//                    stream is never held for the write (here)
//   a 2 s poll       `$.session.model()`, run by lifecycle.ts's onReady timer
//                    (the engine follows `$` only within one file), so a /model
//                    typed or posted lands on the bus within ~2 s and
//                    fleet-model-switch's 15 s verify reads it. It feeds the
//                    model alone — the script unsets @effort, and the next
//                    turn.step restores the new model's.
// The model dedup (`claimModelFeed`) is shared by the two model sources so a
// pair is fed once. Rate limits are stamped only when BOTH windows have a
// reading — the watch reads a half stamp as none; the script enforces that too.

import type { EngineInterface, On, SessionMeasureInput, TurnStepInput } from 'claude-code'

import { isOpen } from './gate'

/** One bash + awk + tmux chain; well under the hook's budget. */
export const STATUSLINE_TIMEOUT_MS = 10_000
/** How often lifecycle.ts re-reads the live model while nothing else reports it. */
export const MODEL_POLL_MS = 2_000

/** <install>/conf/statusline.sh from the plugin root (<install>/mod/fleet). */
export function statuslinePath(root: string): string {
  const base = root.replace(/\/+$/, '').replace(/\/\.claude-plugin$/, '')
  return `${base}/../../conf/statusline.sh`
}

/** The argv that feeds `fields` to the bus through the script. */
export function feedArgv(root: string, fields: readonly string[]): string[] {
  return ['bash', statuslinePath(root), '--from', 'mod', ...fields]
}

/**
 * Claude Code's display name for a model id, as its status line spells it:
 * `claude-opus-5-5` → `Opus 5.5`, `claude-haiku-4-5-20251001` → `Haiku 4.5`,
 * `claude-sonnet-4-6[1m]` → `Sonnet 4.6 (1M context)`. An id outside that
 * grammar (a Bedrock arn, an alias) is shown as it is — fleet-model-switch's
 * match is a case-insensitive substring either way.
 */
export function displayName(id: string): string {
  const raw = id.trim()
  const m = /^claude-([a-z]+)-(\d+)-(\d+)(?:-\d{6,})?(\[1m\])?$/i.exec(raw)
  if (m === null) return raw
  const family = m[1]!.charAt(0).toUpperCase() + m[1]!.slice(1).toLowerCase()
  return `${family} ${m[2]}.${m[3]}${m[4] ? ' (1M context)' : ''}`
}

/** ISO 8601 → epoch seconds as a string; `-` when absent or unreadable. */
function epoch(iso: string | undefined): string {
  const ms = iso === undefined ? NaN : Date.parse(iso)
  return Number.isFinite(ms) ? String(Math.floor(ms / 1000)) : '-'
}

/** The key=value fields one measurement feeds the bus; empty when it carries nothing to say. */
export function measureFields(e: Pick<SessionMeasureInput, 'context' | 'rateLimits'>): string[] {
  const out: string[] = []
  const { percent, window } = e.context
  if (percent !== undefined && Number.isFinite(percent)) {
    // Raw, to two decimals: the script rounds it (printf %.0f) as it rounds Claude's.
    out.push(`ctx_pct=${percent.toFixed(2)}`)
    if (Number.isFinite(window) && window > 0) out.push(`ctx_limit=${Math.floor(window)}`)
  }
  const five = e.rateLimits.find(r => r.kind === 'five_hour')
  const seven = e.rateLimits.find(r => r.kind === 'seven_day')
  if (five !== undefined && seven !== undefined && Number.isFinite(five.percentUsed) && Number.isFinite(seven.percentUsed)) {
    out.push(`rl5h=${Math.max(0, Math.floor(five.percentUsed))}`)
    out.push(`rl7d=${Math.max(0, Math.floor(seven.percentUsed))}`)
    out.push(`rl_reset5=${epoch(five.resetsAt)}`)
    out.push(`rl_reset7=${epoch(seven.resetsAt)}`)
  }
  return out
}

/** The key=value fields for a model (+ its effort; none ⇒ the script unsets @effort). */
export function modelFields(id: string, effort: string | number | undefined): string[] {
  const out = [`model=${displayName(id)}`]
  if (effort !== undefined && effort !== '') out.push(`effort=${effort}`)
  return out
}

// --- the model dedup, shared by turn.step (here) and the poll (lifecycle.ts) ---
// Module state: a reload is a fresh module and session.start fires again.
let fedModel: { id: string; effort: string } | undefined

/** Forget what was fed (session.start, or a feed that failed — the next source retries). */
export function resetModelFeed(): void {
  fedModel = undefined
}

/** True when `id` is not the model last fed (the poll's question). */
export function modelMoved(id: string): boolean {
  return id !== '' && fedModel?.id !== id
}

/**
 * Record (id, effort) as fed and return its fields — or null when that pair is
 * what the bus already has, or `id` is empty.
 */
export function claimModelFeed(id: string, effort: string | number | undefined): string[] | null {
  if (id === '') return null
  const eff = effort === undefined ? '' : String(effort)
  if (fedModel !== undefined && fedModel.id === id && fedModel.effort === eff) return null
  fedModel = { id, effort: eff }
  return modelFields(id, effort)
}

async function feed($: EngineInterface, fields: readonly string[]): Promise<void> {
  if (fields.length === 0) return
  const pane = await $.env.get('TMUX_PANE')
  if (pane === undefined || pane === '') return
  await $.process.run(feedArgv($.plugin.root, fields), { timeoutMs: STATUSLINE_TIMEOUT_MS })
}

async function feedStep($: EngineInterface, e: TurnStepInput): Promise<void> {
  const fields = claimModelFeed(e.model, e.effort)
  if (fields === null) return
  try {
    await feed($, fields)
  } catch {
    resetModelFeed()
  }
}

export function registerUsage(on: On): void {
  on('session.measure', async ($, e, next) => {
    if (!isOpen()) return next(e)
    if (e.changed.includes('context') || e.changed.includes('rateLimits')) {
      try {
        await feed($, measureFields(e))
      } catch {
        // A missed report leaves the last one standing; the next measurement writes.
      }
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.step', async function* ($, e, next) {
    // Observe and pass: the write runs beside the stream, never ahead of it.
    if (isOpen() && e.agentId === undefined) void feedStep($, e)
    return yield* next(e)
  }).catch(async function* ($, e, next) {
    return yield* next(e)
  })
}
