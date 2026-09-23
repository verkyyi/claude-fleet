#!/bin/bash
# backlog-repo-selftest.sh — the backlog for any repo (issue #794).
#
# In a fleet hosting 2+ repos the backlog reads every hosted repo's issues cache
# (fleets/<slug>/issues) — the view is always `all` (#1034) — each row carrying its
# repo as field 4; every row action passes that repo on. Pinned here:
#   A. NO FILTER — a stale current-repo file (the retired picker's, #1034) narrows
#      nothing: both repos' rows, the popup's border says all repos.
#   B. ALL — both repos' rows, one block per repo, each title led by its short tag,
#      field 4 per row; a bound window hides ONLY its own repo's #N (A#12 bound,
#      B#12 still listed).
#   C. ACTIONS TARGET THE ROW'S REPO — close (gh -R + the optimistic drop from THAT
#      repo's cache only), priority (commit pass + labels cache), comment, preview;
#      a --repo= the fleet does not host refuses.
#   D. SPAWN — the popup's enter/preview/close/priority/open binds carry --repo={4};
#      the ⌃g spawn picker hands the picked row's repo to dash-issue-session.sh.
#   E. NEW ISSUE — fleet-issue-file.sh from a no-repo caller refuses (a stale
#      current-repo file too); dash-issue-new.sh with no repo asks via
#      fleet-repo-ask.sh, files into the pick, drops the optimistic row into THAT
#      repo's cache, and its --spawn passes --repo.
#   F. DEGENERATE — a one-repo fleet: rows keep three fields and the per-session
#      cache, no bind carries --repo, actions resolve the sessmap repo as before.
# tmux runs on a PRIVATE socket via a PATH shim (run-shell runs its body inline, so
# fleet_bg is synchronous); gh, fzf and the spawn/collector scripts are stubs.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

CHECKS=0 FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; FAILS=$((FAILS+1)); }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/blrepo.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/s"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# A sandbox bin/: every real script symlinked, the spawn choke point and the
# collector replaced by stubs that log their argv.
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/bin"
for f in "$BIN"/* "$BIN"/.[!.]*; do [ -e "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
rm -f "$SB/dash-issue-session.sh" "$SB/tmux-dash-collect.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/spawn.log"\n' "$WORK" > "$SB/dash-issue-session.sh"
printf '#!/bin/sh\nexit 0\n' > "$SB/tmux-dash-collect.sh"
chmod +x "$SB/dash-issue-session.sh" "$SB/tmux-dash-collect.sh"

# tmux shim: run-shell runs its command inline (fleet_bg becomes synchronous);
# display-message/display-popup toasts are logged; the rest hits the private socket.
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/tmux.log"
case "\${1:-}" in
  run-shell) for last; do :; done; bash -c "\$last"; exit 0 ;;
  display-popup) exit 0 ;;
esac
case "\$*" in
  *display-message*-p*'#{session_name}'*|*display-message*-p*'#S'*)
    [ -n "\${FAKE_CUR:-}" ] && { printf '%s\n' "\$FAKE_CUR"; exit 0; } ;;
  display-message\ -d*|display-message\ \#*|display-message\ [!-]*) exit 0 ;;
esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# gh stub: log argv; `issue create` answers a URL; `issue view` answers JSON.
cat > "$WORK/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/gh.log"
case "\$1 \$2" in
  "issue create") echo "https://github.com/x/y/issues/77" ;;
  "issue view")   echo '{"number":12,"title":"t","state":"OPEN","body":"","labels":[],"milestone":null,"assignees":[],"comments":[],"url":"u"}' ;;
  "api user")     echo me ;;
esac
exit 0
EOF
# fzf stub: record stdin + argv. The repo-only picker (`which repo`) answers the row
# for \$FZF_REPO; a --print-query title read answers \$FZF_TITLE; the spawn picker
# answers the first row whose display matches \$FZF_PICK; otherwise esc.
cat > "$WORK/bin/fzf" <<EOF
#!/bin/bash
cat > "$WORK/fzf.in"; printf '%s\n' "\$*" >> "$WORK/fzf.args"
case "\$*" in
  *'which repo'*) [ -n "\${FZF_REPO:-}" ] || exit 130
                  awk -F '\037' -v r="\$FZF_REPO" '\$1 == r { print; exit }' "$WORK/fzf.in"; exit 0 ;;
  *--print-query*) [ -n "\${FZF_TITLE:-}" ] || exit 130; printf '%s\n' "\$FZF_TITLE"; exit 1 ;;
esac
[ -n "\${FZF_PICK:-}" ] || exit 130
awk -F '\037' -v p="\$FZF_PICK" '\$2 ~ p { print; exit }' "$WORK/fzf.in"
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
unset TMUX TMUX_PANE FLEET_SESSION FLEET_REPO FLEET_MAIN CF_REPO POPUP 2>/dev/null || true
C="$TMPDIR/.claude-dash"
mkdir -p "$C/global" "$FLEET_CONF_DIR/fleets/alpha/repos" "$FLEET_CONF_DIR/fleets/solo"
. "$BIN/fleet-lib.sh"

fconf() { printf 'FLEET_REPO="%s"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH=master\n' "$2" "$WORK/$3" > "$1"; }
fconf "$FLEET_CONF_DIR/fleets/alpha/conf"                o/aaa aaa
fconf "$FLEET_CONF_DIR/fleets/alpha/repos/o-bbb.conf"    o/bbb bbb
fconf "$FLEET_CONF_DIR/fleets/solo/conf"                 o/sss sss
printf 'alpha\to-aaa\to/aaa\nsolo\to-sss\to/sss\n' > "$C/global/sessmap"
seed() {   # (re)write the three repos' issues/labels/parents caches
  local s d
  for s in o-aaa o-bbb o-sss; do
    d="$C/fleets/$s"; mkdir -p "$d"; date +%s > "$d/issues.ts"; : > "$d/parents"
  done
  printf '· no milestone\t#11\t·\tAAA eleven\n· no milestone\t#12\t·\tAAA twelve\n' > "$C/fleets/o-aaa/issues"
  printf '· no milestone\t#12\t·\tBBB twelve\n· no milestone\t#30\t·\tBBB thirty\n' > "$C/fleets/o-bbb/issues"
  printf '· no milestone\t#5\t·\tSSS five\n' > "$C/fleets/o-sss/issues"
  printf '12\tbug\n' > "$C/fleets/o-aaa/labels"
  printf '12\tpriority:p2\n' > "$C/fleets/o-bbb/labels"
  printf '5\tbug\n' > "$C/fleets/o-sss/labels"
}
seed

"$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s alpha -n plan -x 200 -y 40 || { echo "no isolated tmux" >&2; exit 1; }
tmux new-window -d -t alpha -n issue-12
tmux set-option -w -t alpha:issue-12 @issue 12
tmux set-option -w -t alpha:issue-12 @repo o/aaa
tmux new-session -d -s solo -n plan -x 200 -y 40

rows() { FLEET_SESSION="$1" bash "$SB/tmux-issues-rows.sh" all 2>&1; }
f4()   { printf '%s\n' "$1" | tail -n +2 | awk -F '\037' '{ print $1 "|" $4 }'; }
strip(){ printf '%s\n' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }
logs() { : > "$WORK/gh.log"; : > "$WORK/tmux.log"; : > "$WORK/spawn.log"; : > "$WORK/fzf.args"; }

# --- A. no filter ---------------------------------------------------------------
printf 'o/bbb\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"
out=$(rows alpha)
eq    "A: a stale current-repo file narrows nothing" "$(f4 "$out" | tr '\n' ' ')" "11|o/aaa 12|o/bbb 30|o/bbb "
has   "A: B's own #12 NOT hidden by A#12's window" "$(strip "$out")" "BBB twelve"
logs
FAKE_CUR=alpha POPUP=1 bash "$SB/tmux-issues.sh" all >/dev/null 2>&1
has   "A: border says all repos"              "$(cat "$WORK/fzf.args")" "· all repos"
rm -f "$FLEET_CONF_DIR/fleets/alpha/current-repo"

# --- B. all ----------------------------------------------------------------------
out=$(rows alpha)
eq    "B: all → both repos, A block then B"   "$(f4 "$out" | tr '\n' ' ')" "11|o/aaa 12|o/bbb 30|o/bbb "
has   "B: A rows tagged"                      "$(strip "$out")" "aa AAA eleven"
has   "B: B rows tagged"                      "$(strip "$out")" "bb BBB thirty"
hasnt "B: A#12 (bound) hidden"                "$(strip "$out")" "AAA twelve"
has   "B: B#12 priority from B's labels"      "$(strip "$out" | grep 'BBB twelve')" "p2"
touch "$C/global/backlog_show_bound_alpha"
has   "B: ⌃b shows A#12 again"                "$(strip "$(rows alpha)")" "AAA twelve"
rm -f "$C/global/backlog_show_bound_alpha"
logs
FAKE_CUR=alpha POPUP=1 bash "$SB/tmux-issues.sh" all >/dev/null 2>&1
has   "B: border says all repos"              "$(cat "$WORK/fzf.args")" "· all repos"

# --- C. actions target the row's repo -------------------------------------------
logs
printf 'y' | FAKE_CUR=alpha bash "$SB/dash-issue-close.sh" 12 confirm --repo=o/bbb >/dev/null 2>&1
has   "C: close → gh -R the row's repo"       "$(cat "$WORK/gh.log")" "issue close 12 --repo o/bbb"
hasnt "C: close never hits A"                 "$(cat "$WORK/gh.log")" "o/aaa"
hasnt "C: optimistic drop from B's cache"     "$(cat "$C/fleets/o-bbb/issues")" "#12"
has   "C: A's #12 untouched"                  "$(cat "$C/fleets/o-aaa/issues")" "#12"
seed; logs
printf 'y' | FAKE_CUR=alpha CF_REPO=o/bbb bash "$SB/dash-issue-close.sh" 12 confirm >/dev/null 2>&1
has   "C: close phase 2 via CF_REPO → B"      "$(cat "$WORK/gh.log")" "issue close 12 --repo o/bbb"
seed; logs
printf 'y' | FAKE_CUR=alpha bash "$SB/dash-issue-close.sh" 12 confirm --repo=o/zzz >/dev/null 2>&1
hasnt "C: an unhosted --repo refuses"         "$(cat "$WORK/gh.log")" "issue close"
logs
FAKE_CUR=alpha bash "$SB/dash-issue-priority.sh" 12 cycle --repo=o/bbb >/dev/null 2>&1
has   "C: priority → gh edit -R B"            "$(cat "$WORK/gh.log")" "issue edit 12 --repo o/bbb"
has   "C: priority cycles from B's tier (p2→p1)" "$(cat "$WORK/gh.log")" "--add-label priority:p1"
has   "C: B's labels cache repainted"         "$(cat "$C/fleets/o-bbb/labels")" "priority:p1"
eq    "C: A's labels untouched"               "$(cat "$C/fleets/o-aaa/labels")" "12	bug"
seed; logs
printf 'dupe\n' | FAKE_CUR=alpha bash "$SB/dash-issue-comment.sh" 12 confirm --repo=o/bbb >/dev/null 2>&1
has   "C: comment → -R B"                     "$(cat "$WORK/gh.log")" "o/bbb"
hasnt "C: comment never hits A"               "$(cat "$WORK/gh.log")" "o/aaa"
logs
FLEET_SESSION=alpha bash "$SB/tmux-issue-preview.sh" 12 --repo=o/bbb >/dev/null 2>&1
has   "C: preview → gh view -R B"             "$(cat "$WORK/gh.log")" "issue view 12 --repo o/bbb"

# --- D. spawn --------------------------------------------------------------------
logs
FAKE_CUR=alpha POPUP=1 bash "$SB/tmux-issues.sh" all >/dev/null 2>&1
a=$(cat "$WORK/fzf.args")
has   "D: enter spawns with --repo={4}"       "$a" "dash-issue-session.sh {1} --async --repo={4}"
has   "D: preview carries --repo={4}"         "$a" "tmux-issue-preview.sh {1} --repo={4}"
has   "D: priority carries --repo={4}"        "$a" "cycle --repo={4}"
has   "D: close sentinel carries {4}"         "$a" "printf 'close %s' {1} {4}"
has   "D: open uses the row's repo"           "$a" "https://github.com/{4}/issues/{1}"
logs
FAKE_CUR=alpha FZF_PICK='BBB thirty' bash "$SB/dash-issue-spawn.sh" >/dev/null 2>&1
eq    "D: ⌃g spawn picker → --repo of the row" "$(cat "$WORK/spawn.log")" "30 --repo=o/bbb"

# --- E. new issue ----------------------------------------------------------------
logs
( cd "$WORK" && FAKE_CUR=alpha bash "$SB/fleet-issue-file.sh" --title 'x' >/dev/null 2>"$WORK/err" ); rc=$?
eq    "E: filer under all refuses"            "$rc" "1"
has   "E: … and says why"                     "$(cat "$WORK/err")" "pass --repo"
printf 'o/bbb\n' > "$FLEET_CONF_DIR/fleets/alpha/current-repo"; logs
( cd "$WORK" && FAKE_CUR=alpha bash "$SB/fleet-issue-file.sh" --title 'x' >/dev/null 2>&1 ); rc=$?
eq    "E: a stale current-repo file does not pick the filer's repo" "$rc" "1"
hasnt "E: … files nothing"                    "$(cat "$WORK/gh.log")" "issue create"
seed; logs
FAKE_CUR=alpha FZF_REPO=o/bbb FZF_TITLE='new thing' bash "$SB/dash-issue-new.sh" confirm --spawn >/dev/null 2>&1
has   "E: ⌃n with no repo asks which repo"    "$(cat "$WORK/fzf.args")" "which repo"
has   "E: filed into the picked repo"         "$(cat "$WORK/gh.log")" "issue create --repo o/bbb"
has   "E: optimistic row in B's cache"        "$(cat "$C/fleets/o-bbb/issues")" "new thing"
hasnt "E: … not A's"                          "$(cat "$C/fleets/o-aaa/issues")" "new thing"
has   "E: --spawn passes --repo"              "$(cat "$WORK/spawn.log")" "77 --title new thing --repo o/bbb"
seed; logs
FAKE_CUR=alpha FZF_TITLE='nope' bash "$SB/dash-issue-new.sh" confirm >/dev/null 2>&1
hasnt "E: esc on the repo pick files nothing" "$(cat "$WORK/gh.log")" "issue create"
logs
FAKE_CUR=alpha bash "$SB/fleet-repo-ask.sh" alpha >/dev/null 2>&1
eq    "E: the ask lists the hosted repos"     "$(awk -F '\037' '{ print $1 }' "$WORK/fzf.in" | tr '\n' ' ')" "o/aaa o/bbb "
seed; logs
FAKE_CUR=alpha FZF_REPO=o/aaa FZF_TITLE='cur thing' bash "$SB/dash-issue-new.sh" confirm >/dev/null 2>&1
has   "E: a stale current-repo file still asks" "$(cat "$WORK/fzf.args")" "which repo"
has   "E: … and files into the pick"          "$(cat "$WORK/gh.log")" "issue create --repo o/aaa"
rm -f "$FLEET_CONF_DIR/fleets/alpha/current-repo"

# --- F. degenerate ---------------------------------------------------------------
out=$(rows solo)
eq    "F: one-repo rows keep 3 fields"        "$(printf '%s\n' "$out" | tail -n +2 | awk -F '\037' '{ print NF }')" "3"
has   "F: its own issues"                     "$(strip "$out")" "SSS five"
echo o/bbb > "$FLEET_CONF_DIR/fleets/solo/current-repo"
eq    "F: a stray current-repo file is ignored" "$(rows solo)" "$out"
logs
FAKE_CUR=solo POPUP=1 bash "$SB/tmux-issues.sh" all >/dev/null 2>&1
hasnt "F: no bind carries --repo"             "$(cat "$WORK/fzf.args")" "--repo="
has   "F: open keeps the fleet repo"          "$(cat "$WORK/fzf.args")" "https://github.com/o/sss/issues/{1}"
has   "F: border unchanged"                   "$(cat "$WORK/fzf.args")" "--border-label= backlog · GitHub issues  "
logs
printf 'y' | FAKE_CUR=solo bash "$SB/dash-issue-close.sh" 5 confirm >/dev/null 2>&1
has   "F: close → the sessmap repo"           "$(cat "$WORK/gh.log")" "issue close 5 --repo o/sss"
seed; logs
FAKE_CUR=solo FZF_TITLE='solo thing' bash "$SB/dash-issue-new.sh" confirm --spawn >/dev/null 2>&1
hasnt "F: ⌃n never asks"                      "$(cat "$WORK/fzf.args")" "which repo"
has   "F: files into the fleet repo"          "$(cat "$WORK/gh.log")" "issue create --repo o/sss"
eq    "F: spawn call unchanged (no --repo)"   "$(cat "$WORK/spawn.log")" "77 --title solo thing"

if [ "$FAILS" -gt 0 ]; then
  printf 'backlog-repo-selftest: %d/%d checks FAILED\n' "$FAILS" "$CHECKS" >&2; exit 1
fi
printf 'backlog-repo-selftest: all %d checks passed\n' "$CHECKS"
