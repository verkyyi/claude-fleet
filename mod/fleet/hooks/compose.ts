// The mod's sections of the system prompt — ONE `prompt.compose` hook (the
// engine takes one unmatched hook per event per plugin). Each feature keeps its
// own text and state; this hook only puts them after the engine's own:
//
//   fleet:orchestrator-role  the orchestrator's role (orchestrator.ts, #2582)
//   fleet:where              where the person is, always last (where.ts, #1716)
//
// Nothing to add (gate shut, no role, no line yet) passes the engine's through.

import type { On, PromptComposeSection } from 'claude-code'

import { isOpen } from './gate'
import { ROLE_SECTION, currentRole, roleSection } from './orchestrator'
import { WHERE_SECTION, currentWhere, whereSection } from './where'

export function registerCompose(on: On): void {
  on('prompt.compose', async ($, e, next) => {
    const r = await next(e)
    if (!isOpen()) return r
    const role = currentRole()
    const where = currentWhere()
    const ours: PromptComposeSection[] = []
    if (role !== undefined) ours.push(roleSection(role))
    if (where !== undefined) ours.push(whereSection(where))
    if (ours.length === 0) return r
    const ids = new Set([ROLE_SECTION, WHERE_SECTION])
    return { sections: [...r.sections.filter(s => !ids.has(s.id)), ...ours] }
  }).catch(($, e, next) => next(e))
}
