// Conditional idle acceptance for a Claude session (issue #4618; Codex: #4617).
//
// fleet_runtime.accept_if_idle posts ONE request to the pane's inbox
// (inbox.ts, fixed slot `idle-accept.json`, a nonce like runtime.v1):
//
//   {"accept":"idle.v1","nonce":…,"launch":…,"delivery_id":…,
//    "expected_turn":…,"text":…,"deadline":…}
//
// and only an `accepted` answer carrying the turn that started is a delivery.
// What the engine gives (verified on 2.1.295, bin/fleet-idle-accept-claude-selftest.py):
//
//   - `$.prompt.submit` is a turn of its own once the session is idle, never
//     folded into a running one. Called while a turn runs, the prompt.submit
//     hooks run when it is dequeued, right before it enters — the entry boundary.
//   - a `prompt.submit` hook that answers `{ drop }` keeps it out: no turn, never
//     re-queued, and the call resolves `{ drop }`.
//   - while one prompt's chain runs, a person's Enter waits behind it.
//   - a `$` call made from a module TIMER skips every hook of this plugin, so the
//     submit is made from an engine frame instead: the inbox poll (a timer) bumps
//     an atom, and the band's redraw (`ui.render` AbovePrompt, raised by the
//     engine) makes the call, which this plugin's prompt.submit hook then sees.
//
// So: precheck in-process (lifecycle.ts), queue the slot, and at the entry
// boundary check again — this request's own prompt, the last finished turn is
// still `expected_turn` with no turn running and no session boundary since, the
// prompt box holds no draft, the deadline has not passed. Any miss ⇒ `{ drop }`
// ⇒ rejected. Passed ⇒ the receipt rides as hidden context
// (`fleet idle-accept receipt delivery_id=<id>`), readable again in the
// transcript after a disconnect, and the turn that starts is the receipt's.
// A prompt this module handed to the engine that matches no live slot (a late
// one, after its deadline) is dropped. Every other prompt passes untouched —
// the same `plugin:fleet` origin also stamps the prompt a markdown command or
// skill expands into when the inbox runs it with `$.command.run` (a handoff's
// `/fleet-handoff pickup`, issue #4865), so the origin alone never decides.

import { atom, read } from 'claude-code'
import type { On, PromptSubmitResult } from 'claude-code'

import { isOpen } from './gate'
import { runtimeIdle, runtimeTurnNow } from './state'

export const ACCEPT = 'idle.v1'
/** A submitted slot still unanswered this long past its deadline is unknown. */
export const ACCEPT_GRACE_S = 3
/** The receipt line's prefix in the hidden context. */
export const RECEIPT_PREFIX = 'fleet idle-accept receipt delivery_id='

export type AcceptRequest = {
  nonce: string
  delivery_id: string
  expected_turn: string
  text: string
  deadline: number
}

export type AcceptOutcome = {
  state: 'accepted' | 'rejected' | 'unknown'
  reason: string
  nonce: string
  delivery_id: string
  turn_id?: string
  previous_turn_id?: string
}

type Slot = AcceptRequest & { phase: 'queued' | 'submitted' | 'entered'; receipt: string; outcome?: AcceptOutcome }

/** Bumped by lifecycle.ts when a slot is queued; the band's redraw reads it. */
const acceptKick = atom({ plugin: 'fleet', key: 'acceptKick' } as const, 0)

// One slot per pane: the inbox runs one request at a time.
let slot: Slot | undefined
// Texts this module passed to `$.prompt.submit` whose call has not resolved yet:
// the only prompts the entry hook may claim (and drop).
const handed = new Map<string, number>()

function hand(text: string, d: 1 | -1): void {
  const n = (handed.get(text) ?? 0) + d
  if (n > 0) handed.set(text, n)
  else handed.delete(text)
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** A request's fields, or why it cannot run. `context` is FLEET_LAUNCH_CONTEXT. */
export function parseAccept(request: Record<string, unknown>, context: string | undefined, now: number): AcceptRequest | { error: string } {
  let launch: Record<string, unknown> | undefined
  try { launch = context ? JSON.parse(context) as Record<string, unknown> : undefined } catch { launch = undefined }
  const expected = request.launch as Record<string, unknown> | undefined
  if (request.accept !== ACCEPT) return { error: 'unsupported accept' }
  if (!isOpen() || !launch || !expected || typeof expected !== 'object'
      || Object.keys(launch).length !== Object.keys(expected).length
      || !Object.keys(launch).every(k => launch?.[k] === expected[k])) return { error: 'launch_changed' }
  const { nonce, delivery_id: id, expected_turn: turn, text, deadline } = request
  if (typeof nonce !== 'string' || !/^[a-f0-9]{32}$/.test(nonce)
      || typeof id !== 'string' || !UUID.test(id)
      || typeof turn !== 'string' || turn === '' || turn.length > 200
      || typeof text !== 'string' || text === '' || text.length > 65536
      || typeof deadline !== 'number' || !Number.isFinite(deadline)) return { error: 'invalid_request' }
  if (now >= deadline || deadline - now > 30) return { error: 'expired' }
  return { nonce, delivery_id: id, expected_turn: turn, text, deadline }
}

function outcome(r: AcceptRequest, state: AcceptOutcome['state'], reason: string, turn?: string): AcceptOutcome {
  return { state, reason, nonce: r.nonce, delivery_id: r.delivery_id,
    ...(turn ? { turn_id: turn, previous_turn_id: r.expected_turn } : {}) }
}

function settle(s: Slot, o: AcceptOutcome): void {
  if (s.outcome === undefined) s.outcome = o
}

/** The durable receipt beside the inbox, read again after a disconnect. */
export function receiptPath(inbox: string, id: string): string {
  return `${inbox}/idle-accept-${id}.receipt`
}

/** lifecycle.ts: refuse before anything is queued, or take the one slot. */
export function beginAccept(r: AcceptRequest, inbox: string): AcceptOutcome | undefined {
  if (slot !== undefined) return outcome(r, 'rejected', 'slot_busy')
  if (!runtimeIdle(r.expected_turn)) return outcome(r, 'rejected', 'precheck_not_idle')
  slot = { ...r, phase: 'queued', receipt: receiptPath(inbox, r.delivery_id) }
  return undefined
}

/** lifecycle.ts, each wait step: the slot's answer once there is one (and the slot freed). */
export function acceptOutcome(r: AcceptRequest, now: number): AcceptOutcome | undefined {
  const s = slot
  if (s === undefined || s.nonce !== r.nonce) return outcome(r, 'unknown', 'slot_lost')
  let o = s.outcome
  // Never submitted by the deadline: nothing was handed to the engine.
  if (o === undefined && s.phase === 'queued' && now >= s.deadline) o = outcome(r, 'rejected', 'not_submitted')
  // Handed over and unanswered: a late arrival is dropped (no live slot).
  if (o === undefined && now >= s.deadline + ACCEPT_GRACE_S) o = outcome(r, 'unknown', 'entry_unanswered')
  if (o !== undefined) slot = undefined
  return o
}

/** session.end (lifecycle.ts): a queued slot never goes into the next conversation. */
export function acceptSessionEnded(): void {
  if (slot !== undefined && slot.phase === 'queued') settle(slot, outcome(slot, 'rejected', 'session_ended'))
}

/** Why this prompt may not enter now, or '' — synchronous, after every await. */
export function entryRefusal(s: Slot, draft: string, now: number): string {
  if (slot !== s) return 'slot_lost'
  if (now >= s.deadline) return 'deadline_passed'
  if (!runtimeIdle(s.expected_turn)) return 'not_idle_at_entry'
  if (draft.trim() !== '') return 'draft_present'
  return ''
}

/** This module's own submit: fleet's origin AND a text it handed over and is still waiting on. */
function ours(e: { text: string; origin?: { kind: string; name?: string } }): boolean {
  return e.origin?.kind === 'plugin' && e.origin.name === 'fleet' && handed.has(e.text)
}

export function registerAccept(on: On): void {
  // The engine frame that makes the call (see the header): one redraw per kick.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    await read($, acceptKick)
    const s = slot
    if (!isOpen() || s === undefined || s.phase !== 'queued') return next(e)
    s.phase = 'submitted'
    hand(s.text, 1)
    // Once the entry hook passed it on, that hook alone names the outcome.
    $.prompt.submit({ text: s.text, asUser: true }).then(
      (r: PromptSubmitResult) => {
        hand(s.text, -1)
        if (r.drop !== undefined) settle(s, outcome(s, 'rejected', 'dropped'))
        else if (s.phase !== 'entered') settle(s, outcome(s, 'unknown', 'entry_unreviewed'))
      },
      () => { hand(s.text, -1); if (s.phase !== 'entered') settle(s, outcome(s, 'unknown', 'submit_failed')) })
    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.submit', async ($, e, next) => {
    if (!isOpen() || !ours(e)) return next(e)
    const s = slot
    if (s === undefined || s.phase !== 'submitted' || s.text !== e.text || s.outcome !== undefined) {
      return { drop: 'fleet idle-accept: no live request' }
    }
    const draft = (await $.prompt.read()).text
    const now = (await $.clock.now()) / 1000
    const why = entryRefusal(s, draft, now)
    if (why !== '') {
      settle(s, outcome(s, 'rejected', why))
      return { drop: `fleet idle-accept: ${why}` }
    }
    s.phase = 'entered'
    const r = await next({ ...e, context: [...(e.context ?? []), RECEIPT_PREFIX + s.delivery_id] })
    if (r.drop !== undefined) {
      settle(s, outcome(s, 'rejected', 'dropped_beneath'))
      return r
    }
    // state.ts's turn.start hook names the turn that began with this prompt.
    let turn = runtimeTurnNow()
    for (let i = 0; i < 40 && (turn === undefined || turn === s.expected_turn); i++) {
      await $.clock.sleep(50)
      turn = runtimeTurnNow()
    }
    const o = turn !== undefined && turn !== s.expected_turn
      ? outcome(s, 'accepted', 'native_entry', turn)
      : outcome(s, 'unknown', 'turn_unobserved')
    if (o.state === 'accepted') {
      try {
        await $.fs.write(s.receipt, `${JSON.stringify({ ...o, nonce: undefined, accepted_at: (await $.clock.now()) / 1000 })}\n`)
      } catch {
        // The hidden-context line in the transcript still names the delivery.
      }
    }
    settle(s, o)
    return r
  }).catch(($, e, next) => (next.called ? next(e) : ours(e) ? { drop: 'fleet idle-accept: guard failed' } : next(e)))
}
