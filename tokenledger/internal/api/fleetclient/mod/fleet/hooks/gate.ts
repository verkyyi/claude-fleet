// The one switch every fleet hook stands behind (EPIC #1334 rule 5).
//
// `register` runs before the engine can say its version, so a feature file
// cannot simply skip registering. lifecycle.ts's session.start hook checks the
// version and opens the gate when it is in range, so:
//
//   - an ordinary hook starts with `if (!isOpen()) return next(e)` and passes
//     straight through to the engine while the gate is shut;
//   - work that needs the session up (a timer, a first write) goes in
//     lifecycle.ts's `onReady`, which runs only once the gate is open — the
//     engine takes one unmatched session.start hook per plugin.
//
// `$` is never handed across an import (the engine follows it only within one
// file), so this file holds the flag and nothing else. A reload is a fresh
// module: the gate starts shut and session.start fires again.

let open = false

export function isOpen(): boolean {
  return open
}

/** lifecycle.ts only: the version check passed. */
export function openGate(): void {
  open = true
}
