// A slip of the hand must not end the orchestrator (issue #2584, EPIC #2581 C3).
//
// The fleet's one orchestrating session carries the whole conversation the
// person had with it; one stray /exit or /clear used to throw that away. In the
// orchestrator's window (orchestrator.ts's start-up read of `@fleet_role`) the
// first /exit or /clear does not run: its answer is one line saying what this
// session is, that ⌃D puts it in the background, and how to confirm — the same
// command again within CONFIRM_MS, or the `!` form (`/exit!`, `/clear!`; typed
// with a space, `/exit !`, it is the command's argument and confirms the same).
//
// The engine resolves aliases before `command.run` (/quit → exit, /reset and
// /new → clear), so the two names cover them. `/exit!` is not a command: it
// arrives at `prompt.submit` as text, and the hook there drops it and runs the
// real command through `$.command.run` a moment later (the engine refuses a run
// from inside that hook) — a plugin's run (this one, the command
// inbox's /clear or /exit) is never guarded. Only a person's hand is: the
// composer and the Remote Control bridge. Any other window, or a shut gate,
// passes untouched.

import type { On, PromptOrigin } from 'claude-code'

import { isOpen } from './gate'
import { isOrchestrator } from './orchestrator'

export const GUARDED = ['exit', 'clear'] as const
export type Guarded = (typeof GUARDED)[number]

/** How long a hinted command stays armed: the second one inside it runs. */
export const CONFIRM_MS = 60_000

/** `/exit!`'s real run waits this long, past the prompt.submit that carried it. */
export const DEFER_MS = 50

let armed: { command: Guarded; at: number } | undefined

export function isGuarded(command: string): command is Guarded {
  return (GUARDED as readonly string[]).includes(command)
}

/** The `!` form typed as a prompt: exactly `/<command>!`, an alias's too. */
export function confirmForm(text: string): Guarded | undefined {
  const m = /^\/(exit|quit|clear|reset|new)!$/.exec(text.trim())
  if (m === null) return undefined
  return m[1] === 'clear' || m[1] === 'reset' || m[1] === 'new' ? 'clear' : 'exit'
}

export function hint(command: Guarded): string {
  const what = command === 'exit' ? '结束它' : '清空它的对话'
  return [
    `这是编排会话：/${command} 会${what}，之后要重新交代一切。`,
    `只想离开：⌃D 放到后台，它继续在。`,
    `确实要${command === 'exit' ? '退出' : '清空'}：${CONFIRM_MS / 1000} 秒内再输一次 /${command}，或输 /${command}!`,
  ].join('\n')
}

/** Typed by a person, not run by a plugin, a peer or a schedule. */
export function byHand(origin: PromptOrigin): boolean {
  return origin.kind === 'composer' || origin.kind === 'bridge'
}

/**
 * One guarded command typed at `now`: `run` when this window is not the
 * orchestrator's or the same command was hinted within CONFIRM_MS (the arm is
 * spent), else `hint` (and the arm is set).
 */
export function decide(command: Guarded, now: number): 'run' | 'hint' {
  if (!isOrchestrator()) return 'run'
  if (armed !== undefined && armed.command === command && now - armed.at <= CONFIRM_MS) {
    armed = undefined
    return 'run'
  }
  armed = { command, at: now }
  return 'hint'
}

/** Tests: forget the arm. */
export function resetGuard(): void {
  armed = undefined
}

export function registerExitGuard(on: On): void {
  on('command.run', async ($, e, next) => {
    if (!isOpen() || !isGuarded(e.command) || !byHand(e.origin)) return next(e)
    if (e.args.trim() === '!' && isOrchestrator()) {
      resetGuard()
      return next({ ...e, args: '' })
    }
    if (decide(e.command, await $.clock.now()) === 'run') return next(e)
    return { text: hint(e.command) }
  }).catch(($, e, next) => next(e))

  on('prompt.submit', async ($, e, next) => {
    const command = isOpen() && isOrchestrator() && byHand(e.origin) ? confirmForm(e.text) : undefined
    if (command === undefined) return next(e)
    resetGuard()
    // The engine refuses a run from inside prompt.submit (it would wait on the
    // turn this hook holds), so it goes from a one-shot timer just after.
    const once = $.clock.every(DEFER_MS, () => {
      once.cancel()
      void $.command.run({ command, args: '' }).catch(() => undefined)
    })
    return { drop: `/${command}! → /${command}` }
  }).catch(($, e, next) => next(e))
}
