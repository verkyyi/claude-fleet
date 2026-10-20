#!/bin/bash
# history-multirepo-selftest.sh — history across every hosted repo (issue #804).
#
# Fleet M hosts o/a (its conf) + o/b (an overlay), each with its own ledger
# (landed_<slug>.tsv). Both ledgers hold an issue #12 landed by PR #101 — the
# collision a bare key or a bare PR number would get wrong — and o/b's #31 was
# spawned by o/a's #30 (origin `o-a:issue-30`). Fleet D hosts one repo (o/c), no
# repos/ dir: the degenerate case, which must keep the old shapes.
#
#   list      `list` merges both ledgers newest-first, with a legend + a repo column;
#             `--repo` pins one ledger; a filter word matches the repo too
#   rows      the dash's landed view merges both, badges each row, and every target
#             ends in `@<repo>`; the cross-repo parent owns its child's block
#   fold      expanding `landed:issue:30@o/a` writes o/a's own fold file
#   stale     a stale current-repo file (the retired picker's, #1034) filters nothing
#   restore   dash-restore-session.sh resumes a row in the repo its target names
#   one-repo  fleet D: one road (#1940) — every target ends in `@<repo>` as with 2+,
#             but no legend and no badge (one repo has nothing to tell apart)
#
# No tmux server, no network: tmux + gh are shimmed to fail, and the restore leg
# runs a copy of the restorer against a stub fleet-history.sh.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
st_sandbox "${TMPDIR:-/tmp}/history-multirepo-selftest.XXXXXX" physical
mkdir -p "$WORK/shim" "$WORK/home"
printf '#!/bin/sh\nexit 1\n' > "$WORK/shim/tmux"
st_fake_gh "$WORK/shim"
chmod +x "$WORK/shim/tmux" "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
mkdir -p "$FLEET_CONF_DIR" "$TMPDIR"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION FLEET_HISTORY_LEDGER
. "$BIN/fleet-lib.sh"

st_tally miss
leg()  { if [ "$FAIL" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; _legf=$FAIL; }
# before <a> <b> <text> — <a> appears on an earlier line of <text> than <b>
before() { local la lb
  la=$(printf '%s\n' "$3" | grep -nF -- "$1" | head -n1 | cut -d: -f1)
  lb=$(printf '%s\n' "$3" | grep -nF -- "$2" | head -n1 | cut -d: -f1)
  [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ] || st_miss "order: [$1] should precede [$2] in: $3"; }

for r in A B C; do mkdir -p "$WORK/main$r/.git"; done
M=M D=D
mkdir -p "$FLEET_CONF_DIR/fleets/$M/repos" "$FLEET_CONF_DIR/fleets/$D"
: > "$FLEET_CONF_DIR/fleets/$M/conf"
fx_repo "$FLEET_CONF_DIR" "$M" o/a FLEET_MAIN="$WORK/mainA" FLEET_BASE_BRANCH="master"
printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$WORK/mainB" > "$FLEET_CONF_DIR/fleets/$M/repos/o-b.conf"
: > "$FLEET_CONF_DIR/fleets/$D/conf"
fx_repo "$FLEET_CONF_DIR" "$D" o/c FLEET_MAIN="$WORK/mainC" FLEET_BASE_BRANCH="master"
mkdir -p "$FLEET_C/global"
printf '%s\t%s\t%s\n' "$M" o-a o/a "$D" o-c o/c > "$FLEET_C/global/sessmap"

# ledger rows: when key title pr sha wt tdir sid summary state origin
LOGS="$FLEET_CONF_DIR/logs"; mkdir -p "$LOGS"   # the login's records (#4668)
row() { printf '%s\t%s\t%s\t%s\tdeadbeef\t-\t-\t-\t-\t%s\t%s\n' "$@"; }
{ row 2026-09-20T10:00:00Z 12 alpha-twelve 101 landed -
  row 2026-09-20T12:00:00Z 30 alpha-parent -   closed-unlanded -; } > "$LOGS/landed_o-a.tsv"
{ row 2026-09-20T11:00:00Z 12 beta-twelve  101 landed -
  row 2026-09-20T13:00:00Z 31 beta-child   -   closed-unlanded o-a:issue-30; } > "$LOGS/landed_o-b.tsv"
{ row 2026-09-20T10:00:00Z 12 gamma-twelve 101 landed -; } > "$LOGS/landed_o-c.tsv"

H="$BIN/fleet-history.sh"
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- list ------------------------------------------------------------------------
out=$(FLEET_SESSION=$M bash "$H" list 2>&1)
st_has "list: legend names both repos" "$out" "repos: a=o/a · b=o/b"
for t in alpha-twelve alpha-parent beta-twelve beta-child; do st_has "list: merged row $t" "$out" "$t"; done
before beta-child alpha-parent "$out"; before alpha-parent beta-twelve "$out"; before beta-twelve alpha-twelve "$out"
st_has "list: repo column on an o/b row" "$(printf '%s\n' "$out" | grep beta-twelve)" "#12    b "
st_has "list: repo column on an o/a row" "$(printf '%s\n' "$out" | grep alpha-twelve)" "#12    a "
out=$(FLEET_SESSION=$M bash "$H" list --repo o/a 2>&1)
st_has "list --repo: its own rows" "$out" "alpha-twelve"
st_hasnt "list --repo: not the other repo's" "$out" "beta"
st_hasnt "list --repo: no legend" "$out" "repos:"
out=$(FLEET_SESSION=$M bash "$H" list o/b 2>&1)
st_has "list <filter>: the repo matches" "$out" "beta-twelve"
st_hasnt "list <filter>: the other repo is filtered out" "$out" "alpha"
leg list

# --- rows (the dash's landed view) ------------------------------------------------
rows() { FLEET_SESSION="$1" FZF_COLUMNS=160 bash "$H" rows 2>/dev/null; }
out=$(rows "$M")
st_has "rows: o/a's #12 targets o/a" "$out" "landed:101@o/a"
st_has "rows: o/b's #12 targets o/b" "$out" "landed:101@o/b"
st_has "rows: o/a's #30 targets o/a" "$out" "landed:issue:30@o/a"
vis=$(printf '%s\n' "$out" | strip)
st_has "rows: badge on an o/a row" "$vis" "a alpha-twelve"
st_has "rows: badge on an o/b row" "$vis" "b beta-twelve"
st_has "rows: the cross-repo parent owns its child's block" "$vis" "a 0/1 ✓ alpha-parent"
st_hasnt "rows: the child is folded under it" "$vis" "beta-child"
before beta-twelve alpha-twelve "$vis"
leg rows

# --- fold ---------------------------------------------------------------------------
FLEET_SESSION=$M bash "$H" fold expand 'landed:issue:30@o/a' >/dev/null 2>&1
[ -f "$FLEET_C/global/dash_fold_landed_$M.o-a" ] || st_miss "fold: o/a's own fold file"
st_has "fold: holds the bare key" "$(cat "$FLEET_C/global/dash_fold_landed_$M.o-a" 2>/dev/null)" "issue-30"
vis=$(rows "$M" | strip)
st_has "fold: the o/b child nests under its o/a parent" "$vis" "└  beta-child"
before alpha-parent beta-child "$vis"
act=$(FLEET_SESSION=$M bash "$H" fold collapse 'landed:scratch:nope@o/a' 2>/dev/null)
[ -z "$act" ] || st_miss "fold: an unknown row is a dead keystroke, got [$act]"
leg fold

# --- a stale current-repo file ------------------------------------------------------
all_rows=$(rows "$M")
printf 'o/b\n' > "$FLEET_CONF_DIR/fleets/$M/current-repo"
[ "$(rows "$M")" = "$all_rows" ] || st_miss "stale: a stale current-repo file changed the rows (#1034)"
rm -f "$FLEET_CONF_DIR/fleets/$M/current-repo"
leg stale

# --- restore: the row's repo ------------------------------------------------
HB="$WORK/hb"; mkdir -p "$HB"
cp "$BIN/dash-restore-session.sh" "$BIN/fleet-lib.sh" "$BIN/fleet-client-core.sh" "$HB/"
cat > "$HB/fleet-history.sh" <<'EOF'
#!/bin/bash
repo='' main=''; while [ "$#" -gt 1 ]; do case "$1" in --repo) repo=$2; shift ;; --main) main=$2; shift ;; esac; shift; done
printf 'REVIEW-ONLY\trepo=%s main=%s key=%s\n' "$repo" "$main" "$1"
EOF
err=$(FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=0 bash "$HB/dash-restore-session.sh" 'landed:101@o/b' "$M" 2>&1 >/dev/null)
st_has "restore: an o/b row resumes in o/b" "$err" "repo=o/b main=$WORK/mainB key=#101"
err=$(FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=0 bash "$HB/dash-restore-session.sh" 'landed:issue:30@o/a' "$M" 2>&1 >/dev/null)
st_has "restore: an o/a row resumes in o/a" "$err" "repo=o/a main=$WORK/mainA key=30"
st_has "restore: --plan strips the repo" "$(bash "$HB/dash-restore-session.sh" --plan 'landed:scratch:scratch-4@o/b')" "scratch-4"
leg restore

# --- the one-repo fleet ------------------------------------------------------------------
out=$(FLEET_SESSION=$D bash "$H" list --repo o/c 2>&1)
st_has "one-repo: list" "$out" "gamma-twelve"
st_hasnt "one-repo: no legend" "$out" "repos:"
out=$(rows "$D"); vis=$(printf '%s\n' "$out" | strip)
st_has "one-repo: the target names its repo" "$out" "landed:101@o/c"$'\x1f'
st_hasnt "one-repo: no other repo on a target" "$out" "@o/a"
st_has "one-repo: no badge" "$vis" "  gamma-twelve"
leg one-repo

st_done
