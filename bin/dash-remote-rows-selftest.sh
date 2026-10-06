#!/bin/bash
# dash-remote-rows-selftest.sh — the sidebar shows your sessions on the OTHER
# machines (issue #1423, EPIC #1419 C4; the #1475 look + identity), mixed in with
# this machine's, nested under their real parents, drawn like them (no machine
# name on a row — #1475); no machine status line on top (#1531); a lost machine's rows dimmed
# where they stand (#1882). Drives tmux-dashboard-rows.sh, fleet-hub-sessions.sh,
# fleet-control-read.sh + fleet_control.py, and the read-only guards in
# dash-fold-toggle.sh, dash-pin-toggle.sh and dash-migrate.sh.
#
# Legs:
#   A. degenerate — CCQUOTA_FLEET unset: a remote cache on disk changes NOTHING
#                   (sidebar + hub byte for byte the no-cache output); on, with no
#                   cache, the same bytes again
#   B. rows       — a remote row nests under its LOCAL parent (bare-key origin) and a
#                   remote grandchild under ITS remote parent (worker_id origin); each
#                   carries its machine as the sidebar's 9th field (`m4`) and the hub
#                   row's last field, NEVER drawn — no `[m4]` in the name, no tag: a
#                   remote row looks exactly like a local one (#1475); a local row has an
#                   empty 9th field; the local parent's k/N counts them; the hub row keeps the
#                   common width; its id is `wid:<worker_id>`
#   S. status     — NO machine status line (issue #1531): the first row is the first
#                   group, in the sidebar and the hub list alike; which machine is
#                   online / 维护中 / lost lives in the bar and each row's @m4! only
#   C. lost       — a lost machine's rows (the hub says lost, or the cache is older than
#                   FLEET_HUB_SESSIONS_STALE) are `m4!` for the view and STAY PUT (#1882):
#                   same order, same nesting, no heading of their own — the frame is the
#                   online one line by line but for the `!`; never vanish
#   N. needs      — a remote row that is asking its person draws the local `!` + detail
#   D. no network — rendering with the hub on runs no curl/wget/nc/ccquota, and the
#                   producer names none of them (nor the refresher)
#   H. hub source — FLEET_SIDEBAR_SOURCE=hub (issue #1480, EPIC #1479 C1): the
#                   sidebar's row SET is the cache's — a local row the cache names
#                   renders off its own tmux line (its `@` id, its LIVE state, its
#                   subtree), a local window the cache does not name is not a row (the
#                   sidebar's own window excepted), nor is a cached local row whose
#                   window is gone; a pinned or `@norepo` window the cache does not
#                   name STAYS (issue #1643 — the hub never lists one: no worker_id,
#                   and a pin is this machine's own mark); the
#                   hub list ignores the switch; on the DEFAULT source a cache carrying
#                   local rows is byte for byte the one without (the golden), and with
#                   the hub off `hub` is `local`
#   L. hub silent — issue #1483 (EPIC #1479 C4): global/hub_ok older than
#                   FLEET_HUB_SESSIONS_STALE is 失联 — the ONE word (the bar and the
#                   remote-row actions read it too). The other machines' rows stay,
#                   dimmed where they stand (#1882); on the hub
#                   source THIS machine's rows are tmux's set again (a window the cache
#                   never named is back) with their live state — byte for byte the
#                   local source under the same silence; a fresh hub_ok restores the
#                   hub's row set on the next render; no network; a cache from before
#                   hub_ok (no file, a stale #ts) renders the very same bytes; the hub
#                   off ⇒ the no-cache output
#   P. shell      — the client (FLEET_SHELL=1, no conf, issue #1680): its hub rows
#                   group under one heading per repo THEY name (2+), sorted, plus
#                   `无仓库`; ←/→ folds a group through the shell's OWN @repo_fold;
#                   one repo ⇒ no heading; a node on the hub source (no FLEET_SHELL)
#                   renders the same cache flat, byte for byte as before
#                   (#1882: a lost machine's rows stay in their repo's group, dimmed —
#                   the frame is the online one but for the `!`, 入口连不上 included)
#   E. refresher  — fleet-hub-sessions.sh --refresh keeps YOUR sessions with a
#                   worker_id: the other machines' (local=0) and, since #1480, this
#                   fleet's own, marked local=1 with the window that holds them (empty
#                   when none does; leg G maps one on a real server); translates
#                   @origin_wid into this fleet's terms (own fleet → bare key,
#                   elsewhere → worker_id, none → the sub-issue parent — a local one
#                   its bare key), writes #me / #node / the needs field and the C1
#                   locator cache; derives #node from the sessions on a hub without a
#                   `nodes` list, never counting a local row; writes global/hub_ok on
#                   a round that stood (#1483); a failed fetch keeps the last cache AND
#                   hub_ok; off ⇒ writes nothing, --ensure starts nothing; a machine
#                   the hub could not read (sessions null) keeps its last rows when
#                   the answer lists none of them, until a read stands (#1795)
#   I. identity   — who the refresher asks the hub as (#1475): FLEET_HUB_SESSIONS_CMD,
#                   else a VALID connection certificate (a signed POST), else the viewer
#                   token (a bearer GET), else nothing is fetched and --identity says why;
#                   an expired certificate is skipped
#   F. read-only  — fold / pin / migrate on a `wid:` row touch no tmux option
#   G. inventory  — the real adapter on an isolated socket hands fleet_control.py the
#                   window name, @origin_wid and @claude_needs; a 9-column adapter still
#                   parses
#   R. ready      — fleet-control-read.sh ready: gh login, a credential, every checkout,
#                   each named in `missing` when absent; fleet_control.py's `ready`
#                   method hands it on as the node's heartbeat field
#
# Hermetic: the row legs PATH-shim `tmux` to replay a fixture window list; leg G runs
# a private `tmux -L` server; leg I mints its own throwaway CA + certificate. No gh,
# no network. Exit 0 = pass.
set -uo pipefail
# The rows' order asserted here is the status order (needs/done/working by rank):
# pin it — the default born order (issue #1750) is dash-born-order-selftest.sh's.
export FLEET_DASH_ORDER=status

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
HUBS="$BIN/fleet-hub-sessions.sh"
CREAD="$BIN/fleet-control-read.sh"
command -v python3 >/dev/null 2>&1 || { echo 'dash-remote-rows selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashremote-selftest.XXXXXX")" || exit 2
S="hubs$$"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE TMUX TMUX_PANE FLEET_HUB_URL FLEET_CERT XDG_CONFIG_HOME \
      FLEET_ACCOUNTS_DIR CODEX_HOME
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/bin" "$WORK/main"
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
case "$*" in *show-option*@repo_fold*) [ -n "${REPO_FOLD:-}" ] && printf '%s\n' "$REPO_FOLD" ;; esac
exit 0
SHIM
# network tools: every call logged (argv verbatim — printf, since /bin/sh's echo
# would turn a JSON body's `\n` into newlines), every call refused
for n in curl wget nc ccquota; do
  cat > "$WORK/bin/$n" <<SHIM
#!/bin/sh
printf '%s %s\n' '$n' "\$*" >> "\$NET_LOG"
exit 1
SHIM
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
# srow: id|tree|badge|depth|node (field 9, empty for a local row)
srow()  { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$1 != "hdr" && $4 == n { print $1 "|" $5 "|" $6 "|" $7 "|" $9; exit }'; }
sorder(){ printf '%s\n' "$1" | LC_ALL=C awk -F"$US" '$1 != "hdr" { printf "%s;", $4 }'; }
shdrs() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" '$1 == "hdr" { printf "%s;", $4 }'; }
sfirst(){ printf '%s\n' "$1" | head -1 | LC_ALL=C awk -F"$US" '{ print $1 "|" $4 }'; }
sneed() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$1 != "hdr" && $4 == n { print $3 "|" $8; exit }'; }
nfields(){ printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$1 != "hdr" && $4 == n { print NF; exit }'; }

F=11111111-2222-3333-4444-555555555555            # a fleet on another machine
NOW=$(date +%s)
remote_cache() {   # $1 = the #ts epoch; $2 = m4's #node line availability; $3 = its last-seen epoch
  { printf '#ts\037%s\n' "$1"
    printf '#me\037m5\n'
    printf '#node\037m4\037%s\0372\037%s\n' "${2:-online}" "${3:-$1}"
    printf 'wid:%s/issue-1423\037m4\037online\0371423\037acme/app\037working\037claude\037侧边栏\037issue-1419\037\n' "$F"
    printf 'wid:%s/issue-1500\037m4\037online\0371500\037acme/app\037done\037claude\037孙\037%s/issue-1423\037\n' "$F" "$F"
    printf 'wid:%s/scratch-2\037m4\037lost\037\037\037working\037claude\037草稿\037\037\n' "$F"
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
hasnt "A: hub off — no machine anywhere" "$(side)$(hub)" "m4"
hasnt "A: hub off — no status line" "$(side)$(hub)" "●"
mv "$G/remote_$S" "$WORK/remote.keep"
eq "A: hub on, no cache — the same bytes (sidebar)" "$base_s" "$(CCQUOTA_FLEET=1 side)"
eq "A: hub on, no cache — the same bytes (hub)"     "$base_h" "$(CCQUOTA_FLEET=1 hub)"
mv "$WORK/remote.keep" "$G/remote_$S"

# ============================================================================
# B. rows
# ============================================================================
export CCQUOTA_FLEET=1
# A remote parent starts FOLDED, as a local one does (issue #1749): its bit is
# this machine's global/remote_fold_<sess>, absent ⇒ collapsed.
s=$(side)
eq "B: a remote parent starts folded — its done grandchild hidden" "solo;草稿;EPIC;C1;侧边栏;" "$(sorder "$s")"
eq "B: …its caret says so" "wid:$F/issue-1423|└▸|1/1|1|m4" "$(srow "$s" '侧边栏')"
printf '%s/issue-1423\n' "$F" > "$G/remote_fold_$S"   # opened HERE: the rows below read it open
s=$(side)
eq "B: mixed with the local rows, each under its real parent; the lost one where it would be online (#1882)" \
   "solo;草稿;EPIC;C1;侧边栏;孙;" "$(sorder "$s")"
eq "B: the local parent counts its remote descendants" "@1|▾|1/3|0|" "$(srow "$s" EPIC)"
eq "B: a remote child under a LOCAL parent: depth 1, its own subtree, its machine in field 9" \
   "wid:$F/issue-1423|└▾|1/1|1|m4" "$(srow "$s" '侧边栏')"
eq "B: a remote grandchild under its REMOTE parent: depth 2" \
   "wid:$F/issue-1500|  └||2|m4" "$(srow "$s" '孙')"
eq "B: a local sibling is untouched" "@2|└||1|" "$(srow "$s" C1)"
# fields 10-12 (issue #1532) are the info column's issue · PR · ctx%, after it.
eq "B: a local row carries the 9th field too, empty" "12" "$(nfields "$s" C1)"
eq "B: a remote row has it" "12" "$(nfields "$s" '侧边栏')"
hasnt "B: no [m4] in any name" "$s" "[m4"
# A remote row ends in its machine's `@m4` (issue #1780; #1475 drew none): the
# view's own renderer lays the name out as the same row local does, and the mark
# takes its cells at the end — row_need asks exactly `@m4` plus a gap more.
printf '%s\n' "$s" > "$WORK/srows"
drawn=$(python3 - "$BIN/fleet-sidebar.py" '侧边栏' "$WORK/srows" <<'PYR'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1]); sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
rows = [sb.row_fields(l) for l in open(sys.argv[3], encoding="utf-8").read().split("\n") if l.count(sb.US) >= 4]
r = next(x for x in rows if x[3] == sys.argv[2])
local = r[:8] + [""]
text = sb.row_text(" ", r[2], r[4], r[3], r[5], 34)
print(text, "same" if text == sb.row_text(" ", local[2], local[4], local[3], local[5], 34) else "differs",
      sb.row_need(r) == sb.row_need(local) + 4, sb.machine_tag(r[8]), repr(sb.machine_tag(local[8])), sep="|")
PYR
)
has "B: the view ends a remote row in @m4 (#1780), a local row in nothing" "$drawn" "|@m4|''"
has "B: …and lays the name out exactly as the same row local" "$drawn" "|same|True|"
h=$(hub)
has "B: the hub row shows the issue" "$h" "#1423"
hrow=$(printf '%s\n' "$h" | LC_ALL=C awk -F"$US" -v w="wid:$F/issue-1423" '$2 == w { print $3; exit }')
has "B: the hub row ends its tags in @m4 too (#1780)" "$hrow" "@m4"
hasnt "B: the hub row carries no [m4]" "$hrow" "[m4"
widths=$(printf '%s\n' "$h" | python3 -c 'import sys, unicodedata
w = lambda t: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)
print("\n".join(sorted({str(w(l.split("\x1f")[2])) for l in sys.stdin.read().split("\n")[1:] if l.count("\x1f") >= 2 and not l.startswith("hdr")})))')
eq "B: every hub session row is the same width, the remote ones included" "136" "$widths"
hasnt "B: no @title_info is written for a remote row" "$(cat "$TMUX_LOG")" "wid:"

# ============================================================================
# M. the row MENU names the machine — the one place the list does (#1475)
# ============================================================================
menu=$(PATH="$SHIMPATH" FLEET_UI_LANG=zh bash -c '
  BIN=$1; sess=$2; verb=menu; set -- menu "$2" "$3" --print
  . "$BIN/fleet-lib.sh"; . "$BIN/fleet-ui-lang.sh"; . "$BIN/fleet-sidebar-menu.sh"' _ "$BIN" "$S" "wid:$F/issue-1423" 2>/dev/null)
eq "M: a remote row's menu is titled with its name and machine (「名称 · 机器」, #1535)" "title	侧边栏 · m4" "$(printf '%s\n' "$menu" | head -1)"
has "M: …and its first item opens the proxy window" "$(printf '%s\n' "$menu" | sed -n 2p | cut -f1,2)" "e	进入（代理窗口）…"
has "M: …through fleet-remote-view.sh" "$(printf '%s\n' "$menu" | sed -n 2p)" "fleet-remote-view.sh"
has "M: …open, on that worker_id" "$(printf '%s\n' "$menu" | sed -n 2p)" " open '\\''wid:$F/issue-1423'\\'' "
eq "M: a row the cache does not hold gets no menu" "" "$(PATH="$SHIMPATH" bash -c '
  BIN=$1; sess=$2; verb=menu; set -- menu "$2" "$3" --print
  . "$BIN/fleet-lib.sh"; . "$BIN/fleet-ui-lang.sh"; . "$BIN/fleet-sidebar-menu.sh"' _ "$BIN" "$S" "wid:$F/issue-9999" 2>/dev/null)"

# ============================================================================
# S. no machine status line (issue #1531)
# ============================================================================
hasnt "S: no machine status line in the sidebar — no ● m5 / ● m4 row" "$(shdrs "$s")" "●"
eq "S: the sidebar's first row is the first group (the pin tier's heading)" \
   "$(sfirst "$base_s")" "$(sfirst "$s")"
hasnt "S: …nor in the hub list" "$h" "● m"
eq "S: the hub list's first row is its column header, as with the hub off" \
   "$(printf '%s\n' "$base_h" | head -1)" "$(printf '%s\n' "$h" | head -1)"

# ============================================================================
# C. lost
# ============================================================================
# The list does not move (issue #1882): a lost row keeps its place, its group
# and its parent; only field 9 gains `!` (the view dims the row off it). So the
# whole frame with every row lost is the online frame with `m4` → `m4!`.
online_s=$(side); online_h=$(hub)
eq "C: a row the hub calls lost: in its place, at its depth, m4! for the view" \
   "wid:$F/scratch-2| ||0|m4!" "$(srow "$online_s" '草稿')"
hasnt "C: …no lost heading of its own (#1882 — no ─ m4 失联 ─ group)" "$(shdrs "$online_s")" "失联"
unlost() { LC_ALL=C sed -e 's/m4!/m4/g'; }
remote_cache $((NOW - 600)) online $((NOW - 600))
s=$(side)
eq "C: a stale cache: every remote row is lost — the SAME order as online" \
   "$(sorder "$online_s")" "$(sorder "$s")"
eq "C: …each m4!" "m4!|m4!|m4!" \
   "$(printf '%s|%s|%s' "$(srow "$s" '侧边栏' | cut -d'|' -f5)" "$(srow "$s" '孙' | cut -d'|' -f5)" "$(srow "$s" '草稿' | cut -d'|' -f5)")"
eq "C: …still nested under its real parent" "wid:$F/issue-1423|└▾|1/1|1|m4!" "$(srow "$s" '侧边栏')"
eq "C: …the local parent still counts them" "$(srow "$online_s" EPIC)" "$(srow "$s" EPIC)"
eq "C: …the whole sidebar frame is the online one but for the ! (line by line)" \
   "$(printf '%s\n' "$online_s" | unlost)" "$(printf '%s\n' "$s" | unlost)"
h=$(hub)
hasnt "C: the hub list draws no lost heading either" "$h" "失联"
eq "C: …and keeps its row order" \
   "$(printf '%s\n' "$online_h" | LC_ALL=C awk -F"$US" '{ print $2 }')" "$(printf '%s\n' "$h" | LC_ALL=C awk -F"$US" '{ print $2 }')"
remote_cache "$NOW" lost $((NOW - 180))
s=$(side)
eq "C: the hub says the machine is lost: the same order" "$(sorder "$online_s")" "$(sorder "$s")"
hasnt "C: …no heading" "$(shdrs "$s")" "失联"
eq "C: …and every row of it is lost, whatever its own word" "m4!" "$(srow "$s" '侧边栏' | cut -d'|' -f5)"
# 维护中 (#1427): the hub's third word for a machine — heard, the operator is
# taking it down. The bar's machine cell says so; nothing about its rows
# changes: not lost, not dimmed (no m4!), nesting intact.
remote_cache "$NOW" maintenance "$NOW"
s=$(side)
eq "C: a 维护中 machine: no heading, the same order" "$(sorder "$online_s")" "$(sorder "$s")"
eq "C: …its online rows are live rows (no m4!), still nested under the local parent, their own child counted" \
   "wid:$F/issue-1423|└▾|1/1|1|m4" "$(srow "$s" '侧边栏')"
eq "C: …only the row the hub itself calls lost is lost" "m4!" "$(srow "$s" '草稿' | cut -d'|' -f5)"
remote_cache "$NOW"

# ============================================================================
# N. needs — a remote row asking its person
# ============================================================================
printf 'wid:%s/issue-1600\037m4\037online\0371600\037acme/app\037needs\037claude\037问\037\037ask\n' "$F" >> "$G/remote_$S"
s=$(side)
eq "N: a remote row that is asking draws the local ! and says which" "!|在问你" "$(sneed "$s" '问')"
remote_cache "$NOW"

# ============================================================================
# D. no network on the render path
# ============================================================================
: > "$NET_LOG"; side >/dev/null; hub >/dev/null
eq "D: rendering with the hub on makes no network call" "" "$(cat "$NET_LOG")"
eq "D: the producer's code names no network tool and not the refresher" "0" \
   "$(grep -v '^[[:space:]]*#' "$ROWS" | grep -cE '(^|[^A-Za-z_])(curl|wget|nc|ccquota)([^A-Za-z_]|$)|fleet-hub-sessions')"

# ============================================================================
# H. the list from the hub (issue #1480)
# ============================================================================
L=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee            # this machine's fleet
new_cache() {   # the #1480 shape: `local` + `wid` on every row, this machine's rows included
  { printf '#ts\037%s\n#me\037m5\n#node\037m4\037online\0372\037%s\n' "$NOW" "$NOW"
    printf 'wid:%s/issue-1423\037m4\037online\0371423\037acme/app\037working\037claude\037侧边栏\037issue-1419\037\0370\037\n' "$F"
    printf 'wid:%s/issue-1500\037m4\037online\0371500\037acme/app\037done\037claude\037孙\037%s/issue-1423\037\0370\037\n' "$F" "$F"
    printf 'wid:%s/scratch-2\037m4\037lost\037\037\037working\037claude\037草稿\037\037\0370\037\n' "$F"
    printf 'wid:%s/issue-1419\037m5\037online\0371419\037acme/app\037done\037claude\037EPIC\037\037\0371\037@1\n' "$L"
    printf 'wid:%s/issue-1420\037m5\037online\0371420\037acme/app\037done\037claude\037C1\037issue-1419\037\0371\037@2\n' "$L"
    printf 'wid:%s/issue-1499\037m5\037online\0371499\037acme/app\037working\037claude\037gone\037\037\0371\037@9\n' "$L"
    printf 'wid:%s/scratch-7\037m5\037online\037\037\037working\037claude\037nowin\037\037\0371\037\n' "$L"
  } > "$G/remote_$S"
}
srow9() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$1 != "hdr" && $4 == n { print $1 "|" $2 "|" $5 "|" $6 "|" $7 "|" $9; exit }'; }
golden_s=$(side); golden_h=$(hub)                # the pre-#1480 cache, default source
new_cache
eq "H: default source — a cache carrying this machine's rows is byte for byte the golden (sidebar)" "$golden_s" "$(side)"
eq "H: …and the hub list" "$golden_h" "$(hub)"
eq "H: …FLEET_SIDEBAR_SOURCE=local says the same" "$golden_s" "$(FLEET_SIDEBAR_SOURCE=local side)"
hs=$(FLEET_SIDEBAR_SOURCE=hub side)
eq "H: hub source — the row set is the cache's: the local rows it names, the remote rows; solo (unnamed), gone (@9), nowin (no window) are not rows" \
   "草稿;EPIC;C1;侧边栏;孙;" "$(sorder "$hs")"
eq "H: a local row is its tmux line: its @ id, its LIVE state (tmux says looping, the cache said done), its caret + k/N, no machine" \
   "@1|looping|▾|1/3|0|" "$(srow9 "$hs" EPIC)"
eq "H: …its child nests under it as today" "@2|└||1|" "$(srow "$hs" C1)"
eq "H: …and the remote child under the local parent, as today" "wid:$F/issue-1423|└▾|1/1|1|m4" "$(srow "$hs" '侧边栏')"
hasnt "H: hub source — no machine status line either" "$(shdrs "$hs")" "●"
eq "H: the sidebar's own window stays on its list before the hub has it" \
   "solo;草稿;EPIC;C1;侧边栏;孙;" "$(sorder "$(FLEET_SIDEBAR_SOURCE=hub FLEET_SIDEBAR_CURRENT=@3 side)")"
eq "H: the hub list ignores the switch" "$golden_h" "$(FLEET_SIDEBAR_SOURCE=hub hub)"
eq "H: hub off — \`hub\` is the no-cache output" "$base_s" "$(CCQUOTA_FLEET='' FLEET_SIDEBAR_SOURCE=hub side)"
mv "$G/remote_$S" "$WORK/remote.keep"
eq "H: no cache — \`hub\` is the no-cache output" "$base_s" "$(FLEET_SIDEBAR_SOURCE=hub side)"
mv "$WORK/remote.keep" "$G/remote_$S"
: > "$NET_LOG"; FLEET_SIDEBAR_SOURCE=hub side >/dev/null
eq "H: …and still no network on the render path" "" "$(cat "$NET_LOG")"
# a pinned or @norepo window the cache does not name stays (issue #1643): the hub
# never lists one — a `@norepo` session has no worker_id, a pin is this machine's
# own mark — so the pinned guide and every no-repo session vanished with the switch.
# Full WFMT lines: @pin is field 15, @norepo field 21 (w() stops at 14).
cp "$WLIST_FILE" "$WORK/wlist.keep"
wf() {   # idx name path state wid issue pin norepo
  printf '%s\n' "$S$US$1$US$2$US$3$US$4$US$US$5$US$6$US$US$US$US$US$US$US$7$US$US$US$US$US$US$8$US$US$US$US" >> "$WLIST_FILE"
}
#  idx name    path                state    wid  issue  pin norepo
wf 4   向导    /home/op            'done'   @4   ''     1   1          # the guide: pinned, no repo, no key
wf 5   无仓库  /home/op            working  @5   ''     ''  1          # a no-repo session
wf 6   钉住    /w/app-issue-1431   'done'   @6   1431   1   ''         # pinned, keyed, not in the cache
hs=$(FLEET_SIDEBAR_SOURCE=hub side)
eq "H: hub source — a pinned or @norepo window the cache does not name is still a row; the keyed, unpinned one (solo) still is not" \
   "向导;钉住;无仓库;草稿;EPIC;C1;侧边栏;孙;" "$(sorder "$hs")"   # 无仓库 is working: it sorts ahead of looping as on the local source
has "H: …in the 置顶 group" "$(shdrs "$hs")" "置顶 (2)"
eq "H: …the local source's rows minus solo (keyed, unlisted: #1480's rule stands)" "$(sorder "$(side)" | sed 's/solo;//')" "$(sorder "$hs")"
mv "$WORK/wlist.keep" "$WLIST_FILE"
remote_cache "$NOW"

# ============================================================================
# L. the hub silent (issue #1483, EPIC #1479 C4)
# ============================================================================
# global/hub_ok is the one word on 入口通不通 — the refresher writes it on every
# round that stood (leg E pins the writer); older than FLEET_HUB_SESSIONS_STALE
# ⇒ 失联, whatever the cache's own #ts says (a 304 restamps both).
stamp_cache() { { printf '#ts\037%s\n' "$1"; tail -n +2 "$G/remote_$S"; } > "$WORK/stamp" && mv "$WORK/stamp" "$G/remote_$S"; }
new_cache
hs=$(FLEET_SIDEBAR_SOURCE=hub side)
printf '%s\n' "$NOW" > "$G/hub_ok"
eq "L: a fresh hub_ok changes nothing on the hub source" "$hs" "$(FLEET_SIDEBAR_SOURCE=hub side)"
eq "L: …nor on the default source" "$golden_s" "$(side)"
printf '%s\n' $(( NOW - 600 )) > "$G/hub_ok"            # silent 10 minutes; the cache itself fresh
ls_=$(FLEET_SIDEBAR_SOURCE=hub side)
eq "L: hub source, the hub silent — this machine's rows are tmux's set again (solo, never in the cache, is back), the other machine's where they were (#1882)" \
   "solo;草稿;EPIC;C1;侧边栏;孙;" "$(sorder "$ls_")"
eq "L: …byte for byte the local source under the same silence: one code path, not a second" "$(FLEET_SIDEBAR_SOURCE=local side)" "$ls_"
hasnt "L: …the other machine's rows are 失联 without a heading of their own (#1882)" "$(shdrs "$ls_")" "失联"
eq "L: …each of them m4! for the view, still nested" "wid:$F/issue-1423|└▾|1/1|1|m4!" "$(srow "$ls_" '侧边栏')"
eq "L: …a local row is still its tmux line: its @ id, its live state" "@1|looping" "$(srow9 "$ls_" EPIC | cut -d'|' -f1,2)"
cp "$WLIST_FILE" "$WORK/wlist.keep"
LC_ALL=C awk -F"$US" -v OFS="$US" '$3 == "EPIC" { $5 = "working" } 1' "$WORK/wlist.keep" > "$WLIST_FILE"
eq "L: …and follows tmux while the hub is silent (looping → working)" "@1|working" "$(srow9 "$(FLEET_SIDEBAR_SOURCE=hub side)" EPIC | cut -d'|' -f1,2)"
cp "$WORK/wlist.keep" "$WLIST_FILE"
: > "$NET_LOG"; FLEET_SIDEBAR_SOURCE=hub side >/dev/null
eq "L: …no network call on the render path, silent or not" "" "$(cat "$NET_LOG")"
eq "L: FLEET_HUB_SESSIONS_STALE is the knob here too" "$hs" "$(FLEET_HUB_SESSIONS_STALE=900 FLEET_SIDEBAR_SOURCE=hub side)"
eq "L: hub off — the no-cache output, hub_ok or not" "$base_s" "$(CCQUOTA_FLEET='' FLEET_SIDEBAR_SOURCE=hub side)"
printf '%s\n' "$NOW" > "$G/hub_ok"
eq "L: hub_ok fresh again — the hub's row set is back on the next render, nothing restarted" "$hs" "$(FLEET_SIDEBAR_SOURCE=hub side)"
# degenerate: a loop from before #1483 writes no hub_ok — the cache's own #ts is
# the clock, as it always was, and renders the very same bytes
rm -f "$G/hub_ok"; stamp_cache $(( NOW - 600 ))
eq "L: no hub_ok, a stale #ts (the pre-#1483 cache) — the local source renders the bytes the silence did" "$ls_" "$(FLEET_SIDEBAR_SOURCE=local side)"
eq "L: …and so does the hub source" "$ls_" "$(FLEET_SIDEBAR_SOURCE=hub side)"
stamp_cache "$NOW"
remote_cache "$NOW"

# ============================================================================
# P. the shell's list groups by repo (issue #1680)
# ============================================================================
# The client has no conf: its repos are the ones the hub's rows name. Client-mode
# cache (#1484): `#me` empty, every row another machine's (local=0).
SH="shell$$"
shell_cache() {
  { printf '#ts\037%s\n#me\037\n#node\037m4\037online\0373\037%s\n' "$NOW" "$NOW"
    printf 'wid:%s/issue-11\037m4\037online\03711\037acme/tool\037working\037claude\037工具活\037\037\0370\037\n' "$F"
    printf 'wid:%s/issue-21\037m4\037online\03721\037acme/app\037working\037claude\037应用活\037\037\0370\037\n' "$F"
    printf 'wid:%s/issue-22\037m4\037online\03722\037acme/app\037done\037claude\037应用二\037\037\0370\037\n' "$F"
    printf 'wid:%s/scratch-3\037m4\037online\037\037\037working\037claude\037草稿三\037\037\0370\037\n' "$F"
  } > "$G/remote_$SH"
}
shell_side() { PATH="$SHIMPATH" FLEET_SESSION=$SH FLEET_SIDEBAR_SOURCE=hub bash "$ROWS" --sidebar 2>/dev/null | strip; }
printf '%s\n' "$NOW" > "$G/hub_ok"
cp "$WLIST_FILE" "$WORK/wlist.keep"; : > "$WLIST_FILE"   # the shell's own windows: proxies, none named
shell_cache
flat=$(shell_side)
eq "P: a node on the hub source (no FLEET_SHELL) — no conf repos, no heading: today's flat list" "" "$(shdrs "$flat")"
ps=$(FLEET_SHELL=1 shell_side)
eq "P: the shell — one heading per repo its rows name, sorted, then 无仓库" \
   "app (2);tool (1);无仓库 (1);" "$(shdrs "$ps")"
eq "P: …each row under its own repo's heading" "应用二;应用活;工具活;草稿三;" "$(sorder "$ps")"
eq "P: …a heading's key is its repo (the view's hdr:<owner/name>)" "acme/tool" \
   "$(printf '%s\n' "$ps" | LC_ALL=C awk -F"$US" '$1 == "hdr" && $4 ~ /^tool/ { print $2; exit }')"
pf=$(REPO_FOLD=acme-tool FLEET_SHELL=1 shell_side)
eq "P: the shell's @repo_fold folds that group: ▸ heading, its rows hidden" \
   "app (2);▸ tool (1);无仓库 (1);" "$(shdrs "$pf")"
eq "P: …the rest stay" "应用二;应用活;草稿三;" "$(sorder "$pf")"
# The keep-current rail joins on the ROW key (issue #1697): the shell's current
# window is a proxy (`@12`) whose row is `wid:…` — the sidebar passes that as
# FLEET_SIDEBAR_CURRENT_ROW, and a folded group still shows the row being viewed.
eq "P: the row the shell is viewing stays inside its folded group" "应用二;应用活;工具活;草稿三;" \
   "$(sorder "$(REPO_FOLD=acme-tool FLEET_SHELL=1 FLEET_SIDEBAR_CURRENT=@12 FLEET_SIDEBAR_CURRENT_ROW="wid:$F/issue-11" shell_side)")"
eq "P: …the proxy's local window id alone never matched a \`wid:\` row (the #1697 bug)" "应用二;应用活;草稿三;" \
   "$(sorder "$(REPO_FOLD=acme-tool FLEET_SHELL=1 FLEET_SIDEBAR_CURRENT=@12 shell_side)")"
: > "$TMUX_LOG"
PATH="$SHIMPATH" FLEET_SHELL=1 FLEET_SESSION=$SH DASH_FOLD_PLAIN=1 bash "$BIN/dash-fold-toggle.sh" collapse hdr:acme/tool >/dev/null 2>&1
has "P: ← on a shell heading writes the fold to the shell's OWN session" "$(cat "$TMUX_LOG")" "set-option -t =$SH: @repo_fold acme-tool"
: > "$TMUX_LOG"
PATH="$SHIMPATH" FLEET_SESSION=$SH DASH_FOLD_PLAIN=1 bash "$BIN/dash-fold-toggle.sh" collapse hdr:acme/tool >/dev/null 2>&1
hasnt "P: …a node with no conf repos writes nothing" "$(cat "$TMUX_LOG")" "@repo_fold"
LC_ALL=C grep -v 'acme/tool' "$G/remote_$SH" > "$WORK/one" && mv "$WORK/one" "$G/remote_$SH"
eq "P: one repo among the rows — no repo heading (a one-repo fleet's frame)" "" "$(shdrs "$(FLEET_SHELL=1 shell_side)")"
# Issues #1770/#1882: on the client (`#me` empty) a row with a repo goes to its
# repo's group, a no-repo row to 无仓库 — and a LOST machine's row STAYS there,
# dimmed (`m4!`): no `─ m4 失联 ─` group at the foot, so the list does not
# reshuffle when a network drops and again when it comes back (#1882). Before
# #1770 the foot group had no heading on a client and read as 无仓库's rows.
FP=33333333-4444-5555-6666-888888888888            # a fleet on m5
{ printf '#ts\037%s\n#me\037\n#node\037m4\037lost\0371\037%s\n#node\037m5\037online\0373\037%s\n' "$NOW" "$((NOW - 600))" "$NOW"
  printf 'wid:%s/acme-app:issue-41\037m5\037online\03741\037acme/app\037working\037claude\037应用活\037\037\0370\037\n' "$FP"
  printf 'wid:%s/acme-tool:issue-42\037m5\037online\03742\037acme/tool\037working\037claude\037工具活\037\037\0370\037\n' "$FP"
  printf 'wid:%s/0247d1c0-6d9d-420e-88ac-d867ee7526d1\037m5\037online\037\037\037working\037claude\037无仓活\037\037\0370\037\n' "$FP"
  printf 'wid:%s/acme-app:issue-43\037m4\037online\03743\037acme/app\037looping\037claude\037活页\037\037\0370\037\n' "$F"
} > "$G/remote_$SH"
lr=$(FLEET_SHELL=1 shell_side)
eq "P: #1882 — a client's lost machine: its row stays in its repo's group, no lost heading" \
   "app (2);tool (1);无仓库 (1);" "$(shdrs "$lr")"
eq "P: #1882 — …in its place, dimmed (m4!)" "应用活;活页;工具活;无仓活;|m4!" "$(sorder "$lr")|$(srow "$lr" '活页' | cut -d'|' -f5)"
sed -e "s/^#node\x1fm4\x1flost/#node\x1fm4\x1fonline/" "$G/remote_$SH" > "$WORK/l" && mv "$WORK/l" "$G/remote_$SH"
lo=$(FLEET_SHELL=1 shell_side)
eq "P: #1882 — m4 back online: the frame is the lost one line by line but for the !" \
   "$(printf '%s\n' "$lr" | LC_ALL=C sed 's/m4!/m4/g')" "$lo"
# the whole entrance silent (hub_ok stale): every row lost, still the same frame
printf '%s\n' $(( NOW - 600 )) > "$G/hub_ok"
eq "P: #1882 — 入口连不上: every row m4!/m5!, the frame otherwise unchanged" \
   "$lo" "$(FLEET_SHELL=1 shell_side | LC_ALL=C sed -e 's/m4!/m4/g' -e 's/m5!/m5/g')"
rm -f "$G/hub_ok"

# K. kinship on the shell (issue #1698): a row's key is `wid:<worker_id>`, its
# parent `<worker_id>` bare — pass A strips the `wid:` off the key (KEYTAB), so
# the two spellings meet there; adding `wid:` to the origin instead would break
# every chain. A child nests under a parent on the SAME machine, on ANOTHER
# machine (by design, #1423: a worker_id names one session wherever it runs —
# the sidebar shows the real tree, not a per-machine one) and in another repo
# (it follows its root's group, #1031, its own repo as a ⇢ tag); a parent whose
# machine is lost keeps its child nested (#1882 — the list does not move), and a parent
# no row names (another login's fleet) leaves the child at the top.
F5=33333333-4444-5555-6666-777777777777            # a fleet on a third machine, m5
{ printf '#ts\037%s\n#me\037\n#node\037m4\037online\0373\037%s\n#node\037m5\037online\0371\037%s\n' "$NOW" "$NOW" "$NOW"
  printf 'wid:%s/acme-app:scratch-5\037m4\037online\037\037acme/app\037looping\037claude\037父\037\037\0370\037\n' "$F"
  printf 'wid:%s/acme-app:issue-31\037m4\037online\03731\037acme/app\037working\037claude\037同机子\037%s/acme-app:scratch-5\037\0370\037\n' "$F" "$F"
  printf 'wid:%s/acme-tool:issue-32\037m4\037online\03732\037acme/tool\037working\037claude\037跨仓子\037%s/acme-app:scratch-5\037\0370\037\n' "$F" "$F"
  printf 'wid:%s/acme-app:issue-33\037m5\037online\03733\037acme/app\037working\037claude\037跨机子\037%s/acme-app:scratch-5\037\0370\037\n' "$F5" "$F"
  printf 'wid:%s/acme-app:issue-34\037m4\037online\03734\037acme/app\037working\037claude\037孤儿\037%s/acme-app:scratch-9\037\0370\037\n' "$F" "$F5"
} > "$G/remote_$SH"
# A client's list is ALL `wid:` rows (issue #1749): it folds like a node's — the
# parent starts shut (▸, its children hidden), → opens it, ← on a child shuts it
# again — every bit in the client's own file, nothing written to any tmux.
ks=$(FLEET_SHELL=1 shell_side)
eq "K: on a client the parent starts folded" "wid:$F/acme-app:scratch-5|▸|0" "$(srow "$ks" '父' | cut -d'|' -f1,2,4)"
eq "K: …its children hidden" "" "$(srow "$ks" '同机子')"
kfold() { PATH="$SHIMPATH" FLEET_SHELL=1 FLEET_SESSION=$SH DASH_FOLD_PLAIN=1 bash "$BIN/dash-fold-toggle.sh" "$1" "$2" >/dev/null 2>&1; }
: > "$TMUX_LOG"
kfold expand "wid:$F/acme-app:scratch-5"
ks=$(FLEET_SHELL=1 shell_side)
eq "K: → opens it" "wid:$F/acme-app:scratch-5|▾|0" "$(srow "$ks" '父' | cut -d'|' -f1,2,4)"
kfold collapse "wid:$F/acme-app:issue-31"
eq "K: ← on a child shuts the parent's block" "▸" "$(srow "$(FLEET_SHELL=1 shell_side)" '父' | cut -d'|' -f2)"
hasnt "K: the fold wrote no tmux option" "$(cat "$TMUX_LOG")" "set-"
kfold expand "wid:$F/acme-app:scratch-5"
ks=$(FLEET_SHELL=1 shell_side)
eq "K: the parent is a top row with its fold caret" "wid:$F/acme-app:scratch-5|▾|0" "$(srow "$ks" '父' | cut -d'|' -f1,2,4)"
eq "K: a child on the same machine nests under it" "wid:$F/acme-app:issue-31|└|1" "$(srow "$ks" '同机子' | cut -d'|' -f1,2,4)"
eq "K: …a child on ANOTHER machine too (one tree across machines, by design)" "└|1" "$(srow "$ks" '跨机子' | cut -d'|' -f2,4)"
eq "K: …a child in another repo too, in its root's group" "└|1" "$(srow "$ks" '跨仓子 ⇢too' | cut -d'|' -f2,4)"
eq "K: a parent no row names leaves its child at the top" " |0" "$(srow "$ks" '孤儿' | cut -d'|' -f2,4)"
eq "K: …and the children sort right under their parent" "父;" "$(sorder "$ks" | cut -d';' -f1);"
sed -e "s/^#node\x1fm4\x1fonline/#node\x1fm4\x1flost/" "$G/remote_$SH" > "$WORK/k" && mv "$WORK/k" "$G/remote_$SH"
kl=$(FLEET_SHELL=1 shell_side)
eq "K: the parent's machine lost — the m5 child stays nested under it (#1882)" "└|1" "$(srow "$kl" '跨机子' | cut -d'|' -f2,4)"
eq "K: …the same order as online" "$(sorder "$ks")" "$(sorder "$kl")"
rm -f "$G/remote_$SH" "$G/remote_fold_$SH" "$G/hub_ok"
mv "$WORK/wlist.keep" "$WLIST_FILE"

# ============================================================================
# E. refresher
# ============================================================================
unset CCQUOTA_FLEET
U=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
f=[x for x in c.Control(sys.argv[1]).inventory() if x["name"]==sys.argv[2]]
print(f[0]["fleet_id"] if f else "")' "$FLEET_CONF_DIR" "$S")
[ -n "$U" ] || fail "E: could not mint this fleet's UUID"
ME=$(id -un)
MYHOST=$(hostname | cut -d. -f1)
mkdir -p "$WORK/.claude-dash/fleets/acme-app"
printf '1600\t1419\n1501\t1500\n' > "$WORK/.claude-dash/fleets/acme-app/parents"
python3 - "$WORK/sessions.json" "$WORK/sessions-old.json" "$U" "$F" "$ME" <<'PY'
import json, sys
path, old, u, f, me = sys.argv[1:6]
def s(fleet, host, user, key, avail="online", wid=True, seen="2026-10-04T10:00:00Z", **w):
    w.setdefault("key", key); w.setdefault("state", "working"); w.setdefault("lifecycle", "awake")
    w.setdefault("agent", "claude"); w.setdefault("repo", "acme/app")
    return dict(worker_id=(fleet + "/" + key) if wid else None, machine_name=host, os_user=user,
                fleet_id=fleet, fleet_name="x", availability=avail, worker=w, observed_at=seen)
sessions = [
    s(u, "elsewhere", me, "issue-1420", issue=1420, name="local-one"),           # this fleet: dropped
    s(f, "mini2.local", me, "issue-1423", issue=1423, name="侧边栏", origin_wid=u + "/issue-1419"),
    s(f, "mini2.local", me, "issue-1500", issue=1500, name="孙", origin_wid=f + "/issue-1423", seen="2026-10-04T10:05:00Z"),
    s(f, "mini2.local", me, "issue-1600", issue=1600, name="epic-kid", busy="bg"),  # sub-issue of local 1419; #1607 busy
    s(f, "mini2.local", me, "issue-1501", issue=1501, name="remote-sub"),        # sub-issue of REMOTE 1500
    s(f, "mini2.local", me, "issue-1700", issue=1700, name="sleeper", lifecycle="sleeping"),
    s(f, "mini2.local", me, "issue-1800", issue=1800, name="asker", state="needs", needs="ask"),
    s(f, "mini2.local", me, "scratch-4", avail="lost", issue=None, repo=None, name="草稿"),
    s(f, "mini2.local", "someone-else", "issue-1900", issue=1900, name="theirs"),
    s(f, "mini2.local", me, "issue-2000", wid=False, issue=2000, name="no-id"),
]
nodes = [dict(machine_name="mini2.local", availability="online", sessions=12, observed_at="2026-10-04T10:07:00Z", age_sec=3),
         dict(machine_name="box3", availability="lost", sessions=0, observed_at="2026-10-04T09:00:00Z", age_sec=4000),
         dict(machine_name="box8", availability="maintenance", sessions=2, observed_at="2026-10-04T10:06:00Z", age_sec=60)]
json.dump({"machines": [], "sessions": sessions, "nodes": nodes}, open(path, "w"), ensure_ascii=False)
json.dump({"machines": [], "sessions": sessions}, open(old, "w"), ensure_ascii=False)   # a hub older than #1475
unk = [dict(n, sessions=None) if n["machine_name"] == "mini2.local" else n for n in nodes]   # #1465: a fleet there unread
json.dump({"machines": [], "sessions": sessions, "nodes": unk}, open(path.replace("sessions.json", "sessions-unk.json"), "w"), ensure_ascii=False)
# #1795: a hub that blanked the unread machine's rows — the same unknown count, none of its rows
blank = [x for x in sessions if x["machine_name"] != "mini2.local"]
json.dump({"machines": [], "sessions": blank, "nodes": unk}, open(path.replace("sessions.json", "sessions-blank.json"), "w"), ensure_ascii=False)
# …and the machine read again, really empty: its rows go
gone = [dict(n, sessions=0) if n["machine_name"] == "mini2.local" else n for n in nodes]
json.dump({"machines": [], "sessions": blank, "nodes": gone}, open(path.replace("sessions.json", "sessions-gone.json"), "w"), ensure_ascii=False)
PY
export FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="mini2=m4 box3=m9 box8=m8"
rm -f "$G/remote_$S"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
CHECKS=$((CHECKS+1)); [ ! -e "$G/remote_$S" ] || fail "E: off — --refresh must write nothing"
CHECKS=$((CHECKS+1)); [ ! -e "$G/hub_ok" ] || fail "E: off — --refresh must not write hub_ok"
PATH="$SHIMPATH" bash "$HUBS" --ensure 2>/dev/null
CHECKS=$((CHECKS+1)); [ ! -e "$G/hubsess.pid" ] || fail "E: off — --ensure must start nothing"

export CCQUOTA_FLEET=1
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err" || fail "E: --refresh failed" "$(cat "$WORK/err")"
R=$(cat "$G/remote_$S" 2>/dev/null)
rrow() { printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/$1" '$1 == w { print $2 "|" $3 "|" $6 "|" $8 "|" $9 "|" $10 }'; }
has  "E: a #ts line leads the cache" "$(printf '%s\n' "$R" | head -1)" "#ts$US"
eq   "E: #me is this machine's label" "#me$US$MYHOST" "$(printf '%s\n' "$R" | sed -n 2p)"
ep() { python3 -c 'from datetime import datetime, timezone; import sys; print(int(datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$1"; }
eq   "E: one #node per other machine from the hub's list: YOUR session count, its observation; 维护中 (#1427) passes through as its own word" \
     "#node${US}m4${US}online${US}7$US$(ep 2026-10-04T10:07:00Z)${US}hub;#node${US}m8${US}maintenance${US}0$US$(ep 2026-10-04T10:06:00Z)${US}hub;#node${US}m9${US}lost${US}0$US$(ep 2026-10-04T09:00:00Z)${US}hub;" \
     "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" '$1 == "#node" { printf "%s;", $0 }')"
eq   "E: parent in THIS fleet → its bare key"  "m4|online|working|侧边栏|issue-1419|" "$(rrow issue-1423)"
eq   "E: parent elsewhere → its worker_id"     "m4|online|working|孙|$F/issue-1423|" "$(rrow issue-1500)"
eq   "E: no @origin_wid → the sub-issue parent (local)"  "m4|online|working|epic-kid|issue-1419|" "$(rrow issue-1600)"
eq   "E: the node's busy word rides as field 14 (#1607), empty where it has none" "bg|" \
     "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v a="wid:$F/issue-1600" -v b="wid:$F/issue-1423" '$1 == a { x = $14 } $1 == b { y = $14 } END { print x "|" y }')"
eq   "E: no @origin_wid → the sub-issue parent (remote)" "m4|online|working|remote-sub|$F/issue-1500|" "$(rrow issue-1501)"
eq   "E: a sleeping lifecycle is the row's state" "m4|online|sleeping|sleeper||" "$(rrow issue-1700)"
eq   "E: what the window needs rides along (field 10)" "m4|online|needs|asker||ask" "$(rrow issue-1800)"
eq   "E: a lost machine's row is kept, marked lost" "m4|lost|working|草稿||" "$(rrow scratch-4)"
eq   "E: this fleet's own session is a LOCAL row (#1480): local=1, this machine's label, no window here → empty wid" \
     "local-one|1||$MYHOST|online" \
     "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$U/issue-1420" '$1 == w { print $8 "|" $11 "|" $12 "|" $2 "|" $3 }')"
eq   "E: a row on another machine says local=0, no wid" "0|" \
     "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/issue-1423" '$1 == w { print $11 "|" $12 }')"
eq   "E: every row carries the six appended fields (local, wid, via, busy, born, cfg — #1480, #1488, #1607, #1750, #1783)" "" "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" '/^wid:/ && NF != 16')"
eq   "E: a hub answer's rows are via=hub" "" "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" '/^wid:/ && $13 != "hub"')"
hasnt "E: another login's session is not shown" "$R" "theirs"
hasnt "E: a session with no worker_id is not shown" "$R" "no-id"
has  "E: the C1 locator cache is written" "$(cat "$FLEET_CONF_DIR/control/hub-workers.tsv" 2>/dev/null)" "$F/issue-1423	m4"
FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions-old.json'" PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null || fail "E: --refresh (old hub) failed"
eq   "E: a hub without a nodes list: #node derived from the sessions (newest observation)" \
     "#node${US}m4${US}online${US}7$US$(ep 2026-10-04T10:05:00Z)${US}hub;" \
     "$(LC_ALL=C awk -F"$US" '$1 == "#node" { printf "%s;", $0 }' "$G/remote_$S")"
FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions-unk.json'" PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null || fail "E: --refresh (unknown count) failed"
eq   "E: the hub's sessions null (a fleet it could not read, #1465) → that #node's count is ?, never the rows held" \
     "#node${US}m4${US}online${US}?$US$(ep 2026-10-04T10:07:00Z)${US}hub;" \
     "$(LC_ALL=C awk -F"$US" '$1 == "#node" && $2 == "m4" { printf "%s;", $0 }' "$G/remote_$S")"
# #1795: an unread machine is "could not read", never "no windows" — a hub answer
# that lists none of its rows keeps their last lines, so the sidebar does not
# collapse to the row it stands on for the seconds a node's read times out
m4rows() { LC_ALL=C awk -F"$US" '/^wid:/ && $2 == "m4" { print $1 }' "$G/remote_$S" | sort | tr '\n' ' '; }
M4=$(m4rows)
FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions-blank.json'" PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null || fail "E: --refresh (blanked rows) failed"
eq   "E: the hub's sessions null and none of that machine's rows (#1795) → its last rows stay, none lost" "$M4" "$(m4rows)"
FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions-blank.json'" PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
eq   "E: …round after round while it stays unread" "$M4" "$(m4rows)"
FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions-gone.json'" PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null || fail "E: --refresh (read empty) failed"
eq   "E: …and a read that stands with no rows takes them away" "" "$(m4rows)"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null; R=$(cat "$G/remote_$S")
OK=$(cat "$G/hub_ok" 2>/dev/null)
case "$OK" in
  [0-9]*) [ "$OK" -ge "$NOW" ] || fail "E: hub_ok is not a fresh epoch (#1483)" "$OK" ;;
  *) fail "E: a round that stood must write global/hub_ok (#1483)" "$OK" ;;
esac; CHECKS=$((CHECKS+1))
FLEET_HUB_SESSIONS_CMD='exit 1' PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err"
eq   "E: a failed fetch returns 1"          "1" "$?"
eq   "E: …and keeps the last cache"         "$R" "$(cat "$G/remote_$S")"
eq   "E: …and hub_ok as it was: the silence dates from the last answer (#1483)" "$OK" "$(cat "$G/hub_ok")"
has  "E: …and says so on stderr"            "$(cat "$WORK/err")" "hub unreachable for"
# The refreshed cache renders: the epic's sub-issue nests under the local EPIC.
s=$(side)
eq "E: the refreshed cache renders under the local parent" "$F/issue-1600" \
   "$(printf '%s\n' "$s" | LC_ALL=C awk -F"$US" '$4 == "epic-kid" && $7 == 1 { sub(/^wid:/, "", $1); print $1 }')"
hasnt "E: …and the #node lines draw no machine status line (#1531)" \
   "$(shdrs "$(FLEET_HUB_SESSIONS_STALE=99999999 side)")" "●"

# ============================================================================
# I. identity — who asks the hub (#1475)
# ============================================================================
eq "I: a seam command is the identity" "cmd FLEET_HUB_SESSIONS_CMD" "$(bash "$HUBS" --identity)"
unset FLEET_HUB_SESSIONS_CMD
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh" "$HOME/.ccquota"
id_out=$(bash "$HUBS" --identity 2>/dev/null); id_rc=$?
eq  "I: nothing: --identity exits 1" "1" "$id_rc"
has "I: …and says why" "$id_out" "none no connection certificate"
: > "$NET_LOG"; : > "$WORK/err"
CCQUOTA_HUB_URL=http://hub.test PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err"
eq  "I: nothing: no fetch at all" "" "$(cat "$NET_LOG")"
has "I: …one note" "$(cat "$WORK/err")" "no connection certificate"
# the viewer token: a bearer GET
printf 'tok-123\n' > "$HOME/.ccquota/viewer-token"
eq  "I: a viewer token file" "token ~/.ccquota/viewer-token" "$(bash "$HUBS" --identity)"
eq  "I: …the env wins" "token CCQUOTA_VIEWER_TOKEN" "$(CCQUOTA_VIEWER_TOKEN=x bash "$HUBS" --identity)"
: > "$NET_LOG"
CCQUOTA_HUB_URL=http://hub.test PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
has   "I: token → a bearer GET of fleet_sessions" "$(cat "$NET_LOG")" "Bearer tok-123"
has   "I: …at the hub URL" "$(cat "$NET_LOG")" "http://hub.test/v1/fleet/fleet_sessions"
hasnt "I: …not a POST" "$(cat "$NET_LOG")" "POST"
# the hub URL from hub.json (what `fleet login` wrote), when no env names one
mkdir -p "$HOME/.config/claude-fleet"; printf '{"url": "http://json.hub/"}\n' > "$HOME/.config/claude-fleet/hub.json"
: > "$NET_LOG"; PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
has   "I: the hub URL falls back to hub.json" "$(cat "$NET_LOG")" "http://json.hub/v1/fleet/fleet_sessions"
: > "$NET_LOG"; FLEET_HUB_URL=http://env.hub PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
has   "I: …FLEET_HUB_URL before it" "$(cat "$NET_LOG")" "http://env.hub/v1/fleet/fleet_sessions"
# a connection certificate: a signed POST, no token used
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/ca" >/dev/null 2>&1
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/fleet-cert" >/dev/null 2>&1
  ssh-keygen -q -s "$WORK/ca" -I 'wecom:wx-a' -n alice -V '-5m:+1h' "$HOME/.ssh/fleet-cert.pub" >/dev/null 2>&1 \
    || fail "I: could not sign a test certificate"
  has "I: a valid certificate is the identity, before the token" "$(bash "$HUBS" --identity)" "cert $HOME/.ssh/fleet-cert-cert.pub "
  : > "$NET_LOG"
  CCQUOTA_HUB_URL=http://hub.test PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
  has   "I: cert → a POST of fleet_sessions" "$(cat "$NET_LOG")" "POST"
  has   "I: …carrying the certificate line" "$(cat "$NET_LOG")" "ssh-ed25519-cert-v01@openssh.com"
  has   "I: …and an ssh-keygen signature" "$(cat "$NET_LOG")" "BEGIN SSH SIGNATURE"
  hasnt "I: …and never the token" "$(cat "$NET_LOG")" "tok-123"
  sigok=$(printf '%s\n' "$(cat "$NET_LOG")" | python3 -c '
import json, re, subprocess, sys, tempfile, os
line = sys.stdin.read()
m = re.search(r"--data-binary (\{.*?\}) http", line, re.S)   # the armored signature spans lines
body = json.loads(m.group(1))
d = tempfile.mkdtemp()
# ssh-keygen signs with the plain key (the hub checks it against the certificate it
# was sent): verify against that key
k = open(sys.argv[1]).read().split()
open(os.path.join(d, "allowed"), "w").write("alice " + k[0] + " " + k[1] + "\n")
open(os.path.join(d, "sig"), "w").write(body["sig"])
r = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", os.path.join(d, "allowed"), "-I", "alice",
                    "-n", "fleet-sessions@claude-fleet", "-s", os.path.join(d, "sig")],
                   input=("fleet-sessions %d" % body["ts"]).encode(), capture_output=True)
print("ok" if r.returncode == 0 else "bad:" + r.stderr.decode(errors="replace").strip())
' "$HOME/.ssh/fleet-cert.pub" 2>&1)
  eq "I: …the signature verifies under fleet-sessions@claude-fleet over the timestamp" "ok" "$sigok"
  # an expired certificate is skipped: the token again, and --identity says expired without one
  ssh-keygen -q -s "$WORK/ca" -I 'wecom:wx-a' -n alice -V '-2h:-1h' "$HOME/.ssh/fleet-cert.pub" >/dev/null 2>&1
  eq  "I: an expired certificate falls back to the token" "token ~/.ccquota/viewer-token" "$(bash "$HUBS" --identity)"
  rm -f "$HOME/.ccquota/viewer-token"
  has "I: …and with no token says it expired" "$(bash "$HUBS" --identity 2>/dev/null)" "none certificate expired"
  # FLEET_CERT names another pair
  ssh-keygen -q -s "$WORK/ca" -I 'wecom:wx-a' -n alice -V '-5m:+1h' "$HOME/.ssh/fleet-cert.pub" >/dev/null 2>&1
  cp "$HOME/.ssh/fleet-cert" "$WORK/other"; cp "$HOME/.ssh/fleet-cert-cert.pub" "$WORK/other-cert.pub"
  rm -f "$HOME/.ssh/fleet-cert" "$HOME/.ssh/fleet-cert-cert.pub"
  has "I: FLEET_CERT names the pair" "$(FLEET_CERT="$WORK/other" bash "$HUBS" --identity)" "cert $WORK/other-cert.pub "
else
  printf 'dash-remote-rows selftest: no ssh-keygen — the certificate legs of I skipped\n' >&2
fi
HOME="$(cd ~ && pwd)"; export HOME
export FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null

# ============================================================================
# F. read-only — and the fold is THIS machine's (issue #1749)
# ============================================================================
: > "$TMUX_LOG"
rm -f "$G/remote_fold_$S"; cp "$G/remote_$S" "$WORK/remote.f"; remote_cache "$NOW"   # B's tree
fold() { PATH="$SHIMPATH" FLEET_SESSION=$S DASH_FOLD_PLAIN=1 bash "$BIN/dash-fold-toggle.sh" "$1" "$2" 2>/dev/null; }
eq "F: → on a remote parent opens it" "reload(bash $BIN/tmux-dashboard-rows.sh)" "$(fold expand "wid:$F/issue-1423")"
eq "F: …written to this machine's own file" "$F/issue-1423" "$(cat "$G/remote_fold_$S" 2>/dev/null)"
eq "F: → on an open parent is a dead key" "" "$(fold expand "wid:$F/issue-1423")"
eq "F: → on a remote leaf is a dead key" "" "$(fold expand "wid:$F/issue-1500")"
eq "F: → on a row the cache does not list is a dead key" "" "$(fold expand "wid:$F/issue-9")"
fold collapse "wid:$F/issue-1500" >/dev/null
[ -e "$G/remote_fold_$S" ] && fail "F: ← on a remote child should shut its parent's block (the file goes)" "$(cat "$G/remote_fold_$S")"
CHECKS=$((CHECKS + 1))
eq "F: ← with nothing open is a dead key" "" "$(fold collapse "wid:$F/issue-1423")"
printf '%s/issue-1423\n%s/issue-gone\n' "$F" "$F" > "$G/remote_fold_$S"
fold expand "wid:$F/scratch-2" >/dev/null   # a leaf: no write, nothing pruned
fold collapse "wid:$F/issue-1423" >/dev/null; fold expand "wid:$F/issue-1423" >/dev/null
eq "F: a rewrite drops an id the cache no longer lists" "$F/issue-1423" "$(cat "$G/remote_fold_$S")"
PATH="$SHIMPATH" FLEET_SESSION=$S bash "$BIN/dash-pin-toggle.sh" "wid:$F/issue-1423" >/dev/null 2>&1
PATH="$SHIMPATH" FLEET_SESSION=$S bash "$BIN/dash-migrate.sh" "wid:$F/issue-1423" >/dev/null 2>&1
hasnt "F: fold/pin/migrate on a remote row set no tmux option" "$(cat "$TMUX_LOG")" "set-"
mv "$WORK/remote.f" "$G/remote_$S"; rm -f "$G/remote_fold_$S"

# ============================================================================
# G. inventory columns 10-12
# ============================================================================
if [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$S" -f /dev/null new-session -d -s "$S" -n plan 'while :; do sleep 300; done' 2>/dev/null; then
  wi=$("$REAL_TMUX" -L "$S" new-window -d -P -F '#{window_id}' -n '侧边栏 x' 'while :; do sleep 300; done')
  "$REAL_TMUX" -L "$S" set-window-option -t "$wi" @issue 1423
  "$REAL_TMUX" -L "$S" set-window-option -t "$wi" @origin_wid "$F/issue-1419"
  "$REAL_TMUX" -L "$S" set-window-option -t "$wi" @claude_needs ask
  got=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = [x for x in ctl.inventory() if x["name"] == sys.argv[2]][0]
w = [x for x in ctl.workers(f)["workers"] if x["issue"] == 1423][0]
print(w["name"] + "|" + str(w["origin_wid"]) + "|" + w["key"] + "|" + str(w["needs"]))' "$FLEET_CONF_DIR" "$S" 2>&1)
  eq "G: the adapter hands over the window name, @origin_wid and @claude_needs" "侧边栏 x|$F/issue-1419|issue-1423|ask" "$got"
  # The shell's road while the hub is silent (#1488): fleet-remote-view.sh
  # sessions reads the SAME adapter on this machine. Its hand copy of the column
  # rule missed #1607's `busy=` and glued @origin_wid onto the name (issue
  # #1698), so every row of a silent hub came back un-nested and mislabelled.
  got=$(bash "$BIN/fleet-remote-view.sh" sessions 2>&1 | python3 -c 'import json, sys
d = json.load(sys.stdin); w = [s["worker"] for s in d["sessions"] if s["worker"]["issue"] == 1423][0]
print(w["name"] + "|" + str(w["origin_wid"]) + "|" + str(w["needs"]) + "|" + str("busy" in w))' 2>&1)
  eq "G: remote-view sessions — name, @origin_wid, needs each in its own field (#1698)" \
     "侧边栏 x|$F/issue-1419|ask|True" "$got"
  "$REAL_TMUX" -L "$S" set-window-option -t "$wi" -u @origin_wid
  "$REAL_TMUX" -L "$S" set-window-option -t "$wi" -u @claude_needs
  got=$(bash "$BIN/fleet-remote-view.sh" sessions 2>&1 | python3 -c 'import json, sys
d = json.load(sys.stdin); w = [s["worker"] for s in d["sessions"] if s["worker"]["issue"] == 1423][0]
print(repr(w["name"]) + "|" + str(w["origin_wid"]) + "|" + str(w["needs"]))' 2>&1)
  eq "G: …a row with no parent: no trailing space on its name, origin_wid None" \
     "'侧边栏 x'|None|None" "$got"
  # The refresher maps a LOCAL row to the window that holds it now (#1480) —
  # through this same adapter on the real server, by the hub's own key rule.
  wl=$("$REAL_TMUX" -L "$S" new-window -d -P -F '#{window_id}' -n 'local-one' 'while :; do sleep 300; done')
  "$REAL_TMUX" -L "$S" set-window-option -t "$wl" @issue 1420
  CCQUOTA_FLEET=1 bash "$HUBS" --refresh 2>"$WORK/err" || fail "G: --refresh (real server) failed" "$(cat "$WORK/err")"
  eq "G: a local row's wid is the live window of its worker_id" "1|$wl" \
     "$(LC_ALL=C awk -F"$US" -v w="wid:$U/issue-1420" '$1 == w { print $11 "|" $12 }' "$G/remote_$S")"
  "$REAL_TMUX" -L "$S" kill-window -t "$wl" 2>/dev/null
  CCQUOTA_FLEET=1 bash "$HUBS" --refresh 2>/dev/null
  eq "G: …and empty again once that window is gone" "1|" \
     "$(LC_ALL=C awk -F"$US" -v w="wid:$U/issue-1420" '$1 == w { print $11 "|" $12 }' "$G/remote_$S")"
  # Every session the node's own list shows is reported (issue #1749): a no-repo
  # window with no key is listed under the identity the adapter mints for it, and
  # a raw scratch whose @worktree was never stamped keys off its scratch cwd —
  # fleet_window_okey's fallback. A panel is never a session.
  mkdir -p "$WORK/wt/acme-scratch-21"
  wg=$("$REAL_TMUX" -L "$S" new-window -d -P -F '#{window_id}' -n guide -c "$WORK" 'while :; do sleep 300; done')
  "$REAL_TMUX" -L "$S" set-window-option -t "$wg" @norepo 1
  wr=$("$REAL_TMUX" -L "$S" new-window -d -P -F '#{window_id}' -n 'SPACE' -c "$WORK/wt/acme-scratch-21" 'while :; do sleep 300; done')
  "$REAL_TMUX" -L "$S" set-window-option -t "$wr" @raw 1
  sleep 1   # pane_current_path is read off the process: let the shell start
  got=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = [x for x in ctl.inventory() if x["name"] == sys.argv[2]][0]
ws = {w["name"]: w for w in ctl.workers(f)["workers"]}
g, r = ws.get("guide") or {}, ws.get("SPACE") or {}
print(str(g.get("key")) + "|" + str(g.get("worker_id")) + "|" + str(r.get("key")) + "|" + str("plan" in ws))' "$FLEET_CONF_DIR" "$S" 2>&1)
  gfid=$("$REAL_TMUX" -L "$S" show-options -wqv -t "$wg" @fleet_id)
  case "$gfid" in ????????-????-????-????-????????????) ;; *) fail "G: the adapter minted no @fleet_id for a keyless window (got '$gfid')" ;; esac
  eq "G: a keyless no-repo window is listed under its minted identity; a raw scratch keys off its cwd; no panel" \
     "None|$U/$gfid|scratch-21|False" "$got"
  got=$(bash "$BIN/fleet-remote-view.sh" sessions 2>&1 | python3 -c 'import json, sys
d = json.load(sys.stdin); print(";".join(sorted(s["worker_id"].split("/", 1)[1] for s in d["sessions"])))' 2>&1)
  has "G: remote-view sessions lists the keyless window too" "$got" "$gfid"
  has "G: …and the cwd-keyed scratch" "$got" "scratch-21"
else
  printf 'dash-remote-rows selftest: no isolated tmux server — leg G (live adapter) skipped\n' >&2
fi
got=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = {"name": "x", "agent": "claude", "fleet_id": sys.argv[2], "repo": "acme/app"}
ctl.adapter = lambda *a, **k: (0, b"@5\t7\t0\t/w/app-issue-7\tworking\tclaude\ta1\t\t\n", b"")
w = ctl.workers(f)["workers"][0]
print("name" in w, "origin_wid" in w, "needs" in w, w["key"])' "$FLEET_CONF_DIR" "$U" 2>&1)
eq "G: a 9-column adapter still parses, with no new keys" "False False False issue-7" "$got"
got=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = {"name": "x", "agent": "claude", "fleet_id": sys.argv[2], "repo": "acme/app"}
# the adapter 13-column shape (issue #1646: column 13 is @fleet_id, the identity)
ctl.adapter = lambda *a, **k: (0, b"@5\t7\t0\t/w/app-issue-7\tworking\tclaude\ta1\t\t\ta\tb\t\t\t9d1c6b7e-2f4a-4c3b-8e5d-6a7b8c9d0e1f\n", b"")
w = ctl.workers(f)["workers"][0]
print(w["name"] + "|" + str(w["origin_wid"]) + "|" + str(w["needs"]) + "|" + str(w["identity"]))' "$FLEET_CONF_DIR" "$U" 2>&1)
eq "G: a tab inside the window name is absorbed — kept as the tab it is (#1698), never a protocol error" \
   $'a\tb|None|None|9d1c6b7e-2f4a-4c3b-8e5d-6a7b8c9d0e1f' "$got"

# ============================================================================
# R. ready — can this login take a new session? (#1475)
# ============================================================================
export HOME="$WORK/home2"; mkdir -p "$HOME"
# gh "logged in" iff a marker file exists — the controller hands the adapter an
# allowlisted environment, so an env var would not reach the shim through it
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && [ -e "%s/gh-ok" ] && exit 0\nexit 1\n' "$WORK" > "$WORK/bin/gh"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/security"
chmod +x "$WORK/bin/gh" "$WORK/bin/security"
rdy() { PATH="$SHIMPATH" bash "$CREAD" ready 2>/dev/null | python3 -c 'import json, sys
d = json.load(sys.stdin); print("%s|%s|%s|%s|%s" % (d["ready"], d["gh"], d["creds"], d["checkouts"], ",".join(d["missing"])))'; }
eq "R: nothing in place: not ready, gh + creds named" "False|False|False|True|gh,creds" "$(rdy)"
touch "$WORK/gh-ok"
eq "R: a gh login" "False|True|False|True|creds" "$(rdy)"
mkdir -p "$HOME/.claude"; printf '{}' > "$HOME/.claude/.credentials.json"
eq "R: Claude Code's own credential file counts" "True|True|True|True|" "$(rdy)"
rm -f "$HOME/.claude/.credentials.json"; mkdir -p "$HOME/.codex"; printf '{}' > "$HOME/.codex/auth.json"
eq "R: Codex's auth.json counts" "True|True|True|True|" "$(rdy)"
rm -f "$HOME/.codex/auth.json"; mkdir -p "$FLEET_CONF_DIR/accounts"; printf 'sk-x\n' > "$FLEET_CONF_DIR/accounts/alpha"
eq "R: a pool token file counts" "True|True|True|True|" "$(rdy)"
rm -f "$FLEET_CONF_DIR/accounts/alpha"; mkdir -p "$FLEET_CONF_DIR/accounts/beta.hub"; printf '{}' > "$FLEET_CONF_DIR/accounts/beta.hub/.credentials.json"
eq "R: a pool account's hub credential counts" "True|True|True|True|" "$(rdy)"
rmdir "$WORK/main"
eq "R: a missing checkout is named" "False|True|True|False|checkout:$S/app" "$(rdy)"
mkdir -p "$WORK/main"
got=$(cd "$BIN" && PATH="$SHIMPATH" python3 -c 'import sys, fleet_control as c
ctl = c.Control(sys.argv[1])
r = ctl.dispatch(dict(protocol=1, method="ready", params={}))
print("%s|%s|%s" % (r["ready"], r["gh"], ",".join(r["missing"])))' "$FLEET_CONF_DIR" 2>&1)
eq "R: fleet_control.py's ready method hands the verdict on, no fleet identity needed" "True|True|" "$got"
HOME="$(cd ~ && pwd)"; export HOME

printf 'dash-remote-rows selftest: PASS (%d checks)\n' "$CHECKS"
