#!/bin/bash
# origin-selftest.sh — spawn provenance (@origin, issue #503) end to end.
#
# Three parts:
#   A. fleet_origin_key (fleet-lib.sh) against a REAL isolated tmux server:
#      an @issue window resolves to issue-<N>, an @raw window to its
#      scratch-<N> (from @worktree), a plain window / no-$TMUX caller to EMPTY.
#   B. the HISTORY half, fully hermetic (no tmux): record-closed --origin writes
#      ledger col 11; an origin-less record writes '-'; fleet_reap_record threads
#      its 11th arg through; `rows` renders the ↳ tag only on tagged rows; `meta`
#      emits origin as its 3rd field.
#   C. the DASH GROUPING (tmux-dashboard-rows.sh) against the isolated server:
#      hub-spawned roots keep their order, a child (`@origin=issue-<N>` /
#      scratch parent) sorts DIRECTLY under its live parent with the └ indent +
#      ↳ tag, and an orphan (parent window gone) sinks below every live group.
#
# tmux absent → parts A/C SKIP cleanly; part B always runs. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
HIST="$BIN/fleet-history.sh"
[ -f "$LIB" ]  || { printf 'selftest: %s not found\n' "$LIB"  >&2; exit 2; }
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
[ -f "$HIST" ] || { printf 'selftest: %s not found\n' "$HIST" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/origin-selftest.XXXXXX")" || exit 2

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]";; esac; }

# ============================================================================
# B. history: ledger col 11, fleet_reap_record arg 11, rows ↳ tag, meta field 3
# ============================================================================
export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
export CLAUDE_PROJECTS_DIR="$WORK/projects"
mkdir -p "$CLAUDE_PROJECTS_DIR"

mk_wt() { # <worktree-path> — fabricate the transcript dir so record-closed indexes it
  local enc; enc=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
  mkdir -p "$CLAUDE_PROJECTS_DIR/$enc" "$1"
  : > "$CLAUDE_PROJECTS_DIR/$enc/sess-$(basename "$1").jsonl"
}

WT1="$WORK/wt/repo-issue-77";   mk_wt "$WT1"
WT2="$WORK/wt/repo-issue-78";   mk_wt "$WT2"
WT3="$WORK/wt/repo-scratch-901"; mk_wt "$WT3"

# record-closed WITH --origin → col 11 carries it; state stays col 10.
bash "$HIST" record-closed --key 77 --worktree "$WT1" --session s \
  --title t77 --origin issue-42 >/dev/null 2>&1
row=$(grep -m1 "	77	" "$FLEET_HISTORY_LEDGER")
eq "record-closed --origin → col 11" "issue-42" "$(printf '%s' "$row" | awk -F'\t' '{print $11}')"
eq "record-closed --origin → col 10 still state" "closed-unlanded" "$(printf '%s' "$row" | awk -F'\t' '{print $10}')"

# record-closed WITHOUT --origin → '-' (hub), 11 columns still.
bash "$HIST" record-closed --key 78 --worktree "$WT2" --session s \
  --title t78 >/dev/null 2>&1
row=$(grep -m1 "	78	" "$FLEET_HISTORY_LEDGER")
eq "origin-less record → col 11 is '-'" "-" "$(printf '%s' "$row" | awk -F'\t' '{print $11}')"

# fleet_reap_record threads its 11th arg into the ledger row.
# shellcheck source=/dev/null
. "$LIB"
fleet_reap_record "unmerged" "fake/repo" "" "" "$WT3" "" "s" "" "scratch-901" "scrX" "issue-100"
row=$(grep -m1 "	scratch-901	" "$FLEET_HISTORY_LEDGER")
[ -n "$row" ] || fail "fleet_reap_record: no scratch-901 row written"
eq "fleet_reap_record arg 11 → col 11" "issue-100" "$(printf '%s' "$row" | awk -F'\t' '{print $11}')"

# fleet_origin_canon <explicit> <detected> [<target-sess>] [<src-sess>] — the
# spawners' single provenance decision. An explicit --origin is canonicalized to
# the key grammar (a Claude that read the spawner's header passed its worktree
# BASENAME, `cd-conductor-scratch-52` — that must land as scratch-52, or the dash
# can neither nest the child nor find its parent); an unrecognizable explicit
# value yields to the pane-detected key when there is one (headless, it stays a
# free-form label); and the #516 cross-fleet override (source FLEET, not a key
# that names some other window on the target's dash) applies to whatever was
# detected. Canonical keys + the known literals pass through untouched.
canon() { fleet_origin_canon "$@" 2>/dev/null; }
eq "canon: worktree basename → scratch key"              "scratch-52" "$(canon cd-conductor-scratch-52 scratch-52)"
eq "canon: basename alone (tail re-entry, no pane)"      "scratch-52" "$(canon cd-conductor-scratch-52 '')"
eq "canon: issue worktree basename → issue key"          "issue-4591" "$(canon repo-issue-4591 '')"
eq "canon: a canonical key passes through"               "issue-77"   "$(canon issue-77 scratch-5)"
eq "canon: a known literal wins over detection"          "autofill"   "$(canon autofill scratch-5)"
eq "canon: garbage explicit yields to detected"          "scratch-52" "$(canon foo scratch-52)"
eq "canon: garbage explicit, headless → kept as label"   "foo"        "$(canon foo '')"
eq "canon: sanitized to the key charset"                 "badvalue"   "$(canon 'bad value!' '')"
eq "canon: no explicit → detected"                       "scratch-52" "$(canon '' scratch-52)"
eq "canon: cross-fleet → source fleet"                   "srcfleet"   "$(canon '' scratch-5 dstfleet srcfleet)"
eq "canon: same fleet keeps the key"                     "scratch-5"  "$(canon '' scratch-5 srcfleet srcfleet)"
eq "canon: no target ≡ own fleet"                        "scratch-5"  "$(canon '' scratch-5 '' srcfleet)"
eq "canon: garbage explicit + cross-fleet → source fleet" "srcfleet"  "$(canon foo scratch-5 dstfleet srcfleet)"
eq "canon: explicit key honoured across fleets (#516)"   "issue-77"   "$(canon issue-77 scratch-5 dstfleet srcfleet)"
eq "canon: nothing anywhere ≡ hub"                       ""           "$(canon '' '')"

# rows: the ↳ tag renders on tagged rows only (strip ANSI + the US field bytes).
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g' -e $'s/\x1f/ /g'; }
rows_out=$(FZF_COLUMNS=140 bash "$HIST" rows 2>/dev/null | strip)
contains "rows: worker-origin tag" "$rows_out" "↳#42"
contains "rows: scratch row's own worker-origin tag" "$rows_out" "↳#100"
r78=$(printf '%s\n' "$rows_out" | grep 't78')
not_contains "rows: hub row has no tag" "$r78" "↳"

# meta: origin rides as field 3 ('-' for a hub row).
eq "meta: origin field" "issue-42" "$(bash "$HIST" meta 77 | awk -F'\t' '{print $3}')"
eq "meta: hub row origin field" "-" "$(bash "$HIST" meta 78 | awk -F'\t' '{print $3}')"

printf 'origin-selftest: part B ok (%d checks)\n' "$CHECKS"

# ============================================================================
# A + C need a real tmux — SKIP them cleanly when absent (run-selftests convention)
# ============================================================================
REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -z "$REAL_TMUX" ]; then
  printf 'origin-selftest: tmux not installed — parts A/C SKIPPED, part B passed\n'
  rm -rf "$WORK"; exit 0
fi

# Isolated server via PATH shim (never the live server; see dash-marker-selftest).
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK"     # scope the dash cache under WORK
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# US round-trip probe (some Linux tmux builds octal-escape 0x1f in -F output —
# the producer can't parse there for reasons unrelated to #503; see #208's test).
US=$(printf '\037')
tmux new-session -d -s probe -x 80 -y 24 'sleep 300' 2>/dev/null || fail "could not start isolated tmux server"
probe_out=$(tmux list-windows -t probe -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n')
tmux kill-session -t probe 2>/dev/null
case "$probe_out" in
  *611f62*) : ;;
  *) printf 'origin-selftest: this tmux octal-escapes US in -F — parts A/C SKIPPED, part B passed\n'; exit 0 ;;
esac

# ============================================================================
# A. fleet_origin_key — caller-pane detection
# ============================================================================
mkdir -p "$WORK/wt/repo-scratch-7" "$WORK/wt/repo-scratch-9"
# -c "$WORK" on the session AND every pane: a pane must never inherit the INVOKING
# cwd — run from a checkout named `…-scratch-<N>` the plain pane would otherwise
# key as that scratch (detection is path-based below, like the dash's okey_v).
tmux new-session -d -s ok -x 200 -y 50 -c "$WORK" 'sleep 300' || fail "could not start 'ok' session"
mk_pane() { # <name> [cwd] → pane id of a fresh window running sleep
  tmux new-window -d -P -F '#{pane_id}' -t ok: -n "$1" -c "${2:-$WORK}" 'sleep 300'
}
p_iss=$(mk_pane w-iss);  tmux set-window-option -t "$p_iss" @issue 42
p_raw=$(mk_pane w-raw);  tmux set-window-option -t "$p_raw" @raw 1
tmux set-window-option -t "$p_raw" @worktree "$WORK/wt/repo-scratch-7"
p_plain=$(mk_pane w-plain)
# A scratch window with NO @raw/@worktree stamps — what fleet-restore.sh recreates
# after a crash (it re-stamps only @issue/@origin/@claude_state) — is still a
# scratch: its cwd IS the scratch worktree, the very path-only rule the dash's
# okey_v keys the PARENT side by. Detection must agree, or every spawn from a
# crash-restored scratch reads as hub-spawned (#4594 on the monorepo dash).
p_bare=$(mk_pane w-bare "$WORK/wt/repo-scratch-9")

og() { TMUX="fake,1,1" TMUX_PANE="$1" bash -c ". '$LIB'; fleet_origin_key"; }
eq "origin_key: @issue pane" "issue-42" "$(og "$p_iss")"
eq "origin_key: @raw pane (from @worktree)" "scratch-7" "$(og "$p_raw")"
eq "origin_key: plain pane ≡ hub (empty)" "" "$(og "$p_plain")"
eq "origin_key: unstamped scratch pane (cwd only)" "scratch-9" "$(og "$p_bare")"
noenv=$(env -u TMUX -u TMUX_PANE bash -c ". '$LIB'; fleet_origin_key")
eq "origin_key: no \$TMUX ≡ hub (empty)" "" "$noenv"

printf 'origin-selftest: part A ok\n'

# ============================================================================
# C. dash grouping — roots keep order, children under parents, orphans sink
# ============================================================================
mkdir -p "$WORK/wt/repo-scratch-5"
# -c "$WORK": the initial window must NOT inherit the invoking cwd — running this
# selftest from a checkout whose dir name happens to end `-scratch-<N>` would give
# that window the same scratch key as scrP and shadow the parent lookup.
tmux new-session -d -s fleetC -x 220 -y 50 -c "$WORK" 'sleep 300' || fail "could not start 'fleetC' session"
mk_win() { # <name> [issue] [origin] [cwd] → window id
  local n="$1" iss="${2:-}" org="${3:-}" cwd="${4:-$WORK}" wid
  wid=$(tmux new-window -d -P -F '#{window_id}' -t fleetC: -n "$n" -c "$cwd" 'sleep 300')
  [ -n "$iss" ] && tmux set-window-option -t "$wid" @issue "$iss"
  [ -n "$org" ] && tmux set-window-option -t "$wid" @origin "$org"
  printf '%s' "$wid"
}
mk_win rootA 100 ''            >/dev/null
mk_win rootB 101 ''            >/dev/null
mk_win kidA  102 issue-100     >/dev/null
mk_win orphX 103 issue-999     >/dev/null
mk_win scrP  ''  ''  "$WORK/wt/repo-scratch-5" >/dev/null
mk_win kidS  104 scratch-5     >/dev/null

out=$(FLEET_SESSION=fleetC FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null | strip)
[ -n "$out" ] || fail "grouping: rows produced no output"
[ "${ORIGIN_SELFTEST_DEBUG:-0}" = 1 ] && printf '%s\n' "$out" | cat -n | cut -c1-100 >&2

lineno() { printf '%s\n' "$out" | grep -n -- "$1" | head -1 | cut -d: -f1; }
l_rootA=$(lineno ' rootA'); l_rootB=$(lineno ' rootB'); l_kidA=$(lineno 'kidA')
l_orphX=$(lineno 'orphX');  l_scrP=$(lineno ' scrP');   l_kidS=$(lineno 'kidS')
for v in l_rootA l_rootB l_kidA l_orphX l_scrP l_kidS; do
  [ -n "${!v}" ] || fail "grouping: window ${v#l_} missing from rows output"
done
CHECKS=$((CHECKS + 6))

# children directly under their parents; orphan below every live group
[ "$l_kidA" -eq $((l_rootA + 1)) ] || fail "grouping: kidA (↳#100) must sit directly under rootA (rootA=$l_rootA kidA=$l_kidA)"
[ "$l_rootB" -gt "$l_kidA" ]       || fail "grouping: rootB must follow rootA's group (rootB=$l_rootB kidA=$l_kidA)"
[ "$l_kidS" -eq $((l_scrP + 1)) ]  || fail "grouping: kidS (↳~5) must sit directly under scrP (scrP=$l_scrP kidS=$l_kidS)"
for v in "$l_rootA" "$l_rootB" "$l_kidA" "$l_scrP" "$l_kidS"; do
  [ "$l_orphX" -gt "$v" ] || fail "grouping: orphX (dead parent) must sink below every live group (orphX=$l_orphX vs $v)"
done
CHECKS=$((CHECKS + 8))

# tags + indent
contains "grouping: kidA carries the ↳#100 tag" "$out" "↳#100"
contains "grouping: kidA is indented" "$out" "└ kidA"
contains "grouping: kidS carries the ↳~5 tag" "$out" "↳~5"
contains "grouping: orphX keeps its tag" "$out" "↳#999"
rootA_line=$(printf '%s\n' "$out" | grep -- ' rootA')
not_contains "grouping: a hub root has no tag" "$rootA_line" "↳"

printf 'origin-selftest OK (%d checks)\n' "$CHECKS"
