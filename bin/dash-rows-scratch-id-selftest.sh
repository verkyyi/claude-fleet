#!/bin/bash
# dash-rows-scratch-id-selftest.sh — the dash id column tells a SCRATCH apart from
# an ISSUE WORKER at a glance, in BOTH dash views (issue #529).
#
# The rule under test, one grammar across the ⌃t toggle:
#   * an issue-bound worker → `#<N>` in GREEN  (38;2;158;206;106)
#   * a scratch session     → `~<N>` in INDIGO (38;2;187;154;247)
#   * anything else         → a blank cell
# `~<N>` is the fleet's existing scratch grammar (fleet-history.sh key_label, the
# `↳~12` provenance tag, `/fleet-history list`); indigo is the colour that tag is
# already drawn in. The COLOUR is the load-bearing half: #499/#502 put a GREEN
# `~<N>` in this cell, found it "indistinguishable from `#<N>` at a glance", and
# blanked the cell instead — which left a scratch with NO id on the dash at all.
# So every id assertion here pins the colour ESCAPE + the text together; a future
# change that paints `~<N>` green again fails this test, it does not quietly
# re-create the #502 confusion.
#
# The other half is WHERE the id comes from. It must be read from `@worktree`
# first and the pane cwd only as a fallback, because both of the cwd-only reader's
# blind spots are ordinary states for a live scratch:
#   * the window was renamed (`dash-raw-session.sh --name`, #225, or ⌃n), so the
#     window column no longer carries `scratch-<N>` either — the id cell is then
#     the ONLY place the id survives; and
#   * its Claude `cd`'d into a subdirectory, so the cwd basename is `docs`, not
#     `<repo>-scratch-<N>`, and the strict key rule yields nothing.
# Fixture 3 below is exactly that window (renamed AND wandered) and is the reason
# WFMT carries @worktree at all. It doubles as a guard on okey_v's other consumer:
# the same key drives the #503 spawn-provenance grouping, which had the same blind
# spot (a restored/wandered scratch's children rendered as hub-spawned).
#
# Fully hermetic: `tmux` is PATH-shimmed to replay a fixture window list (never a
# live server, per the repo rail — and it keeps the test independent of the tmux
# version, since tmux ≤3.4 vis-escapes the 0x1f field separator the real producer
# asks for), and the landed view reads a FLEET_HISTORY_LEDGER temp file. No gh, no
# git, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
HIST="$BIN/fleet-history.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
[ -f "$HIST" ] || { printf 'selftest: %s not found\n' "$HIST" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashid-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"                    # fleet_cache's $C lands in the sandbox
mkdir -p "$WORK/.claude-dash/global"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

US=$'\x1f'
GN='38;2;158;206;106m'      # green  — an issue-bound worker
IN='38;2;187;154;247m'      # indigo — a scratch
SESS=fleet-testrepo

# --- tmux shim: replay a fixed window list, no-op everything else --------------
# The producer makes exactly ONE tmux call (`list-windows -a -F <fmt>`); the shim
# replays $WLIST_FILE for it and exits 0 silently for anything fleet-lib might ask.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
for a in "$@"; do
  [ "$a" = list-windows ] && { cat "$WLIST_FILE"; exit 0; }
done
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

# --- fixture windows ----------------------------------------------------------
# Field order MUST match WFMT in tmux-dashboard-rows.sh:
#   session idx name path state state_ts window_id @issue @origin @worktree
WLIST_FILE="$WORK/wlist"; export WLIST_FILE
w() { printf '%s\n' "$SESS$US$1$US$2$US$3$US$4$US$US$5$US$6$US$7$US$8" >> "$WLIST_FILE"; }
: > "$WLIST_FILE"
#   idx name              cwd                     state  wid @issue @origin @worktree
w 1 fix-the-thing         /w/repo-issue-123       idle   @1  123 ''  /w/repo-issue-123
w 2 scratch-9             /w/repo-scratch-9       idle   @2  ''  ''  /w/repo-scratch-9
w 3 tencent-workbuddy     /w/repo-scratch-5/docs  idle   @3  ''  ''  /w/repo-scratch-5
w 4 hub                   /w/repo                 idle   @4  ''  ''  ''

out=$(FLEET_SESSION="$SESS" FZF_COLUMNS=120 bash "$ROWS" 2>&1) \
  || fail "live rows producer exited non-zero" "$out"
row_of() { printf '%s\n' "$out" | grep -F "$SESS:$1$US"; }
r1=$(row_of 1); r2=$(row_of 2); r3=$(row_of 3); r4=$(row_of 4)
[ -n "$r1" ] && [ -n "$r2" ] && [ -n "$r3" ] && [ -n "$r4" ] \
  || fail "live rows: expected a row per fixture window" "$out"

# 1. an issue worker keeps the green `#<N>` it always had.
has "live: worker id cell is GREEN #123" "$r1" "$GN#123"

# 2. a scratch gets an INDIGO `~<N>` — never green, and never `#<N>` (which would
#    read as an issue that does not exist).
has   "live: scratch id cell is INDIGO ~9" "$r2" "$IN~9"
hasnt "live: scratch id must not be green" "$r2" "$GN~9"
hasnt "live: scratch must not render as #9" "$r2" "#9"

# 3. THE #529 CASE — renamed window + cwd wandered into a subdir: the id survives
#    because it is read from @worktree, and it is the only id left on the row.
has   "live: renamed+wandered scratch still shows INDIGO ~5" "$r3" "$IN~5"
hasnt "live: renamed scratch's window column no longer carries the id" "$r3" "scratch-5"

# 4. a window that is neither → blank cell (5 spaces), not a stray `~`/`#`.
hasnt "live: a non-scratch, non-worker window prints no id" "$r4" "~"

# 5. alignment: the id cell stays 5 wide in every shape, so every column after it
#    lines up. Asserted as ONE exact substring — <colour><cell><reset> — rather than
#    by character offset: the row's leading state glyph (·/⠋/✓) is multi-byte UTF-8,
#    so any positional read (cut -c, substr) counts BYTES under the C locale CI runs
#    in and lands one column short, while the escape-anchored form is locale-proof
#    and pins the colour and the padding in the same check.
cellis() {   # <label> <row> <5-char cell> <colour>
  CHECKS=$((CHECKS+1))
  case "$2" in *"$4$3"$'\033[0m'*) : ;; *) fail "$1" "$2";; esac
}
cellis "live: worker id cell is GREEN and 5 wide"           "$r1" "#123 " "$GN"
cellis "live: scratch id cell is INDIGO and 5 wide"         "$r2" "~9   " "$IN"
cellis "live: wandered scratch id cell is INDIGO, 5 wide"   "$r3" "~5   " "$IN"
cellis "live: unkeyed window id cell is 5 blanks"           "$r4" "     " "$GN"

# --- the landed view (⌃t) must speak the SAME grammar -------------------------
# #502 blanked the landed scratch cell to match the live view of the day; now that
# the live view paints an id, a blank here is what would split the two.
export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
printf '2026-01-01T00:00:00Z\t123\tfix the thing\t61\tsha1\t/w/repo-issue-123\t/nope\tsid-a\t-\t\n' \
  > "$FLEET_HISTORY_LEDGER"
printf '2026-01-02T00:00:00Z\tscratch-7\tan experiment\t-\t-\t/w/repo-scratch-7\t/nope\tsid-b\t-\tclosed-unlanded\n' \
  >> "$FLEET_HISTORY_LEDGER"
lout=$(FLEET_REPO=fake/repo FZF_COLUMNS=120 bash "$HIST" rows 2>&1) \
  || fail "landed rows producer exited non-zero" "$lout"
lw=$(printf '%s\n' "$lout" | grep -F 'landed:61')
ls_=$(printf '%s\n' "$lout" | grep -F 'landed:scratch:scratch-7')
[ -n "$lw" ] && [ -n "$ls_" ] || fail "landed rows: expected a worker row and a scratch row" "$lout"
has   "landed: worker id cell is GREEN #123"  "$lw"  "$GN#123"
has   "landed: scratch id cell is INDIGO ~7"  "$ls_" "$IN~7"
hasnt "landed: scratch id must not be green"  "$ls_" "$GN~7"
hasnt "landed: scratch must not render as #7" "$ls_" "#7"

printf 'dash-rows-scratch-id-selftest: OK (%d checks)\n' "$CHECKS"
