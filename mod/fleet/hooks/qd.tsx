// Quick dispatch: `/qd` in the orchestrator's window (issue #2618, EPIC #2615 C3).
//
// The orchestrator can be busy for a while on one step (a long read, a slow
// script), and whatever the person types waits behind that step. `/qd` is the
// one road to a new worker that does not pass through it: registered
// `immediate`, so Enter runs it mid-turn; it opens a small dialog — a title, a
// repo (the fleet's hosted ones, the last one used first) — and Enter files the
// issue through the SAME road the orchestrator takes (`fleet-mcp.py --call
// file_issue {title, repo, spawn: true}`, the session's FLEET_WORKER_CRED in the
// environment), so the spawn's origin is the orchestrator's window and the
// worker's [child-report] comes back to it as always. Nothing reaches the model
// and nothing is written into the conversation; a failure stays in the dialog
// with the title kept, and fleet-issue-file.sh's own hints show as they came.
//
// Off by default, a prefix does the same without the dialog: with
// FLEET_ORCH_QD_PREFIX=1, a prompt typed while a turn runs that opens with
// `派：` is dropped (never queued) and dispatched to the last repo.
//
// Only the orchestrator's window (orchestrator.ts's start-up read) registers the
// command — lifecycle.ts does it, with the strings (bin/fleet-ui-lang.sh's
// `qd_` keys, read once) — so a worker's window has no /qd at all. Codex has no
// mod, so no dialog. Every UI string comes from that table; a key with no entry
// shows itself, as the table's own rule says.

import { atom, read, update } from 'claude-code'
import type { CommandSpec, EngineInterface, On } from 'claude-code'

import type { QdState } from '../types'
import { isOpen } from './gate'
import { isOrchestrator } from './orchestrator'
import { binDir, callArgv } from './tools'
import { byHand } from './exit-guard'

export const QD_COMMAND = 'qd'
export const QD_PANE = 'fleet-qd'
/** fleet-mcp.py's FILE_TIMEOUT_S (180) plus headroom: its own «did not answer» wins. */
export const FILE_TIMEOUT_MS = 190_000
export const REPOS_TIMEOUT_MS = 40_000
/** `$.store` key: the repo the last dispatch went to. */
export const LAST_REPO = 'qd.lastRepo'
export const PREFIX_RE = /^\s*派[：:]\s*/

const IDLE: QdState = { title: '', repo: '', repos: [], error: '', busy: false }
const qd = atom({ plugin: 'fleet', key: 'qd' } as const, IDLE as QdState)

let strings: Record<string, string> = {}

/** The argv that prints the `qd_` strings (KEY NUL TEXT NUL, a \001 per printf slot). */
export function stringsArgv(root: string): string[] {
  return ['sh', `${binDir(root)}/fleet-ui-lang.sh`, 'dump', 'qd_']
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

/** The command as lifecycle.ts registers it. */
export function qdCommand(): CommandSpec {
  return { name: QD_COMMAND, description: t('qd_desc'), immediate: true }
}

/** Tests: is this argv the strings read? */
export function isStringsRun(argv: readonly string[]): boolean {
  return argv[0] === 'sh' && (argv[1] ?? '').endsWith('/fleet-ui-lang.sh') && argv[2] === 'dump'
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

/** The issue number from the filer's URL, if it printed one. */
export function issueNumber(stdout: string): string | undefined {
  return /\/issues\/(\d+)/.exec(stdout)?.[1]
}

/** fleet-issue-file.sh's `hint:` lines, as it wrote them. */
export function hints(stderr: string): string[] {
  return stderr.split('\n').filter(l => /\bhint:/.test(l)).map(l => l.trim())
}

type Outcome = { ok: true; text: string } | { ok: false; text: string }

/** One dispatch: `fleet-mcp.py --call file_issue`, its answer folded to one line or a reason. */
async function fileIssue($: EngineInterface, title: string, repo: string): Promise<Outcome> {
  const args: Record<string, unknown> = { title, spawn: true }
  if (repo !== '') args.repo = repo
  let text: string
  let exitCode: number
  try {
    const r = await $.process.run(callArgv(binDir($.plugin.root), 'file_issue', args), { timeoutMs: FILE_TIMEOUT_MS })
    text = `${r.stdout}${r.stdout && r.stderr ? '\n' : ''}${r.stderr}`
    exitCode = r.exitCode
  } catch (err) {
    return { ok: false, text: t('qd_failed_fmt', err instanceof Error ? err.message : String(err)) }
  }
  const rep = parseReport(text)
  const num = issueNumber(rep.stdout)
  if (exitCode === 0 && rep.exit === 0 && num !== undefined) {
    return { ok: true, text: [t('qd_done_fmt', num), ...hints(rep.stderr)].join('\n') }
  }
  // A refusal (exit 1 + its reason), a script that failed, a filed issue whose spawn did not go.
  const why = [num !== undefined ? rep.stdout : '', rep.stderr || (rep.exit === null ? text.trim() : rep.stdout)]
    .filter(s => s !== '').join('\n')
  return { ok: false, text: t('qd_failed_fmt', why || `exit ${rep.exit ?? exitCode}`) }
}

async function loadRepos($: EngineInterface): Promise<string[]> {
  try {
    const r = await $.process.run(callArgv(binDir($.plugin.root), 'repos', {}), { timeoutMs: REPOS_TIMEOUT_MS })
    return r.exitCode === 0 ? parseRepos(r.stdout) : []
  } catch {
    return []
  }
}

/** The repo to start on: the last one used while it is still hosted, else the first. */
export function pickRepo(repos: readonly string[], last: unknown): string {
  return typeof last === 'string' && repos.includes(last) ? last : (repos[0] ?? '')
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
  const out = await fileIssue($, title, s.repo)
  if (!out.ok) {
    await update($, qd, v => ({ ...v, busy: false, error: out.text }))
    return
  }
  if (s.repo !== '') await $.store.set(LAST_REPO, s.repo).catch(() => undefined)
  await update($, qd, v => ({ ...v, title: '', busy: false, error: '' }))
  await $.ui.close({ id: QD_PANE })
  $.ui.toast(out.text)
}

export function registerQuickDispatch(on: On): void {
  on('command.run', { command: QD_COMMAND }, async ($, e, next) => {
    if (!isOpen() || !isOrchestrator()) return next(e)
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
    if (!isOpen()) return next(e)
    const ui = $.ui.resolve(e)
    const { Box, Text } = ui
    if (!('Input' in ui) || !('Select' in ui)) return <Text>{t('qd_hint')}</Text>
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
        {s.busy && <Text dimColor>{t('qd_sending')}</Text>}
        {s.error !== '' && <Text color="red">{s.error}</Text>}
        <Text dimColor>{t('qd_hint')}</Text>
      </Box>
    )
  }).catch(($, e, next) => next(e))

  // The prefix (off unless FLEET_ORCH_QD_PREFIX=1): `派：<title>` typed by hand
  // over a running turn never enters the queue; idle (or not dispatched), it goes on as typed.
  on('prompt.submit', { text: PREFIX_RE }, async ($, e, next) => {
    if (!isOpen() || !isOrchestrator() || e.turnId === undefined || !byHand(e.origin)) return next(e)
    if (!PREFIX_RE.test(e.text) || (await $.env.get('FLEET_ORCH_QD_PREFIX')) !== '1') return next(e)
    const title = e.text.replace(PREFIX_RE, '').trim()
    if (title === '') return next(e)
    const repo = pickRepo(await loadRepos($), await $.store.get(LAST_REPO).catch(() => undefined))
    const out = await fileIssue($, title, repo)
    $.ui.toast(out.text)
    // Not dispatched: the words are not thrown away — they wait in the queue as typed.
    if (!out.ok) return next(e)
    if (repo !== '') await $.store.set(LAST_REPO, repo).catch(() => undefined)
    return { drop: out.text }
  }).catch(($, e, next) => next(e))
}
