// The mod's sections of the system prompt — ONE `prompt.compose` hook (the
// engine takes one unmatched hook per event per plugin). Each feature keeps its
// own text and state; this hook only puts them after the engine's own:
//
//   fleet:where              where the person is (where.ts, #1716)
//
// The orchestrator's role section (#2582) left with the resident seat (#3118):
// the mod adds no role to any session's prompt.
//
// Nothing to add (gate shut, no line yet) passes the engine's through.

import type { On, PromptComposeSection } from 'claude-code'

import { isOpen } from './gate'
import { WHERE_SECTION, currentWhere, whereSection } from './where'

export function registerCompose(on: On): void {
  on('prompt.compose', async ($, e, next) => {
    const r = await next(e)
    if (!isOpen()) return r
    const where = currentWhere()
    const ours: PromptComposeSection[] = []
    if (where !== undefined) ours.push(whereSection(where))
    if (ours.length === 0) return r
    const ids = new Set([WHERE_SECTION])
    return { sections: [...r.sections.filter(s => !ids.has(s.id)), ...ours] }
  }).catch(($, e, next) => next(e))
}
