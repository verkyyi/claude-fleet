// The batches pane (issue #2833, EPIC #2831 C2): where every batch stands, who is
// parked, what is left for the person — without asking anyone. Only looks and
// jumps; the sidebar stays the navigator (共同约定 1). The fleet-steward plugin's
// since #3115 (EPIC #3111 C4), drawn in the steward holder's window only.
//
// Two parts, one Pane (`fleet-batches`):
//   在跑的批次  a row per epic-running.d mark — `landed/members` bar, 在做 (live)
//              · 待合 (inflight), 停着 (park.json by origin), 「心跳 HH:MM（N 分钟前）」,
//              yellow 「心跳停了」 past its ttl; a driver the book names with no mark
//              but the ledger has going: 「没写心跳 · 进度读不到」; a batch closed
//              today: one grey line. 「到驱动」 on each row with a driver key.
//   待你动手    the steward's open `todo.items` (kind mark · what · due), 「看」
//              opens its source on the person's own computer (fleet-open.sh).
//
// The data is panels.ts's view (`fleet-steward/panels`, batches-model.ts folds
// it), so a redraw runs nothing; a process starts only on a press — 「到驱动」
// runs bin/fleet-panel-jump.sh <key> (fleet_win_for_key; NOTFOUND / AMBIGUOUS
// toast, never a guess), 「看」 bin/fleet-open.sh <url>.
//
// Never opened unasked: `/sheet b` opens it. No holder here ⇒ nothing opens,
// every hook passes through.

import { atom, read } from 'claude-code'
import type { EngineInterface, On } from 'claude-code'

import type { PanelsView } from '../types'
import { bar, beatClock, EMPTY_BOARD, todoIcon } from './batches-model'
import { BATCHES_PANE, fleetBin, isHolder, t } from './common'
import { BATCHES_ARG, panelsOn, SHEET_COMMAND } from './panels'

export { BATCHES_PANE }
export const JUMP_TIMEOUT_MS = 10_000

const panels = atom({ plugin: 'fleet-steward', key: 'panels' } as const, null as PanelsView | null)

// Module state: a reload is a fresh module.
let asked = false

/** Tests: forget the asked open. */
export function resetBatches(): void {
  asked = false
}

/** Does this window carry the batches pane? The steward holder's, with its panels running. */
export function batchesWanted(): boolean {
  return isHolder() && panelsOn()
}

export function jumpArgv(bin: string, key: string, pane: string): string[] {
  return ['bash', `${bin}/fleet-panel-jump.sh`, key, ...(pane !== '' ? ['--pane', pane] : [])]
}

export function openArgv(bin: string, url: string): string[] {
  return ['bash', `${bin}/fleet-open.sh`, url]
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
  const r = await $.process.run(jumpArgv(fleetBin(), key, pane), { timeoutMs: JUMP_TIMEOUT_MS })
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
  on('command.run', { command: SHEET_COMMAND }, async ($, e, next) => {
    if (!batchesWanted() || !BATCHES_ARG.test(e.args)) return next(e)
    asked = true
    const placed = await openBatches($)
    return { text: t(placed ? 'panel_batches_opened' : 'panel_batches_unplaced') }
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: BATCHES_PANE }, async ($, e, next) => {
    // Read first: the read subscribes the pane to both states.
    const view = await read($, panels)
    if (!batchesWanted()) return next(e)
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
                  void $.process.run(openArgv(fleetBin(), i.url), { timeoutMs: JUMP_TIMEOUT_MS }).catch(() => undefined)
                }}
              />
            )}
          </Box>
        ))}
      </Box>
    )
  }).catch(($, e, next) => next(e))
}
