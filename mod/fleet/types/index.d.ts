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

declare module 'claude-code' {
  interface PluginState {
    fleet: { status: FleetModStatus | null }
  }
}
