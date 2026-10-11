// The fleet-steward plugin's mod module (issue #3115, EPIC #3111 C4): the three
// right-hand panels — the decision sheet, the patrol, the batches — moved out of
// the core mod (mod/fleet). This file only ASSEMBLES; panels.ts owns the start,
// the window's holder tick and the books, common.ts the one switch (isHolder).
// Installed only with the plugin: no plugin, no /sheet and no pane anywhere.
// Codex has no mod: its steward reads the text `[decision]` sheet.

import type { Register } from 'claude-code'

import { registerBatches } from './batches'
import { registerPanels } from './panels'
import { registerPatrol } from './patrol'
import { registerSheet } from './sheet'

export const register: Register = on => {
  // before the patrol / batches: the sheet's band answers AbovePrompt only with a hint
  registerSheet(on)
  registerPatrol(on)
  registerPanels(on)
  registerBatches(on)
}
