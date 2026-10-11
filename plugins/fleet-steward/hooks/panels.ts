// The panels follow the books (issue #2835, EPIC #2831 C4): the base the three
// right-hand panels (the decision sheet, the batches, the steward's patrol) all
// stand on. The fleet-steward plugin's since issue #3115 (EPIC #3111 C4): no
// plugin, no panels at all.
//
// Only in ONE window: the one holding the steward role (take_role steward,
// common.ts's isHolder). Every fleet window that binds no issue starts this
// module's one-second tick, which stats global/roles.held (one stat, no
// process) and reads it when it moved: the window that holds the role starts the
// panels, a window that dropped it (or had it stolen) stops them and closes its
// panes. A worker's window (it binds an issue) and a window outside tmux start
// nothing. FLEET_MOD_PANELS=0 keeps them off everywhere.
//
// No polling of commands: the same one-second tick calls panelsTick, which
// stats FOUR paths through `$.fs` — global/steward.stamp (the
// steward writes `<seq> <epoch_ms>` after every State.save()), the
// orchestrator's children ledger, global/epic-running.d/ and global/park.json —
// and re-reads the books only when one of them moved (mtime/size). A full read
// every PANELS_FULL_MS covers a writer that forgets the stamp (BREAK-IT
// `panel-stale`). Nothing here runs a process.
//
// `$` is never handed across an import (the engine follows it only within one
// file), so this file's session.start binds a PanelsIo from its own `$` calls,
// and its `publish` stores the view in the `fleet-steward/panels` state — every
// reader redraws on its own.
//
// Each read is timed (performance.now()) into $FLEET_CONF_DIR/logs/panel.ndjson
// (`refresh` rows, the last 200), and the first time a new sheet is drawn its
// 「写出→看见」 seconds (`seen`, from the sheet's own `at`); `/sheet --stats`
// prints p50 / p95 and the last five. The decision sheet's answers (sheet.tsx,
// issue #2832) are `answer` rows handed over through noteAnswer and written on
// the next tick; `/sheet --stats` prints their median presses. Rows of another
// kind in that file are kept as they are.

import { atom, read, update } from 'claude-code'
import type { CommandSpec, EngineInterface, On, Timer } from 'claude-code'

import {
  BATCHES_PANE, PATROL_PANE, SHEET_OPTION, SHEET_PANE, TMUX_TIMEOUT_MS, binDir, holdsSteward, isHolder, parseWindow,
  setBin, setHeld, stringsArgv, t, takeStrings, windowArgv, windowOptionsArgv,
} from './common'
import type { Self } from './common'
import { foldPanels, percentile } from './panels-model'
import type { PanelsView } from '../types'
import type { PanelsText } from './panels-model'

/** The full read that covers a missed stamp (ms). */
export const PANELS_FULL_MS = 10_000
/** The tick: roles.held, then the four books (ms). */
export const TICK_MS = 1_000
export const SHEET_COMMAND = 'sheet'
/** `/sheet b` (batches, 批次): the batches pane's own (batches.tsx, issue #2833) — passed on here. */
export const BATCHES_ARG = /^\s*(b|batches|批次)\s*$/
/** `/sheet p` (patrol, 巡查): the patrol pane's own (patrol.tsx) — passed on here. */
export const PATROL_ARG = /^\s*(p|patrol|巡查)\s*$/
export const REFRESH_KEEP = 200
export const SEEN_KEEP = 50
export const ANSWER_KEEP = 100
/** The file's own cap, every kind counted. */
export const LOG_KEEP = 500

/** The `fleet-steward/panels` state: written here, read by every pane. */
const panels = atom({ plugin: 'fleet-steward', key: 'panels' } as const, null as PanelsView | null)

/** The `$` calls one tick needs, bound by this file's session.start. */
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
  /** Who holds which role (bin/fleet-role-take.sh). */
  held: string
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
    held: `${c}/global/roles.held`,
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

/** May this window ever hold the panels? The switch, a fleet session to read, no bound issue. */
export function panelsWanted(self: Self, flag: string | undefined, session: string | undefined): boolean {
  if (flag === '0') return false
  if (session === undefined || session === '') return false
  return !/^\d+$/.test(self.issue)
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

/** The holder tick: this window's panels run, reading these books (of this fleet session). */
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

/** `/sheet --summary`: one line of what the books say. */
export function summaryText(v: PanelsView | null): string {
  if (v === null) return t('panel_empty')
  const open = v.sheet?.rows.filter(r => r.state === 'open').length ?? 0
  const live = v.batches.filter(b => b.fresh).length
  return t('panel_summary_fmt', String(open), String(live), String(v.patrol.parked.length), v.patrol.at || '-')
}

// ---- the window: who it is, whether it holds the role, the timers --------------

let pane: string | undefined
let self: Self = { wid: '', fid: '', issue: '' }
let watch: PanelPaths | undefined
let heldPrint = ''
let tickTimer: Timer | undefined
let fullTimer: Timer | undefined
let ticking = false

/** Tests: forget the window. */
export function resetWindow(): void {
  pane = undefined
  self = { wid: '', fid: '', issue: '' }
  watch = undefined
  heldPrint = ''
  tickTimer?.cancel()
  fullTimer?.cancel()
  tickTimer = undefined
  fullTimer = undefined
  ticking = false
}

function panelsIo($: EngineInterface): PanelsIo {
  return {
    stat: async path => {
      try {
        const st = await $.fs.stat(path)
        return `${st.mtimeMs}:${st.size}`
      } catch {
        return '-'
      }
    },
    list: async dir => (await $.fs.list(dir)).filter(f => f.kind === 'file').map(f => f.name),
    read: path => $.fs.read(path),
    write: (path, text) => $.fs.write(path, text),
    now: () => $.clock.now(),
    publish: async view => {
      await update($, panels, () => view)
    },
  }
}

async function setSheetOption($: EngineInterface, value: string | null): Promise<void> {
  if (pane === undefined) return
  const argv = windowOptionsArgv(pane, { [SHEET_OPTION]: value })
  if (argv !== null) await $.process.run(argv, { timeoutMs: TMUX_TIMEOUT_MS }).catch(() => undefined)
}

/** roles.held moved: read it; this window took the role ⇒ start, lost it ⇒ stop and close its panes. */
export async function holderTick($: EngineInterface): Promise<boolean> {
  const p = watch
  if (p === undefined) return false
  let print = '-'
  try {
    const st = await $.fs.stat(p.held)
    print = `${st.mtimeMs}:${st.size}`
  } catch {
    print = '-'
  }
  if (print === heldPrint) return isHolder()
  heldPrint = print
  let text = ''
  try {
    text = print === '-' ? '' : await $.fs.read(p.held)
  } catch {
    text = ''
  }
  const on = holdsSteward(text, self)
  if (on === isHolder()) return on
  setHeld(on)
  if (on) {
    startPanels(p, session || sessionFromPaths(p))
    await tickPanels($, true)
  } else {
    stopPanels()
    await update($, panels, () => null)
    for (const id of [SHEET_PANE, PATROL_PANE, BATCHES_PANE]) await $.ui.close({ id }).catch(() => undefined)
    await setSheetOption($, null)
  }
  return on
}

function sessionFromPaths(p: PanelPaths): string {
  return /\/fleets\/([^/]+)\/children\//.exec(p.ledger)?.[1] ?? ''
}

async function tickPanels($: EngineInterface, full = false): Promise<void> {
  if (!panelsOn()) return
  try {
    await panelsTick(panelsIo($), full)
  } catch {
    // The next tick reads again; a panel never holds up the session.
  }
}

async function tick($: EngineInterface): Promise<void> {
  if (ticking) return
  ticking = true
  try {
    if (await holderTick($)) await tickPanels($)
  } catch {
    // The next tick tries again.
  } finally {
    ticking = false
  }
}

export function registerPanels(on: On): void {
  // The one unmatched session.start of this plugin: one tmux read decides whether
  // this window may ever hold the role (a fleet pane binding no issue), then the
  // strings, /sheet, and the tick. Any failure costs the panels only.
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    try {
      const id = await $.env.get('TMUX_PANE')
      if (id === undefined || id === '') return result
      const sess = sessionOf(await $.env.get('TMUX'))
      const home = (await $.env.get('HOME')) ?? ''
      const conf = (await $.env.get('FLEET_CONF_DIR')) || `${home}/.config/claude-fleet`
      const dir = binDir(await $.env.get('FLEET_MCP_BIN'), home)
      setBin(dir)
      const r = await $.process.run(windowArgv(id), { timeoutMs: TMUX_TIMEOUT_MS })
      const me = parseWindow(r.exitCode === 0 ? r.stdout : '')
      if (r.exitCode !== 0 || !panelsWanted(me, await $.env.get('FLEET_MOD_PANELS'), sess)) return result
      pane = id
      self = me
      watch = panelPaths(conf, sess as string)
      session = sess as string
      heldPrint = ''
      try {
        const s = await $.process.run(stringsArgv(dir), { timeoutMs: TMUX_TIMEOUT_MS })
        if (s.exitCode === 0) takeStrings(s.stdout)
      } catch {
        // Every key shows itself.
      }
      try {
        await $.command.register(sheetCommand())
      } catch {
        // An engine without `immediate`: /sheet between turns; a refused name: none.
        await $.command.register(sheetCommand(false)).catch(() => undefined)
      }
      await tick($)
      tickTimer?.cancel()
      tickTimer = $.clock.every(TICK_MS, () => {
        void tick($)
      })
      fullTimer?.cancel()
      fullTimer = $.clock.every(PANELS_FULL_MS, () => {
        if (isHolder()) void tickPanels($, true)
      })
    } catch {
      // No panels in this window; the session goes on.
    }
    return result
  }).catch(($, e, next) => next(e))

  on('session.end', async ($, e, next) => {
    if (e.reason !== 'reload') {
      tickTimer?.cancel()
      fullTimer?.cancel()
      tickTimer = undefined
      fullTimer = undefined
      if (isHolder()) await setSheetOption($, null)
      stopPanels()
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('command.run', { command: SHEET_COMMAND }, async ($, e, next) => {
    if (watch === undefined) return next(e)
    // Nobody here holds the steward role: say so — nothing opens, nothing answers.
    if (!isHolder()) return { text: t('panel_not_holder') }
    if (paths === undefined || BATCHES_ARG.test(e.args) || PATROL_ARG.test(e.args)) return next(e)
    if (/(^|\s)--stats(\s|$)/.test(e.args)) {
      let log = ''
      try {
        log = await $.fs.read(paths.log)
      } catch {
        log = ''
      }
      return { text: statsText(log) }
    }
    // A bare /sheet opens / closes the decision sheet (sheet.tsx); `--summary` is
    // the one line of the books.
    if (!/(^|\s)--summary(\s|$)/.test(e.args)) return next(e)
    return { text: summaryText(await read($, panels)) }
  }).catch(($, e, next) => next(e))
}
