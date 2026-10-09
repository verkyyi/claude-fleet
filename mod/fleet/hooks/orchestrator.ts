// The orchestrator's role, in every request (issue #2582, EPIC #2581 C1).
//
// The fleet's one orchestrating session (bin/fleet-orchestrator.sh) used to know
// what it was from one seed turn, `/fleet-orchestrate` — a compaction kept only a
// summary of it, a /clear nothing at all. Its role now rides the system prompt
// two ways from ONE file, skills/fleet-orchestrate/role.md: the launcher's
// `--append-system-prompt-file`, and this `session` section, so a session the
// launcher did not start (a hand `claude --resume`, a handoff) still carries it.
//
// lifecycle.ts reads the window's `@fleet_role` and the file once at the start
// (the run and `$` live there: the engine follows `$` only within one file); a
// window that is not `orchestrator`, or a file that cannot be read, adds nothing;
// compose.ts adds the section.
// A worker window never sees this section. The same read says whether this is
// the orchestrator's window at all (isOrchestrator), which exit-guard.ts asks.

import type { PromptComposeSection } from 'claude-code'

export const ROLE_SECTION = 'fleet:orchestrator-role'

let role: string | undefined
let orchestrator = false

/** <install>/skills/fleet-orchestrate/role.md from the plugin root (<install>/mod/fleet). */
export function rolePath(root: string): string {
  const base = root.replace(/\/+$/, '').replace(/\/\.claude-plugin$/, '')
  return `${base}/../../skills/fleet-orchestrate/role.md`
}

/** The argv that prints this pane's window's `@fleet_role`. */
export function roleArgv(pane: string): string[] {
  return ['tmux', 'display-message', '-p', '-t', pane, '#{@fleet_role}']
}

/**
 * Take the start-up read: the window's role and the file's text. Only an
 * `orchestrator` window with a non-empty file keeps a role; anything else
 * clears it.
 */
export function takeRole(windowRole: string, text: string | undefined): void {
  const body = text?.trim() ?? ''
  orchestrator = windowRole.trim() === 'orchestrator'
  role = orchestrator && body !== '' ? body : undefined
}

export function currentRole(): string | undefined {
  return role
}

/** Is this the orchestrator's window — with or without its role file (exit-guard.ts, #2584)? */
export function isOrchestrator(): boolean {
  return orchestrator
}

/** Tests: forget the role. */
export function resetRole(): void {
  role = undefined
  orchestrator = false
}

export function roleSection(text: string): PromptComposeSection {
  return { id: ROLE_SECTION, scope: 'session', text }
}

/** Tests: is this argv the role read? */
export function isRoleRun(argv: readonly string[]): boolean {
  return argv[0] === 'tmux' && argv[1] === 'display-message' && argv[argv.length - 1] === '#{@fleet_role}'
}
