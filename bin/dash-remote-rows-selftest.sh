#!/bin/bash
# dash-remote-rows-selftest.sh — the sidebar shows your sessions on the OTHER
# machines (issue #1423, EPIC #1419 C4), mixed in with this machine's, tagged with
# the machine, nested under their real parents; a lost machine's rows stay and read
# 失联. Drives tmux-dashboard-rows.sh, fleet-hub-sessions.sh, fleet-control-read.sh
# + fleet_control.py, and the read-only guards in dash-fold-toggle.sh,
# dash-pin-toggle.sh and dash-migrate.sh.
#
# Legs:
#   A. degenerate — CCQUOTA_FLEET unset: a remote cache on disk changes NOTHING
#                   (sidebar + hub byte for byte the no-cache output); on, with no
#                   cache, the same bytes again
#   B. rows       — a remote row nests under its LOCAL parent (bare-key origin) and a
#                   remote grandchild under ITS remote parent (worker_id origin); each
#                   wears `[m4]`; the local parent's k/N counts them; the hub row keeps
#                   the common width; its id is `wid:<worker_id>`
#   C. lost       — a machine the hub calls lost, and EVERY row once the cache is older
#                   than FLEET_HUB_SESSIONS_STALE, reads `[m4 失联]` — never vanishes
#   D. no network — rendering with the hub on runs no curl/wget/nc/ccquota, and the
#                   producer names none of them (nor the refresher)
#   E. refresher  — fleet-hub-sessions.sh --refresh keeps only YOUR sessions on OTHER
#                   machines with a worker_id, translates @origin_wid into this fleet's
#                   terms (own fleet → bare key, elsewhere → worker_id, none → the
#                   sub-issue parent), writes the C1 locator cache; a failed fetch keeps
#                   the last cache; off ⇒ writes nothing, --ensure starts nothing
#   F. read-only  — fold / pin / migrate on a `wid:` row touch no tmux option
#   G. inventory  — the real adapter on an isolated socket hands fleet_control.py the
#                   window name and @origin_wid; a 9-column adapter still parses
#
# Hermetic: the row legs PATH-shim `tmux` to replay a fixture window list; leg G runs
# a private `tmux -L` server. No gh, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
HUBS="$BIN/fleet-hub-sessions.sh"
command -v python3 >/dev/null 2>&1 || { echo 'dash-remote-rows selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashremote-selftest.XXXXXX")" || exit 2
S="hubs$$"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE TMUX TMUX_PANE
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/bin"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/$S/conf"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }

US=$'\x1f'
# tmux shim: replays the fixture for a list-windows with a US format, logs the rest.
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do [ "$a" = list-windows ] && lw=1; case "$a" in *"$US"*) fmt=1 ;; esac; done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
for n in curl wget nc ccquota; do
  printf '#!/bin/sh\necho "%s $*" >> "$NET_LOG"\nexit 1\n' "$n" > "$WORK/bin/$n"
done
chmod +x "$WORK/bin/"*
export WLIST_FILE="$WORK/wlist" TMUX_LOG="$WORK/tmux.log" NET_LOG="$WORK/net.log"
: > "$TMUX_LOG"; : > "$NET_LOG"
SHIMPATH="$WORK/bin:$PATH"

# WFMT order: session idx name path state state_ts wid @issue @origin @worktree
#             @cc_agent @wid @claude_needs @expand
w() { printf '%s\n' "$S$US$1$US$2$US$3$US$4$US$US$5$US$6$US$7$US$3$US$US$8$US$US${9:-}" >> "$WLIST_FILE"; }
: > "$WLIST_FILE"
#  idx name  path                 state    wid  issue origin      handle expand
w 1  EPIC  /w/app-issue-1419    looping  @1   1419  ''          a1     1
w 2  C1    /w/app-issue-1420    working  @2   1420  issue-1419  a2
w 3  solo  /w/app-issue-1430    working  @3   1430  ''          a3

# colours off, and the working spinner's frame (it turns every quarter second) → `*`
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g' -e 's/⠋/*/g;s/⠙/*/g;s/⠹/*/g;s/⠸/*/g;s/⠼/*/g;s/⠴/*/g;s/⠦/*/g;s/⠧/*/g;s/⠇/*/g;s/⠏/*/g'; }
side() { PATH="$SHIMPATH" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>/dev/null | strip; }
hub()  { PATH="$SHIMPATH" FLEET_SESSION=$S FZF_COLUMNS=140 bash "$ROWS" 2>/dev/null | strip; }
# LC_ALL=C: BSD awk compares strings with strcoll, and under a UTF-8 locale two
# different CJK names collate EQUAL — `孙` would match `侧边栏`.
srow()  { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$4 == n { print $1 "|" $5 "|" $6 "|" $7; exit }'; }
sorder(){ printf '%s\n' "$1" | LC_ALL=C awk -F"$US" '$1 != "hdr" { printf "%s;", $4 }'; }

F=11111111-2222-3333-4444-555555555555            # a fleet on another machine
NOW=$(date +%s)
remote_cache() {   # $1 = the #ts epoch
  { printf '#ts\037%s\n' "$1"
    printf 'wid:%s/issue-1423\037m4\037online\0371423\037acme/app\037working\037claude\037侧边栏\037issue-1419\n' "$F"
    printf 'wid:%s/issue-1500\037m4\037online\0371500\037acme/app\037done\037claude\037孙\037%s/issue-1423\n' "$F" "$F"
    printf 'wid:%s/scratch-2\037m4\037lost\037\037\037working\037claude\037草稿\037\n' "$F"
  } > "$G/remote_$S"
}

# ============================================================================
# A. degenerate
# ============================================================================
base_s=$(side); base_h=$(hub)
[ -n "$base_s" ] || fail "the sidebar producer printed nothing"
remote_cache "$NOW"
eq "A: hub off — a remote cache changes nothing (sidebar)" "$base_s" "$(side)"
eq "A: hub off — a remote cache changes nothing (hub)"     "$base_h" "$(hub)"
hasnt "A: hub off — no machine tag anywhere" "$(side)$(hub)" "[m4"
mv "$G/remote_$S" "$WORK/remote.keep"
eq "A: hub on, no cache — the same bytes (sidebar)" "$base_s" "$(CCQUOTA_FLEET=1 side)"
eq "A: hub on, no cache — the same bytes (hub)"     "$base_h" "$(CCQUOTA_FLEET=1 hub)"
mv "$WORK/remote.keep" "$G/remote_$S"

# ============================================================================
# B. rows
# ============================================================================
export CCQUOTA_FLEET=1
s=$(side)
eq "B: mixed with the local rows, each under its real parent" \
   "solo;草稿 [m4 失联];EPIC;C1;侧边栏 [m4];孙 [m4];" "$(sorder "$s")"
eq "B: the local parent counts its remote descendants" "@1|▾|1/3|0" "$(srow "$s" EPIC)"
eq "B: a remote child under a LOCAL parent: depth 1, its own subtree" \
   "wid:$F/issue-1423|└▾|1/1|1" "$(srow "$s" '侧边栏 [m4]')"
eq "B: a remote grandchild under its REMOTE parent: depth 2" \
   "wid:$F/issue-1500|  └||2" "$(srow "$s" '孙 [m4]')"
eq "B: a local sibling is untouched" "@2|└||1" "$(srow "$s" C1)"
h=$(hub)
has "B: the hub row carries the tag" "$h" "[m4]"
has "B: the hub row shows the issue" "$h" "#1423"
widths=$(printf '%s\n' "$h" | python3 -c 'import sys, unicodedata
w = lambda t: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)
print("\n".join(sorted({str(w(l.split("\x1f")[2])) for l in sys.stdin.read().split("\n")[1:] if "\x1f" in l})))')
eq "B: every hub row is the same width, 失联 included" "136" "$widths"
hasnt "B: no @title_info is written for a remote row" "$(cat "$TMUX_LOG")" "wid:"

# ============================================================================
# C. lost
# ============================================================================
eq "C: a machine the hub calls lost: the row stays, 失联" \
   "wid:$F/scratch-2| ||0" "$(srow "$s" '草稿 [m4 失联]')"
remote_cache $((NOW - 600))
s=$(side)
eq "C: a stale cache: every remote row stays, reading 失联" \
   "solo;草稿 [m4 失联];EPIC;C1;侧边栏 [m4 失联];孙 [m4 失联];" "$(sorder "$s")"
eq "C: FLEET_HUB_SESSIONS_STALE widens the window" \
   "solo;草稿 [m4 失联];EPIC;C1;侧边栏 [m4];孙 [m4];" "$(sorder "$(FLEET_HUB_SESSIONS_STALE=900 side)")"
remote_cache "$NOW"

# ============================================================================
# D. no network on the render path
# ============================================================================
: > "$NET_LOG"; side >/dev/null; hub >/dev/null
eq "D: rendering with the hub on makes no network call" "" "$(cat "$NET_LOG")"
eq "D: the producer's code names no network tool and not the refresher" "0" \
   "$(grep -v '^[[:space:]]*#' "$ROWS" | grep -cE '(^|[^A-Za-z_])(curl|wget|nc|ccquota)([^A-Za-z_]|$)|fleet-hub-sessions')"

# ============================================================================
# E. refresher
# ============================================================================
unset CCQUOTA_FLEET
U=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
f=[x for x in c.Control(sys.argv[1]).inventory() if x["name"]==sys.argv[2]]
print(f[0]["fleet_id"] if f else "")' "$FLEET_CONF_DIR" "$S")
[ -n "$U" ] || fail "E: could not mint this fleet's UUID"
ME=$(id -un)
mkdir -p "$WORK/.claude-dash/fleets/acme-app"
printf '1600\t1419\n1501\t1500\n' > "$WORK/.claude-dash/fleets/acme-app/parents"
python3 - "$WORK/sessions.json" "$U" "$F" "$ME" <<'PY'
import json, sys
path, u, f, me = sys.argv[1:5]
def s(fleet, host, user, key, avail="online", wid=True, **w):
    w.setdefault("key", key); w.setdefault("state", "working"); w.setdefault("lifecycle", "awake")
    w.setdefault("agent", "claude"); w.setdefault("repo", "acme/app")
    return dict(worker_id=(fleet + "/" + key) if wid else None, machine_name=host, os_user=user,
                fleet_id=fleet, fleet_name="x", availability=avail, worker=w)
json.dump({"machines": [], "sessions": [
    s(u, "elsewhere", me, "issue-1420", issue=1420, name="local-one"),           # this fleet: dropped
    s(f, "mini2.local", me, "issue-1423", issue=1423, name="侧边栏", origin_wid=u + "/issue-1419"),
    s(f, "mini2.local", me, "issue-1500", issue=1500, name="孙", origin_wid=f + "/issue-1423"),
    s(f, "mini2.local", me, "issue-1600", issue=1600, name="epic-kid"),          # sub-issue of local 1419
    s(f, "mini2.local", me, "issue-1501", issue=1501, name="remote-sub"),        # sub-issue of REMOTE 1500
    s(f, "mini2.local", me, "issue-1700", issue=1700, name="sleeper", lifecycle="sleeping"),
    s(f, "mini2.local", me, "scratch-4", avail="lost", issue=None, repo=None, name="草稿"),
    s(f, "mini2.local", "someone-else", "issue-1800", issue=1800, name="theirs"),
    s(f, "mini2.local", me, "issue-1900", wid=False, issue=1900, name="no-id"),
]}, open(path, "w"), ensure_ascii=False)
PY
export FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="mini2=m4"
rm -f "$G/remote_$S"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
CHECKS=$((CHECKS+1)); [ ! -e "$G/remote_$S" ] || fail "E: off — --refresh must write nothing"
PATH="$SHIMPATH" bash "$HUBS" --ensure 2>/dev/null
CHECKS=$((CHECKS+1)); [ ! -e "$G/hubsess.pid" ] || fail "E: off — --ensure must start nothing"

export CCQUOTA_FLEET=1
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err" || fail "E: --refresh failed" "$(cat "$WORK/err")"
R=$(cat "$G/remote_$S" 2>/dev/null)
rrow() { printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/$1" '$1 == w { print $2 "|" $3 "|" $6 "|" $8 "|" $9 }'; }
has  "E: a #ts line leads the cache" "$(printf '%s\n' "$R" | head -1)" "#ts$US"
eq   "E: parent in THIS fleet → its bare key"  "m4|online|working|侧边栏|issue-1419" "$(rrow issue-1423)"
eq   "E: parent elsewhere → its worker_id"     "m4|online|working|孙|$F/issue-1423" "$(rrow issue-1500)"
eq   "E: no @origin_wid → the sub-issue parent (local)"  "m4|online|working|epic-kid|issue-1419" "$(rrow issue-1600)"
eq   "E: no @origin_wid → the sub-issue parent (remote)" "m4|online|working|remote-sub|$F/issue-1500" "$(rrow issue-1501)"
eq   "E: a sleeping lifecycle is the row's state" "m4|online|sleeping|sleeper|" "$(rrow issue-1700)"
eq   "E: a lost machine's row is kept, marked lost" "m4|lost|working|草稿|" "$(rrow scratch-4)"
hasnt "E: this fleet's own session is not a remote row" "$R" "local-one"
hasnt "E: another login's session is not shown" "$R" "theirs"
hasnt "E: a session with no worker_id is not shown" "$R" "no-id"
has  "E: the C1 locator cache is written" "$(cat "$FLEET_CONF_DIR/control/hub-workers.tsv" 2>/dev/null)" "$F/issue-1423	m4"
FLEET_HUB_SESSIONS_CMD='exit 1' PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err"
eq   "E: a failed fetch returns 1"          "1" "$?"
eq   "E: …and keeps the last cache"         "$R" "$(cat "$G/remote_$S")"
has  "E: …and says so on stderr"            "$(cat "$WORK/err")" "hub unreachable"
# The refreshed cache renders: the epic's sub-issue nests under the local EPIC.
s=$(side)
eq "E: the refreshed cache renders under the local parent" "$F/issue-1600" \
   "$(printf '%s\n' "$s" | LC_ALL=C awk -F"$US" '$4 == "epic-kid [m4]" && $7 == 1 { sub(/^wid:/, "", $1); print $1 }')"

# ============================================================================
# F. read-only
# ============================================================================
: > "$TMUX_LOG"
PATH="$SHIMPATH" FLEET_SESSION=$S bash "$BIN/dash-fold-toggle.sh" expand "wid:$F/issue-1423" >/dev/null 2>&1
PATH="$SHIMPATH" FLEET_SESSION=$S bash "$BIN/dash-pin-toggle.sh" "wid:$F/issue-1423" >/dev/null 2>&1
PATH="$SHIMPATH" FLEET_SESSION=$S bash "$BIN/dash-migrate.sh" "wid:$F/issue-1423" >/dev/null 2>&1
hasnt "F: fold/pin/migrate on a remote row set no tmux option" "$(cat "$TMUX_LOG")" "set-"

# ============================================================================
# G. inventory columns 10-11
# ============================================================================
if [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$S" -f /dev/null new-session -d -s "$S" -n plan 'while :; do sleep 300; done' 2>/dev/null; then
  wi=$("$REAL_TMUX" -L "$S" new-window -d -P -F '#{window_id}' -n '侧边栏 x' 'while :; do sleep 300; done')
  "$REAL_TMUX" -L "$S" set-window-option -t "$wi" @issue 1423
  "$REAL_TMUX" -L "$S" set-window-option -t "$wi" @origin_wid "$F/issue-1419"
  got=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = [x for x in ctl.inventory() if x["name"] == sys.argv[2]][0]
w = [x for x in ctl.workers(f)["workers"] if x["issue"] == 1423][0]
print(w["name"] + "|" + str(w["origin_wid"]) + "|" + w["key"])' "$FLEET_CONF_DIR" "$S" 2>&1)
  eq "G: the adapter hands over the window name and @origin_wid" "侧边栏 x|$F/issue-1419|issue-1423" "$got"
else
  printf 'dash-remote-rows selftest: no isolated tmux server — leg G (live adapter) skipped\n' >&2
fi
got=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = {"name": "x", "agent": "claude", "fleet_id": sys.argv[2], "repo": "acme/app"}
ctl.adapter = lambda *a, **k: (0, b"@5\t7\t0\t/w/app-issue-7\tworking\tclaude\ta1\t\t\n", b"")
w = ctl.workers(f)["workers"][0]
print("name" in w, "origin_wid" in w, w["key"])' "$FLEET_CONF_DIR" "$U" 2>&1)
eq "G: a 9-column adapter still parses, with no new keys" "False False issue-7" "$got"
got=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = {"name": "x", "agent": "claude", "fleet_id": sys.argv[2], "repo": "acme/app"}
ctl.adapter = lambda *a, **k: (0, b"@5\t7\t0\t/w/app-issue-7\tworking\tclaude\ta1\t\t\ta\tb\t\n", b"")
w = ctl.workers(f)["workers"][0]
print(w["name"] + "|" + str(w["origin_wid"]))' "$FLEET_CONF_DIR" "$U" 2>&1)
eq "G: a tab inside the window name is absorbed, never a protocol error" "a b|None" "$got"

printf 'dash-remote-rows selftest: PASS (%d checks)\n' "$CHECKS"
