// The panels' pure half (issue #2835, EPIC #2831 C4): text in, view model out.
// No `$` here — panels.ts says when to read, lifecycle.ts does the reading.
//
// Sources, every one a book someone else writes (the panels only read):
//   - global/steward.state.json   the steward's state: the sheet, its rows, the
//                                 beat, the card, the to-do count, the parked list
//   - global/steward.delta.json   what the last beat saw
//   - global/epic-running.d/*     one `key: value` mark per running EPIC batch
//   - global/park.json            the park book (bin/fleet_park.py)
//   - fleets/<sess>/children/orchestrator.ndjson   the orchestrator's children
// A source that is missing or torn just leaves its part empty.

import { parseLedger } from './progress-model'

export type { Batch, PanelsView, Parked, Patrol, QueueRow, Sheet, SheetRow, Todo } from '../types'
import type { Batch, PanelsView, Parked, Patrol, QueueRow, Sheet, SheetRow, Todo } from '../types'

type Obj = Record<string, unknown>

function json(text: string): Obj | null {
  try {
    const v = JSON.parse(text) as unknown
    return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : null
  } catch {
    return null
  }
}

const str = (v: unknown): string => (typeof v === 'string' ? v : '')
const num = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0)
const obj = (v: unknown): Obj => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : {})
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])

/**
 * Who closed a row: `by` as the steward wrote it (steward · person · default);
 * a row written before the field (#2834) is read off its state — defaulted ⇒
 * default, answered ⇒ person — and an open one is nobody's yet ('').
 */
export function rowBy(r: Obj): string {
  const by = str(r.by)
  if (by !== '') return by
  const st = str(r.state)
  return st === 'defaulted' ? 'default' : st === 'answered' ? 'person' : ''
}

/** The first sentence of a finding (its first line, cut at the first full stop), ≤ 80 chars. */
export function firstSentence(text: string): string {
  const line = (text.split('\n')[0] ?? '').trim()
  const m = /^(.*?[。！？]|.*?[.!?](?=\s|$))/.exec(line)
  const one = (m?.[1] ?? line).trim()
  return one.length > 80 ? `${one.slice(0, 79)}…` : one
}

function health(h: Obj): { n: number; top: string } {
  const active = obj(h.active)
  const issues = obj(h.issues)
  const keys = Object.keys(active)
  if (keys.length === 0) return { n: 0, top: '' }
  // newest by the issue it was filed on; else the last the steward noted
  const at = (k: string): string => str(obj(issues[k]).at)
  const newest = keys.reduce((a, k) => (at(k) > at(a) ? k : a), keys[keys.length - 1] as string)
  return { n: keys.length, top: firstSentence(str(obj(active[newest]).msg) || newest) }
}

function sheetRow(id: string, r: Obj): SheetRow {
  return {
    id,
    item: str(r.item),
    suggest: str(r.suggest),
    default: str(r.default),
    due: str(r.due),
    kind: str(r.kind),
    src: str(r.src),
    url: str(r.url),
    state: str(r.state),
    by: rowBy(r),
    asked: str(r.asked),
  }
}

function parked(v: unknown): Parked[] {
  return arr(v).map(o => {
    const p = obj(o)
    return { ref: str(p.ref), at: num(p.at), wait: arr(p.wait).map(str), key: str(p.key) }
  }).filter(p => p.ref !== '')
}

export const EMPTY_PATROL: Patrol = {
  beat: 0, at: '', changed: false, writes: 0, nextAt: 0, card: [], modelCalls: 0,
  parked: [], newAsks: 0, closed: 0, defaulted: 0,
  drivers: 0, openRows: 0, events: 0, bySteward: 0, byDefault: 0, groups: 0, health: 0, healthTop: '', deferred: 0, page: '',
}

export type StateView = { sheet: Sheet | null; todo: Todo; patrol: Patrol }

/** steward.state.json → the sheet (its rows in the sheet's order), the to-do count, the beat. */
export function parseState(text: string): StateView {
  const d = json(text)
  if (d === null) return { sheet: null, todo: { open: 0, desk: '' }, patrol: { ...EMPTY_PATROL } }
  const rows = obj(d.rows)
  const s = obj(d.sheet)
  const ids = arr(s.rows).map(str).filter(id => id !== '')
  const sheet: Sheet | null = str(s.id) === '' && ids.length === 0 ? null : {
    id: str(s.id),
    at: str(s.at),
    where: str(s.where),
    sent: s.sent === true,
    rows: ids.filter(id => id in rows).map(id => sheetRow(id, obj(rows[id]))),
  }
  const beat = obj(d.beat)
  // today = the beat's own local day (the steward writes on the person's clock)
  const today = str(beat.at).slice(0, 10)
  let bySteward = 0
  let byDefault = 0
  let openRows = 0
  for (const v of Object.values(rows)) {
    const r = obj(v)
    if (str(r.state) === 'open') openRows++
    if (today === '' || (str(r.closed_at) || str(r.asked)).slice(0, 10) !== today) continue
    const by = rowBy(r)
    if (by === 'steward') bySteward++
    else if (by === 'default') byDefault++
  }
  const open = sheet?.rows.filter(r => r.state === 'open') ?? []
  const groups = new Set(open.map(r => str(obj(rows[r.id]).group) || r.id)).size
  const hl = health(obj(d.health))
  return {
    sheet,
    todo: { open: num(d.todo_open), desk: str(obj(d.todo).desk) },
    patrol: {
      ...EMPTY_PATROL,
      beat: num(beat.n),
      at: str(beat.at),
      changed: beat.changed === true,
      writes: num(beat.writes),
      nextAt: num(d.next_at),
      card: arr(d.card).map(str),
      modelCalls: num(d.model_calls),
      parked: parked(d.parked),
      drivers: Object.keys(obj(d.drivers)).length,
      openRows,
      bySteward,
      byDefault,
      groups,
      health: hl.n,
      healthTop: hl.top,
      deferred: arr(d.deferred).length,
      page: str(obj(d.page).url),
    },
  }
}

export type DeltaView = { at: string; newAsks: number; closed: number; defaulted: number; events: number }

/** steward.delta.json → what the last beat saw, counted. */
export function parseDelta(text: string): DeltaView {
  const d = json(text) ?? {}
  return {
    at: str(d.at), newAsks: arr(d.new_asks).length, closed: arr(d.closed).length, defaulted: arr(d.defaulted).length,
    events: arr(d.events).length,
  }
}

/** One epic-running.d mark (`key: value` lines, bin/fleet-epic-heartbeat.sh) → a batch, or null. */
export function parseMark(text: string, nowSec: number): Batch | null {
  const kv: Record<string, string> = {}
  for (const line of text.split('\n')) {
    const m = /^([a-z_]+):\s*(.*)$/.exec(line.trim())
    if (m) kv[m[1] as string] = (m[2] as string).trim()
  }
  const int = (k: string): number | null => (/^\d+$/.test(kv[k] ?? '') ? Number(kv[k]) : null)
  const epic = int('epic')
  if (epic === null) return null
  const epoch = int('epoch') ?? 0
  const ttl = int('ttl') ?? 0
  return {
    repo: kv.repo ?? '',
    epic,
    tick: int('tick') ?? 0,
    landed: int('landed') ?? 0,
    members: int('members') ?? 0,
    live: int('live'),
    inflight: int('inflight'),
    epoch,
    ttl,
    fresh: epoch > 0 && nowSec - epoch <= ttl,
  }
}

/** Every mark → the batches, newest heartbeat first. */
export function parseMarks(marks: ReadonlyArray<{ name: string; text: string }>, nowSec: number): Batch[] {
  const out: Batch[] = []
  for (const m of marks) {
    if (m.name.startsWith('.')) continue
    const b = parseMark(m.text, nowSec)
    if (b !== null) out.push(b)
  }
  return out.sort((a, b) => b.epoch - a.epoch || a.epic - b.epic)
}

/** park.json → the parked sessions, oldest first (the steward's state carries the same list when the book is gone). */
export function parsePark(text: string): Parked[] {
  const d = json(text)
  if (d === null) return []
  const out: Parked[] = []
  for (const [ref, v] of Object.entries(obj(d.parked))) {
    const p = obj(v)
    out.push({ ref, at: num(p.at), wait: arr(p.wait).map(str), key: str(p.key) })
  }
  return out.sort((a, b) => a.at - b.at)
}

/** The orchestrator's children ledger → each child's last row, in ledger order. */
export function parseQueue(text: string): QueueRow[] {
  return [...parseLedger(text).values()].map(r => ({ child: r.child, state: r.state, verdict: r.verdict }))
}

export type PanelsText = {
  state: string
  delta: string
  marks: ReadonlyArray<{ name: string; text: string }>
  park: string
  ledger: string
}

/** Every source's text → the view. `at` is the read's epoch ms, `ms` how long it took. */
export function foldPanels(src: PanelsText, at: number, ms: number): PanelsView {
  const st = parseState(src.state)
  const delta = parseDelta(src.delta)
  const park = parsePark(src.park)
  return {
    sheet: st.sheet,
    batches: parseMarks(src.marks, Math.floor(at / 1000)),
    todo: st.todo,
    queue: parseQueue(src.ledger),
    patrol: {
      ...st.patrol,
      parked: src.park.trim() === '' ? st.patrol.parked : park,
      newAsks: delta.newAsks,
      closed: delta.closed,
      defaulted: delta.defaulted,
      events: delta.events,
    },
    at,
    ms,
  }
}

/** Nearest-rank percentile of `xs` (0 when empty). */
export function percentile(xs: readonly number[], p: number): number {
  if (xs.length === 0) return 0
  const s = [...xs].sort((a, b) => a - b)
  const i = Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))
  return s[i] as number
}
