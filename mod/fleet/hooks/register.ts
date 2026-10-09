// claude-fleet's in-session extension (issue #1335, EPIC #1334).
//
// This file only ASSEMBLES: one `register<Feature>(on)` line per feature file.
// lifecycle.ts owns session.start / session.end (the version gate, the
// heartbeat, and every feature's start-up work); gate.ts says how a feature's
// own hooks stand behind the gate. Rules every feature keeps (EPIC #1334):
// tmux window options stay the one state store (tmux.ts); no network, no gh —
// local files via $.fs, the outside world via `$.process.run` of tmux and the
// fleet's own scripts; every hook has a `.catch` that hands the event on, so a
// broken mod never holds up a session.
//
// Loaded by bin/fleet-claude.sh (`--plugin-dir`) when FLEET_MOD is on (the
// default). FLEET_MOD=0, or a Claude Code outside SUPPORTED, and every session
// runs exactly as it did before the mod existed.

import type { Register } from 'claude-code'

import { registerCompose } from './compose'
import { registerExitGuard } from './exit-guard'
import { registerLifecycle } from './lifecycle'
import { registerProgress } from './progress'
import { registerQuickDispatch } from './qd'
import { registerQueue } from './queue'
import { registerState } from './state'
import { registerTools } from './tools'
import { registerUsage } from './usage'

export const register: Register = on => {
  registerLifecycle(on)
  registerUsage(on)
  registerState(on)
  registerProgress(on)
  registerCompose(on)
  registerTools(on)
  registerExitGuard(on)
  registerQuickDispatch(on)
  registerQueue(on)
}
