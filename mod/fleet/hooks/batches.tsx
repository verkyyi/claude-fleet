// The orchestrator's batches pane (issue #2833, EPIC #2831 C2): where every batch
// stands, who is parked, what is left for the person, what waits behind the
// turn — without asking the orchestrator. Only looks and jumps; the sidebar
// stays the navigator (共同约定 1).
//
// Three parts, one Pane (`fleet-batches`):
//   在跑的批次  a row per epic-running.d mark — `landed/members` bar, 在做 (live)
//              · 待合 (inflight), 停着 (park.json by origin), 「心跳 HH:MM（N 分钟前）」,
//              yellow 「心跳停了」 past its ttl; a driver the book names with no mark
//              but the ledger has going: 「没写心跳 · 进度读不到」; a batch closed
//              today: one grey line. 「到驱动」 on each row with a driver key.
//   待你动手    the steward's open `todo.items` (kind mark · what · due), 「看」
//              opens its source on the person's own computer (fleet-open.sh).
//   排队        queue.ts's `fleet/queue` count, with a /qd button.
//
// The data is panels.ts's view (`fleet/panels`, batches-model.ts folds it), so a
// redraw runs nothing; a process starts only on a press — 「到驱动」 runs
// bin/fleet-panel-jump.sh <key> (fleet_win_for_key; NOTFOUND / AMBIGUOUS toast,
// never a guess), 「看」 bin/fleet-open.sh <url>, /qd the command.
//
// Opened unasked at session.start in the orchestrator's window when its panels
// run (the engine places an unasked pane only from 144 columns); `/sheet batches`
// opens it asked. Seated inline (the main screen) after an unasked open it draws
// one hint line, never the whole board. No panels here ⇒ nothing opens, every
// hook passes through.

import { atom, read } from 'claude-code'
import type { EngineInterface, On } from 'claude-code'

import type { OrchQueue, PanelsView } from '../types'
import { bar, beatClock, EMPTY_BOARD, todoIcon } from './batches-model'
import { isOpen } from './gate'
import { isOrchestrator } from './orchestrator'
import { BATCHES_ARG, panelsOn, SHEET_COMMAND } from './panels'
import { QD_COMMAND, t } from './qd'
import { QUEUE_IDLE, queueText } from './queue'
import { binDir } from './tools'

export const BATCHES_PANE = 'fleet-batches'
export const JUMP_TIMEOUT_MS = 10_000

const panels = atom({ plugin: 'fleet', key: 'panels' } as const, null as PanelsView | null)
const queue = atom({ plugin: 'fleet', key: 'queue' } as const, QUEUE_IDLE)

// Module state: a reload is a fresh module.
let asked = false

/** Tests: forget the asked open. */
export function resetBatches(): void {
  asked = false
}

/** Does this window carry the batches pane? The orchestrator's, with its panels running. */
export function batchesWanted(): boolean {
  return isOpen() && isOrchestrator() && panelsOn()
}

export function jumpArgv(root: string, key: string, pane: string): string[] {
  return ['bash', `${binDir(root)}/fleet-panel-jump.sh`, key, ...(pane !== '' ? ['--pane', pane] : [])]
}

export function openArgv(root: string, url: string): string[] {
  return ['bash', `${binDir(root)}/fleet-open.sh`, url]
}

/** What a jump's exit code tells the person; '' when it switched. */
export function jumpToast(code: number): string {
  if (code === 0) return ''
  if (code === 1) return t('panel_batches_jump_notfound')
  if (code === 2) return t('panel_batches_jump_ambiguous')
  return t('panel_batches_jump_failed')
}

async function jump($: EngineInterface, key: string): Promise<void> {
  const pane = (await $.env.get('TMUX_PANE')) ?? ''
  const r = await $.process.run(jumpArgv($.plugin.root, key, pane), { timeoutMs: JUMP_TIMEOUT_MS })
  const msg = jumpToast(r.exitCode)
  if (msg !== '') $.ui.toast(msg)
}

async function openBatches($: EngineInterface): Promise<boolean> {
  const r = await $.ui.open({ id: BATCHES_PANE, title: t('panel_batches_title') })
  return r.isPlaced
}

/** A batch row's text, without the button. */
export function batchLine(b: PanelsView['board']['batches'][number], at: number): { text: string; stale: boolean } {
  const name = b.title !== '' ? `#${b.epic} ${b.title}` : `#${b.epic}`
  if (b.noMark) {
    const parked = b.parked > 0 ? ` · ${t('panel_batches_parked_fmt', String(b.parked))}` : ''
    return { text: `${name}  ${t('panel_batches_nomark')}${parked}`, stale: false }
  }
  const parts: string[] = []
  if (b.members > 0) parts.push(`${bar(b.landed, b.members)} ${t('panel_batches_landed_fmt', String(b.landed), String(b.members))}`)
  if (b.live !== null && b.inflight !== null) parts.push(t('panel_batches_live_fmt', String(b.live), String(b.inflight)))
  if (b.parked > 0) parts.push(t('panel_batches_parked_fmt', String(b.parked)))
  const { hhmm, mins } = beatClock(b.epoch, at)
  parts.push(t(b.fresh ? 'panel_batches_beat_fmt' : 'panel_batches_stale_fmt', hhmm, String(mins)))
  return { text: `${name}  ${parts.join(' · ')}`, stale: !b.fresh }
}

export function registerBatches(on: On): void {
  // Matched on isInteractive: lifecycle.ts holds the one unmatched session.start;
  // `await next(e)` first, so the gate, the role and the panels are settled.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    const result = await next(e)
    if (batchesWanted()) await openBatches($).catch(() => undefined)
    return result
  }).catch(($, e, next) => next(e))

  on('command.run', { command: SHEET_COMMAND }, async ($, e, next) => {
    if (!batchesWanted() || !BATCHES_ARG.test(e.args)) return next(e)
    asked = true
    const placed = await openBatches($)
    return { text: t(placed ? 'panel_batches_opened' : 'panel_batches_unplaced') }
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: BATCHES_PANE }, async ($, e, next) => {
    // Read first: the read subscribes the pane to both states.
    const view = await read($, panels)
    const q: OrchQueue = await read($, queue)
    if (!isOpen()) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    if (e.props.placement === 'inline' && !asked) {
      return (
        <Box key="fleet-batches" flexDirection="column">
          <Text key="fleet-batches-hint" dimColor wrap="truncate-end">{t('panel_batches_inline')}</Text>
        </Box>
      )
    }
    const board = view?.board ?? EMPTY_BOARD
    const at = view?.at ?? 0
    const waiting = queueText(q)
    return (
      <Box key="fleet-batches" flexDirection="column">
        <Text key="fleet-batches-h1" bold>{t('panel_batches_running')}</Text>
        {board.batches.length === 0 && board.done.length === 0 && (
          <Text key="fleet-batches-none" dimColor>{t('panel_batches_none')}</Text>
        )}
        {board.batches.map(b => {
          const line = batchLine(b, at)
          return (
            <Box key={`fleet-batch-${b.ref}`} flexDirection="row">
              <Text key={`fleet-batch-${b.ref}-text`} color={line.stale ? 'yellow' : undefined} wrap="truncate-end">
                {line.text}
              </Text>
              {b.driver !== '' && (
                <Button
                  key={`fleet-batch-${b.ref}-jump`}
                  label={t('panel_batches_jump')}
                  dimColor
                  onPress={() => {
                    void jump($, b.driver).catch(() => undefined)
                  }}
                />
              )}
            </Box>
          )
        })}
        {board.done.map(d => (
          <Box key={`fleet-done-${d.ref}`} flexDirection="row">
            <Text key={`fleet-done-${d.ref}-text`} dimColor wrap="truncate-end">
              {`${d.title !== '' ? `#${d.epic} ${d.title}` : `#${d.epic}`}  ${t('panel_batches_done')}`}
            </Text>
          </Box>
        ))}
        <Text key="fleet-batches-h2" bold>{t('panel_batches_todo')}</Text>
        {board.todo.length === 0 && (
          <Box key="fleet-todo-none" flexDirection="row">
            <Text key="fleet-todo-none-text" dimColor>{t('panel_batches_todo_none')}</Text>
          </Box>
        )}
        {board.todo.map(i => (
          <Box key={`fleet-todo-${i.id}`} flexDirection="row">
            <Text key={`fleet-todo-${i.id}-text`} wrap="truncate-end">
              {`${todoIcon(i.kind)} ${i.what}${i.due !== '' ? ` · ${t('panel_batches_due_fmt', i.due)}` : ''}`}
            </Text>
            {i.url !== '' && (
              <Button
                key={`fleet-todo-${i.id}-open`}
                label={t('panel_batches_open')}
                dimColor
                onPress={() => {
                  void $.process.run(openArgv($.plugin.root, i.url), { timeoutMs: JUMP_TIMEOUT_MS }).catch(() => undefined)
                }}
              />
            )}
          </Box>
        ))}
        <Text key="fleet-batches-h3" bold>{t('panel_batches_queue')}</Text>
        <Box key="fleet-batches-queue" flexDirection="row">
          <Text key="fleet-batches-queue-text" color={waiting !== '' ? 'yellow' : undefined} dimColor={waiting === ''} wrap="truncate-end">
            {waiting !== '' ? waiting : t('panel_batches_queue_none')}
          </Text>
          <Button
            key="fleet-batches-qd"
            label={t('panel_batches_qd')}
            dimColor
            onPress={() => {
              void $.command.run({ command: QD_COMMAND }).catch(() => undefined)
            }}
          />
        </Box>
      </Box>
    )
  }).catch(($, e, next) => next(e))
}
