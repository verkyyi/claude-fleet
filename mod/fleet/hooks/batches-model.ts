// The batches pane's pure half (issue #2833, EPIC #2831 C2): the books' text in,
// the pane's rows out. No `$` — panels.ts reads, panels-model.ts folds this in.
//
//   - a batch per epic-running.d mark (already parsed: panels-model parseMark),
//     its driver off steward.state.json `drivers[<repo#N>]` (`#<N>` too), its
//     parked count = park.json rows whose `origin` is that driver;
//   - a driver the book names with NO mark, whose last row in the orchestrator's
//     children ledger is not an ending (MERGED / REAPED / FAILED / STOPPED) and
//     whose EPIC the steward has not seen close: 「没写心跳 · 进度读不到」;
//   - the batches the steward saw close today (`todo.epics[ref].closed`, local
//     day), not running any more: one grey line each;
//   - 「待你动手」: `todo.items` not done / skipped, by due then id.

import type { Batch, Board, BoardBatch, BoardDone, BoardTodo } from '../types'
import { parseLedger } from './progress-model'

type Obj = Record<string, unknown>

const str = (v: unknown): string => (typeof v === 'string' ? v : '')
const num = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0)
const obj = (v: unknown): Obj => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : {})

function json(text: string): Obj {
  try {
    return obj(JSON.parse(text) as unknown)
  } catch {
    return {}
  }
}

/** Strip a `<slug>:` prefix (the ledger keys children bare). */
export function bareKey(key: string): string {
  const i = key.lastIndexOf(':')
  return i < 0 ? key : key.slice(i + 1)
}

/** A ledger state after which the driver is no longer going. */
const ENDED = new Set(['MERGED', 'REAPED', 'FAILED', 'STOPPED', 'CLOSED'])
/** followup.py's CLOSED. */
const TODO_CLOSED = new Set(['done', 'skipped'])

export const EMPTY_BOARD: Board = { batches: [], done: [], todo: [] }

/** `owner/name#N` / `#N` → [repo, N]; null when it is neither. */
export function splitRef(ref: string): [string, number] | null {
  const m = /^([^#\s]*)#(\d+)$/.exec(ref)
  return m === null ? null : [m[1] as string, Number(m[2])]
}

function sameDay(aMs: number, bMs: number): boolean {
  const a = new Date(aMs)
  const b = new Date(bMs)
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

export type BoardText = { state: string; park: string; ledger: string }

/** The marks (parsed) and the books' text → the pane's rows. `at` is the read's epoch ms. */
export function foldBoard(marks: readonly Batch[], src: BoardText, at: number): Board {
  const st = json(src.state)
  const drivers = obj(st.drivers)
  const driverOf = (repo: string, epic: number): string =>
    str(drivers[`${repo}#${epic}`]) || str(drivers[`#${epic}`])

  const parkedBy = new Map<string, number>()
  for (const v of Object.values(obj(json(src.park).parked))) {
    const o = bareKey(str(obj(v).origin))
    if (o !== '') parkedBy.set(o, (parkedBy.get(o) ?? 0) + 1)
  }
  const parkedFor = (driver: string): number => (driver === '' ? 0 : parkedBy.get(bareKey(driver)) ?? 0)

  const batches: BoardBatch[] = marks.map(b => {
    const ref = b.repo === '' || b.repo === '-' ? `#${b.epic}` : `${b.repo}#${b.epic}`
    const driver = driverOf(b.repo === '-' ? '' : b.repo, b.epic)
    return { ...b, ref, driver, parked: parkedFor(driver), noMark: false }
  })
  const marked = new Set(batches.map(b => b.ref))

  const todo = obj(st.todo)
  const epics = obj(todo.epics)
  const closedAt = (ref: string): number => num(obj(epics[ref]).closed)

  // A driver going with no mark (a loop that never stamps one).
  const last = parseLedger(src.ledger)
  for (const [ref, v] of Object.entries(drivers)) {
    const r = splitRef(ref)
    const driver = str(v)
    if (r === null || driver === '' || marked.has(ref)) continue
    const row = last.get(bareKey(driver))
    if (row === undefined || ENDED.has(row.state) || closedAt(ref) > 0) continue
    marked.add(ref)
    batches.push({
      repo: r[0], epic: r[1], tick: 0, landed: 0, members: 0, live: null, inflight: null, epoch: 0, ttl: 0,
      fresh: false, title: '', ref, driver, parked: parkedFor(driver), noMark: true,
    })
  }

  const done: BoardDone[] = []
  for (const ref of Object.keys(epics).sort()) {
    const c = closedAt(ref)
    const r = splitRef(ref)
    if (r === null || c <= 0 || marked.has(ref) || !sameDay(c * 1000, at)) continue
    done.push({ ref, epic: r[1], title: '' })
  }

  const items: BoardTodo[] = []
  for (const v of Object.values(obj(todo.items))) {
    const i = obj(v)
    if (TODO_CLOSED.has(str(i.state)) || str(i.what) === '') continue
    const srcs = Array.isArray(i.sources) ? i.sources : []
    items.push({ id: str(i.id), kind: str(i.kind), what: str(i.what), due: str(i.due), url: str(obj(srcs[0]).url) })
  }
  items.sort((a, b) => (a.due || '9').localeCompare(b.due || '9') || a.id.localeCompare(b.id))

  return { batches, done, todo: items }
}

/** `██████░░░░` — landed of members, `width` cells; '' when there is no count. */
export function bar(landed: number, members: number, width = 10): string {
  if (members <= 0) return ''
  const k = Math.max(0, Math.min(width, Math.round((landed / members) * width)))
  return '█'.repeat(k) + '░'.repeat(width - k)
}

/** `HH:MM` local, and whole minutes since, for a heartbeat epoch (s) seen at `at` (ms). */
export function beatClock(epochSec: number, at: number): { hhmm: string; mins: number } {
  const d = new Date(epochSec * 1000)
  const hhmm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
  return { hhmm, mins: Math.max(0, Math.floor((at - epochSec * 1000) / 60_000)) }
}

/** The kind's mark on a 「待你动手」 row (followup.py's KINDS). */
export function todoIcon(kind: string): string {
  return kind === 'stable' ? '⇪' : kind === 'hub-deploy' ? '☁' : '✋'
}
