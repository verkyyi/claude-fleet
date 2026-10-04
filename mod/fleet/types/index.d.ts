// The fleet mod's contract (issue #1335, EPIC #1334). One plugin, one module:
// every EPIC member adds a file under hooks/ and the values it keeps here.

/** What the version gate decided at session.start: `on`, or `off:version`. */
export type FleetModState = 'on' | 'off:version'

/** The gate's verdict, kept in $.state so a later hook (a band, a tool) can read it. */
export type FleetModStatus = {
  state: FleetModState
  /** The Claude Code version the session runs (`$.session.version().version`). */
  engine: string
  /** The mod's own version (MOD_VERSION, kept equal to plugin.json's). */
  mod: string
}

/**
 * The task-progress band above the prompt (issue #1339): what the last 10s
 * refresh read from the local caches. A field is null when its source is
 * missing (or the window has no issue), and that segment is simply not drawn.
 */
export type ProgressSnapshot = {
  /** The window's @issue; null on the hub and a scratch (raw) window. */
  issue: number | null
  /** This issue branch's PR from the dash's prmap: ci is `✓` `✗` `…` `·`. */
  pr: { number: number; state: string; ci: string; ready: string } | null
  /** Children standing at `!`, by bare ledger key (`issue-12`, `scratch-3`). */
  needsKids: string[]
}

declare module 'claude-code' {
  interface PluginState {
    fleet: {
      status: FleetModStatus | null
      progress: ProgressSnapshot | null
      /** Alert keys standing now and already toasted (`kid:issue-12`, `pr:34`). */
      alerts: string[]
    }
  }
}
