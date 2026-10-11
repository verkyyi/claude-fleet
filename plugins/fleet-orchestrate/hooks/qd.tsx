// Quick dispatch: `/qd` (issue #2618; the fleet-orchestrate plugin's since #3114) —
// RETIRED by issue #3328 (EPIC #3178 ⑤): one entry, ⌘P (its ⚡ row; ⌃空格 on a
// phone). For ONE version a session that still has /qd keeps it, forwarded: the
// dialog says 「/qd 已并进 ⌘P」 and its Enter runs exactly what ⌘P's ⚡ row runs on
// words + a repo — `fleet-quick-dispatch.py send --title T --repo R` — never a
// second road. compat-1v: 下一批删 (the module, its hooks.json line, its strings).
//
// Registered `immediate`, so Enter runs it mid-turn; a title, a repo (the fleet's
// hosted ones, the last one used first). Nothing reaches the model; a failure
// stays in the dialog with the title kept.
//
// Off by default, a prefix does the same without the dialog: with
// FLEET_ORCH_QD_PREFIX=1, a prompt typed while a turn runs that opens with `派：`
// is dropped (never queued) and sent the same way, to the last repo.
//
// Only a fleet window that binds NO issue registers the command (one tmux read at
// session.start): a worker's window has no /qd. Installed only with the plugin —
// no plugin, no /qd at all. Codex has no mod. Every UI string comes from
// bin/fleet-ui-lang.sh's `qd_` keys; a key with no entry shows itself.

import { atom, read, update } from 'claude-code'
import type { CommandSpec, EngineInterface, PromptOrigin, Register } from 'claude-code'

import type { QdState } from '../types'

export const QD_COMMAND = 'qd'
export const QD_PANE = 'fleet-qd'
/** A send opens the session before it answers (fleet-compose.py --send → place). */
export const SEND_TIMEOUT_MS = 190_000
export const REPOS_TIMEOUT_MS = 40_000
export const READ_TIMEOUT_MS = 5_000
/** `$.store` key: the repo the last dispatch went to. */
export const LAST_REPO = 'qd.lastRepo'
export const PREFIX_RE = /^\s*派[：:]\s*/

const IDLE: QdState = { title: '', repo: '', repos: [], error: '', busy: false }
const qd = atom({ plugin: 'fleet-orchestrate', key: 'qd' } as const, IDLE as QdState)

let strings: Record<string, string> = {}
let on_ = false   // this window registered /qd

/** Where the fleet's scripts are: FLEET_MCP_BIN (a dev tree), else the live install. */
export function binDir(fleetBin: string | undefined, home: string | undefined): string {
  return fleetBin || `${home ?? ''}/.claude/fleet/bin`
}

/** The argv that makes one fleet tool call — the arguments travel as one JSON word. */
export function callArgv(bin: string, tool: string, args: Record<string, unknown>): string[] {
  return ['python3', `${bin}/fleet-mcp.py`, '--call', tool, JSON.stringify(args)]
}

/** ⌘P's ⚡ row on words + a repo (issue #3327): the one send /qd forwards to. */
export function sendArgv(bin: string, title: string, repo: string): string[] {
  return ['python3', `${bin}/fleet-quick-dispatch.py`, 'send', '--title', title, ...(repo !== '' ? ['--repo', repo] : [])]
}

/** The argv that prints the `qd_` strings (KEY NUL TEXT NUL, a \001 per printf slot). */
export function stringsArgv(bin: string): string[] {
  return ['sh', `${bin}/fleet-ui-lang.sh`, 'dump', 'qd_']
}

/** The one tmux read: this pane's window — its @issue and its @fleet_role. */
export function windowArgv(pane: string): string[] {
  return ['tmux', 'display-message', '-p', '-t', pane, '#{@issue}|#{@fleet_role}']
}

/** May this window have /qd? A fleet window (stamped) that binds no issue and is no panel. */
export function mayDispatch(read: string): boolean {
  const [issue = '', role = ''] = read.trim().split('|')
  if (/^\d+$/.test(issue)) return false
  return role !== '' && role !== 'home' && role !== 'panel'
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

/** The command as session.start registers it. */
export function qdCommand(): CommandSpec {
  return { name: QD_COMMAND, description: t('qd_desc'), immediate: true }
}

/** Typed by a person (the composer, or the bridge that relays one). */
export function byHand(origin: PromptOrigin): boolean {
  return origin.kind === 'composer' || origin.kind === 'bridge'
}

/** `--call`'s text: `exit N · <command>`, its stdout, then `[stderr]` and its stderr. */
export function parseReport(text: string): { exit: number | null; stdout: string; stderr: string } {
  const lines = text.replace(/\s+$/, '').split('\n')
  const m = /^exit (-?\d+) · /.exec(lines[0] ?? '')
  if (m === null) return { exit: null, stdout: '', stderr: text.trim() }
  const rest = lines.slice(1)
  const at = rest.indexOf('[stderr]')
  return {
    exit: Number(m[1]),
    stdout: (at < 0 ? rest : rest.slice(0, at)).join('\n').trim(),
    stderr: (at < 0 ? [] : rest.slice(at + 1)).join('\n').trim(),
  }
}

/** The hosted repos out of `--call repos` (fleet-repo.sh list's two-space rows). */
export function parseRepos(text: string): string[] {
  const out: string[] = []
  for (const line of parseReport(text).stdout.split('\n')) {
    const m = /^ {2}(\S+\/\S+)\s/.exec(`${line} `)
    if (m !== null && !out.includes(m[1] as string)) out.push(m[1] as string)
  }
  return out
}

/** The repo to start on: the last one used while it is still hosted, else the first. */
export function pickRepo(repos: readonly string[], last: unknown): string {
  return typeof last === 'string' && repos.includes(last) ? last : (repos[0] ?? '')
}

async function bin($: EngineInterface): Promise<string> {
  return binDir(await $.env.get('FLEET_MCP_BIN'), await $.env.get('HOME'))
}

type Outcome = { ok: true; text: string } | { ok: false; text: string }

/** One dispatch: ⌘P's own send — its first line is what it says, exit 0 = it went. */
async function dispatch($: EngineInterface, title: string, repo: string): Promise<Outcome> {
  try {
    const r = await $.process.run(sendArgv(await bin($), title, repo), { timeoutMs: SEND_TIMEOUT_MS })
    const said = (r.stdout.trim() || r.stderr.trim()).split('\n')[0] ?? ''
    if (r.exitCode === 0) return { ok: true, text: said || t('qd_moved') }
    return { ok: false, text: t('qd_failed_fmt', said || `exit ${r.exitCode}`) }
  } catch (err) {
    return { ok: false, text: t('qd_failed_fmt', err instanceof Error ? err.message : String(err)) }
  }
}

async function loadRepos($: EngineInterface): Promise<string[]> {
  try {
    const r = await $.process.run(callArgv(await bin($), 'repos', {}), { timeoutMs: REPOS_TIMEOUT_MS })
    return r.exitCode === 0 ? parseRepos(r.stdout) : []
  } catch {
    return []
  }
}

/** The dialog's Enter: an empty title is refused in place, a second Enter while one runs is ignored. */
async function submit($: EngineInterface, typed: string): Promise<void> {
  const s = await read($, qd)
  if (s.busy) return
  const title = typed.trim()
  if (title === '') {
    await update($, qd, v => ({ ...v, title: typed, error: t('qd_empty') }))
    return
  }
  if (s.repos.length > 0 && s.repo === '') {
    await update($, qd, v => ({ ...v, title: typed, error: t('qd_norepo') }))
    return
  }
  await update($, qd, v => ({ ...v, title: typed, busy: true, error: '' }))
  const out = await dispatch($, title, s.repo)
  if (!out.ok) {
    await update($, qd, v => ({ ...v, busy: false, error: out.text }))
    return
  }
  if (s.repo !== '') await $.store.set(LAST_REPO, s.repo).catch(() => undefined)
  await update($, qd, v => ({ ...v, title: '', busy: false, error: '' }))
  await $.ui.close({ id: QD_PANE })
  $.ui.toast(out.text)
}

/** session.start: one tmux read decides; then the strings, then the command. Any failure costs /qd only. */
async function start($: EngineInterface): Promise<void> {
  on_ = false
  const pane = await $.env.get('TMUX_PANE')
  if (!pane || !(await $.env.get('TMUX'))) return
  try {
    const r = await $.process.run(windowArgv(pane), { timeoutMs: READ_TIMEOUT_MS })
    if (r.exitCode !== 0 || !mayDispatch(r.stdout)) return
  } catch {
    return
  }
  try {
    const r = await $.process.run(stringsArgv(await bin($)), { timeoutMs: READ_TIMEOUT_MS })
    if (r.exitCode === 0) takeStrings(r.stdout)
  } catch {
    // Every key shows itself; the command still works.
  }
  try {
    await $.command.register(qdCommand())
    on_ = true
  } catch {
    // An engine without `immediate`, or a refused name: no /qd.
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const out = await next(e)
    await start($)
    return out
  }).catch(($, e, next) => next(e))

  on('command.run', { command: QD_COMMAND }, async ($, e, next) => {
    if (!on_) return next(e)
    // Open first, at once; the repo list lands a moment later.
    await update($, qd, v => ({ ...v, error: '', busy: false }))
    await $.ui.open({ id: QD_PANE, title: t('qd_title'), focus: true, closeOnEscape: true, holdToasts: true, rows: 6 })
    const repos = await loadRepos($)
    const repo = pickRepo(repos, await $.store.get(LAST_REPO).catch(() => undefined))
    await update($, qd, v => ({
      ...v,
      repos,
      repo: repos.includes(v.repo) ? v.repo : repo,
      error: repos.length === 0 ? t('qd_norepo') : v.error,
    }))
    return {}
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: QD_PANE }, async ($, e, next) => {
    const s = await read($, qd)
    if (!on_) return next(e)
    const ui = $.ui.resolve(e)
    const { Box, Text } = ui
    if (!('Input' in ui) || !('Select' in ui)) return <Text>{t('qd_moved')}</Text>
    const { Input, Select } = ui
    return (
      <Box flexDirection="column">
        <Input
          key="qd-title"
          label={t('qd_field_title')}
          placeholder={t('qd_placeholder')}
          value={s.title}
          submitLabel={t('qd_submit')}
          autoFocus
          onInput={value => update($, qd, v => ({ ...v, title: value }))}
          onSubmit={value => submit($, value)}
        />
        {s.repos.length > 0 && (
          <Select
            key="qd-repo"
            label={t('qd_field_repo')}
            options={s.repos.map(r => ({ value: r, label: r }))}
            value={s.repo}
            onSelect={value => update($, qd, v => ({ ...v, repo: value }))}
          />
        )}
        <Text color="yellow">{t('qd_moved')}</Text>
        {s.busy && <Text dimColor>{t('qd_sending')}</Text>}
        {s.error !== '' && <Text color="red">{s.error}</Text>}
        <Text dimColor>{t('qd_hint')}</Text>
      </Box>
    )
  }).catch(($, e, next) => next(e))

  // The prefix (off unless FLEET_ORCH_QD_PREFIX=1): `派：<title>` typed by hand
  // over a running turn never enters the queue; idle (or not dispatched), it goes on as typed.
  on('prompt.submit', { text: PREFIX_RE }, async ($, e, next) => {
    if (!on_ || e.turnId === undefined || !byHand(e.origin)) return next(e)
    if (!PREFIX_RE.test(e.text) || (await $.env.get('FLEET_ORCH_QD_PREFIX')) !== '1') return next(e)
    const title = e.text.replace(PREFIX_RE, '').trim()
    if (title === '') return next(e)
    const repo = pickRepo(await loadRepos($), await $.store.get(LAST_REPO).catch(() => undefined))
    const out = await dispatch($, title, repo)
    $.ui.toast(out.text)
    // Not dispatched: the words are not thrown away — they wait in the queue as typed.
    if (!out.ok) return next(e)
    if (repo !== '') await $.store.set(LAST_REPO, repo).catch(() => undefined)
    return { drop: out.text }
  }).catch(($, e, next) => next(e))
}
