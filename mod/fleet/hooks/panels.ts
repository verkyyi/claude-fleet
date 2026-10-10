// The panels follow the books (issue #2835, EPIC #2831 C4): the base the three
// right-hand panels (the decision sheet, the batches, the steward's patrol) all
// stand on.
//
// Only in two windows: the orchestrator's and the steward's (windowRole(),
// orchestrator.ts). Any other window — a worker, a scratch, a driver — never
// starts them: no /sheet, no stat, byte for byte as before. FLEET_MOD_PANELS=0
// keeps them off everywhere.
//
// No polling of commands: lifecycle.ts's one-second inbox tick also calls
// panelsTick, which stats FOUR paths through `$.fs` — global/steward.stamp (the
// steward writes `<seq> <epoch_ms>` after every State.save()), the
// orchestrator's children ledger, global/epic-running.d/ and global/park.json —
// and re-reads the books only when one of them moved (mtime/size). A full read
// every PANELS_FULL_MS covers a writer that forgets the stamp (BREAK-IT
// `panel-stale`). Nothing here runs a process.
//
// `$` is never handed across an import (gate.ts), so lifecycle.ts binds a
// PanelsIo from its own `$` calls, and its `publish` stores the view in the
// `fleet/panels` state — every reader redraws on its own.
//
// Each read is timed (performance.now()) into $FLEET_CONF_DIR/logs/panel.ndjson
// (`refresh` rows, the last 200), and the first time a new sheet is drawn its
// 「写出→看见」 seconds (`seen`, from the sheet's own `at`); `/sheet --stats`
// prints p50 / p95 and the last five. The decision sheet's answers (sheet.tsx,
// issue #2832) are `answer` rows handed over through noteAnswer and written on
// the next tick; `/sheet --stats` prints their median presses. Rows of another
// kind in that file are kept as they are.

import { atom, read } from 'claude-code'
import type { CommandSpec, On } from 'claude-code'

import { isOpen } from './gate'
import { isOrchestrator } from './orchestrator'
import type { WindowRole } from './orchestrator'
import { foldPanels, percentile } from './panels-model'
import type { PanelsView } from '../types'
import type { PanelsText } from './panels-model'
import { t } from './qd'

/** The full read that covers a missed stamp (ms). */
export const PANELS_FULL_MS = 10_000
export const SHEET_COMMAND = 'sheet'
/** `/sheet b` (batches, 批次): the batches pane's own (batches.tsx, issue #2833) — passed on here. */
export const BATCHES_ARG = /^\s*(b|batches|批次)\s*$/
export const REFRESH_KEEP = 200
export const SEEN_KEEP = 50
export const ANSWER_KEEP = 100
/** The file's own cap, every kind counted. */
export const LOG_KEEP = 500

/** The `fleet/panels` state; lifecycle.ts writes it through its own copy (the engine scans each file). */
const panels = atom({ plugin: 'fleet', key: 'panels' } as const, null as PanelsView | null)

/** The `$` calls one tick needs, bound by lifecycle.ts. */
export type PanelsIo = {
  /** `mtimeMs:size`, or '-' when missing. */
  stat: (path: string) => Promise<string>
  /** A directory's file names ([] when missing). */
  list: (dir: string) => Promise<string[]>
  /** Rejects when missing. */
  read: (path: string) => Promise<string>
  write: (path: string, text: string) => Promise<void>
  /** Epoch ms. */
  now: () => Promise<number>
  publish: (view: PanelsView) => Promise<void>
}

export type PanelPaths = {
  stamp: string
  state: string
  delta: string
  marks: string
  park: string
  ledger: string
  log: string
}

export function panelPaths(confDir: string, session: string): PanelPaths {
  const c = confDir.replace(/\/+$/, '')
  return {
    stamp: `${c}/global/steward.stamp`,
    state: `${c}/global/steward.state.json`,
    delta: `${c}/global/steward.delta.json`,
    marks: `${c}/global/epic-running.d`,
    park: `${c}/global/park.json`,
    ledger: `${c}/fleets/${session}/children/orchestrator.ndjson`,
    log: `${c}/logs/panel.ndjson`,
  }
}

/** The four paths a tick stats — never more (共同约定 5). */
export function watched(p: PanelPaths): string[] {
  return [p.stamp, p.ledger, p.marks, p.park]
}

/** Do this window's panels run? Its role, the switch, and a fleet session to read. */
export function panelsWanted(role: WindowRole, flag: string | undefined, session: string | undefined): boolean {
  if (flag === '0') return false
  if (session === undefined || session === '') return false
  return role === 'orchestrator' || role === 'steward'
}

/** `$TMUX`'s socket label — the fleet session's name (#159). */
export function sessionOf(tmux: string | undefined): string | undefined {
  const sock = tmux?.split(',')[0]?.split('/').pop() ?? ''
  return sock === '' ? undefined : sock
}

/** `immediate`: it runs while a turn does, like /qd (issue #2836). */
export function sheetCommand(immediate = true): CommandSpec {
  const spec: CommandSpec = { name: SHEET_COMMAND, description: t('panel_cmd_desc') }
  return immediate ? { ...spec, immediate: true } : spec
}

// Module state: a reload is a fresh module, and session.start starts it again.
let paths: PanelPaths | undefined
let session = ''
let print = ''
let busy = false
let lastSheet = ''
let reads = 0
let logLoaded = false
let refreshRows: string[] = []
let seenRows: string[] = []
let answerRows: string[] = []
let lastFlush = 0
let dirty = false

/** lifecycle.ts: this window's panels run, reading these books (of this fleet session). */
export function startPanels(p: PanelPaths, sess = ''): void {
  paths = p
  session = sess
  print = ''
}

/** The fleet session the books are this window's (sheet.tsx's answers name it). */
export function currentSession(): string {
  return session
}

/** sheet.tsx: one answer sent — written to the log on the next tick. */
export function noteAnswer(row: { kind: 'answer'; ts: number; gid: string; how: string; presses: number; ms: number }): void {
  answerRows.push(JSON.stringify(row))
  dirty = true
}

export function stopPanels(): void {
  paths = undefined
}

export function panelsOn(): boolean {
  return paths !== undefined
}

export function currentPaths(): PanelPaths | undefined {
  return paths
}

/** Tests: forget everything. */
export function resetPanels(): void {
  paths = undefined
  session = ''
  print = ''
  busy = false
  lastSheet = ''
  reads = 0
  logLoaded = false
  refreshRows = []
  seenRows = []
  answerRows = []
  lastFlush = 0
  dirty = false
}

async function readOr(io: PanelsIo, path: string): Promise<string> {
  try {
    return await io.read(path)
  } catch {
    return ''
  }
}

async function readAll(io: PanelsIo, p: PanelPaths): Promise<PanelsText> {
  const names = (await io.list(p.marks).catch(() => [] as string[])).filter(n => !n.startsWith('.')).sort()
  const [state, delta, park, ledger, ...marks] = await Promise.all([
    readOr(io, p.state), readOr(io, p.delta), readOr(io, p.park), readOr(io, p.ledger),
    ...names.map(n => readOr(io, `${p.marks}/${n}`)),
  ])
  return {
    state: state ?? '', delta: delta ?? '', park: park ?? '', ledger: ledger ?? '',
    marks: names.map((name, i) => ({ name, text: marks[i] ?? '' })),
  }
}

function kindOf(line: string): string {
  try {
    const v = JSON.parse(line) as { kind?: unknown }
    return typeof v.kind === 'string' ? v.kind : ''
  } catch {
    return ''
  }
}

/**
 * Write the log: the other writers' rows as they are, then ours (the last
 * SEEN_KEEP `seen`, the last REFRESH_KEEP `refresh`), the file capped at LOG_KEEP.
 * The first flush takes the file's own rows of ours back, so a reload keeps them.
 */
async function flush(io: PanelsIo, p: PanelPaths): Promise<void> {
  const text = await readOr(io, p.log)
  const others: string[] = []
  const oldRefresh: string[] = []
  const oldSeen: string[] = []
  const oldAnswers: string[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    const k = kindOf(line)
    if (k === 'refresh') oldRefresh.push(line)
    else if (k === 'seen') oldSeen.push(line)
    else if (k === 'answer') oldAnswers.push(line)
    else others.push(line)
  }
  if (!logLoaded) {
    refreshRows = [...oldRefresh, ...refreshRows]
    seenRows = [...oldSeen, ...seenRows]
    answerRows = [...oldAnswers, ...answerRows]
    logLoaded = true
  }
  refreshRows = refreshRows.slice(-REFRESH_KEEP)
  seenRows = seenRows.slice(-SEEN_KEEP)
  answerRows = answerRows.slice(-ANSWER_KEEP)
  const ours = seenRows.length + refreshRows.length + answerRows.length
  const all = [...others.slice(-(LOG_KEEP - ours)), ...answerRows, ...seenRows, ...refreshRows]
  await io.write(p.log, `${all.join('\n')}\n`)
}

/**
 * One tick. Off (no panels here) does nothing at all; otherwise stat the four
 * paths and, when one moved — or `full` — read every book, publish the view and
 * log the time it took. Returns what it did.
 */
export async function panelsTick(io: PanelsIo, full = false): Promise<'off' | 'busy' | 'same' | 'read'> {
  const p = paths
  if (p === undefined) return 'off'
  if (busy) return 'busy'
  busy = true
  try {
    const t0 = performance.now()
    const now = watched(p)
    const fp = (await Promise.all(now.map(path => io.stat(path).catch(() => '-')))).join('|')
    if (!full && fp === print) {
      if (dirty) {
        dirty = false
        await flush(io, p).catch(() => undefined)
      }
      return 'same'
    }
    print = fp
    const src = await readAll(io, p)
    const at = await io.now()
    const view = foldPanels(src, at, 0)
    const ms = Math.round((performance.now() - t0) * 100) / 100
    view.ms = ms
    await io.publish(view)
    reads++
    refreshRows.push(JSON.stringify({ kind: 'refresh', ts: at, ms, why: full ? 'full' : 'stamp' }))
    // 「写出→看见」: a sheet this module has not drawn before, seen now. The first
    // read after a start finds an old sheet — that one is no measurement.
    const sheetKey = view.sheet === null ? '' : `${view.sheet.id}@${view.sheet.at}`
    let seen = false
    if (sheetKey !== lastSheet) {
      const wrote = view.sheet === null ? NaN : Date.parse(view.sheet.at)
      if (reads > 1 && view.sheet !== null && view.sheet.rows.length > 0 && Number.isFinite(wrote)) {
        seenRows.push(JSON.stringify({
          kind: 'seen', ts: at, sheet: view.sheet.id, at: wrote, s: Math.max(0, Math.round((at - wrote) / 100) / 10),
        }))
        seen = true
      }
      lastSheet = sheetKey
    }
    if (seen || dirty || at - lastFlush >= PANELS_FULL_MS) {
      lastFlush = at
      dirty = false
      await flush(io, p).catch(() => undefined)
    }
    return 'read'
  } finally {
    busy = false
  }
}

/** `/sheet --stats`: p50 / p95 of the refreshes, the last five 「写出→看见」. */
export function statsText(log: string): string {
  const ms: number[] = []
  const seen: number[] = []
  const presses: number[] = []
  for (const line of log.split('\n')) {
    if (line.trim() === '') continue
    try {
      const v = JSON.parse(line) as { kind?: unknown; ms?: unknown; s?: unknown; presses?: unknown }
      if (v.kind === 'refresh' && typeof v.ms === 'number') ms.push(v.ms)
      if (v.kind === 'seen' && typeof v.s === 'number') seen.push(v.s)
      if (v.kind === 'answer' && typeof v.presses === 'number') presses.push(v.presses)
    } catch {
      // A torn line is skipped.
    }
  }
  const last = ms.slice(-REFRESH_KEEP)
  const lines = [
    last.length === 0 ? t('panel_stats_none')
      : t('panel_stats_fmt', String(last.length), String(percentile(last, 50)), String(percentile(last, 95))),
    seen.length === 0 ? t('panel_seen_none')
      : t('panel_seen_fmt', String(Math.min(5, seen.length)), seen.slice(-5).join(' · ')),
    presses.length === 0 ? t('panel_answer_none')
      : t('panel_answer_stats_fmt', String(presses.length), String(percentile(presses, 50))),
  ]
  return lines.join('\n')
}

/** `/sheet --summary` (bare `/sheet` in the steward's window): one line of what the books say. */
export function summaryText(v: PanelsView | null): string {
  if (v === null) return t('panel_empty')
  const open = v.sheet?.rows.filter(r => r.state === 'open').length ?? 0
  const live = v.batches.filter(b => b.fresh).length
  return t('panel_summary_fmt', String(open), String(live), String(v.patrol.parked.length), v.patrol.at || '-')
}

export function registerPanels(on: On): void {
  on('command.run', { command: SHEET_COMMAND }, async ($, e, next) => {
    if (!isOpen() || paths === undefined || BATCHES_ARG.test(e.args)) return next(e)
    if (/(^|\s)--stats(\s|$)/.test(e.args)) {
      let log = ''
      try {
        log = await $.fs.read(paths.log)
      } catch {
        log = ''
      }
      return { text: statsText(log) }
    }
    // The orchestrator's bare /sheet opens / closes the decision sheet (sheet.tsx).
    // `--summary` is the one line of the books, anywhere.
    if (isOrchestrator() && !/(^|\s)--summary(\s|$)/.test(e.args)) return next(e)
    return { text: summaryText(await read($, panels)) }
  }).catch(($, e, next) => next(e))
}
