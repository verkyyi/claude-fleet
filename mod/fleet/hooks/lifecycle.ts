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

import { atom, update } from 'claude-code'
import type { EngineInterface, On, Timer } from 'claude-code'

import type { FleetModStatus } from '../types'
import { isOpen, openGate } from './gate'
import { TMUX_TIMEOUT_MS, windowOptionsArgv } from './tmux'
import { MOD_VERSION, isSupported } from './version'

export const HEARTBEAT_MS = 15_000

/** Exits that end the process (a `clear` or `resume` keeps it beating). */
const EXITS = new Set(['prompt_input_exit', 'logout', 'other'])

const status = atom({ plugin: 'fleet', key: 'status' } as const, null as FleetModStatus | null)

// Module state: a reload is a fresh module, and session.start fires again.
let timer: Timer | undefined
let pane: string | undefined

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

/** Start-up work of every feature, run once the gate is open. */
async function onReady($: EngineInterface): Promise<void> {
  await beat($)
  timer?.cancel()
  timer = $.clock.every(HEARTBEAT_MS, () => {
    void beat($)
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
      await setOptions($, { '@mod_alive': null })
    }
    return next(e)
  }).catch(($, e, next) => next(e))
}
