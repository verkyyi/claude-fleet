// The task-progress band's pure half (issue #1339): parse the fleet's local
// caches, fold them into one ProgressSnapshot, say what the band shows, and
// say which alerts are new. No `$` here — progress.tsx does the reading.
//
// Sources, all local and all written by someone else (the band only reads):
//   - the window's own tmux options and one `list-windows` of this fleet's
//     server (children are the windows whose @origin names this one);
//   - the dash's prmap   $FLEET_C/fleets/<slug>/prmap   branch⇥#pr⇥state⇥ci⇥ready…
//   - the children ledger $FLEET_CONF_DIR/fleets/<sess>/children/<key>.ndjson
// A source that is missing just drops its segment.

import type { ProgressSnapshot } from '../types'

export const PROGRESS_MS = 10_000

/** The format the band's one tmux call prints: this window, then every window. */
export const SELF_FORMAT = [
  'S', '#{session_name}', '#{window_id}', '#{@issue}', '#{@repo}', '#{@norepo}',
  '#{@worktree}', '#{pane_current_path}', '#{window_name}',
].join('\t')
export const WINDOW_FORMAT = [
  'W', '#{session_name}', '#{window_id}',
  '#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}',
  '#{@claude_needs}', '#{@loop}', '#{@issue}', '#{@worktree}', '#{@origin}',
  '#{pane_current_path}', '#{window_name}',
].join('\t')

/** The argv of that one call, aimed at `pane`'s window. */
export function tmuxArgv(pane: string): string[] {
  return ['tmux', 'display-message', '-p', '-t', pane, SELF_FORMAT, ';', 'list-windows', '-a', '-F', WINDOW_FORMAT]
}

export type SelfRow = {
  session: string
  windowId: string
  issue: number | null
  repo: string
  worktree: string
  path: string
}

export type WindowRow = {
  session: string
  windowId: string
  state: string
  loop: string
  key: string
  origin: string
  name: string
}

const PANELS = new Set(['dash', 'plan', 'backlog'])

function int(text: string | undefined): number | null {
  return text !== undefined && /^\d+$/.test(text) ? Number(text) : null
}

/** `owner/name` → `owner-name`, as `fleet_slug` does. */
export function slug(repo: string): string {
  return repo.replaceAll('/', '-')
}

/** `…-scratch-12` / `scratch-12` (a path or a branch) → `scratch-12`, as `fleet_scratch_key`. */
export function scratchKey(path: string): string {
  const base = path.replace(/\/+$/, '').split('/').pop() ?? ''
  const m = /(?:^|-)scratch-(\d+)$/.exec(base)
  return m ? `scratch-${m[1]}` : ''
}

/** A window's ledger key without the multi-repo `<slug>:` prefix. */
function windowKey(issue: string, worktree: string, path: string): string {
  if (/^\d+$/.test(issue)) return `issue-${issue}`
  return scratchKey(worktree) || scratchKey(path)
}

export function parseTmux(stdout: string): { self: SelfRow | null; windows: WindowRow[] } {
  let self: SelfRow | null = null
  const windows: WindowRow[] = []
  for (const line of stdout.split('\n')) {
    const f = line.split('\t')
    if (f[0] === 'S' && f.length >= 9) {
      self = {
        session: f[1] ?? '',
        windowId: f[2] ?? '',
        issue: int(f[3]),
        repo: f[5] === '1' ? '' : (f[4] ?? ''),
        worktree: f[6] ?? '',
        path: f[7] ?? '',
      }
    } else if (f[0] === 'W' && f.length >= 11) {
      const name = f.slice(10).join('\t')
      if (PANELS.has(name)) continue
      windows.push({
        session: f[1] ?? '',
        windowId: f[2] ?? '',
        state: f[3] ?? '',
        loop: f[5] ?? '',
        key: windowKey(f[6] ?? '', f[7] ?? '', f[9] ?? ''),
        origin: f[8] ?? '',
        name,
      })
    }
  }
  return { self, windows }
}

/** This window's own ledger key (bare), or '' for the hub / a plain window. */
export function selfKey(self: SelfRow): string {
  if (self.issue !== null) return `issue-${self.issue}`
  return scratchKey(self.worktree) || scratchKey(self.path)
}

/** Strip a `<slug>:` prefix off a ledger / origin key. */
function bare(key: string): string {
  const i = key.lastIndexOf(':')
  return i < 0 ? key : key.slice(i + 1)
}

export type LedgerRow = { child: string; state: string; verdict: string }

/** The newest outcome row per child of a children ledger (.ndjson). */
export function parseLedger(text: string): Map<string, LedgerRow> {
  const rows: Array<{ seq: number; row: LedgerRow }> = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    try {
      const d = JSON.parse(line) as Record<string, unknown>
      if (typeof d.child !== 'string' || typeof d.state !== 'string') continue
      rows.push({
        seq: typeof d.seq === 'number' ? d.seq : 0,
        row: { child: bare(d.child), state: d.state, verdict: typeof d.verdict === 'string' ? d.verdict : '' },
      })
    } catch {
      // A torn line is skipped, never fatal.
    }
  }
  rows.sort((a, b) => a.seq - b.seq)
  const last = new Map<string, LedgerRow>()
  for (const { row } of rows) last.set(row.child, row)
  return last
}

/** Same buckets as bin/fleet-children.py: `!` needs you · `✓` done · `▸` going · `–` ended. */
export function bucket(live: WindowRow | undefined, last: LedgerRow | undefined): '!' | '✓' | '▸' | '–' {
  const lst = last?.state ?? ''
  if (live !== undefined) {
    if (live.state === 'needs' || live.state === 'failed') return '!'
    // A `done` window still holding a /loop round is looping, not finished (#1331).
    return live.state === 'done' && live.loop === '' ? '✓' : '▸'
  }
  if (lst === 'MERGED' || (lst === 'REAPED' && (last?.verdict ?? '').startsWith('merged'))) return '✓'
  if (lst === 'BLOCKED' || lst === 'FAILED') return '!'
  if (lst === 'WAITING') return '▸'
  return '–'
}

export type ChildRow = { key: string; glyph: '!' | '✓' | '▸' | '–' }

/** Every child of this window: live ones by @origin, ended ones from the ledger. */
export function children(self: SelfRow, windows: WindowRow[], ledger: Map<string, LedgerRow>): ChildRow[] {
  const mine = selfKey(self)
  const live = new Map<string, WindowRow>()
  for (const w of windows) {
    if (w.session !== self.session || w.windowId === self.windowId || w.key === '') continue
    // The hub's children carry no @origin at all (`fleet_origin_canon`: empty ≡ hub).
    const isMine = mine === '' ? w.origin === '' : bare(w.origin) === mine
    if (isMine) live.set(w.key, w)
  }
  const keys = new Set<string>([...live.keys(), ...(mine === '' ? [] : ledger.keys())])
  return [...keys].sort().map(key => ({ key, glyph: bucket(live.get(key), ledger.get(key)) }))
}

export type PrRow = { number: number; state: string; ci: string; ready: string }

/** prmap: the row for `branch`, newest first as the dash writes it. */
export function prFor(prmap: string, branch: string): PrRow | null {
  for (const line of prmap.split('\n')) {
    const f = line.split('\t')
    if (f[0] !== branch) continue
    const n = int((f[1] ?? '').replace(/^#/, ''))
    if (n === null) continue
    return { number: n, state: f[2] ?? '', ci: f[3] ?? '', ready: f[4] ?? '' }
  }
  return null
}

// ---- the band -------------------------------------------------------------
//
// One segment: this issue's PR and its checks (issue #1527). The task number,
// the EPIC, children k/N and context % were here too, but the top-right corner
// and the sidebar already show them — the band only says what nothing else
// does. A window with no PR (the hub, a scratch, an issue not yet pushed) draws
// nothing, so the row costs no height there.

export type Segment = { id: 'pr'; text: string; color?: string }

const CI: Record<string, { word: string; color?: string }> = {
  '✓': { word: '✓', color: 'green' },
  '✗': { word: '✗!', color: 'red' },
  '…': { word: '…', color: 'yellow' },
  '·': { word: '·' },
}
const READY: Record<string, string> = { conflict: '冲突!', behind: '落后', blocked: '待审', draft: '草稿' }

export function segments(s: ProgressSnapshot): Segment[] {
  const p = s.pr
  if (p === null) return []
  if (p.state === 'MERGED') return [{ id: 'pr', text: `PR #${p.number} 已合并`, color: 'green' }]
  if (p.state === 'CLOSED') return [{ id: 'pr', text: `PR #${p.number} 已关闭` }]
  const ci = CI[p.ci] ?? { word: p.ci }
  const ready = READY[p.ready]
  const color = ready?.endsWith('!') ? 'red' : ci.color
  return [{ id: 'pr', text: `PR #${p.number} ${ci.word}${ready ? ` ${ready}` : ''}`, color }]
}

/** The band as one line of text (what a test and the after-evidence read). */
export function bandText(s: ProgressSnapshot): string {
  return segments(s).map(x => x.text).join('')
}

// ---- alerts ---------------------------------------------------------------

/** The alert keys standing right now, each with its toast. */
export function alertsOf(s: ProgressSnapshot): Map<string, string> {
  const m = new Map<string, string>()
  for (const k of s.needsKids) m.set(`kid:${k}`, `子任务 ${k.replace(/^issue-/, '#')} 需要你处理`)
  if (s.pr !== null && s.pr.state === 'OPEN' && s.pr.ci === '✗') m.set(`pr:${s.pr.number}`, `PR #${s.pr.number} 检查变红了`)
  return m
}

/**
 * Which alerts to toast now, and the set to keep. An alert toasts once when it
 * appears; while it stands it stays quiet; once it clears it is forgotten, so a
 * child that falls back into needs, or a PR red again after green, toasts again.
 */
export function newAlerts(prev: readonly string[], s: ProgressSnapshot): { toasts: string[]; keep: string[] } {
  const now = alertsOf(s)
  const before = new Set(prev)
  return {
    toasts: [...now].filter(([k]) => !before.has(k)).map(([, t]) => t),
    keep: [...now.keys()],
  }
}
