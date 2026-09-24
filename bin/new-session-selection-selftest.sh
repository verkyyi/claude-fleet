#!/bin/bash
# new-session-selection-selftest.sh — under `all`, a new session starts in the
# repo of whatever row is highlighted, a session OR a repo heading (issue #997).
#
# A two-repo sandbox fleet (o/alpha + o/beta) on a private tmux socket; every
# spawn is the REAL dash-raw-session.sh, and `claude` is a stub that idles.
#
#   A. resolver — fleet_selection_repo: a beta row → o/beta; beta's heading
#      (`hdr:o/beta`) → o/beta; a no-repo row / the `no repo` heading → none;
#      the `?` heading, an unhosted repo, a landed row → nothing.
#   B. rows — the hub's heading rows carry the spawn target in a 4th field (fzf
#      shows only field 3); the `?` group's heading carries none. Both key
#      fields stay `hdr`, so every other bind still ignores them.
#   C. real spawns under `all`: highlighted beta row → new window @repo=o/beta;
#      beta's `(0)` heading → @repo=o/beta; a no-repo row → @norepo 1; nothing
#      resolvable → today's no-repo scratch.
#   D. a stale current-repo file (the retired picker's filter, #1034): the selection
#      still wins — there is no filtered view any more.
#   E. DEGENERATE — a one-repo fleet: the selection is ignored, byte for byte.
#   F. the hub's ⌃s / ⌃n / Enter binds pass `{1}:{4}` / `{4}`; ⌃n resolves the
#      highlighted repo instead of asking which repo.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/new-session-sel.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/cc" "$WORK/tmp"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/ccquota"
printf '#!/bin/sh\nexec sleep 300\n' > "$WORK/bin/claude"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh" "$WORK/bin/ccquota" "$WORK/bin/claude"

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export PATH="$WORK/bin:$PATH" HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/cc"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export FLEET_GLOBAL_MAX_SESSIONS=999 FLEET_PRESPAWN_DEDUP=0 FLEET_SCRATCH_POOL=0
export FLEET_TRASH_SWEEP_BUDGET=0 GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_MODEL FLEET_AGENT FLEET_SESSION CF_REPO
mkdir -p "$FLEET_CONF_DIR"
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
ok()   { printf 'ok   %s\n' "$*"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1: [$3] not in: $2" ;; esac; }

g() { git -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
mkrepo() {
  mkdir -p "$(dirname "$1")"
  g init -q "$1" && g -C "$1" commit -q --allow-empty -m init && g -C "$1" branch -q -M master \
    && g -C "$1" remote add origin "https://github.com/$2.git" \
    && g -C "$1" update-ref refs/remotes/origin/master HEAD
}
MA="$WORK/a/app"; MB="$WORK/b/app"; MD="$WORK/d/solo"
mkrepo "$MA" o/alpha; mkrepo "$MB" o/beta; mkrepo "$MD" o/solo

S=ft; D=fd
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos" "$FLEET_CONF_DIR/fleets/$D"
printf 'FLEET_REPO="o/alpha"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\nFLEET_WORKTREE_ROOT="%s"\n' \
  "$MA" "$WORK/wt.noindex" > "$FLEET_CONF_DIR/fleets/$S/conf"
printf 'FLEET_REPO="o/beta"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$MB" \
  > "$FLEET_CONF_DIR/fleets/$S/repos/o-beta.conf"
printf 'FLEET_REPO="o/solo"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\nFLEET_WORKTREE_ROOT="%s"\n' \
  "$MD" "$WORK/wt.noindex" > "$FLEET_CONF_DIR/fleets/$D/conf"

"$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s "$S" -n plan -x 200 -y 50 \
  || { echo "could not start isolated tmux" >&2; exit 1; }
tmux new-session -d -s "$D" -n plan -x 200 -y 50

opt()    { tmux display-message -p -t "$1" "#{$2}"; }
newest() { tmux list-windows -t "$1" -F '#{window_id}' | tail -1; }
raw()    { bash "$BIN/dash-raw-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"; }
# spawned <sess> <label> <args…> → "@repo|@norepo" of the window the spawn made
spawned() {
  local s="$1" before after; shift
  before=$(newest "$s")
  raw "$@" "$s" || { printf 'spawn-refused:%s' "$(tail -1 "$WORK/err")"; return; }
  after=$(newest "$s")
  [ "$after" != "$before" ] || { printf 'no-window'; return; }
  printf '%s|%s' "$(opt "$after" @repo)" "$(opt "$after" @norepo)"
}

# Two sessions to highlight: a beta scratch and a no-repo one.
raw --repo o/beta "$S" || fail "setup: beta scratch: $(cat "$WORK/err")"; wB=$(newest "$S")
raw --no-repo "$S"     || fail "setup: no-repo: $(cat "$WORK/err")";      wN=$(newest "$S")

# ==== A. the resolver ================================================================
eq "A: a beta row → o/beta"                "$(fleet_selection_repo "$S" "$wB")" o/beta
eq "A: a beta row with a trailing {4} → o/beta" "$(fleet_selection_repo "$S" "$wB:")" o/beta
eq "A: beta's heading → o/beta"            "$(fleet_selection_repo "$S" hdr:o/beta)" o/beta
eq "A: alpha's heading → o/alpha"          "$(fleet_selection_repo "$S" hdr:o/alpha)" o/alpha
eq "A: a no-repo row → none"               "$(fleet_selection_repo "$S" "$wN")" none
eq "A: the no-repo heading → none"         "$(fleet_selection_repo "$S" hdr:none)" none
eq "A: the ? heading → nothing"            "$(fleet_selection_repo "$S" hdr:)" ""
eq "A: a bare hdr → nothing"               "$(fleet_selection_repo "$S" hdr)" ""
eq "A: an unhosted repo's heading → nothing" "$(fleet_selection_repo "$S" hdr:o/gone)" ""
eq "A: a landed row → nothing"             "$(fleet_selection_repo "$S" landed:issue:5)" ""
eq "A: the hub window → nothing"           "$(fleet_selection_repo "$S" "$(opt "$S:plan" window_id)")" ""

# ==== B. the rows producer ===========================================================
US=$'\037'
hub=$(FLEET_SESSION=$S bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')
eq "B: hub headings carry the spawn target in field 4" \
   "$(printf '%s\n' "$hub" | awk -F"$US" '$1 == "hdr" && NF == 4 { print $3 "=" $4 }' | tr '\n' ' ')" \
   "alpha (0)=o/alpha beta (1)=o/beta no repo (1)=none "
eq "B: …and both key fields stay hdr" \
   "$(printf '%s\n' "$hub" | awk -F"$US" 'NF == 4 && !($1 == "hdr" && $2 == "hdr")' | wc -l | tr -d ' ')" 0
side=$(FLEET_SESSION=$S FLEET_DASH_SIDEBAR=1 bash "$BIN/tmux-dashboard-rows.sh" --sidebar 2>/dev/null)
eq "B: sidebar headings carry it in the state field" \
   "$(printf '%s\n' "$side" | awk -F"$US" '$1 == "hdr" { print $2 }' | tr '\n' ' ')" "o/alpha o/beta none "
tmux new-window -d -t "$S" -n unk
hub=$(FLEET_SESSION=$S bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')
eq "B: the ? heading carries no target (3 fields)" \
   "$(printf '%s\n' "$hub" | awk -F"$US" '$1 == "hdr" && $3 ~ /unknown repo/ { print NF }')" 3
tmux kill-window -t "$S:unk"

# ==== C. real spawns under all =======================================================
eq "C: highlighted beta row → @repo o/beta"        "$(spawned "$S" --name c1 --selection "$wB:")" "o/beta|"
eq "C: beta's (0)-style heading → @repo o/beta"    "$(spawned "$S" --name c2 --selection hdr:o/beta)" "o/beta|"
eq "C: alpha's (0) heading → @repo o/alpha"        "$(spawned "$S" --name c3 --selection hdr:o/alpha)" "o/alpha|"
eq "C: a no-repo row → @norepo 1"                  "$(spawned "$S" --name c4 --selection "$wN:")" "|1"
eq "C: the no-repo heading → @norepo 1"            "$(spawned "$S" --name c5 --selection hdr:none)" "|1"
eq "C: nothing resolvable → today's no-repo"       "$(spawned "$S" --name c6 --selection hdr:)" "|1"
eq "C: no selection at all → today's no-repo"      "$(spawned "$S" --name c7)" "|1"
eq "C: an explicit --repo still wins"              "$(spawned "$S" --name c8 --repo o/alpha --selection hdr:o/beta)" "o/alpha|"
# ⌃s is `--bg`: the resolved repo must ride the re-exec it dispatches (the sandbox
# holds two fleets on one socket, so the re-exec itself is only recorded here).
mkdir -p "$WORK/rs"
cat > "$WORK/rs/tmux" <<EOF
#!/bin/sh
[ "\$1" = run-shell ] && { printf '%s\n' "\$3" > "$WORK/bg.cmd"; exit 0; }
exec "$WORK/bin/tmux" "\$@"
EOF
chmod +x "$WORK/rs/tmux"
PATH="$WORK/rs:$PATH" raw --bg --name c9 --selection hdr:o/beta "$S"
has "C: ⌃s (--bg) dispatches with the resolved repo" "$(cat "$WORK/bg.cmd" 2>/dev/null)" "--repo='o/beta'"
PATH="$WORK/rs:$PATH" raw --bg --name c10 --selection "$wN:" "$S"
has "C: ⌃s (--bg) on a no-repo row dispatches --no-repo" "$(cat "$WORK/bg.cmd" 2>/dev/null)" " --no-repo"

# ==== D. a stale current-repo file ==================================================
printf 'o/alpha\n' > "$FLEET_CONF_DIR/fleets/$S/current-repo"
eq "D: a stale current-repo file — the resolver still reads the row" "$(fleet_selection_repo "$S" "$wB")" o/beta
eq "D: …and a beta row spawns in beta" "$(spawned "$S" --name d1 --selection "$wB:")" "o/beta|"
rm -f "$FLEET_CONF_DIR/fleets/$S/current-repo"

# ==== E. degenerate: one repo =======================================================
eq "E: one-repo fleet — the resolver says nothing" "$(fleet_selection_repo "$D" hdr:o/solo)" ""
eq "E: one-repo fleet — a selection changes nothing" \
   "$(spawned "$D" --name e1 --selection hdr:o/beta)" "$(spawned "$D" --name e2)"

# ==== F. the hub binds ==============================================================
dash=$(cat "$BIN/tmux-dashboard.sh")
has "F: ⌃s passes the highlighted row" "$dash" 'dash-raw-session.sh --bg --selection={1}:{4})'
has "F: ⌃n passes the highlighted row" "$dash" 'dash-issue-new.sh confirm --spawn --selection={1}:{4})'
has "F: Enter passes the heading target" "$dash" 'dash-enter.sh {1} {q} {4})'
# ⌃n: fzf is shimmed to record its header and cancel, so the popup's repo shows.
mkdir -p "$WORK/fz"
cat > "$WORK/fz/fzf" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in --header=*) printf '%s\n' "\${a#--header=}" > "$WORK/fzf.header" ;; esac; done
exit 130
EOF
chmod +x "$WORK/fz/fzf"
newi() { rm -f "$WORK/fzf.header"; TMUX="$SOCK,1,0" TMUX_PANE="$(opt "$S:plan" pane_id)" PATH="$WORK/fz:$PATH" \
  bash "$BIN/dash-issue-new.sh" confirm --spawn "$@" </dev/null >/dev/null 2>&1; cat "$WORK/fzf.header" 2>/dev/null; }
has "F: ⌃n on beta's heading files in o/beta" "$(newi --selection=hdr:o/beta)" "in o/beta"
has "F: ⌃n on a beta row files in o/beta"     "$(newi --selection="$wB:")" "in o/beta"

if [ "$FAILS" -gt 0 ]; then
  printf 'new-session-selection-selftest: %s failure(s)\n' "$FAILS" >&2; exit 1
fi
printf 'new-session-selection-selftest: all passed\n'
