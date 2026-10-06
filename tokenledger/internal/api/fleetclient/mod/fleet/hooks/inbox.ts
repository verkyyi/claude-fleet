// The pane's command inbox (issue #1337, EPIC #1334 C3).
//
// The fleet used to TYPE `/clear`, `/compact …`, `/model …` and the handoff
// pickup into a pane (Escape, the text, a separate Enter, then poll the screen).
// Now bash posts the command as a file (bin/fleet-lib.sh fleet_session_command)
// and this mod runs it with `$.command.run`, which the engine queues until the
// session is idle — never mid-turn, never glued onto a half-typed draft.
//
//   <FLEET_CONF_DIR>/global/mod-inbox/<socket-label>/<pane-id>/
//     <seq>.json   {"cmd":"/clear","args":"","from":"handoff-cycle"}
//     <seq>.taken  our claim: an atomic `mv` of the .json — the poster cancels with
//                  the same rename, so exactly one side ever wins
//     <seq>.done   {"ok":true} | {"ok":false,"error":"…"}
//
// The poll runs on lifecycle.ts's timer, not on a session event: a /clear ends
// the session and fires no new session.start, but the module and its timers go
// on — so the pickup posted right after a handoff's /clear is still taken.
// `$` is never handed across an import (gate.ts), so lifecycle.ts hands this
// file an `InboxIo` built from its own `$` calls; everything here is plain logic.

/** The poll interval (ms). */
export const INBOX_MS = 1000

/** One posted command. */
export type InboxMessage = { cmd: string; args: string; from: string }

/** The `$` calls one poll needs, bound by lifecycle.ts. */
export type InboxIo = {
  list: (dir: string) => Promise<string[]>
  read: (path: string) => Promise<string>
  write: (path: string, text: string) => Promise<void>
  /** Atomic rename; false when the source is gone (the poster cancelled it). */
  claim: (from: string, to: string) => Promise<boolean>
  run: (command: string, args: string) => Promise<void>
}

/**
 * The inbox directory for this pane, or undefined outside tmux. `tmux` is $TMUX
 * (`<socket path>,<pid>,<session>`); the socket's basename is the fleet's label —
 * a pane id is unique per server only, and every fleet runs its own (#159).
 */
export function inboxDir(confDir: string, tmux: string | undefined, pane: string | undefined): string | undefined {
  if (!tmux || !pane || !/^%\d+$/.test(pane)) return undefined
  const sock = tmux.split(',')[0]?.split('/').pop() ?? ''
  if (sock === '') return undefined
  return `${confDir.replace(/\/+$/, '')}/global/mod-inbox/${sock}/${pane.slice(1)}`
}

/** A posted file's message, or a reason it cannot run. */
export function parseMessage(text: string): InboxMessage | { error: string } {
  let v: unknown
  try {
    v = JSON.parse(text)
  } catch {
    return { error: 'not JSON' }
  }
  if (typeof v !== 'object' || v === null) return { error: 'not an object' }
  const o = v as Record<string, unknown>
  const cmd = typeof o.cmd === 'string' ? o.cmd.trim() : ''
  if (!/^\/[^\s/][^\s]*$/.test(cmd)) return { error: 'cmd must be one /command' }
  return {
    cmd: cmd.slice(1),
    args: typeof o.args === 'string' ? o.args : '',
    from: typeof o.from === 'string' ? o.from : '?',
  }
}

/** Pending seqs, oldest first (seqs start with the epoch second). */
export function pending(names: readonly string[]): string[] {
  return names
    .filter(n => n.endsWith('.json') && !n.startsWith('.'))
    .map(n => n.slice(0, -'.json'.length))
    .sort()
}

function errorText(err: unknown): string {
  const s = err instanceof Error ? err.message : String(err)
  return s.replace(/\s+/g, ' ').slice(0, 300)
}

/**
 * One poll: claim each pending command, run it, write its .done. Commands run
 * one at a time, in post order; `$.command.run` itself waits for an idle session.
 */
export async function pollInbox(io: InboxIo, dir: string): Promise<number> {
  let names: string[]
  try {
    names = await io.list(dir)
  } catch {
    return 0 // no inbox yet: nothing was ever posted to this pane
  }
  let ran = 0
  for (const seq of pending(names)) {
    const base = `${dir}/${seq}`
    if (!(await io.claim(`${base}.json`, `${base}.taken`))) continue
    let result: { ok: boolean; error?: string }
    try {
      const msg = parseMessage(await io.read(`${base}.taken`))
      if ('error' in msg) result = { ok: false, error: msg.error }
      else {
        await io.run(msg.cmd, msg.args)
        result = { ok: true }
      }
    } catch (err) {
      result = { ok: false, error: errorText(err) }
    }
    try {
      await io.write(`${base}.done`, `${JSON.stringify(result)}\n`)
    } catch {
      // The poster times out to "running" (exit 6) and never types it again.
    }
    ran++
  }
  return ran
}
