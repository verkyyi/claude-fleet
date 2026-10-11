// Who the mocked window is (issue #3115): the one tmux read at session.start
// (common.ts windowArgv — `#{window_id}|#{@fleet_id}|#{@issue}`) and the line
// global/roles.held carries for the steward role (bin/fleet-role-take.sh).
//
//   holder  binds no issue and holds the steward role
//   other   binds no issue; another window holds the role
//   worker  binds #12 — never a holder, starts nothing
//   none    binds no issue; nobody holds the role

export const HELD = '/conf/global/roles.held'
export const VERSION = { version: '2.1.295', base: '2.1.295' }

export function windowOf(who: string): string {
  return who === 'worker' ? '@7|fid-7|12\n' : '@7|fid-7|\n'
}

export function heldOf(who: string): string {
  if (who === 'holder') return 'orchestrator\tfleet\tfid-1\t@1\t1\nsteward\tfleet\tfid-7\t@7\t1\n'
  if (who === 'other') return 'steward\tfleet\tfid-9\t@9\t1\n'
  return ''
}
