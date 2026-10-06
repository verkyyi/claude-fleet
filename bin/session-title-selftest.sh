#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word in a fixture, not the keyword
# session-title-selftest.sh — a session's issue title travels with it (issue #1921).
#
# The other machines' sidebars and a session's top bar (#1904) show the issue
# TITLE, not the window name's slug. Every layer, each with its degenerate case:
#   A. adapter   — fleet-control-read.sh workers (a real isolated tmux socket):
#                  column 17 `title=<title>` off this machine's issue cache, joined
#                  on (repo, issue); empty for a scratch or an uncached issue; a
#                  tab inside a title becomes a space
#   B. inventory — fleet_hub_common.inventory_row parses `title=`; a 16-column row
#                  (an older adapter) has no `title`, every other field as before
#   C. cache     — fleet-hub-sessions.sh --refresh appends `title` as field 17 of
#                  a remote_<sess> row; a worker without one keeps its 16 fields
#   D. sidebar   — tmux-dashboard-rows.sh --sidebar: field 14 = the title, for a
#                  local row (this machine's issue cache) and a remote one (cache
#                  field 17); field 13 stays empty when cfg is unknown; a row with
#                  no title is byte for byte what it was with no issue cache at all
# No gh, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
HUBS="$BIN/fleet-hub-sessions.sh"
CREAD="$BIN/fleet-control-read.sh"
command -v python3 >/dev/null 2>&1 || { echo 'session-title selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sesstitle-selftest.XXXXXX")" || exit 2
S="stitle$$"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_HUB_URL \
      FLEET_SIDEBAR_SOURCE XDG_CONFIG_HOME
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
G="$WORK/.claude-dash/global"
IC="$WORK/.claude-dash/fleets/acme-app"
mkdir -p "$G" "$IC" "$WORK/conf/fleets/$S" "$WORK/bin"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"
printf '%s\tacme-app\tacme/app\n' "$S" > "$G/sessmap"
# the collector's issue cache: milestone<TAB>#num<TAB>assignee<TAB>title
issues() { printf '\t#7\tme\t修复侧栏：显示 issue 标题\n\t#9\t\tA\ttabbed title\n' > "$IC/issues"; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

# ============================================================================
# A. adapter — fleet-control-read.sh workers on an isolated socket
# ============================================================================
if [ -n "$REAL_TMUX" ]; then
  T() { "$REAL_TMUX" -L "$S" "$@"; }
  T -f /dev/null new-session -d -s "$S" -n home 'sleep 600' || fail "A: could not start the isolated server"
  T new-window -d -t "=$S:" -n fix-sidebar-slug 'sleep 600'
  T new-window -d -t "=$S:" -n tabbed 'sleep 600'
  T new-window -d -t "=$S:" -n uncached 'sleep 600'
  T new-window -d -t "=$S:" -n draft 'sleep 600'
  T set-option -w -t "=$S:fix-sidebar-slug" @issue 7
  T set-option -w -t "=$S:tabbed" @issue 9
  T set-option -w -t "=$S:uncached" @issue 12
  T set-option -w -t "=$S:draft" @raw 1
  T set-option -w -t "=$S:draft" @worktree "$WORK/app-scratch-3"
  col17() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$10 == n { print $17 }'; }
  rm -f "$IC/issues"
  out0=$(bash "$CREAD" workers "$S" 2>"$WORK/err") || fail "A: workers failed" "$(cat "$WORK/err")"
  eq "A: no issue cache — the column is there, empty" "title=" "$(col17 "$out0" fix-sidebar-slug)"
  issues
  out=$(bash "$CREAD" workers "$S" 2>"$WORK/err") || fail "A: workers failed" "$(cat "$WORK/err")"
  eq "A: an issue window carries its title (column 17)" "title=修复侧栏：显示 issue 标题" "$(col17 "$out" fix-sidebar-slug)"
  eq "A: a tab inside a title becomes a space" "title=A tabbed title" "$(col17 "$out" tabbed)"
  eq "A: an issue the cache does not hold → empty" "title=" "$(col17 "$out" uncached)"
  eq "A: a scratch → empty" "title=" "$(col17 "$out" draft)"
  # column 18 is the reap policy (issue #1902): 16 before the title as they were
  eq "A: column 17, then the reap column 18; 16 before it as they were" "16 reap=" \
     "$(printf '%s\n' "$out" | awk -F'\t' '$10 == "fix-sidebar-slug" { print NF - 2, $18 }')"
  eq "A: every other column is unchanged by the cache" \
     "$(printf '%s\n' "$out0" | awk -F'\t' '{ $17 = ""; print }' OFS='\t' | sort)" \
     "$(printf '%s\n' "$out" | awk -F'\t' '{ $17 = ""; print }' OFS='\t' | sort)"
  T kill-server 2>/dev/null
else
  echo 'session-title selftest: tmux absent — leg A skipped'
fi

# ============================================================================
# B. inventory — inventory_row parses title=
# ============================================================================
out=$(python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fleet_hub_common import inventory_row
base = ["@1", "7", "", "/w", "done", "", "", "", "", "nm", "", "", "11111111-2222-3333-4444-555555555555"]
tail = ["busy=", "born=1759000010", "cfg=ok"]
p, x = inventory_row(base + tail + ["title=修复侧栏"])
assert x["title"] == "修复侧栏" and x["cfg"] == "ok" and x["born"] == 1759000010 and x["name"] == "nm", x
p, x = inventory_row(base + tail + ["title="])
assert x["title"] is None and x["cfg"] == "ok", x
p0, x0 = inventory_row(base + tail)
assert "title" not in x0, x0
assert (p0, x0) == (p, {k: v for k, v in x.items() if k != "title"}), (x0, x)
# a name that happens to start with `title=` in a short row is still the name
p, x = inventory_row(base[:9] + ["title=x"])
assert x["name"] == "title=x" and "title" not in x, x
print("ok")
PY
)
eq "B: inventory_row parses title=, an older row has none" "ok" "$out"

# ============================================================================
# C. cache — fleet-hub-sessions.sh --refresh, field 17
# ============================================================================
F=11111111-2222-3333-4444-555555555555
ME=$(id -un)
python3 - "$WORK/sessions.json" "$F" "$ME" <<'PY'
import json, sys
path, f, me = sys.argv[1:4]
def s(key, **w):
    w.setdefault("key", key); w.setdefault("state", "working"); w.setdefault("lifecycle", "awake")
    w.setdefault("agent", "claude"); w.setdefault("repo", "acme/app")
    return dict(worker_id=f + "/" + key, machine_name="mini2.local", os_user=me, fleet_id=f,
                fleet_name="x", availability="online", worker=w, observed_at="2026-10-06T10:00:00Z")
sessions = [s("issue-21", issue=21, name="slug-of-21", title="远程的 issue 标题"),
            s("issue-22", issue=22, name="slug-of-22", title=None),
            s("issue-23", issue=23, name="slug-of-23")]
nodes = [dict(machine_name="mini2.local", availability="online", sessions=3, observed_at="2026-10-06T10:00:00Z", age_sec=3)]
json.dump({"machines": [], "sessions": sessions, "nodes": nodes}, open(path, "w"), ensure_ascii=False)
PY
export CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="mini2=m4"
bash "$HUBS" --refresh 2>"$WORK/err" || fail "C: --refresh failed" "$(cat "$WORK/err")"
R=$(cat "$G/remote_$S" 2>/dev/null)
US=$'\x1f'
crow() { printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/$1" '$1 == w { print NF "|" $NF }'; }
eq "C: a titled worker's row ends in field 17 = the title" "17|远程的 issue 标题" "$(crow issue-21)"
eq "C: a null title keeps the row's 16 fields" "16|" "$(crow issue-22)"
eq "C: no title key keeps the row's 16 fields" "16|" "$(crow issue-23)"

# ============================================================================
# D. sidebar — field 14
# ============================================================================
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do [ "$a" = list-windows ] && lw=1; case "$a" in *"$US"*) fmt=1 ;; esac; done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
export WLIST_FILE="$WORK/wlist"
SHIMPATH="$WORK/bin:$PATH"
# The 27 WFMT fields: session idx name path state ts window_id @issue … born @agent_cfg
# w <idx> <name> <window_id> <issue>
w() { printf '%s\n' "$S$US$1$US$2$US/w/app-$2${US}done$US$US$3$US$4$US$US$US$US$US$US$US$US$US$US$US$US$US$US$US$US$US$US${1}000$US" >> "$WLIST_FILE"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
side() { PATH="$SHIMPATH" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>"$WORK/err" | strip; }
fld() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" -v k="$3" '$4 == n { print (NF >= k ? $k : "-") }'; }
: > "$WLIST_FILE"
w 1 fix-sidebar-slug @1 7
w 2 uncached @2 12
w 3 draft @3 ''
unset CCQUOTA_FLEET
rm -f "$IC/issues"
s0=$(side)
eq "D: no issue cache — no field 14" "-" "$(fld "$s0" fix-sidebar-slug 14)"
issues
s=$(side)
eq "D: a local issue row carries its title as field 14" "修复侧栏：显示 issue 标题" "$(fld "$s" fix-sidebar-slug 14)"
eq "D: …with field 13 (cfg, unknown here) empty" "" "$(fld "$s" fix-sidebar-slug 13)"
eq "D: …and the label is still the window name" "fix-sidebar-slug" \
   "$(printf '%s\n' "$s" | LC_ALL=C awk -F"$US" '$4 == "fix-sidebar-slug" { print $4 }')"
eq "D: an uncached issue row is byte for byte as before" \
   "$(printf '%s\n' "$s0" | grep "${US}uncached$US")" "$(printf '%s\n' "$s" | grep "${US}uncached$US")"
eq "D: a scratch row is byte for byte as before" \
   "$(printf '%s\n' "$s0" | grep "${US}draft$US")" "$(printf '%s\n' "$s" | grep "${US}draft$US")"
# another machine's rows: field 17 of the hub cache
export CCQUOTA_FLEET=1
NOW=$(date +%s); printf '%s\n' "$NOW" > "$G/hub_ok"
{ printf '#ts\037%s\n#me\037m5\n#node\037m4\037online\0372\037%s\n' "$NOW" "$NOW"
  printf 'wid:%s/issue-21\037m4\037online\03721\037acme/app\037done\037claude\037RT\037\037\0370\037\037hub\037\0371759000000\037stale\037远程的 issue 标题\n' "$F"
  printf 'wid:%s/issue-22\037m4\037online\03722\037acme/app\037done\037claude\037RN\037\037\0370\037\037hub\037\0371759000000\n' "$F"
} > "$G/remote_$S"
s=$(side)
eq "D: a remote row carries its node's title as field 14" "远程的 issue 标题" "$(fld "$s" RT 14)"
eq "D: …beside its cfg verdict (field 13)" "stale" "$(fld "$s" RT 13)"
eq "D: a remote row with no title (an older cache) has no field 14" "-" "$(fld "$s" RN 14)"
eq "D: …nor field 13" "-" "$(fld "$s" RN 13)"

printf 'session-title selftest: PASS (%s checks)\n' "$CHECKS"
