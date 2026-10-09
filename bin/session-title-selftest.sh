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
  # column 19 is the question a `needs` session asks (issue #1951), empty otherwise
  # column 20 is role=orchestrator on the orchestrating session (issue #1957), empty otherwise
  # column 21 is epic=<ref>[:k/n] on an EPIC's driver window (issue #1958), empty otherwise
  # column 22 is epicstale= — the login's batches nobody drives (issue #1916), empty with none
  # column 23 is backfill=failed on a warm start whose issue was never filed (issue #2235)
  # columns 24-28 are the measurement bus (issue #2431), 29 agentstatus= (#2536),
  # 30 test= (#2505) — NF - 12 keeps the count of the 18
  eq "A: column 17, the reap column 18, the detail column 19, the role column 20, the epic column 21, the epicstale column 22, the backfill column 23 (NF counts through column 30, #2505); 16 before it as they were" "18 reap= detail= role= epic= epicstale= backfill= test=" \
     "$(printf '%s\n' "$out" | awk -F'\t' '$10 == "fix-sidebar-slug" { print NF - 12, $18, $19, $20, $21, $22, $23, $30 }')"
  T set-option -w -t "=$S:draft" @backfill failed
  T set-option -w -t "=$S:uncached" @backfill filing
  out2=$(bash "$CREAD" workers "$S" 2>"$WORK/err") || fail "A: workers failed" "$(cat "$WORK/err")"
  eq "A: @backfill failed → backfill=failed (column 23, #2235); still filing → empty" "backfill=failed backfill=" \
     "$(printf '%s\n' "$out2" | awk -F'\t' '$10 == "draft" { d = $23 } $10 == "uncached" { u = $23 } END { print d, u }')"
  T set-option -wu -t "=$S:draft" @backfill; T set-option -wu -t "=$S:uncached" @backfill
  # columns 24-28 (issue #2431): ctxleft= ctxband= ctxts= model= effort= off the bus;
  # an unmeasured window the five keys empty; no @ctx_left → 100 - @ctx_pct; a Codex
  # window with only the launcher's @cc_model gives that (compat-1v)
  eq "A: an unmeasured window → columns 24-28 empty" "ctxleft= ctxband= ctxts= model= effort=" \
     "$(printf '%s\n' "$out" | awk -F'\t' '$10 == "draft" { print $24, $25, $26, $27, $28 }')"
  T set-option -w -t "=$S:draft" @ctx_pct 38; T set-option -w -t "=$S:draft" @ctx_left 62
  T set-option -w -t "=$S:draft" @ctx_band ok; T set-option -w -t "=$S:draft" @ctx_ts 1800000000
  T set-option -w -t "=$S:draft" @model 'Opus 5.5'; T set-option -w -t "=$S:draft" @effort high
  T set-option -w -t "=$S:uncached" @ctx_pct 53; T set-option -w -t "=$S:uncached" @cc_agent codex
  T set-option -w -t "=$S:uncached" @cc_model gpt-6-astra; T set-option -w -t "=$S:uncached" @ctx_band 'x;y'
  out3=$(bash "$CREAD" workers "$S" 2>"$WORK/err") || fail "A: workers failed" "$(cat "$WORK/err")"
  eq "A: the bus → columns 24-28" "ctxleft=62|ctxband=ok|ctxts=1800000000|model=Opus 5.5|effort=high" \
     "$(printf '%s\n' "$out3" | awk -F'\t' '$10 == "draft" { print $24 "|" $25 "|" $26 "|" $27 "|" $28 }')"
  eq "A: no @ctx_left → 100 - @ctx_pct; a Codex @cc_model; a bad band dropped" "ctxleft=47|ctxband=|model=gpt-6-astra" \
     "$(printf '%s\n' "$out3" | awk -F'\t' '$10 == "uncached" { print $24 "|" $25 "|" $27 }')"
  # column 29 (issue #2536): agentstatus= — @agent_status as fleet-status-7501.py
  # stamped it, verbatim; empty when the agent said nothing, a non-JSON value dropped
  eq "A: no @agent_status → column 29 empty" "agentstatus=" \
     "$(printf '%s\n' "$out3" | awk -F'\t' '$10 == "draft" { print $29 }')"
  T set-option -w -t "=$S:draft" @agent_status '{"state":"blocked","kind":"permission","msg":"Bash: git push","app":"claude-code","ts":1800000000}'
  T set-option -w -t "=$S:uncached" @agent_status 'not json'
  out4=$(bash "$CREAD" workers "$S" 2>"$WORK/err") || fail "A: workers failed" "$(cat "$WORK/err")"
  eq "A: @agent_status → column 29; a malformed one dropped" 'agentstatus={"state":"blocked","kind":"permission","msg":"Bash: git push","app":"claude-code","ts":1800000000}|agentstatus=' \
     "$(printf '%s\n' "$out4" | awk -F'\t' '$10 == "draft" { d = $29 } $10 == "uncached" { u = $29 } END { print d "|" u }')"
  T set-option -wu -t "=$S:draft" @agent_status; T set-option -wu -t "=$S:uncached" @agent_status
  for o in @ctx_pct @ctx_left @ctx_band @ctx_ts @model @effort @cc_agent @cc_model; do
    T set-option -wu -t "=$S:draft" "$o"; T set-option -wu -t "=$S:uncached" "$o"
  done
  T set-option -w -t "=$S:uncached" @claude_state needs
  T set-option -w -t "=$S:uncached" @claude_needs_detail '演练放在 m5 还是只在 m4？'
  T set-option -w -t "=$S:draft" @claude_needs_detail 'a stale question'
  out1=$(bash "$CREAD" workers "$S" 2>"$WORK/err") || fail "A: workers failed" "$(cat "$WORK/err")"
  eq "A: a needs session carries its question (column 19, #1951)" "detail=演练放在 m5 还是只在 m4？" \
     "$(printf '%s\n' "$out1" | awk -F'\t' '$10 == "uncached" { print $19 }')"
  eq "A: not in needs → no question, whatever the option says" "detail=" \
     "$(printf '%s\n' "$out1" | awk -F'\t' '$10 == "draft" { print $19 }')"
  T set-option -wu -t "=$S:uncached" @claude_state
  eq "A: every other column is unchanged by the cache" \
     "$(printf '%s\n' "$out0" | awk -F'\t' '{ $17 = ""; print }' OFS='\t' | sort)" \
     "$(printf '%s\n' "$out" | awk -F'\t' '{ $17 = ""; print }' OFS='\t' | sort)"
  # @task_line (issue #2359): a window bound to no issue sends its first sentence
  # as title=; an issue window keeps its issue's title whatever the line says
  T new-window -d -t "=$S:" -n '我的会话' 'sleep 600'
  T set-option -w -t "=$S:我的会话" @norepo 1
  T set-option -w -t "=$S:我的会话" @task_line '帮我看下 mini2 的日志'
  T set-option -w -t "=$S:draft" @task_line '试一下新的侧栏'
  T set-option -w -t "=$S:fix-sidebar-slug" @task_line '/fleet-claim'
  out5=$(bash "$CREAD" workers "$S" 2>"$WORK/err") || fail "A: workers failed" "$(cat "$WORK/err")"
  eq "A: a no-repo session → its @task_line as title= (#2359)" "title=帮我看下 mini2 的日志" "$(col17 "$out5" '我的会话')"
  eq "A: a scratch → its @task_line as title=" "title=试一下新的侧栏" "$(col17 "$out5" draft)"
  eq "A: an issue window keeps its issue's title" "title=修复侧栏：显示 issue 标题" "$(col17 "$out5" fix-sidebar-slug)"
  eq "A: …and the line moves no other column" "19 reap= detail= role= epic=" \
     "$(printf '%s\n' "$out5" | awk -F'\t' '$10 == "draft" { print NF - 11, $18, $19, $20, $21 }')"
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
# column 19 (issue #1951): the question a needs session asks; empty = None
p, x = inventory_row(base + tail + ["title=t", "reap=", "detail=演练放在 m5 还是只在 m4？"])
assert x["detail"] == "演练放在 m5 还是只在 m4？" and x["title"] == "t" and x["reap"] is None, x
p, x = inventory_row(base + tail + ["title=t", "reap=keep", "detail="])
assert x["detail"] is None and x["reap"] == "keep", x
p, x = inventory_row(base + tail + ["title=t", "reap=keep"])
assert "detail" not in x, x
# columns 24-28 (issue #2431): the measurement bus, after backfill=
full = base + tail + ["title=t", "reap=", "detail=", "role=", "epic=", "epicstale=", "backfill="]
p, x = inventory_row(full + ["ctxleft=62", "ctxband=ok", "ctxts=1800000000", "model=Opus 5.5", "effort=high"])
assert (x["ctx_left"], x["ctx_band"], x["ctx_ts"], x["model"], x["effort"], x["title"]) == (62, "ok", 1800000000, "Opus 5.5", "high", "t"), x
p, x = inventory_row(full + ["ctxleft=", "ctxband=bad", "ctxts=x", "model=a;b", "effort="])
assert not any(k in x for k in ("ctx_left", "ctx_band", "ctx_ts", "model", "effort")) and x["title"] == "t", x
p0, x0 = inventory_row(full)
assert "model" not in x0 and x0["title"] == "t", x0
# column 29 (issue #2536): agentstatus= → status_kind / status_msg, after effort=
bus = ["ctxleft=62", "ctxband=ok", "ctxts=1800000000", "model=Opus 5.5", "effort=high"]
p, x = inventory_row(full + bus + ['agentstatus={"state":"blocked","kind":"permission","msg":"Bash: git push","app":"claude-code","ts":1}'])
assert (x["status_kind"], x["status_msg"], x["ctx_left"], x["title"]) == ("permission", "Bash: git push", 62, "t"), x
p, x = inventory_row(full + bus + ['agentstatus={"state":"working","kind":"","msg":"","app":"claude-code","ts":1}'])
assert "status_kind" not in x and "status_msg" not in x and x["effort"] == "high", x
p, x = inventory_row(full + bus + ["agentstatus=nope"])
assert "status_kind" not in x and x["model"] == "Opus 5.5", x
p, x = inventory_row(full + bus + ["agentstatus="])
assert "status_msg" not in x and x["ctx_band"] == "ok", x
# issue #2538: no report, a needs row's subtype + detail fill the pair; a report wins
ask = base[:11] + ["perm"] + base[12:]
p, x = inventory_row(ask + tail + ["title=t", "reap=", "detail=Bash: rm -rf build"])
assert (x["status_kind"], x["status_msg"]) == ("permission", "Bash: rm -rf build"), x
p, x = inventory_row(ask + tail + ["title=t", "reap=", "detail=", "role=", "epic=", "epicstale=", "backfill="] + bus
                     + ['agentstatus={"state":"blocked","kind":"auth","msg":"/login","app":"claude-code","ts":1}'])
assert (x["status_kind"], x["status_msg"], x["needs"]) == ("auth", "/login", "perm"), x
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
            s("issue-23", issue=23, name="slug-of-23"),
            s("issue-24", issue=24, name="slug-of-24", state="needs", needs="ask", detail="演练放在 m5 还是只在 m4？"),
            s("scratch-5", name="scratch-5", state="needs", needs="perm", detail="Bash: git push"),
            s("issue-25", issue=25, name="slug-of-25", state="failed"),
            s("issue-26", issue=26, name="slug-of-26", agent="codex", ctx_left=81, ctx_band="ok",
              ctx_ts=1800000000, model="gpt-6-astra", effort="high"),
            s("issue-27", issue=27, name="slug-of-27", ctx_left=None, ctx_band=None, model=None)]
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
# fields 21-25 (issue #2431): the bus, all five, the empty optional ones before kept
eq "C: a measured session's row carries fields 21-25" "25|81|ok|1800000000|gpt-6-astra|high" \
   "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/issue-26" '$1 == w { print NF "|" $21 "|" $22 "|" $23 "|" $24 "|" $25 }')"
eq "C: nulls for every bus key keep the row's 16 fields" "16|" "$(crow issue-27)"
# who waits on you and what they ask (issue #1951): needs_<sess> beside the cache
eq "C: needs_<sess> lists the needs / failed sessions with their question" \
   "$F/issue-24${US}#24${US}ask${US}m4${US}演练放在 m5 还是只在 m4？
$F/scratch-5${US}scratch-5${US}perm${US}m4${US}Bash: git push
$F/issue-25${US}#25${US}failed${US}m4${US}" "$(cat "$G/needs_$S" 2>/dev/null)"

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

# D2 (issue #2359): a session bound to no issue reads as what it is about — its
# @task_line (WFMT field 28) as field 14, and as the label when the name is only
# a number; a no-repo session reads `我的会话 · <line>`, an older `norepo-N`
# too, never its number. An issue window keeps its name without a title.
# wl <idx> <name> <window_id> <issue> <norepo> <task_line> — working: a done
# unbound row folds into 已结束 (issue #2565)
wl() { printf '%s\n' "$S$US$1$US$2$US/w/app-$2${US}working$US$US$3$US$4$US$US$US$US$US$US$US$US$US$US$US$US$US$5$US$US$US$US$US${1}000$US$US$6" >> "$WLIST_FILE"; }
unset CCQUOTA_FLEET
: > "$WLIST_FILE"
wl 1 scratch-5 @1 '' '' '试一下新的侧栏'
wl 2 '我的会话' @2 '' 1 '帮我看下 mini2 的日志'
wl 3 norepo-2 @3 '' 1 ''
wl 4 '我的会话-2' @4 '' 1 '第二个'
wl 5 issue-12 @5 12 '' '/fleet-claim'
s=$(side)
lbl() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v w="$2" '$1 == w { print $4 }'; }
eq "D2: an unbound scratch → its first sentence as the label" "试一下新的侧栏" "$(lbl "$s" @1)"
eq "D2: …and as field 14" "试一下新的侧栏" "$(printf '%s\n' "$s" | LC_ALL=C awk -F"$US" '$1 == "@1" { print $14 }')"
eq "D2: a no-repo session → 我的会话 · <line>" "我的会话 · 帮我看下 mini2 的日志" "$(lbl "$s" @2)"
eq "D2: an older norepo-N with no line → 我的会话" "我的会话" "$(lbl "$s" @3)"
eq "D2: a deduped 我的会话-2 → 我的会话 · <line>" "我的会话 · 第二个" "$(lbl "$s" @4)"
eq "D2: an issue window with no cached title keeps its name" "issue-12" "$(lbl "$s" @5)"
eq "D2: …and no field 14 (the line is not its title)" "-" \
   "$(printf '%s\n' "$s" | LC_ALL=C awk -F"$US" '$1 == "@5" { print (NF >= 14 ? $14 : "-") }')"
eq "D2: no row reads norepo" "" "$(printf '%s\n' "$s" | LC_ALL=C awk -F"$US" '$4 ~ /norepo/')"
# fleet ls reads these same rows (fleet-quickopen.py full_rows → parse_rows)
eq "D2: fleet ls's parse of them — names, no norepo" "试一下新的侧栏|我的会话 · 帮我看下 mini2 的日志|我的会话|我的会话 · 第二个|issue-12" \
   "$(printf '%s\n' "$s" | python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("qo", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lines = [l.split(m.US, 14) for l in sys.stdin.read().split("\n") if l.count(m.US) >= 4]
rows = [(r + [""] * 15)[:15] for r in lines]
print("|".join(r["name"] for r in m.parse_rows(m.rows_text(rows)) if not r["key"].startswith("hdr")))' "$BIN/fleet-quickopen.py")"

# E (issue #2355): ccquota's agent runs the adapter with no TMPDIR (a
# LaunchDaemon) — it must find the SAME cache the login's daemons write, or
# every title= goes out empty. The per-user dir is set before fleet-lib.sh
# fixes $FLEET_C off it.
_tl=$(grep -n 'DARWIN_USER_TEMP_DIR' "$BIN/fleet-control-read.sh" | head -n1 | cut -d: -f1)
_ll=$(grep -n '^\. "\$BIN/fleet-lib.sh"' "$BIN/fleet-control-read.sh" | head -n1 | cut -d: -f1)
eq "E: fleet-control-read.sh sets TMPDIR before it sources fleet-lib.sh" "yes" \
   "$([ -n "$_tl" ] && [ -n "$_ll" ] && [ "$_tl" -lt "$_ll" ] && echo yes || echo no)"
if _ut=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) && [ -d "$_ut" ]; then
  got=$(env -u TMPDIR bash -c 'BIN=$1; eval "$(sed -n "/DARWIN_USER_TEMP_DIR/,/^fi/p" "$BIN/fleet-control-read.sh")"; . "$BIN/fleet-lib.sh"; printf %s "$FLEET_C"' _ "$BIN")
  CHECKS=$((CHECKS+1))
  case "$got" in "${_ut%/}"/*.claude-dash) ;; *) fail "E: with no TMPDIR the cache must be the per-user one (got '$got', want under '$_ut')" ;; esac
fi

printf 'session-title selftest: PASS (%s checks)\n' "$CHECKS"
