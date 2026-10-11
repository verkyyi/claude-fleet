// The `qd_` / `orch_queue` / `panel_` UI strings (bin/fleet-ui-lang.sh), read once
// at session.start by lifecycle.ts and shared by the orchestrator's band, the
// panels and the decision sheet. A key with no entry shows itself.
//
// `/qd` itself — the quick-dispatch dialog (issue #2618) — moved into the
// fleet-orchestrate plugin's mod module (plugins/fleet-orchestrate/hooks/qd.tsx,
// issue #3114, EPIC #3111): installed with the plugin, registered in any fleet
// window that binds no issue. This mod no longer registers it; the band's and the
// batches panel's buttons still run `/qd`, which answers when the plugin is there.

import { binDir } from './tools'

export const QD_COMMAND = 'qd'

let strings: Record<string, string> = {}

/** The argv that prints the `qd_` strings and queue.ts's `orch_queue` ones (KEY NUL TEXT NUL, a \001 per printf slot). */
export function stringsArgv(root: string): string[] {
  return ['sh', `${binDir(root)}/fleet-ui-lang.sh`, 'dump', 'qd_', 'orch_queue', 'panel_']
}

/** Take the dump; one that cannot be read leaves every key showing itself. */
export function takeStrings(dump: string): void {
  const parts = dump.split('\0')
  const out: Record<string, string> = {}
  for (let i = 0; i + 1 < parts.length; i += 2) if (parts[i] !== '') out[parts[i] as string] = parts[i + 1] as string
  strings = out
}

/** One string, its \001 slots filled in order. */
export function t(key: string, ...args: string[]): string {
  let i = 0
  return (strings[key] ?? key).replace(/\u0001/g, () => args[i++] ?? '')
}

/** Tests: is this argv the strings read? */
export function isStringsRun(argv: readonly string[]): boolean {
  return argv[0] === 'sh' && (argv[1] ?? '').endsWith('/fleet-ui-lang.sh') && argv[2] === 'dump'
}
