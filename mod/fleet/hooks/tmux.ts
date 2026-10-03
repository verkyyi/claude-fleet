// Window options through tmux — the fleet's one state store (EPIC #1334 rule 1).
//
// Run the argv this builds with `$.process.run(...)` at the call site (`$` is
// never handed across an import). `$.process.run` inherits the session's
// environment, so a bare `tmux` lands on THIS fleet's own server via $TMUX (one
// fleet ≡ one socket, issue #159), and `-t $TMUX_PANE` pins the write to this
// pane's window — an untargeted `set-option -w` would hit the session's CURRENT
// window instead (issue #511). Read the pane with `$.env.get('TMUX_PANE')`;
// unset or empty = outside tmux, write nothing.

/**
 * The argv that sets (string) or unsets (null) window options on `pane`'s
 * window, all in ONE tmux call (`;`-chained); null when there is nothing to do.
 */
export function windowOptionsArgv(
  pane: string,
  options: Record<string, string | null>,
): string[] | null {
  const argv: string[] = ['tmux']
  for (const [key, value] of Object.entries(options)) {
    if (argv.length > 1) argv.push(';')
    if (value === null) argv.push('set-option', '-w', '-u', '-t', pane, key)
    else argv.push('set-option', '-w', '-t', pane, key, value)
  }
  return argv.length > 1 ? argv : null
}

/** How long one tmux write may take before the run is abandoned. */
export const TMUX_TIMEOUT_MS = 5000
