// The task-progress band above the prompt (issue #1339, EPIC #1334 C5).
//
// One segment: this issue's PR + checks (`PR #N ✓/✗!/…`, issue #1527). Task,
// EPIC, children and context % are the top-right corner's and the sidebar's,
// so the band no longer repeats them; a window with no PR — the hub, a
// scratch — draws nothing and the row takes no height. `!` means it needs you;
// no sleep durations — the same reading as the sidebar (#1328).
//
// Data: every PROGRESS_MS, ONE tmux call (this window's options + one
// list-windows of this fleet's own server) and `$.fs` reads of the dash's
// local caches. No network, no gh, no writes anywhere: the band only reads.
// A child newly at `!`, or this PR's checks turning red, toasts once; the
// alert re-arms when it clears.
//
// In the orchestrator's window the same band carries what waits behind its
// running turn (queue.ts, issue #2617): 「排队 N 条 · 在忙 X（已 M 秒）· /qd 直接派」
// in yellow above the PR line, with a button that opens /qd (qd.tsx).
//
// The refresh timer starts from this file's own session.start hook, past the
// version gate (`$` is followed only within one file, so it cannot start from
// lifecycle.ts's onReady, and a render hook is pure — no state writes). While
// the gate is shut nothing refreshes and the render hook passes through. A
// /clear keeps the module, so the timer goes on; a reload starts it afresh.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'

import type { ProgressSnapshot } from '../types'
import { isOpen } from './gate'
import { isOrchestrator } from './orchestrator'
import { QD_COMMAND, t } from './qd'
import { QUEUE_IDLE, idleText, queueText } from './queue'
import {
  children, newAlerts, parseLedger, parseTmux, PROGRESS_MS, prFor, segments, selfKey, slug, tmuxArgv,
} from './progress-model'
import { TMUX_TIMEOUT_MS } from './tmux'

const progress = atom({ plugin: 'fleet', key: 'progress' } as const, null as ProgressSnapshot | null)
const alerts = atom({ plugin: 'fleet', key: 'alerts' } as const, [] as string[])
/** queue.ts's count, drawn here: the same `fleet/queue` state (issue #2617). */
const queue = atom({ plugin: 'fleet', key: 'queue' } as const, QUEUE_IDLE)

// Module state: a reload is a fresh module, and session.start fires again.
let timer: Timer | undefined

async function readOr($: EngineInterface, path: string): Promise<string> {
  try {
    const text = await $.fs.read(path)
    return typeof text === 'string' ? text : ''
  } catch {
    return ''
  }
}

function join(dir: string, ...parts: string[]): string {
  return [dir.replace(/\/+$/, ''), ...parts].join('/')
}

/** Read the caches, fold them, store the snapshot, toast what is new. */
async function refreshProgress($: EngineInterface): Promise<void> {
  const pane = await $.env.get('TMUX_PANE')
  if (pane === undefined || pane === '') return
  const run = await $.process.run(tmuxArgv(pane), { timeoutMs: TMUX_TIMEOUT_MS })
  if (run.exitCode !== 0) return
  const { self, windows } = parseTmux(run.stdout)
  if (self === null) return

  // No TMPDIR: this login's own fallback, never the /tmp every login shares (#2442).
  let tmp = (await $.env.get('TMPDIR')) || ''
  if (tmp === '') {
    const id = await $.process.run(['id', '-u'], { timeoutMs: TMUX_TIMEOUT_MS })
    tmp = `/tmp/claude-fleet-${id.stdout.trim()}`
  }
  const dash = join(tmp, '.claude-dash', 'fleets')
  const home = (await $.env.get('HOME')) ?? ''
  const conf = (await $.env.get('FLEET_CONF_DIR')) || join(home, '.config', 'claude-fleet')
  const s = self.repo === '' ? '' : slug(self.repo)

  // Children: the ledger is keyed `<slug>:<key>` in a multi-repo fleet, bare otherwise.
  const key = selfKey(self)
  let ledgerText = ''
  if (key !== '') {
    const dir = join(conf, 'fleets', self.session, 'children')
    if (s !== '') ledgerText = await readOr($, join(dir, `${s}:${key}.ndjson`))
    if (ledgerText === '') ledgerText = await readOr($, join(dir, `${key}.ndjson`))
  }
  const kids = children(self, windows, parseLedger(ledgerText))

  const pr = self.issue !== null && s !== ''
    ? prFor(await readOr($, join(dash, s, 'prmap')), `issue-${self.issue}`)
    : null
  const snap: ProgressSnapshot = {
    issue: self.issue,
    pr,
    needsKids: kids.filter(k => k.glyph === '!').map(k => k.key),
  }
  await update($, progress, () => snap)
  const { toasts, keep } = newAlerts(await read($, alerts), snap)
  await update($, alerts, () => keep)
  for (const t of toasts) $.ui.toast(t)
}

export function registerProgress(on: On): void {
  // Matched on isInteractive: lifecycle.ts holds the plugin's one unmatched
  // session.start, and a band means nothing to a headless (`-p`) session.
  // `await next(e)` first, so lifecycle's gate has run whichever way the two
  // hooks nest.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    const result = await next(e)
    if (!isOpen()) return result
    const refresh = () => refreshProgress($).catch(() => undefined)
    timer?.cancel()
    timer = $.clock.every(PROGRESS_MS, () => {
      void refresh()
    })
    await refresh()
    return result
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // Read FIRST, every time: the read is what subscribes this band to the
    // snapshot, so a draw that passed early (gate shut, nothing read yet)
    // would otherwise never be redrawn when the first refresh lands.
    const snap = await read($, progress)
    const q = await read($, queue)
    if (!isOpen() || e.props.hasSurvey) return next(e)
    // The orchestrator's queue (queue.ts, issue #2617) shares this one site:
    // its yellow line on top, the PR segment under it — one tree, never two.
    const waiting = isOrchestrator() ? queueText(q) : ''
    // …and idle, how to dispatch in one go (issue #2753)
    const idle = isOrchestrator() && waiting === '' ? idleText(q) : ''
    const kept = snap === null ? [] : segments(snap)
    if (kept.length === 0 && waiting === '' && idle === '') return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    return (
      <Box key="fleet-band" flexDirection="column">
        {waiting !== '' && (
          <Box key="fleet-queue" flexDirection="row">
            <Text key="fleet-queue-text" color="yellow" wrap="truncate-end">
              {waiting}
            </Text>
            <Button
              key="fleet-queue-qd"
              label={t('orch_queue_qd')}
              dimColor
              onPress={() => {
                void $.command.run({ command: QD_COMMAND }).catch(() => undefined)
              }}
            />
          </Box>
        )}
        {idle !== '' && (
          <Box key="fleet-idle" flexDirection="row">
            <Text key="fleet-idle-text" dimColor wrap="truncate-end">
              {idle}
            </Text>
          </Box>
        )}
        {kept.length > 0 && (
          <Box key="fleet-progress" flexDirection="row">
            {kept.map(seg => (
              <Text key={seg.id} color={seg.color} wrap="truncate-end">
                {seg.text}
              </Text>
            ))}
          </Box>
        )}
      </Box>
    )
  }).catch(($, e, next) => next(e))
}
