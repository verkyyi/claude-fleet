// The fleet-orchestrate plugin's contract (issue #3114, EPIC #3111 C3): the values
// its mod module (hooks/qd.tsx) keeps in $.state.

/** The /qd dialog (issue #2618): what it holds while open. */
export type QdState = {
  /** The title as typed — kept after a failed dispatch. */
  title: string
  /** The repo picked; '' while the list has not landed. */
  repo: string
  /** The fleet's hosted repos (`fleet-mcp.py --call repos`). */
  repos: string[]
  /** Why the last Enter did not dispatch ('' = nothing to say). */
  error: string
  /** A dispatch is running: a second Enter is ignored. */
  busy: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'fleet-orchestrate': {
      /** The /qd dialog. */
      qd: QdState
    }
  }
}
