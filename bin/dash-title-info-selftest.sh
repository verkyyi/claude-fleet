#!/bin/bash
# dash-title-info-selftest.sh — the rows producer writes each window's
# @title_info, the worker pane header's status line (issue #1377).
#
#   ` 阿里云成本 #8 · 子任务 1/2 · 等子任务 · 父 #3 `
#
# The sidebar's selected-row line used to carry these words; the header has the
# room. The producer (tmux-dashboard-rows.sh, both the hub and --sidebar modes)
# computes the line every frame and writes it ONLY when it changed, and UNSETS it
# when every segment is empty, so a lone worker's header stays ` name #issue `.
#
# Legs: sub-tasks k/N · why a ↻ waits · a Loop's next round (local HH:MM) · which
# `!` · the parent; then the write discipline (unchanged → no write, all-empty →
# no write, stale → unset) and the same answer from --sidebar.
#
# Hermetic: `tmux` is PATH-shimmed to replay a fixture window list and to LOG
# every set-option call (never a live server). Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
[ -f "$ROWS" ] || { printf 'selftest: rows producer not found\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/titleinfo-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
mkdir -p "$WORK/.claude-dash/global" "$WORK/conf" "$WORK/bin"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

US=$'\x1f'
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0; so=0
for a in "$@"; do
  [ "$a" = list-windows ] && lw=1; [ "$a" = set-option ] && so=1
  case "$a" in *"$US"*) fmt=1 ;; esac
done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
[ "$so" = 1 ] && printf '%s\n' "$*" >> "$SETLOG"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH
WLIST_FILE="$WORK/wlist"; SETLOG="$WORK/setlog"; export WLIST_FILE SETLOG
# WFMT order: sess idx name path state ts wid @issue @origin @worktree agent @wid
# needs/wait @expand @pin qwait reap_due reap_seen reap_stamp @repo @norepo
# @sleep_since @repo_fold @loop @title_info
# w idx name state wid issue origin [wait] [@loop] [@title_info]
w() { printf '%s\n' "S$US$1$US$2$US/w/r-issue-$5$US$3$US$US$4$US$5$US$6$US/w/r-issue-$5$US${US}a$1$US${7:-}$US$US$US$US$US$US$US$US$US$US$US${8:-}$US${9:-}" >> "$WLIST_FILE"; }
hub()  { : > "$SETLOG"; FLEET_SESSION=S FZF_COLUMNS=140 bash "$ROWS" >/dev/null 2>&1; }
side() { : > "$SETLOG"; FLEET_SESSION=S bash "$ROWS" --sidebar >/dev/null 2>&1; }
# the value written for a window ('' = none written; `-u` = unset)
put() { awk -v w="$1" '$0 ~ ("-t " w " @title_info") {
          if ($0 ~ /set-option -wqu /) { print "-u"; exit }
          sub(".*-t " w " @title_info ", ""); print; exit }' "$SETLOG"; }

NOW=$(date +%s); NEXT=$((NOW + 1800))
HM=$(python3 -c 'import sys,time; print(time.strftime("%H:%M", time.localtime(int(sys.argv[1]))))' "$NEXT")

: > "$WLIST_FILE"
#  idx name   state     wid  issue origin    wait      @loop                      @title_info
w 1  par    looping   @1   1     ''        children
w 2  kid1   'done'    @2   2     issue-1
w 3  kid2   working   @3   3     issue-1
w 4  lp     'done'    @4   4     ''        ''        "next=$NEXT ttl=3600"
w 5  ask    needs     @5   5     ''        ask
w 6  vague  needs     @6   6     ''        ''
w 7  bgw    looping   @7   7     scratch-9 bg
w 8  lone   working   @8   8     ''
w 9  same   working   @9   9     issue-1   ''        ''                         '父 #1'
w 10 stale  working   @10  10    ''        ''        ''                         '子任务 0/1'

hub
L=$(cat "$SETLOG")
eq "sub-tasks: k/N, then why the ↻ waits"   "子任务 1/3 · 等子任务"     "$(put @1)" "$L"
eq "a child names its parent"               "父 #1"                     "$(put @3)" "$L"
eq "a Loop: its next round in local HH:MM"  "Loop 下次 $HM"             "$(put @4)" "$L"
eq "needs: which kind of !"                 "要你处理：在问你"          "$(put @5)" "$L"
eq "needs with no kind: just 要你处理"      "要你处理"                  "$(put @6)" "$L"
eq "a background wait + a scratch parent"   "后台命令在跑 · 父 scratch-9" "$(put @7)" "$L"
eq "all empty: nothing written"             ""                          "$(put @8)" "$L"
eq "unchanged: nothing written"             ""                          "$(put @9)" "$L"
eq "stale value with nothing to say: unset" "-u"                        "$(put @10)" "$L"

side
L=$(cat "$SETLOG")
eq "--sidebar writes the same line"         "子任务 1/3 · 等子任务"     "$(put @1)" "$L"
eq "--sidebar: a lone worker stays unset"   ""                          "$(put @8)" "$L"

# a folded parent's child is hidden from the list, never from its own header
: > "$WLIST_FILE"
w 1  par    working   @1   1     ''
w 2  kid    working   @2   2     issue-1
hub
eq "a folded-away child still gets its header" "父 #1" "$(put @2)" "$(cat "$SETLOG")"

printf 'dash-title-info-selftest: OK (%d checks)\n' "$CHECKS"
