#!/bin/bash
# dash-rows-prmap-scale-selftest.sh — the dash's PR-cell lookup must not scan the
# whole prmap per row (issue #662).
#
# The PR cell resolves a window's branch to its prmap line. That lookup used to be
# `${PRMAPN#*$'\n'"$bare"$'\t'}` against the ENTIRE prmap string, up to THREE times
# per row (the exact spelling, then the two decoration-stripped ones) — so the cost
# of one dash frame was O(prmap × windows), and it grew every time the repo landed a
# PR. On a 6-window fleet with an 88-line prmap that was 270ms of a 380ms frame, and
# the dash repaints at 1Hz; #648's ←/→ pay one frame per keystroke.
#
# Two things are pinned here, and the SECOND is the one that rots silently:
#   A. correctness — all three candidate spellings still resolve, an exact branch
#      that itself ends in `-<digits>` still wins over its stripped form, and a
#      branch with no PR still renders the em-dash.
#   B. SCALE — a render against a BIG prmap must cost about the same as one against
#      a tiny prmap. This is a ratio, not an absolute: it is the algorithmic
#      property (per-row work independent of prmap size), and a generous bound
#      keeps it honest on a noisy CI box without letting an O(n)-per-row
#      regression back in — the pre-fix code is ~20× over this fixture.
#
# Hermetic: a tmux STUB feeds the fixture window list; no server, no git, no gh.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prmap-scale-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
export TMPDIR="$WORK"                  # fleet-lib derives FLEET_C from TMPDIR
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"
unset FLEET_REPO 2>/dev/null || true
SESS=s1
C="$WORK/.claude-dash"; mkdir -p "$C/global" "$C/fleets/fake-repo" "$WORK/conf" "$WORK/bin"
FD="$C/fleets/fake-repo"
printf '%s\tfake-repo\tfake/repo\n' "$SESS" > "$C/global/sessmap"

US=$(printf '\037')
# Only the producer's `list-windows -a -F <US-separated fmt>` gets the fixture;
# #566's own `-F '#{@wid}'` handle scan must NOT (it would read as N taken handles).
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037')
lw=0; fmt=0
for a in "$@"; do
  [ "$a" = list-windows ] && lw=1
  case "$a" in *"$US"*) fmt=1 ;; esac
done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

# git_<key> cache = the branch of each window's cwd. cache_key: / → _s, _ → _u.
gk() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }
gitc() { printf '%s\tclean\n' "$2" > "$C/global/git_$(gk "$1")"; }

WLIST_FILE="$WORK/wlist"; export WLIST_FILE
# Field order MUST match WFMT in tmux-dashboard-rows.sh; trailing fields a fixture
# does not set simply arrive empty.
#   session idx name path state state_ts window_id @issue @origin @worktree …
w() { printf '%s\n' "$SESS$US$1$US$2$US$3$US$4$US$US$5$US$6$US$7$US$8" >> "$WLIST_FILE"; }

rows() { FLEET_SESSION="$SESS" FZF_COLUMNS=140 bash "$ROWS" 2>&1; }
row_of() { printf '%s\n' "$1" | grep -F "$SESS:$2$US"; }
ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || printf '0'; }

# ============================================================================
# A. correctness — the three candidate spellings, and the miss
# ============================================================================
# `issue-231` is the load-bearing case: the EXACT branch ends in `-<digits>`, so
# the decoration-stripped candidate would be the bare `issue`. Exact must win.
{ printf 'issue-231\t#901\tOPEN\t✓\tready\t\n'
  printf 'feat-x\t#902\tOPEN\t✓\tready\t\n'
  printf 'issue\t#903\tMERGED\t✓\t\t\n'
} > "$FD/prmap"
: > "$FD/prmap.ts"
: > "$WLIST_FILE"
#   idx name   cwd              state wid @issue @origin @worktree
w 1 exact      /w/r-issue-231   idle @1 231 '' /w/r-issue-231
w 2 ahead      /w/r-feat-x      idle @2 232 '' /w/r-feat-x
w 3 nopr       /w/r-orphan      idle @3 233 '' /w/r-orphan
gitc /w/r-issue-231 'issue-231'      # exact — must NOT be stripped to `issue`
gitc /w/r-feat-x    'feat-x+3'       # +ahead decoration — strips to `feat-x`
gitc /w/r-orphan    'no-such-branch' # no PR at all

out=$(rows) || fail "rows producer exited non-zero" "$out"
has  "exact branch ending in -<digits> resolves to ITS OWN PR" "$(row_of "$out" 1)" "#901"
hasnt "… and not to the stripped-name PR"                      "$(row_of "$out" 1)" "#903"
has  "a +ahead-decorated branch resolves to the bare branch"   "$(row_of "$out" 2)" "#902"
hasnt "a branch with no PR shows no number"                    "$(row_of "$out" 3)" "#9"
has  "… it shows the em-dash instead"                          "$(row_of "$out" 3)" "—"

# ============================================================================
# B. scale — per-row cost must not follow prmap size
# ============================================================================
# Same three windows, same three real entries, but buried in a prmap two orders of
# magnitude larger. The rendered ROWS must be byte-identical (nothing in the noise
# matches any window's branch) and the frame must not cost meaningfully more.
# A regression here is SLOW (the pre-fix code takes ~20s on this fixture), so the
# big side is measured with ONE render and the assertion fires on it — a broken
# build must not sit in CI for minutes doing repetitions of a known-bad frame.
small_out="$out"
t0=$(ms); for i in 1 2 3; do rows >/dev/null 2>&1; done; t1=$(ms)
small_ms=$(( (t1 - t0) / 3 ))

{ cat "$FD/prmap"
  i=0
  while [ "$i" -lt 2000 ]; do printf 'noise-branch-%s\t#%s\tMERGED\t✓\t\tsha%s\n' "$i" "$i" "$i"; i=$((i+1)); done
} > "$FD/prmap.big"
mv "$FD/prmap.big" "$FD/prmap"

t0=$(ms); big_out=$(rows); rc=$?; t1=$(ms); big_ms=$(( t1 - t0 ))
[ "$rc" -eq 0 ] || fail "rows producer exited non-zero against a big prmap" "$big_out"

CHECKS=$((CHECKS+1))
[ "$big_out" = "$small_out" ] || fail "a 2000-line prmap changed the rendered rows" \
  "$(printf 'SMALL:\n%s\n\nBIG:\n%s\n' "$small_out" "$big_out")"

if [ "$small_ms" -le 0 ] || [ "$small_ms" -gt 2000 ]; then
  printf 'dash-rows-prmap-scale-selftest: timing unusable (small=%sms) — SCALE leg skipped\n' "$small_ms" >&2
else
  # Generous: 3× plus a 200ms floor for CI noise. The pre-#662 code is ~20× here.
  budget=$(( small_ms * 3 + 200 ))
  CHECKS=$((CHECKS+1))
  [ "$big_ms" -le "$budget" ] || fail \
    "the PR-cell lookup still scales with prmap size — a 2000-line prmap costs ${big_ms}ms vs ${small_ms}ms for 3 lines (budget ${budget}ms). The per-row lookup must run against a haystack built ONCE per frame, not the whole prmap (issue #662)."
  printf 'dash-rows-prmap-scale-selftest: 3-line prmap %sms · 2000-line prmap %sms (budget %sms)\n' \
    "$small_ms" "$big_ms" "$budget"
fi

# ============================================================================
# C. the LANDED view has the same lookup, on the LONGER list
# ============================================================================
# fleet-history.sh cmd_rows resolves each landed row's PR the same way — by PR
# NUMBER rather than branch — and the closed list is the one that grows without
# bound: a ledger accumulates every session a fleet ever closed. So the same
# narrowing has to hold there, or the ⌃t view gets slower every week.
HIST="$BIN/fleet-history.sh"
if [ -f "$HIST" ]; then
  export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
  lr() { printf '%s\t%s\t%s\t%s\tsha%s\t/w/wt-%s\t-\t-\t-\tlanded\t-\n' "$1" "$2" "$3" "$4" "$2" "$2" >> "$FLEET_HISTORY_LEDGER"; }
  : > "$FLEET_HISTORY_LEDGER"
  lr 2026-09-14T10:00:00Z 501 'first'  '#901'
  lr 2026-09-14T09:00:00Z 502 'second' '#902'
  lr 2026-09-14T08:00:00Z 503 'third'  '-'
  # …and a run of rows whose PR is NOT in the prmap. This is the shape a real
  # ledger has — it keeps every session a fleet ever closed, while the prmap holds
  # only the last ~100 PRs — and it is the EXPENSIVE shape: a hit stops the scan
  # early, a MISS walks the whole string before failing. A fixture of hits only
  # would pass against the pre-fix code and pin nothing.
  i=0
  while [ "$i" -lt 12 ]; do
    lr "2026-09-1${i}T07:00:00Z" "6$i" "aged $i" "#7$i"
    i=$((i+1))
  done
  # deploy verdicts keyed by the merge sha the prmap carries, so the `dep` cell
  # exercises the looked-up line rather than just its presence.
  printf 'issue-501\t#901\tMERGED\t✓\t\tmsha901\nissue-502\t#902\tMERGED\t✓\t\tmsha902\n' > "$FD/prmap"
  printf 'live\t1\n' > "$FD/deploy_msha901"
  lrows() { FLEET_SESSION="$SESS" FLEET_REPO=fake/repo FZF_COLUMNS=140 bash "$HIST" rows 2>&1; }

  lsmall=$(lrows) || fail "landed rows exited non-zero" "$lsmall"
  has "landed: the looked-up PR reaches the dep cell" "$lsmall" "live"
  has "landed: a row whose PR is not in the prmap still renders" "$lsmall" "aged 0"
  t0=$(ms); for i in 1 2 3; do lrows >/dev/null 2>&1; done; t1=$(ms); lsmall_ms=$(( (t1 - t0) / 3 ))

  # 600, not 2000 like the live leg: the landed list pays a full failed scan per
  # MISS row and this fixture has twelve of them, so the pre-fix cost here is
  # superlinear — 600 lines is already ~20× the budget (a clear pin) while keeping
  # a regressed CI run to a few seconds instead of a minute.
  { cat "$FD/prmap"
    i=0
    while [ "$i" -lt 600 ]; do printf 'noise-%s\t#8%s\tMERGED\t✓\t\tnsha%s\n' "$i" "$i" "$i"; i=$((i+1)); done
  } > "$FD/prmap.big"
  mv "$FD/prmap.big" "$FD/prmap"
  t0=$(ms); lbig=$(lrows); rc=$?; t1=$(ms); lbig_ms=$(( t1 - t0 ))
  [ "$rc" -eq 0 ] || fail "landed rows exited non-zero against a big prmap" "$lbig"

  CHECKS=$((CHECKS+1))
  [ "$lbig" = "$lsmall" ] || fail "a 2000-line prmap changed the landed rows" \
    "$(printf 'SMALL:\n%s\n\nBIG:\n%s\n' "$lsmall" "$lbig")"
  if [ "$lsmall_ms" -le 0 ] || [ "$lsmall_ms" -gt 2000 ]; then
    printf 'dash-rows-prmap-scale-selftest: landed timing unusable (%sms) — leg skipped\n' "$lsmall_ms" >&2
  else
    lbudget=$(( lsmall_ms * 3 + 200 ))
    CHECKS=$((CHECKS+1))
    [ "$lbig_ms" -le "$lbudget" ] || fail \
      "the LANDED PR lookup still scales with prmap size — ${lbig_ms}ms vs ${lsmall_ms}ms (budget ${lbudget}ms). The per-row lookup must run against a haystack built ONCE per frame (issue #662)."
    printf 'dash-rows-prmap-scale-selftest: landed  3-line %sms · 600-line %sms (budget %sms)\n' \
      "$lsmall_ms" "$lbig_ms" "$lbudget"
  fi
fi

printf 'dash-rows-prmap-scale-selftest OK (%d checks)\n' "$CHECKS"
