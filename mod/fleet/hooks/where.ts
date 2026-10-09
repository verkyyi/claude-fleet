// Where the person is (issue #1716, EPIC #1710 C6): one line in the session's
// context — 「操作者此刻在：MacBook · macOS · iTerm2 3.6 · 能：打开网页…」 — so a
// session on any machine knows which device and terminal the person uses right
// now, and what it can do for them there.
//
// The line comes from bin/fleet-client-where.sh, THE one reader (EPIC rule 7):
// the hub's client lease, or with no hub the fleet-shell client attached here.
// lifecycle.ts reads it at the start and every WHERE_POLL_MS (the timer and `$`
// live there: the engine follows `$` only within one file); compose.ts's
// `prompt.compose` hook adds it as the last `session` section, so a takeover (the phone
// opening the client) reaches the model's next request within the poll. A read
// that fails keeps the last line; no line yet adds nothing.

import type { PromptComposeSection } from 'claude-code'

export const WHERE_POLL_MS = 15_000
/** The script asks the hub (≤5 s) and maybe tmux; well inside this. */
export const WHERE_TIMEOUT_MS = 10_000
export const WHERE_SECTION = 'fleet:where'

let line: string | undefined

/** <install>/bin/fleet-client-where.sh from the plugin root (<install>/mod/fleet). */
export function whereArgv(root: string): string[] {
  const base = root.replace(/\/+$/, '').replace(/\/\.claude-plugin$/, '')
  return ['bash', `${base}/../../bin/fleet-client-where.sh`]
}

/**
 * Take one run of the script: exit 0 names a client, 3 says nobody is
 * connected; anything else is no answer and keeps what we had. Returns true
 * when the line changed.
 */
export function takeWhere(exitCode: number, stdout: string): boolean {
  if (exitCode !== 0 && exitCode !== 3) return false
  const next = stdout.split('\n')[0]?.trim() ?? ''
  if (next === '' || next === line) return false
  line = next
  return true
}

export function currentWhere(): string | undefined {
  return line
}

/** Tests: forget the line. */
export function resetWhere(): void {
  line = undefined
}

export function whereSection(text: string): PromptComposeSection {
  return {
    id: WHERE_SECTION,
    scope: 'session',
    text:
      `# 操作者此刻在哪\n操作者此刻在：${text}\n` +
      '（fleet 客户端租约；换设备接管后这一行会跟着变。要最新的或要字段，运行 ' +
      '`~/.claude/fleet/bin/fleet-client-where.sh [--json]`；给操作者看网页/文件前按这里的「能：」选送达方式，不要自己猜终端或设备。）',
  }
}

/** Tests: is this argv the where read (so a test counting its own runs can skip it)? */
export function isWhereRun(argv: readonly string[]): boolean {
  return argv[0] === 'bash' && (argv[1] ?? '').endsWith('/bin/fleet-client-where.sh')
}
