// The decision sheet, a pane on the orchestrator's right (issue #2832, EPIC #2831 C1).
//
// What the person has to decide, one line a thing: what · the suggestion · what
// happens if nobody answers · the deadline — and three buttons a line: 按建议
// (`y`), 翻案 / 我来答 (`f`, a one-line field, ↵ sends), 看原话 (`t`, the ticket
// opened on the person's own computer through fleet-open.sh). Open things on
// top; answered and defaulted ones dim at the bottom, a defaulted one marked
// 「已按默认」 + its time (never a never:* one — those are never defaulted).
//
// The lines are the steward's own `groups` (bin/fleet_decision.py group, kept in
// global/steward.state.json on every save): the panel never merges, sorts or
// judges a row itself (EPIC #2831 共同约定 4), so the sheet's text and the panel
// can never count differently. panels.ts reads the books; this file only draws
// `fleet/panels` and writes nothing but its own state.
//
// An answer waits UNDO_MS in 「已答 · 撤回」 (`u` takes it back), then runs the ONE
// write road, `fleet-steward-tick.sh answer --row <id> --text <t> --by person`,
// once per row id of the group (a merged group = each of its ids, the same
// words). A failure puts the line back as it was and toasts the reason. Each
// answer sent is one `answer` row in logs/panel.ndjson (panels.ts writes the
// file): `{kind:'answer', ts, gid, how, presses, ms}` — `/sheet --stats` prints
// the median presses.
//
// Only the orchestrator's window draws it: the first band drawn on a fullscreen
// terminal opens it unasked, once (the engine seats that from 144 columns; the
// main screen would set it inline over the prompt — no), bare `/sheet` opens it
// (asked, so it is placed down to 110 columns) or closes it, and the window's
// `@sheet_pane` says 1 while it is up — the steward then sends one sentence
// instead of the whole table; never opened, no option, the whole sheet as
// before. Any other window: no pane, no `/sheet` handling here.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'

import type { PanelsView, SheetGroup, SheetPending, SheetUi } from '../types'
import { isOpen } from './gate'
import { isOrchestrator } from './orchestrator'
import { SHEET_COMMAND, currentSession, noteAnswer, panelsOn } from './panels'
import { t } from './qd'
import { TMUX_TIMEOUT_MS, windowOptionsArgv } from './tmux'
import { binDir } from './tools'

export const SHEET_PANE = 'fleet-sheet'
export const SHEET_OPTION = '@sheet_pane'
/** How long an answer can be taken back before it is sent. */
export const UNDO_MS = 10_000
/** fleet-steward-tick.sh answer posts one comment; its own timeouts are 60 s. */
export const ANSWER_TIMEOUT_MS = 90_000
export const OPEN_TIMEOUT_MS = 20_000

export const SHEET_IDLE: SheetUi = { pending: {}, editing: '', expanded: '', sending: [], presses: {} }

const panels = atom({ plugin: 'fleet', key: 'panels' } as const, null as PanelsView | null)
const sheet = atom({ plugin: 'fleet', key: 'sheet' } as const, SHEET_IDLE)

// The undo timers: a module's, so a reload re-arms them from the state (session.start).
const timers = new Map<string, Timer>()
// A reload is a fresh module, and opens the pane once again.
let autoOpened = false

/** Tests: forget the unasked open. */
export function resetSheet(): void {
  autoOpened = false
}

/** The write road for one row: the steward's own `answer`. */
export function answerArgv(root: string, session: string, id: string, text: string): string[] {
  const argv = ['bash', `${binDir(root)}/fleet-steward-tick.sh`, 'answer', '--row', id, '--text', text, '--by', 'person']
  return session === '' ? argv : [...argv, '--session', session]
}

/** Tests: is this argv an answer? */
export function isAnswerRun(argv: readonly string[]): boolean {
  return (argv[1] ?? '').endsWith('/fleet-steward-tick.sh') && argv[2] === 'answer'
}

export function openArgv(root: string, url: string): string[] {
  return ['bash', `${binDir(root)}/fleet-open.sh`, url]
}

/** `HH:MM` out of an ISO time ('' when there is none). */
export function hhmm(iso: string): string {
  return /T(\d\d:\d\d)/.exec(iso)?.[1] ?? ''
}

/** The dim line under a closed group: 已按默认 + its time, else 已答（by）+ the answer. */
export function closedText(g: SheetGroup): string {
  if (g.state === 'defaulted' && !g.never) return t('panel_sheet_defaulted_fmt', hhmm(g.closedAt) || hhmm(g.due))
  return t('panel_sheet_answered_fmt', g.by || '—', g.answer)
}

/** The facts line of an open group: suggestion · default · deadline. */
export function factsText(g: SheetGroup): string {
  const parts = [
    ...(g.suggest !== '' ? [t('panel_sheet_suggest_fmt', g.suggest)] : []),
    t('panel_sheet_default_fmt', g.default),
    ...(g.dueShow !== '' && g.dueShow !== '—' ? [t('panel_sheet_due_fmt', g.dueShow)] : []),
  ]
  return parts.join(' · ')
}

/** The groups split as drawn: open (the steward's order) on top, closed under them. */
export function splitGroups(groups: readonly SheetGroup[], s: SheetUi): { open: SheetGroup[]; closed: SheetGroup[] } {
  const open: SheetGroup[] = []
  const closed: SheetGroup[] = []
  for (const g of groups) (g.state === 'open' ? open : closed).push(g)
  return { open, closed: closed.filter(g => !(g.gid in s.pending)) }
}

async function setPaneOption($: EngineInterface, up: boolean | null): Promise<void> {
  const pane = await $.env.get('TMUX_PANE')
  if (pane === undefined || pane === '') return
  const argv = windowOptionsArgv(pane, { [SHEET_OPTION]: up === null ? null : up ? '1' : '0' })
  if (argv !== null) await $.process.run(argv, { timeoutMs: TMUX_TIMEOUT_MS }).catch(() => undefined)
}

function bump(s: SheetUi, gid: string): Record<string, number> {
  return { ...s.presses, [gid]: (s.presses[gid] ?? 0) + 1 }
}

function arm($: EngineInterface, gid: string, wait: number): void {
  timers.get(gid)?.cancel()
  timers.set(gid, $.clock.after(Math.max(0, wait), () => {
    void fire($, gid).catch(() => undefined)
  }))
}

/** A press that answers: into 「已答 · 撤回」 for UNDO_MS. */
async function answer($: EngineInterface, g: SheetGroup, how: 'take' | 'turn', text: string): Promise<void> {
  const words = text.trim()
  if (words === '') return
  const at = await $.clock.now()
  const s = await read($, sheet)
  if (g.gid in s.pending || s.sending.includes(g.gid)) return
  const presses = bump(s, g.gid)
  const p: SheetPending = { ids: g.ids, text: words, how, at, presses: presses[g.gid] ?? 1 }
  await update($, sheet, v => ({ ...v, pending: { ...v.pending, [g.gid]: p }, editing: '', presses }))
  arm($, g.gid, UNDO_MS)
}

async function undo($: EngineInterface, gid: string): Promise<void> {
  timers.get(gid)?.cancel()
  timers.delete(gid)
  await update($, sheet, v => {
    const pending = { ...v.pending }
    delete pending[gid]
    return { ...v, pending, presses: bump(v, gid) }
  })
}

/** The deadline passed: write the answer back, row by row; a failure puts the line back. */
async function fire($: EngineInterface, gid: string): Promise<void> {
  timers.delete(gid)
  const s = await read($, sheet)
  const p = s.pending[gid]
  if (p === undefined) return
  await update($, sheet, v => {
    const pending = { ...v.pending }
    delete pending[gid]
    return { ...v, pending, sending: [...v.sending.filter(x => x !== gid), gid] }
  })
  const t0 = await $.clock.now()
  let why = ''
  for (const id of p.ids) {
    try {
      const r = await $.process.run(answerArgv($.plugin.root, currentSession(), id, p.text), { timeoutMs: ANSWER_TIMEOUT_MS })
      if (r.exitCode !== 0) why = (r.stderr || r.stdout).trim() || `exit ${r.exitCode}`
    } catch (err) {
      why = err instanceof Error ? err.message : String(err)
    }
    if (why !== '') break
  }
  if (why !== '') {
    await update($, sheet, v => ({ ...v, sending: v.sending.filter(x => x !== gid) }))
    $.ui.toast(t('panel_sheet_failed_fmt', why))
    return
  }
  const done = await $.clock.now()
  noteAnswer({ kind: 'answer', ts: done, gid, how: p.how, presses: p.presses, ms: done - t0 })
  await update($, sheet, v => {
    const presses = { ...v.presses }
    delete presses[gid]
    return { ...v, presses }
  })
}

async function thread($: EngineInterface, g: SheetGroup): Promise<void> {
  await update($, sheet, v => ({ ...v, presses: bump(v, g.gid) }))
  const r = await $.process.run(openArgv($.plugin.root, g.url), { timeoutMs: OPEN_TIMEOUT_MS }).catch(() => null)
  if (r === null || r.exitCode > 2) $.ui.toast(t('panel_sheet_failed_fmt', g.url))
}

/** Bare `/sheet` in the orchestrator: open the pane (asked), or close one that is up. */
async function toggle($: EngineInterface): Promise<string> {
  const up = (await $.ui.panes()).find(p => p.id === SHEET_PANE)
  if (up?.isPlaced === true) {
    await $.ui.close({ id: SHEET_PANE })
    await setPaneOption($, false)
    return t('panel_sheet_closed')
  }
  const r = await $.ui.open({ id: SHEET_PANE, title: t('panel_sheet_title') })
  await setPaneOption($, r.isPlaced)
  return r.isPlaced ? t('panel_sheet_opened') : t('panel_sheet_waiting')
}

export function registerSheet(on: On): void {
  // A reload is a fresh module: re-arm what was pressed and not sent yet.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    const result = await next(e)
    if (!isOpen() || !isOrchestrator()) return result
    const s = await read($, sheet)
    const now = await $.clock.now()
    for (const [gid, p] of Object.entries(s.pending)) if (!timers.has(gid)) arm($, gid, p.at + UNDO_MS - now)
    return result
  }).catch(($, e, next) => next(e))

  on('command.run', { command: SHEET_COMMAND }, async ($, e, next) => {
    // bare /sheet only: `--stats` / `--summary` are panels.ts's, `batches` batches.tsx's
    if (!isOpen() || !isOrchestrator() || !panelsOn() || e.args.trim() !== '') return next(e)
    return { text: await toggle($) }
  }).catch(($, e, next) => next(e))

  // Unasked, once: the first band drawn on a fullscreen terminal opens it.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!autoOpened && isOpen() && isOrchestrator() && panelsOn() && e.viewport?.isFullscreen === true) {
      autoOpened = true
      void (async () => {
        const r = await $.ui.open({ id: SHEET_PANE, title: t('panel_sheet_title') })
        await setPaneOption($, r.isPlaced)
      })().catch(() => undefined)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  // The person's close mark: the steward sends the whole sheet again.
  on('ui.close', { id: SHEET_PANE }, async ($, e, next) => {
    const result = await next(e)
    if (isOpen() && e.origin.kind !== 'unload') await setPaneOption($, false)
    return result
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: SHEET_PANE }, async ($, e, next) => {
    // Read first: the reads subscribe this pane to both states.
    const view = await read($, panels)
    const s = await read($, sheet)
    if (!isOpen() || !isOrchestrator()) return next(e)
    const ui = $.ui.resolve(e)
    const { Box, Text, Button } = ui
    const groups = view?.groups ?? []
    const { open, closed } = splitGroups(groups, s)
    if (open.length === 0 && closed.length === 0) {
      return <Text dimColor>{view === null ? t('panel_empty') : t('panel_sheet_empty')}</Text>
    }
    // The hotkeys sit on ONE line at a time (two would clash): the first still to answer, the first to undo.
    const lead = open.find(g => !(g.gid in s.pending) && !s.sending.includes(g.gid))?.gid ?? ''
    const undoLead = open.find(g => g.gid in s.pending)?.gid ?? ''
    const field = 'Input' in ui ? ui.Input : undefined
    const line = (g: SheetGroup, n: number) => {
      const p = s.pending[g.gid]
      const sending = s.sending.includes(g.gid)
      const hot = g.gid === lead
      return (
        <Box key={`g:${g.gid}`} flexDirection="column" marginBottom={1}>
          <Text key={`item:${g.gid}`} bold>{`${n}. ${g.item}`}</Text>
          <Text key={`facts:${g.gid}`} dimColor>{factsText(g)}</Text>
          {g.from !== '' && <Text key={`from:${g.gid}`} dimColor>{g.from}</Text>}
          {p !== undefined && (
            <Box key={`pending:${g.gid}`} flexDirection="row" gap={1}>
              <Text key={`pending-text:${g.gid}`} color="green">{t('panel_sheet_pending_fmt', p.text)}</Text>
              <Button
                key={`undo:${g.gid}`}
                label={t('panel_sheet_undo')}
                {...(g.gid === undoLead ? { hotkey: 'u' } : {})}
                onPress={() => undo($, g.gid)}
              />
            </Box>
          )}
          {p === undefined && sending && <Text key={`sending:${g.gid}`} dimColor>{t('panel_sheet_sending')}</Text>}
          {p === undefined && !sending && (
            <Box key={`buttons:${g.gid}`} flexDirection="row" gap={1}>
              {g.suggest !== '' && (
                <Button
                  key={`take:${g.gid}`}
                  label={t('panel_sheet_take')}
                  variant="primary"
                  {...(hot ? { hotkey: 'y' } : {})}
                  onPress={() => answer($, g, 'take', g.suggest)}
                />
              )}
              <Button
                key={`turn:${g.gid}`}
                label={g.suggest !== '' ? t('panel_sheet_overturn') : t('panel_sheet_own')}
                {...(hot ? { hotkey: 'f' } : {})}
                onPress={() => update($, sheet, v => ({ ...v, editing: v.editing === g.gid ? '' : g.gid, presses: bump(v, g.gid) }))}
              />
              {g.url !== '' && (
                <Button
                  key={`thread:${g.gid}`}
                  label={t('panel_sheet_thread')}
                  dimColor
                  {...(hot ? { hotkey: 't' } : {})}
                  onPress={() => thread($, g)}
                />
              )}
              {g.asks.length > 1 && (
                <Button
                  key={`asks:${g.gid}`}
                  label={t('panel_sheet_asks_fmt', String(g.asks.length))}
                  dimColor
                  onPress={() => update($, sheet, v => ({ ...v, expanded: v.expanded === g.gid ? '' : g.gid }))}
                />
              )}
            </Box>
          )}
          {p === undefined && !sending && s.editing === g.gid && field !== undefined && (() => {
            const Input = field
            return (
              <Input
                key={`input:${g.gid}`}
                label={t('panel_sheet_input')}
                placeholder={t('panel_sheet_placeholder')}
                submitLabel={t('panel_sheet_send')}
                autoFocus
                onSubmit={value => answer($, g, 'turn', value)}
              />
            )
          })()}
          {s.expanded === g.gid && g.asks.map(a => (
            <Text key={`ask:${a.id}`} dimColor wrap="wrap">{`· ${hhmm(a.asked)} ${a.item}`}</Text>
          ))}
        </Box>
      )
    }
    return (
      <Box key="fleet-sheet" flexDirection="column">
        {open.map((g, i) => line(g, i + 1))}
        {closed.map(g => (
          <Text key={`closed:${g.gid}`} dimColor wrap="truncate-end">{`✓ ${g.item} — ${closedText(g)}`}</Text>
        ))}
        {open.length > 0 && <Text key="hint" dimColor>{t('panel_sheet_hint')}</Text>}
      </Box>
    )
  }).catch(($, e, next) => next(e))
}
