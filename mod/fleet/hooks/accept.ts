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
//
// `idle.v2` (task HHV0, the session gate — bin/fleet_session_gate.py): the same
// slot and the same entry check, with no launch context (C8 retired it — a window
// is its ID) and no turn the caller must name. The fence is the conversation it
// was taken in: no main turn running at the precheck and at entry, no session.end
// (a /clear, a /resume) in between, no draft, before the deadline. A person's turn
// that ran and finished in between does not refuse it — the gate's words are a
// turn of their own after it, first come first in. `expected_turn`, when given,
// still pins the last finished turn.
//
// Stopped (the gate's 停止 is an Esc): the engine puts an interrupted prompt back
// in the box (verified on 2.1.295) — for the gate's own words that would be a
// "draft" nobody typed, refusing every later sentence. When a turn this module
// entered ends aborted, a box holding exactly its words is emptied; anything else
// in the box is the person's and stays (state.ts's turn.complete does it: one
// turn.complete hook a plugin).

import { atom, read } from 'claude-code'
import type { On, PromptSubmitResult } from 'claude-code'

import { isOpen } from './gate'
import { runtimeGen, runtimeIdle, runtimeIdleNow, runtimeLastTurn, runtimeTurnNow } from './state'

export const ACCEPT = 'idle.v1'
/** What a pane's `@mod_accept` says since task HHV0: the session gate's road. */
export const ACCEPT_V2 = 'idle.v2'
/** A submitted slot still unanswered this long past its deadline is unknown. */
export const ACCEPT_GRACE_S = 3
/** The receipt line's prefix in the hidden context. */
export const RECEIPT_PREFIX = 'fleet idle-accept receipt delivery_id='

export type AcceptRequest = {
  version: 1 | 2
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

type Slot = AcceptRequest & { phase: 'queued' | 'submitted' | 'entered'; receipt: string; gen: number; outcome?: AcceptOutcome }

/** Bumped by lifecycle.ts when a slot is queued; the band's redraw reads it. */
const acceptKick = atom({ plugin: 'fleet', key: 'acceptKick' } as const, 0)

// One slot per pane: the inbox runs one request at a time.
let slot: Slot | undefined
// The turns this module entered, by id → their words (a few, newest last).
const entered = new Map<string, string>()

/** state.ts's turn.complete: the words of a turn this module entered (once), else undefined. */
export function takeEntered(turnId: string): string | undefined {
  const t = entered.get(turnId)
  entered.delete(turnId)
  return t
}
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
  const version = request.accept === ACCEPT ? 1 : request.accept === ACCEPT_V2 ? 2 : 0
  if (version === 0) return { error: 'unsupported accept' }
  if (version === 1) {
    let launch: Record<string, unknown> | undefined
    try { launch = context ? JSON.parse(context) as Record<string, unknown> : undefined } catch { launch = undefined }
    const expected = request.launch as Record<string, unknown> | undefined
    if (!isOpen() || !launch || !expected || typeof expected !== 'object'
        || Object.keys(launch).length !== Object.keys(expected).length
        || !Object.keys(launch).every(k => launch?.[k] === expected[k])) return { error: 'launch_changed' }
  } else if (!isOpen()) return { error: 'closed' }
  const { nonce, delivery_id: id, text, deadline } = request
  const turn = version === 2 && request.expected_turn === undefined ? '' : request.expected_turn
  if (typeof nonce !== 'string' || !/^[a-f0-9]{32}$/.test(nonce)
      || typeof id !== 'string' || !UUID.test(id)
      || typeof turn !== 'string' || (turn === '' && version === 1) || turn.length > 200
      || typeof text !== 'string' || text === '' || text.length > 65536
      || typeof deadline !== 'number' || !Number.isFinite(deadline)) return { error: 'invalid_request' }
  if (now >= deadline || deadline - now > 30) return { error: 'expired' }
  return { version, nonce, delivery_id: id, expected_turn: turn, text, deadline }
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
  if (!(r.version === 2 ? runtimeIdleNow(r.expected_turn) : runtimeIdle(r.expected_turn))) {
    return outcome(r, 'rejected', 'precheck_not_idle')
  }
  // v2: the turn it follows is whichever finished last ('' before any) — the
  // entered turn is told apart from it, and it is the receipt's previous_turn_id
  const anchor = r.version === 2 ? runtimeLastTurn() : r.expected_turn
  slot = { ...r, expected_turn: anchor, phase: 'queued', receipt: receiptPath(inbox, r.delivery_id), gen: runtimeGen() }
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
  if (s.version === 2 && s.gen !== runtimeGen()) return 'session_changed'
  if (!(s.version === 2 ? runtimeIdleNow() : runtimeIdle(s.expected_turn))) return 'not_idle_at_entry'
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
      if (o.turn_id) {
        entered.set(o.turn_id, s.text)
        if (entered.size > 8) entered.delete(entered.keys().next().value as string)
      }
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
