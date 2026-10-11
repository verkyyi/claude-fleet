// The steward's patrol panel (issue #2834, EPIC #2831 C3): what the steward's
// last beat looked at, who is parked waiting for what, what it answered itself
// and what went by default, the health findings it follows, when the next beat
// is — read off the books in five seconds, without typing a word.
//
// The steward holder's window only (common.ts isHolder, and the panels on —
// panels.ts; the fleet-steward plugin's since #3115): every other window draws
// nothing and opens nothing. The view is panels.ts's `fleet-steward/panels`
// state, read on the books' change stamp; drawing it runs no process. Two
// buttons, only when pressed: 「到编排会话」 (bin/fleet-panel-jump.sh orchestrator
// — the one resolver, never a guess) and 「看决定单」 (`/sheet`: the decision
// sheet is in this same window now).
//
// Never opened unasked (the decision sheet is what opens by itself in this
// window, sheet.tsx): `/sheet p` opens it.

import { atom, read } from 'claude-code'
import type { EngineInterface, On } from 'claude-code'

import { PATROL_PANE, TMUX_TIMEOUT_MS, fleetBin, isHolder, t } from './common'
import { PATROL_ARG, SHEET_COMMAND, panelsOn } from './panels'
import type { Patrol, PanelsView } from './panels-model'

export { PATROL_PANE }
/** The steward's write budget a beat when FLEET_STEWARD_WRITES says nothing (bin/fleet_steward.py). */
export const WRITES_DEFAULT = 20

const panels = atom({ plugin: 'fleet-steward', key: 'panels' } as const, null as PanelsView | null)

/** Tests: nothing is kept between tests now (no unasked open). */
export function resetPatrol(): void {}

/** This window shows the patrol: the steward holder's, with the panels on. */
export function patrolHere(): boolean {
  return panelsOn() && isHolder()
}

/** The UTC offset an ISO time carries, in minutes (null: none). */
export function offsetOf(iso: string): number | null {
  if (/Z$/.test(iso)) return 0
  const m = /([+-])(\d\d):?(\d\d)$/.exec(iso)
  if (m === null) return null
  return (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]))
}

/** `MM-DD HH:MM` of an epoch second on the steward's clock (the beat's own offset). */
function stamp(sec: number, offset: number): string {
  return new Date((sec + offset * 60) * 1000).toISOString().slice(5, 16).replace('T', ' ')
}

/** `HH:MM` of an epoch second on the steward's clock, its date too when it is not `day` (`MM-DD`). */
export function clockOf(sec: number, offset: number, day = ''): string {
  if (sec <= 0) return '-'
  const s = stamp(sec, offset)
  return day === '' || s.slice(0, 5) === day ? s.slice(6) : s
}

export type PatrolSection = { id: string; head: string; lines: string[] }
export type PatrolModel = { title: string; changed: boolean; sections: PatrolSection[]; foot: string }

/** The patrol in text: the title, five sections, the footer. Pure. */
export function patrolModel(p: Patrol, writesCap: number): PatrolModel {
  const off = offsetOf(p.at) ?? 0
  const day = p.at.slice(5, 10)
  const at = p.at.length >= 16 ? p.at.slice(11, 16) : '-'
  const parked = p.parked.map(k => t('panel_patrol_parked_fmt',
    k.key || k.ref, k.wait.length > 0 ? k.wait.join(' · ') : '-', clockOf(k.at, off, day)))
  return {
    title: p.beat === 0 ? t('panel_patrol_none')
      : t('panel_patrol_title_fmt', String(p.beat), at, t(p.changed ? 'panel_patrol_changed' : 'panel_patrol_calm')),
    changed: p.changed,
    sections: [
      {
        id: 'seen',
        head: t('panel_patrol_seen'),
        lines: [
          t('panel_patrol_seen_fmt', String(p.drivers), String(p.openRows)),
          t('panel_patrol_delta_fmt', String(p.events), String(p.newAsks), String(p.closed)),
        ],
      },
      {
        id: 'park',
        head: t('panel_patrol_park_fmt', String(p.parked.length)),
        lines: parked.length > 0 ? parked : [t('panel_patrol_park_none')],
      },
      {
        id: 'answers',
        head: t('panel_patrol_answers'),
        lines: [t('panel_patrol_answers_fmt', String(p.bySteward), String(p.byDefault), String(p.groups))],
      },
      {
        id: 'health',
        head: t('panel_patrol_health_fmt', String(p.health)),
        lines: p.healthTop === '' ? [] : [p.healthTop],
      },
      {
        id: 'next',
        head: t('panel_patrol_next_fmt', clockOf(p.nextAt, off, day)),
        lines: [t('panel_patrol_night')],
      },
    ],
    foot: t('panel_patrol_foot_fmt', String(p.writes), String(writesCap), String(p.modelCalls), String(p.deferred)),
  }
}

async function run($: EngineInterface, argv: string[]): Promise<number> {
  try {
    return (await $.process.run(argv, { timeoutMs: TMUX_TIMEOUT_MS })).exitCode
  } catch {
    return 1
  }
}

/** 「到编排会话」: rc 1 / 2 is said, never guessed past. */
async function jump($: EngineInterface): Promise<void> {
  const rc = await run($, ['bash', `${fleetBin()}/fleet-panel-jump.sh`, 'orchestrator'])
  if (rc === 1) $.ui.toast(t('panel_patrol_jump_none'))
  else if (rc !== 0) $.ui.toast(t('panel_patrol_jump_ambiguous'))
}

/** 「看决定单」: the decision sheet — in this same window (`/sheet`). */
async function sheet($: EngineInterface): Promise<void> {
  await $.command.run({ command: SHEET_COMMAND, args: '' }).catch(() => undefined)
}

export function registerPatrol(on: On): void {
  // `/sheet p` in the holder's window opens the patrol (asked: placed from 110
  // columns, focused, Esc closes it) — or closes it when it is placed (issue
  // #2836: an open but unplaced pane is opened, never closed); anything else
  // goes on (bare /sheet is the decision sheet's, sheet.tsx).
  on('command.run', { command: SHEET_COMMAND }, async ($, e, next) => {
    if (!patrolHere() || !PATROL_ARG.test(e.args)) return next(e)
    if ((await $.ui.panes()).some(p => p.id === PATROL_PANE && p.isPlaced)) {
      await $.ui.close({ id: PATROL_PANE })
      return { text: t('panel_patrol_closed') }
    }
    const opened = await $.ui.open({ id: PATROL_PANE, title: t('panel_patrol_pane'), focus: true, closeOnEscape: true })
    return { text: opened.isPlaced ? t('panel_patrol_opened') : t('panel_patrol_waits') }
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PATROL_PANE }, async ($, e, next) => {
    const view = await read($, panels)
    if (!patrolHere()) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    if (view === null) return <Text dimColor>{t('panel_empty')}</Text>
    const cap = Number((await $.env.get('FLEET_STEWARD_WRITES')) ?? '') || WRITES_DEFAULT
    const m = patrolModel(view.patrol, cap)
    return (
      <Box key="patrol" flexDirection="column">
        <Text key="patrol-title" bold color={m.changed ? 'yellow' : 'green'} wrap="truncate-end">
          {m.title}
        </Text>
        {m.sections.map(s => (
          <Box key={`patrol-${s.id}`} flexDirection="column" marginTop={1}>
            <Text key={`patrol-${s.id}-head`} bold wrap="truncate-end">
              {s.head}
            </Text>
            {s.lines.map((line, i) => (
              <Text key={`patrol-${s.id}-${i}`} dimColor wrap="truncate-end">
                {line}
              </Text>
            ))}
          </Box>
        ))}
        <Box key="patrol-buttons" flexDirection="row" marginTop={1}>
          <Button key="patrol-orch" label={t('panel_patrol_to_orch')} hotkey="o" onPress={() => void jump($)} />
          <Button key="patrol-sheet" label={t('panel_patrol_to_sheet')} hotkey="s" onPress={() => void sheet($)} />
        </Box>
        <Text key="patrol-foot" dimColor wrap="truncate-end">
          {m.foot}
        </Text>
      </Box>
    )
  }).catch(($, e, next) => next(e))
}
