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

import { atom, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'

import type { FleetModStatus } from '../types'
import { isOpen, openGate } from './gate'
import { TOOL_SPECS } from './tools'
import { INBOX_MS, inboxDir, pollInbox } from './inbox'
import type { InboxIo } from './inbox'
import { TMUX_TIMEOUT_MS, windowOptionsArgv } from './tmux'
import { MODEL_POLL_MS, STATUSLINE_TIMEOUT_MS, claimModelFeed, feedArgv, modelMoved, resetModelFeed } from './usage'
import { MOD_VERSION, isSupported } from './version'
import { WHERE_POLL_MS, WHERE_TIMEOUT_MS, takeWhere, whereArgv } from './where'

export const HEARTBEAT_MS = 15_000

/** Exits that end the process (a `clear` or `resume` keeps it beating). */
const EXITS = new Set(['prompt_input_exit', 'logout', 'other'])

const status = atom({ plugin: 'fleet', key: 'status' } as const, null as FleetModStatus | null)

// Module state: a reload is a fresh module, and session.start fires again.
let timer: Timer | undefined
let inboxTimer: Timer | undefined
let modelTimer: Timer | undefined
let whereTimer: Timer | undefined
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

/** Start-up work of every feature, run once the gate is open. */
async function onReady($: EngineInterface): Promise<void> {
  // The fleet tools (tools.ts serves them): registered before the first prompt —
  // unless the launcher mounted the fleet tool service (bin/fleet-mcp.py, issue
  // #1807), which owns the `fleet` name and serves the same three (and more). The
  // mod's copy stays one version as the fallback for a session without it.
  const served = (await $.env.get('FLEET_MCP_SERVER')) === '1'
  for (const spec of served ? [] : TOOL_SPECS) {
    try {
      await $.tool.register(spec)
    } catch {
      // One tool that will not register costs that tool, never the session.
    }
  }
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
  // Where the person is, in the context from the first request (#1716).
  await pollWhere($)
  whereTimer?.cancel()
  whereTimer = $.clock.every(WHERE_POLL_MS, () => {
    void pollWhere($)
  })
  const home = (await $.env.get('HOME')) ?? ''
  const conf = (await $.env.get('FLEET_CONF_DIR')) || `${home}/.config/claude-fleet`
  inbox = inboxDir(conf, await $.env.get('TMUX'), pane)
  inboxTimer?.cancel()
  inboxTimer = inbox === undefined ? undefined : $.clock.every(INBOX_MS, () => {
    void pollOnce($)
  })
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
      await setOptions($, { '@mod_alive': null })
    }
    return next(e)
  }).catch(($, e, next) => next(e))
}
