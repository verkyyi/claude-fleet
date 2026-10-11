// What the steward plugin's panels share (issue #3115, EPIC #3111 C4): the
// strings, where the fleet's scripts are, the window-option write, a children
// ledger's reader — and WHO HOLDS THE STEWARD ROLE, which is the one switch here.
//
// The panels moved out of the core mod (mod/fleet) into this plugin. A plugin
// cannot import another plugin's files, so the few helpers they leaned on there
// live here; nothing else.
//
// The holder: bin/fleet-role-take.sh (take_role steward, run by /fleet-steward)
// writes the role's ONE line in $FLEET_CONF_DIR/global/roles.held —
// `steward TAB <session> TAB <fleet_id> TAB <window id> TAB <epoch>` — and stamps
// the window `@fleet_role_def steward`. panels.ts stats that file on its one-second
// tick and reads it when it moved: this window holds the role ⇔ the line names
// its @fleet_id (else its window id). So the panels follow a /fleet-steward typed
// after the session started, and stop the tick after the role is dropped or
// stolen — no process is run for it. No line, another window, or a window that is
// no fleet pane ⇒ nothing here draws, opens or answers.

/** How long one tmux call may take before the run is abandoned. */
export const TMUX_TIMEOUT_MS = 5000

/** The three panes, and the window option that says the decision sheet is up. */
export const SHEET_PANE = 'fleet-sheet'
export const PATROL_PANE = 'fleet-patrol'
export const BATCHES_PANE = 'fleet-batches'
export const SHEET_OPTION = '@sheet_pane'

let strings: Record<string, string> = {}
let bin = ''
let held = false

/** Where the fleet's scripts are: FLEET_MCP_BIN (a dev tree), else the live install. */
export function binDir(fleetBin: string | undefined, home: string | undefined): string {
  return fleetBin || `${home ?? ''}/.claude/fleet/bin`
}

/** panels.ts's session.start: the scripts' directory for every run here. */
export function setBin(dir: string): void {
  bin = dir
}

/** The fleet's bin/ (set at session.start; the live install's before that). */
export function fleetBin(): string {
  return bin || binDir(undefined, '')
}

/** The argv that prints the `panel_` strings (KEY NUL TEXT NUL, a \001 per printf slot). */
export function stringsArgv(dir: string): string[] {
  return ['sh', `${dir}/fleet-ui-lang.sh`, 'dump', 'panel_']
}

/** Tests: is this argv the strings read? */
export function isStringsRun(argv: readonly string[]): boolean {
  return argv[0] === 'sh' && (argv[1] ?? '').endsWith('/fleet-ui-lang.sh') && argv[2] === 'dump'
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

/**
 * The argv that sets (string) or unsets (null) window options on `pane`'s
 * window, all in ONE tmux call (`;`-chained); null when there is nothing to do.
 * A bare `tmux` lands on this fleet's own server through $TMUX; `-t` pins the
 * write to this pane's window.
 */
export function windowOptionsArgv(pane: string, options: Record<string, string | null>): string[] | null {
  const argv: string[] = ['tmux']
  for (const [key, value] of Object.entries(options)) {
    if (argv.length > 1) argv.push(';')
    if (value === null) argv.push('set-option', '-w', '-u', '-t', pane, key)
    else argv.push('set-option', '-w', '-t', pane, key, value)
  }
  return argv.length > 1 ? argv : null
}

/** The one tmux read at session.start: this pane's window — its id, @fleet_id and @issue. */
export function windowArgv(pane: string): string[] {
  return ['tmux', 'display-message', '-p', '-t', pane, '#{window_id}|#{@fleet_id}|#{@issue}']
}

/** Tests: is this argv the window read? */
export function isWindowRun(argv: readonly string[]): boolean {
  return argv[0] === 'tmux' && argv[1] === 'display-message' && argv[argv.length - 1] === '#{window_id}|#{@fleet_id}|#{@issue}'
}

export type Self = { wid: string; fid: string; issue: string }

export function parseWindow(read: string): Self {
  const [wid = '', fid = '', issue = ''] = read.trim().split('|')
  return { wid, fid, issue }
}

/** Does roles.held name this window as the steward? Its @fleet_id first, else its window id. */
export function holdsSteward(rolesHeld: string, self: Self): boolean {
  if (self.wid === '' && self.fid === '') return false
  let line: string[] | undefined
  for (const l of rolesHeld.split('\n')) {
    const f = l.split('\t')
    if (f[0] === 'steward') line = f
  }
  if (line === undefined) return false
  const fid = line[2] ?? ''
  const wid = line[3] ?? ''
  if (fid !== '' && self.fid !== '') return fid === self.fid
  return wid !== '' && wid === self.wid
}

/** panels.ts: the last roles.held read said this window holds the role (or not). */
export function setHeld(on: boolean): void {
  held = on
}

/** Does this window hold the steward role right now? Every hook here asks this first. */
export function isHolder(): boolean {
  return held
}

/** Tests: forget everything. */
export function resetCommon(): void {
  strings = {}
  bin = ''
  held = false
}

export type LedgerRow = { child: string; state: string; verdict: string }

/** Strip a `<slug>:` prefix off a ledger / origin key. */
function bare(key: string): string {
  const i = key.lastIndexOf(':')
  return i < 0 ? key : key.slice(i + 1)
}

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
