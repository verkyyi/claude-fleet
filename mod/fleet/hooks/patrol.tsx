// The steward's patrol panel (issue #2834, EPIC #2831 C3): what the steward's
// last beat looked at, who is parked waiting for what, what it answered itself
// and what went by default, the health findings it follows, when the next beat
// is — read off the books in five seconds, without typing a word.
//
// The steward's window only (windowRole() === 'steward', and the panels on —
// panels.ts): every other window draws nothing and opens nothing. The view is
// panels.ts's `fleet/panels` state, read on the books' change stamp; drawing it
// runs no process. Two buttons run one each, only when pressed: 「到编排会话」
// (bin/fleet-panel-jump.sh orchestrator — the one resolver, never a guess) and
// 「看决定单」 (the steward page, opened on the person's computer by
// bin/fleet-open.sh; no page yet ⇒ the orchestrator's window, where the sheet is).
//
// Opened unasked once, from the first band drawn on a fullscreen terminal (the
// engine seats it from 144 columns); `/sheet` in this window opens it asked.

import { atom, read } from 'claude-code'
import type { EngineInterface, On } from 'claude-code'

import { isOpen } from './gate'
import { windowRole } from './orchestrator'
import { panelsOn } from './panels'
import type { Patrol, PanelsView } from './panels-model'
import { t } from './qd'
import { binDir } from './tools'
import { TMUX_TIMEOUT_MS } from './tmux'

export const PATROL_PANE = 'fleet-patrol'
/** The steward's write budget a beat when FLEET_STEWARD_WRITES says nothing (bin/fleet_steward.py). */
export const WRITES_DEFAULT = 20

const panels = atom({ plugin: 'fleet', key: 'panels' } as const, null as PanelsView | null)

// Module state: a reload is a fresh module, and opens the pane once again.
let autoOpened = false

/** Tests: forget the unasked open. */
export function resetPatrol(): void {
  autoOpened = false
}

/** This window shows the patrol: the steward's, with the panels on. */
export function patrolHere(): boolean {
  return isOpen() && panelsOn() && windowRole() === 'steward'
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
  const rc = await run($, ['bash', `${binDir($.plugin.root)}/fleet-panel-jump.sh`, 'orchestrator'])
  if (rc === 1) $.ui.toast(t('panel_patrol_jump_none'))
  else if (rc !== 0) $.ui.toast(t('panel_patrol_jump_ambiguous'))
}

/** 「看决定单」: the steward page on the person's computer; none yet ⇒ the orchestrator, where the sheet is. */
async function sheet($: EngineInterface, page: string): Promise<void> {
  if (page === '') return jump($)
  if ((await run($, ['bash', `${binDir($.plugin.root)}/fleet-open.sh`, page])) !== 0) $.ui.toast(page)
}

async function openPatrol($: EngineInterface) {
  return $.ui.open({ id: PATROL_PANE, title: t('panel_patrol_pane') })
}

export function registerPatrol(on: On): void {
  // /sheet in the steward's window opens the patrol (asked: placed at any width);
  // `--stats` / `--summary`, and every other window, go on to panels.ts.
  on('command.run', { command: 'sheet' }, async ($, e, next) => {
    if (!patrolHere() || /(^|\s)--(stats|summary)(\s|$)/.test(e.args)) return next(e)
    const opened = await openPatrol($)
    autoOpened = true
    return { text: opened.isPlaced ? t('panel_patrol_opened') : t('panel_patrol_waits') }
  }).catch(($, e, next) => next(e))

  // Unasked, once: the first band drawn on a fullscreen terminal opens it (the
  // main screen would seat it inline above the prompt — no).
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!autoOpened && patrolHere() && e.viewport?.isFullscreen === true) {
      autoOpened = true
      void openPatrol($).catch(() => undefined)
    }
    return next(e)
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
          <Button key="patrol-sheet" label={t('panel_patrol_to_sheet')} hotkey="s" onPress={() => void sheet($, view.patrol.page)} />
        </Box>
        <Text key="patrol-foot" dimColor wrap="truncate-end">
          {m.foot}
        </Text>
      </Box>
    )
  }).catch(($, e, next) => next(e))
}
