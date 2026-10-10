// The session's lifecycle: the version gate and the heartbeat (issue #1335).
//
// The engine takes ONE unmatched `session.start` (and `session.end`) hook per
// plugin, and follows `$` only within the file it is spelled in — so start-up
// work for every feature lives in THIS file's start hook, behind the gate.
// A feature that needs to start something (a timer, a first write) adds it
// to `onReady` below; its other hooks live in its own file and start with
// `if (!isOpen()) return next(e)` (gate.ts).
//
// Gate: out of SUPPORTED (version.ts), nothing past the gate runs and the
// window says `@mod_state off:version`; in range, `@mod_state on`.
//
// Heartbeat: while the session lives, its window carries `@mod_alive <epoch
// seconds>`, rewritten every HEARTBEAT_MS. Bash reads it with `fleet_mod_alive
// <win>` (bin/fleet-lib.sh): fresh within 45s = the mod is here, take the new
// path; stale or missing = take today's path. The timer lives in the module,
// not the session: a /clear ends the session (`session.end`, reason `clear`)
// and fires no new `session.start`, but the module and its timers go on — so
// the beat survives a handoff's /clear. A real exit unsets it at once.
//
// Inbox (issue #1337): the same module also polls the pane's command inbox every
// INBOX_MS and runs what bash posted there with `$.command.run` (inbox.ts) — on a
// module timer for the same reason: the pickup a handoff posts right after its
// /clear must still be taken.
//
// Where (issue #1716): the same module reads bin/fleet-client-where.sh at the
// start and every WHERE_POLL_MS; where.ts puts the line in the context.
//
// Orchestrator (issue #2582): the same start reads the window's @fleet_role and,
// in the orchestrator's window, its role's text (@fleet_role_body, #2782);
// orchestrator.ts
// puts it in every request, so a /clear leaves the session its role.
//
// Quick dispatch (issue #2618): in the orchestrator's window the same start reads
// the `qd_` strings and registers `/qd` (qd.tsx); any other window has no /qd.
//
// Queue (issue #2617): in the orchestrator's window the same start stamps
// `@orch_queue 0` (queue.ts counts from there), and a real exit unsets it.
//
// Panels (issue #2835): in the orchestrator's and the steward's windows only,
// the same start registers /sheet and starts the panels (panels.ts): the inbox
// tick also stats the books' change marks and re-reads them when one moved, and
// a PANELS_FULL_MS timer reads them whole. Any other window stats nothing.
//
// Tools (issue #2057): a session the launcher gave no fleet tool service (no
// FLEET_MCP_SERVER=1 — launched before #1828) gets the mod's three fallback tools
// at the start, from the service's own specs (tools.ts); a served session gets
// none — status / spawn / await are the service's there.

import { atom, update } from 'claude-code'
import type { EngineInterface, On, Timer, ToolSpec } from 'claude-code'

import type { FleetModStatus, PanelsView } from '../types'
import { isOpen, openGate } from './gate'
import { INBOX_MS, inboxDir, pollInbox } from './inbox'
import { bodyArgv, isOrchestrator, roleArgv, rolePath, takeRole, windowRole } from './orchestrator'
import {
  PANELS_FULL_MS, panelPaths, panelsOn, panelsTick, panelsWanted, sessionOf, sheetCommand, startPanels,
  stopPanels,
} from './panels'
import type { PanelsIo } from './panels'
import { qdCommand, stringsArgv, takeStrings } from './qd'
import { QUEUE_OPTION } from './queue'
import type { InboxIo } from './inbox'
import { TMUX_TIMEOUT_MS, windowOptionsArgv } from './tmux'
import { SPEC_TIMEOUT_MS, binDir, fallbackSpecs, specArgv } from './tools'
import { MODEL_POLL_MS, STATUSLINE_TIMEOUT_MS, claimModelFeed, feedArgv, modelMoved, resetModelFeed } from './usage'
import { MOD_VERSION, isSupported } from './version'
import { WHERE_POLL_MS, WHERE_TIMEOUT_MS, takeWhere, whereArgv } from './where'

export const HEARTBEAT_MS = 15_000

/** Exits that end the process (a `clear` or `resume` keeps it beating). */
const EXITS = new Set(['prompt_input_exit', 'logout', 'other'])

const status = atom({ plugin: 'fleet', key: 'status' } as const, null as FleetModStatus | null)
/** panels.ts's view (issue #2835): written here, where `$` is. */
const panels = atom({ plugin: 'fleet', key: 'panels' } as const, null as PanelsView | null)

// Module state: a reload is a fresh module, and session.start fires again.
let timer: Timer | undefined
let inboxTimer: Timer | undefined
let modelTimer: Timer | undefined
let whereTimer: Timer | undefined
let panelsTimer: Timer | undefined
let whereBusy = false
let inboxBusy = false
let pane: string | undefined
let inbox: string | undefined

async function setOptions($: EngineInterface, options: Record<string, string | null>): Promise<void> {
  if (pane === undefined) return
  const argv = windowOptionsArgv(pane, options)
  if (argv !== null) await $.process.run(argv, { timeoutMs: TMUX_TIMEOUT_MS })
}

async function beat($: EngineInterface): Promise<void> {
  try {
    await setOptions($, { '@mod_alive': String(Math.floor((await $.clock.now()) / 1000)) })
  } catch {
    // A missed beat ages the option out; the bash side falls back on its own.
  }
}

function inboxIo($: EngineInterface): InboxIo {
  return {
    list: async dir => (await $.fs.list(dir)).filter(f => f.kind === 'file').map(f => f.name),
    read: path => $.fs.read(path),
    write: (path, text) => $.fs.write(path, text),
    claim: async (from, to) => {
      const r = await $.process.run(['mv', from, to], { timeoutMs: TMUX_TIMEOUT_MS })
      return r.exitCode === 0
    },
    run: async (command, args) => {
      await $.command.run({ command, args })
    },
  }
}

// The panels' reads (panels.ts): four stats a tick, the books only when one moved.
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

async function tickPanels($: EngineInterface, full = false): Promise<void> {
  if (!panelsOn()) return
  try {
    await panelsTick(panelsIo($), full)
  } catch {
    // The next tick reads again; a panel never holds up the session.
  }
}

// The model poll (usage.ts explains it; the timer and `$` live here because the
// engine follows `$` only within one file): when the live model is not the one
// last fed, feed it alone through conf/statusline.sh, so a `/model` with no turn
// yet still flips @model within MODEL_POLL_MS (fleet-model-switch's verify).
async function pollModel($: EngineInterface): Promise<void> {
  if (pane === undefined) return
  let fields: string[] | null = null
  try {
    const id = await $.session.model()
    if (!modelMoved(id)) return
    fields = claimModelFeed(id, undefined)
    if (fields === null) return
    await $.process.run(feedArgv($.plugin.root, fields), { timeoutMs: STATUSLINE_TIMEOUT_MS })
  } catch {
    if (fields !== null) resetModelFeed()   // the next tick or turn feeds it again
  }
}

// Where the person is (where.ts): one read at a time, a failed one keeps the line.
async function pollWhere($: EngineInterface): Promise<void> {
  // A session outside tmux is no fleet session: there is no one to place.
  if (whereBusy || pane === undefined) return
  whereBusy = true
  try {
    const r = await $.process.run(whereArgv($.plugin.root), { timeoutMs: WHERE_TIMEOUT_MS })
    takeWhere(r.exitCode, r.stdout)
  } catch {
    // The next tick reads it again.
  } finally {
    whereBusy = false
  }
}

// The orchestrator's role (orchestrator.ts): read once — a window's role does not
// change under a running session. A read that fails adds nothing.
async function readRole($: EngineInterface): Promise<void> {
  if (pane === undefined) return
  let windowRole = ''
  try {
    const r = await $.process.run(roleArgv(pane), { timeoutMs: TMUX_TIMEOUT_MS })
    windowRole = r.exitCode === 0 ? r.stdout : ''
  } catch {
    takeRole('', undefined)
    return
  }
  // A role file that cannot be read drops the section, never the window's role
  // (exit-guard.ts and /qd ask isOrchestrator with or without it).
  // The launcher's rendered body first (@fleet_role_body, #2782), else the copy
  // beside the skill — a window opened before the stamp existed.
  let text: string | undefined
  if (windowRole.trim() === 'orchestrator') {
    let body = ''
    try {
      const b = await $.process.run(bodyArgv(pane), { timeoutMs: TMUX_TIMEOUT_MS })
      body = b.exitCode === 0 ? b.stdout.trim() : ''
    } catch {
      body = ''
    }
    for (const path of body !== '' ? [body, rolePath($.plugin.root)] : [rolePath($.plugin.root)]) {
      try {
        text = await $.fs.read(path)
        break
      } catch {
        text = undefined
      }
    }
  }
  takeRole(windowRole, text)
}

// Quick dispatch (qd.tsx): the orchestrator's window only — its strings, then the
// command. A read or a register that fails costs /qd, never the session.
// The `qd_` / `panel_` strings, for the two windows that show them.
async function readStrings($: EngineInterface): Promise<void> {
  if (!isOrchestrator() && !panelsOn()) return
  try {
    const r = await $.process.run(stringsArgv($.plugin.root), { timeoutMs: TMUX_TIMEOUT_MS })
    if (r.exitCode === 0) takeStrings(r.stdout)
  } catch {
    // Every key shows itself; the command still works.
  }
}

async function registerQuickDispatchCommand($: EngineInterface): Promise<void> {
  if (!isOrchestrator()) return
  try {
    await $.command.register(qdCommand())
  } catch {
    // An engine without `immediate`, or a refused name: no /qd.
  }
}

async function pollOnce($: EngineInterface): Promise<void> {
  // One command at a time: a /compact can hold its run for a minute, and the
  // next one waits its turn behind it rather than racing it.
  if (inboxBusy || inbox === undefined) return
  inboxBusy = true
  try {
    await pollInbox(inboxIo($), inbox)
  } catch {
    // A failed poll is retried on the next tick; the poster times out on its own.
  } finally {
    inboxBusy = false
  }
}

// The fallback tools (tools.ts explains them; the run is here because the engine
// follows `$` only within one file): the specs from the service itself; a spec
// read that fails registers nothing (an old session's list already carries them),
// and one tool that will not register costs that tool only, never the session.
async function registerFallbackTools($: EngineInterface): Promise<void> {
  let specs: ToolSpec[]
  try {
    const r = await $.process.run(specArgv(binDir($.plugin.root)), { timeoutMs: SPEC_TIMEOUT_MS })
    if (r.exitCode !== 0) return
    specs = fallbackSpecs(r.stdout)
  } catch {
    return
  }
  for (const spec of specs) {
    try {
      await $.tool.register(spec)
    } catch {
      // Already listed (a reload), or refused: this tool only.
    }
  }
}

/** Start-up work of every feature, run once the gate is open. */
async function onReady($: EngineInterface): Promise<void> {
  // The fallback tools (tools.ts, issue #2057) — only for a fleet session the
  // launcher did not give the tool service: FLEET_MCP_SERVER=1 says it did (issue
  // #1807), and then status / spawn / await are the service's and the mod
  // registers nothing (#1812). Without it — a pane launched before #1828, whose
  // tool list still carries the mod's three — register them from the service's
  // own specs, so a reload of this code never leaves a listed tool unanswered.
  if (pane !== undefined && (await $.env.get('FLEET_MCP_SERVER')) !== '1') await registerFallbackTools($)
  await beat($)
  timer?.cancel()
  timer = $.clock.every(HEARTBEAT_MS, () => {
    void beat($)
  })
  // The model on the bus from the first second, and a /model within ~2 s (#1459).
  resetModelFeed()
  await pollModel($)
  modelTimer?.cancel()
  modelTimer = $.clock.every(MODEL_POLL_MS, () => {
    void pollModel($)
  })
  // The orchestrator's role, in the context from the first request (#2582).
  await readRole($)
  const home = (await $.env.get('HOME')) ?? ''
  const conf = (await $.env.get('FLEET_CONF_DIR')) || `${home}/.config/claude-fleet`
  const tmux = await $.env.get('TMUX')
  // The panels: the orchestrator's and the steward's windows only (#2835).
  const session = pane === undefined ? undefined : sessionOf(tmux)
  stopPanels()
  if (session !== undefined && panelsWanted(windowRole(), await $.env.get('FLEET_MOD_PANELS'), session)) {
    startPanels(panelPaths(conf, session))
  }
  await readStrings($)
  // /qd, the orchestrator's quick dispatch (#2618).
  await registerQuickDispatchCommand($)
  // What waits behind its turn starts at 0, so a counting orchestrator always says a number (#2617).
  if (isOrchestrator()) await setOptions($, { [QUEUE_OPTION]: '0' }).catch(() => undefined)
  // Where the person is, in the context from the first request (#1716).
  await pollWhere($)
  whereTimer?.cancel()
  whereTimer = $.clock.every(WHERE_POLL_MS, () => {
    void pollWhere($)
  })
  inbox = inboxDir(conf, tmux, pane)
  inboxTimer?.cancel()
  inboxTimer = inbox === undefined && !panelsOn() ? undefined : $.clock.every(INBOX_MS, () => {
    void pollOnce($)
    void tickPanels($)
  })
  panelsTimer?.cancel()
  panelsTimer = undefined
  if (panelsOn()) {
    try {
      await $.command.register(sheetCommand())
    } catch {
      // A refused name: no /sheet; the panels still follow the books.
    }
    await tickPanels($, true)
    panelsTimer = $.clock.every(PANELS_FULL_MS, () => {
      void tickPanels($, true)
    })
  }
}

export function registerLifecycle(on: On): void {
  on('session.start', async ($, e, next) => {
    const { version } = await $.session.version()
    const supported = isSupported(version)
    const state = supported ? 'on' : 'off:version'
    const id = await $.env.get('TMUX_PANE')
    pane = id !== undefined && id !== '' ? id : undefined
    await update($, status, () => ({ state, engine: version, mod: MOD_VERSION }))
    await setOptions($, {
      '@mod_state': state,
      '@mod_ver': MOD_VERSION,
      // Out of range never beats: clear one a previous load left behind.
      ...(supported ? {} : { '@mod_alive': null }),
    })
    if (supported) {
      openGate()
      await onReady($)
      if (e.isInteractive) $.ui.toast(`fleet 扩展已加载 · v${MOD_VERSION}`)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.end', async ($, e, next) => {
    if (isOpen() && EXITS.has(e.reason)) {
      timer?.cancel()
      timer = undefined
      inboxTimer?.cancel()
      inboxTimer = undefined
      modelTimer?.cancel()
      modelTimer = undefined
      whereTimer?.cancel()
      whereTimer = undefined
      panelsTimer?.cancel()
      panelsTimer = undefined
      stopPanels()
      await setOptions($, { '@mod_alive': null, ...(isOrchestrator() ? { [QUEUE_OPTION]: null } : {}) })
    }
    return next(e)
  }).catch(($, e, next) => next(e))
}
