#!/bin/bash
# tmux-status-selftest.sh — pins issue #1616 (EPIC #1615 C1): the status bar
# draws ONLY WHAT WANTS YOUR HAND. The right side is empty while all is well, and
# each segment appears on its own condition, in one order, in both modes:
#   <machine> [○ 失联 Nm] [旧]   a proxy window's machine (hub mode); 旧 also for
#                               this machine's own row (#644)
#   <account> 5h N% · 周 N%     max(5h, 周) ≥ FLEET_STATUS_QUOTA_PCT (80) — only
#                               the window(s) past the line
#   ✖ N  ▲ N                    alarms / warnings, each only when ≠ 0
#   ○ 入口 Nm                   hub mode, the hub silent past the stale knob
# Off hub mode and on it, issue #1482's rules for WHICH machine / account / hub
# stand (EPIC #1479 C3, #1483) — only what is drawn changed.
#
#   A  degenerate: no args · the hub off · the fleet on FLEET_SIDEBAR_SOURCE=local ·
#      hub on but no remote_<sess> cache · a healthy hub-mode local window
#                                   → nothing at all (an empty right side)
#   B  the account: past the line → `<label> 5h N%`, only the window(s) past it,
#      through the account knobs' bands; FLEET_STATUS_QUOTA_PCT moves the line;
#      off the hub's limits in hub mode, else the window's own reading
#   C  a proxy window (@remote=m4:…) → `m4`; the account after it
#   D  a lost machine → `m9 ○ 失联 Nm` (the hub's age + the cache's); an unknown
#      one, or no hub_nodes row → just its name; the sessions cache's word on a
#      machine with no hub_nodes row
#   E  the hub: a stale remote_ cache → `○ 入口 Nm`; the stale knob; global/hub_ok
#      as THE word (#1483): old with a fresh cache → `○ 入口`, a proxy window's
#      machine NOT also lost (the hub chip says it); fresh hub_ok over an old #ts
#      → nothing; an unreadable hub_ok → the #ts
#   F  the window list: blank on entering hub mode (formats saved), restored on
#      leaving; no tmux call when there is nothing to do — on an ISOLATED server
#   G  fleet-hub-sessions.sh --refresh writes hub_nodes / hub_limits from the
#      seams: the alias, mem %, newest login's version, the uuid → local label
#      map, rounding, skipped rows; a failed fetch keeps the last file; off
#      (CCQUOTA_FLEET unset) writes nothing; their own cadence (FLEET_HUB_SUMMARY_EVERY);
#      hub_ok written on a sessions round that stood, left alone on a failed one (#1483);
#      a connection certificate asks POST /v1/fleet/summary once for both and
#      never the token; refused → the viewer routes with it; no answer → nothing (#1502);
#      each version's word against the live install's local refs/tags/stable
#      (issue #644): ok / old:<n> / ahead:<n> / off / ? — and '' (unknown, never
#      current) with no live checkout or no stable tag
#   H  fleet_status_node: the one rule for 「当前会话所在机器」
#   I  the width (`cw=`): narrower than 60 the account's label goes and only the
#      higher window stays; no width / junk = wide
#   J  the alert counts: only when ≠ 0, alarm then warning, each in its range;
#      the full order machine · account · alerts · hub
#   K  旧 (issue #644, EPIC #1524 R4): a hub_nodes row whose 11th field is
#      `old:<n>` → `旧` after the machine — this machine's own row too (its name
#      drawn with it), a lost machine's, at any width; ok / ahead / off / ? / a
#      10-field row (a pre-#644 cache) draw nothing, and off hub mode never
#   L  the 54-column contract: a 54 / 120 / 189-column CLIENT of an isolated
#      server running the shipped bar — the CLIENT's (conf/tmux-shell.conf's
#      status lines; a node's own line is one hint since issue #1714) — four
#      states (正常 / 额度高 / 有告警 / 入口失联): the bar line as tmux draws it —
#      ≤ 30 columns of ink at 54 in every state, the state's segment present,
#      本机 / 负载 / 内存 / 盘 / ● 入口 never
#
# Drives bin/tmux-status.sh, bin/fleet-status-lib.sh, bin/fleet-hub-sessions.sh
# and conf/tmux-shell.conf's bar. ps / sysctl / vm_stat / free / df are shims (as
# tmux-status-cache-selftest.sh); TMPDIR, FLEET_CONF_DIR and FLEET_ACCOUNTS_DIR are
# a sandbox; every tmux server is on a private socket.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; CHECKS=$((CHECKS+1)); }
has() { case "$3" in *"$2"*) CHECKS=$((CHECKS+1)) ;; *) fail "$1" "want a substring: [$2]
 got: [$3]" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "must not contain: [$2]
 got: [$3]" ;; *) CHECKS=$((CHECKS+1)) ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tmux-status-selftest.XXXXXX") || exit 2
T="$WORK/tmp"; G="$T/.claude-dash/global"; CONF="$WORK/conf"; ACC="$WORK/acc"
mkdir -p "$T" "$G" "$WORK/bin" "$CONF/fleets/f1" "$ACC"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
SOCK="$WORK/tmux.sock"
cleanup() {
  if [ -n "$REAL_TMUX" ]; then
    for s in "$SOCK" "$WORK"/l-*.sock; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  fi
  rm -rf "$WORK"
}
[ -n "${KEEP:-}" ] || trap cleanup EXIT
trap 'exit 130' INT TERM HUP
US=$'\x1f'
NOW=$(date +%s)

sh_shim() { printf '#!/bin/sh\n%s\n' "$2" > "$WORK/bin/$1"; chmod +x "$WORK/bin/$1"; }
sh_shim ps      'printf "%%CPU\n12.0\n28.0\n"'
sh_shim sysctl  'printf "4\n8589934592\n16384\n{ 1.20 1.00 0.90 }\n"'
sh_shim vm_stat 'printf "Pages active:  100000.\nPages wired down:  50000.\nPages occupied by compressor:  50000.\n"'
sh_shim free    'printf "       total used\nMem:    8192 3125\n"'
sh_shim df      "printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1 1 104857600 1%% /\n'"
# every `tmux` the bar runs goes to the private server, and is logged (leg F)
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$WORK/tmux.log'
exec '$REAL_TMUX' -S '$SOCK' "\$@"
EOF
chmod +x "$WORK/bin/tmux"; : > "$WORK/tmux.log"

# bar [k=v …] — the status bar's right side in the sandbox. CF overrides
# CCQUOTA_FLEET (default 1). The alerts file is the test's own: planted empty
# here, fresh for FLEET_ALERTS_TTL=3600, so the producer never recomputes it — a
# sandbox has no quota-watch tick (a real `✖ quota stale`), and a busy runner's
# real load must not draw a ▲ into a golden. Leg J plants rows into it; the
# producer's own legs are fleet-alerts-selftest.sh's.
mkdir -p "$G"; : > "$G/alerts.ndjson"; printf '%s\n' "$NOW" > "$G/alerts.ndjson.ts"
bar() { FLEET_ALERTS_TTL=3600 FLEET_ALERTS_DISK=0 FLEET_ALERTS_MACHINE=0 TMPDIR="$T/" FLEET_CONF_DIR="$CONF" FLEET_ACCOUNTS_DIR="$ACC" \
        CCQUOTA_HUB_URL=http://127.0.0.1:9 CCQUOTA_FLEET="${CF-1}" FLEET_NODE_ALIASES="box=m5" HOSTNAME=box.local \
        PATH="$WORK/bin:$PATH" bash "$BIN/tmux-status.sh" "$@" 2>/dev/null; }
# the palette's colours, as tmux-status.sh writes them
B='#[fg=#7aa2f7]' R='#[fg=#f7768e]' Y='#[fg=#e0af68]' GR='#[fg=#9ece6a]' D='#[fg=#565f89]'
plain=$(CF='' bar)
eq "golden (plain): nothing to say → an empty right side — issue #1616's contract" "" "$plain"

# caches: the sidebar's (header only matters here), hub_nodes, hub_limits
remote() { printf '#ts%s%s\n#me%sm5\n#node%sm4%sonline%s1%s%s\n#node%sm2%slost%s0%s%s\n' "$US" "$1" "$US" "$US" "$US" "$US" "$US" "$1" "$US" "$US" "$US" "$US" $(( $1 - 600 )) > "$G/remote_f1"; }
nodes() { # nodes <ts> <row>… (each row US-joined)
  local ts="$1"; shift; { printf '#ts%s%s\n' "$US" "$ts"; printf '%s\n' "$@"; } > "$G/hub_nodes"; }
j() { local IFS="$US"; printf '%s' "$*"; }
remote "$NOW"
nodes "$NOW" "$(j m5 online 5.65 15 56 14 1607453 3 37035 65536)" \
             "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)" \
             "$(j m8 online 9.00 10 90 2 abc 1 14746 16384)" \
             "$(j m9 lost 0.00 4 10 0 '' 4000 400 4096)"
{ printf '#ts%s%s\n' "$US" "$NOW"; printf '%s\n' "$(j icloud 63 65 7a7e ylianghui@icloud.com)" "$(j gmail 41 13 e58c verky.yi@gmail.com)" \
  "$(j ly297 90 72 5a77 ly297@georgetown.edu)" "$(j hot 85 92 9f9f hot@x.y)"; } > "$G/hub_limits"
printf 'FLEET_SIDEBAR_SOURCE=hub   # per fleet\n' > "$CONF/fleets/f1/conf"
LOCAL='sess=f1 win=@1 remote= acct=icloud wsf= wscf= wsaved='
PROXY='sess=f1 win=@2 remote=m4:u/issue-9 wsf= wscf= wsaved='
px() { local n="$1"; shift; bar sess=f1 win=@3 "remote=$n:u/x" wsf= wscf= wsaved= "$@"; }

# ---- A: degenerate — nothing at all
eq "A: no args (the pre-#1482 conf) = nothing" "" "$(bar)"
eq "A: args, hub off = nothing" "" "$(CF='' bar $LOCAL)"
eq "A: args, hub off, a proxy window = nothing (no machine off hub mode)" "" "$(CF='' bar $PROXY acct=)"
printf 'FLEET_SIDEBAR_SOURCE=local\n' > "$CONF/fleets/f1/conf"
eq "A: the fleet on the local source = nothing" "" "$(bar $LOCAL)"
eq "A: the local source, a proxy window = nothing" "" "$(bar $PROXY acct=)"
printf 'FLEET_SIDEBAR_SOURCE=hub\n' > "$CONF/fleets/f1/conf"
eq "A: hub, but fleet.settings says local and the fleet conf has no key → nothing" "" "$(printf '' > "$CONF/fleets/f1/conf"; bar $PROXY acct=)"
printf 'export FLEET_SIDEBAR_SOURCE="hub"\n' > "$CONF/fleets/f1/conf"
mv "$G/remote_f1" "$G/remote_f1.off"
eq "A: hub on, no remote_ cache yet = nothing" "" "$(bar $PROXY acct=)"
mv "$G/remote_f1.off" "$G/remote_f1"
eq "A: hub mode, a healthy local window (icloud 63% / 65%) → nothing: 本机, 负载, 内存, ● 入口 are not drawn" "" "$(bar $LOCAL)"
setcalls() { grep -c set-option "$WORK/tmux.log"; }   # the alerts refresh may read tmux; the bar must never SET anything on a render
eq "A: no tmux set-option on any of those" 0 "$(setcalls)"

# ---- B: the account past FLEET_STATUS_QUOTA_PCT
eq "B: hub mode, ly297 5h 90% (past 80) · 周 72% (not) → only the 5h, red (FLEET_ACCOUNT_CEILING)" \
   " ${B}ly297 ${D}5h ${R}90% " "$(bar sess=f1 win=@1 remote= acct=ly297 wsf= wscf= wsaved=)"
eq "B: both past the line → both, 周 92% red, 5h 85% red" \
   " ${B}hot ${D}5h ${R}85% ${D}· ${D}周 ${R}92% " "$(bar sess=f1 win=@1 remote= acct=hot wsf= wscf= wsaved=)"
eq "B: the bands are the account knobs (95 / 99 → 90% green)" " ${B}ly297 ${D}5h ${GR}90% " \
   "$(FLEET_ACCOUNT_WARN_PCT=95 FLEET_ACCOUNT_CEILING=99 bar sess=f1 win=@1 remote= acct=ly297 wsf= wscf= wsaved=)"
eq "B: 80–84 → yellow (FLEET_ACCOUNT_WARN_PCT 70 ≤ n < 85)" " ${B}icloud ${D}5h ${Y}82% " "$(CF='' bar acct=icloud rl5=82 rl7=10)"
eq "B: FLEET_STATUS_QUOTA_PCT=95 → 90% is under the line: nothing" "" \
   "$(FLEET_STATUS_QUOTA_PCT=95 bar sess=f1 win=@1 remote= acct=ly297 wsf= wscf= wsaved=)"
eq "B: FLEET_STATUS_QUOTA_PCT=60 → icloud 63% · 65% both drawn" " ${B}icloud ${D}5h ${GR}63% ${D}· ${D}周 ${GR}65% " \
   "$(FLEET_STATUS_QUOTA_PCT=60 bar $LOCAL)"
eq "B: exactly at the line (80) counts" " ${B}icloud ${D}周 ${Y}80% " "$(CF='' bar acct=icloud rl5=10 rl7=80)"
eq "B: 79 does not" "" "$(CF='' bar acct=icloud rl5=79 rl7=79)"
eq "B: off hub mode the window's own reading" " ${B}icloud ${D}5h ${R}99% " "$(CF='' bar acct=icloud rl5=99 rl7=2)"
eq "B: hub mode, the hub's limits win over the window's reading (63 under the line)" "" "$(bar $LOCAL rl5=99 rl7=99)"
eq "B: hub mode, an account the hub does not know → the window's reading" " ${B}nope ${D}5h ${R}99% " \
   "$(bar sess=f1 win=@1 remote= acct=nope wsf= wscf= wsaved= rl5=99 rl7=2)"
eq "B: the hub's own label finds the row too" " ${B}ly297@georgetown.edu ${D}5h ${R}90% " \
   "$(bar sess=f1 win=@1 remote= acct=ly297@georgetown.edu wsf= wscf= wsaved=)"
eq "B: a reading but no account → nothing" "" "$(CF='' bar acct= rl5=99 rl7=99)"
eq "B: junk readings → nothing" "" "$(CF='' bar acct=icloud rl5=x rl7=9.5)"

# ---- C: a proxy window → that machine's name
eq "C: @remote=m4:… → m4, nothing else (its load and memory are not drawn)" " ${B}m4 " "$(bar $PROXY acct=)"
eq "C: an account under the line adds nothing" " ${B}m4 " "$(bar $PROXY acct=gmail)"
eq "C: the account past the line follows the machine" " ${B}m4  ${B}ly297 ${D}5h ${R}90% " "$(bar $PROXY acct=ly297)"
eq "C: a busy machine is not the bar's to say (负载 / 内存 left the bar)" " ${B}m8 " "$(px m8)"

# ---- D: lost / unknown
eq "D: a lost machine → ○ 失联 + its age (4000s → 66m)" " ${B}m9 ${R}○ 失联 66m " "$(px m9)"
nodes $(( NOW - 300 )) "$(j m9 lost 0.00 4 10 0 '' 300 400 4096)"
eq "D: the age grows with the cache's own age (300 + 300 → 10m)" " ${B}m9 ${R}○ 失联 10m " "$(px m9)"
eq "D: a machine the cache has no row for → its name" " ${B}m7 " "$(px m7)"
rm -f "$G/hub_nodes"
# No hub_nodes row (a certificate identity gets no /v1/nodes until #1502 — the
# shell on a colleague's computer, #1484): the sessions cache's #node line.
eq "D: no hub_nodes, a #node line says online → its name" " ${B}m4 " "$(px m4)"
eq "D: no hub_nodes, a #node line says lost → ○ 失联 + its age (600s → 10m)" " ${B}m2 ${R}○ 失联 10m " "$(px m2)"
eq "D: no hub_nodes and no #node line either → its name" " ${B}m7 " "$(px m7)"
nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)"

# ---- E: the hub
HUBLOST="${R}○ ${B}入口 ${R}3m"
remote $(( NOW - 200 ))
eq "E: a remote_ cache older than FLEET_HUB_SESSIONS_STALE (no hub_ok: a loop from before #1483) → ○ 入口 3m; the proxy window's machine is not ALSO lost (the hub chip says it)" \
   " ${B}m4  ${HUBLOST} " "$(bar $PROXY acct=)"
eq "E: the stale knob is the sidebar's" " ${B}m4 " "$(FLEET_HUB_SESSIONS_STALE=1000 bar $PROXY acct=)"
remote "$NOW"
printf '%s\n' $(( NOW - 200 )) > "$G/hub_ok"
eq "E: hub_ok older than the knob, the remote_ cache FRESH → ○ 入口 3m" " ${B}m4  ${HUBLOST} " "$(bar $PROXY acct=)"
eq "E: …a local window: the hub chip alone (本机照常 — nothing of its own to say)" " ${HUBLOST} " "$(bar $LOCAL)"
nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)" "$(j m9 lost 0.00 4 10 0 '' 4000 400 4096)"
eq "E: …a machine the hub had already called lost: its name, the hub chip says the rest" " ${B}m9  ${HUBLOST} " "$(px m9)"
nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)"
printf '%s\n' "$NOW" > "$G/hub_ok"; remote $(( NOW - 200 ))
eq "E: a fresh hub_ok over an old #ts → nothing (the file is the word)" " ${B}m4 " "$(bar $PROXY acct=)"
printf '%s\n' $(( NOW - 200 )) > "$G/hub_ok"
eq "E: the knob applies to hub_ok" " ${B}m4 " "$(FLEET_HUB_SESSIONS_STALE=1000 bar $PROXY acct=)"
printf 'junk\n' > "$G/hub_ok"
eq "E: an unreadable hub_ok falls back to the cache's #ts (200s → 3m)" " ${B}m4  ${HUBLOST} " "$(bar $PROXY acct=)"
eq "E: off hub mode the hub is never drawn" "" "$(CF='' bar $PROXY acct=)"
rm -f "$G/hub_ok"; remote "$NOW"
eq "E: still no tmux set-option on a render" 0 "$(setcalls)"

# ---- F: the window list, on an isolated server
if [ -n "$REAL_TMUX" ]; then
  "$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s f1 -x 80 -y 24 2>/dev/null || fail "F: no isolated tmux server"
  tm() { "$REAL_TMUX" -S "$SOCK" "$@"; }
  tm set-option -g window-status-format '#I:#W' \; set-option -g window-status-current-format '[#I:#W]'
  bar sess=f1 win=@1 remote= acct= 'wsf=#I:#W' 'wscf=[#I:#W]' wsaved= >/dev/null
  eq "F: entering hub mode blanks window-status-format" "" "$(tm show-options -gqv window-status-format)"
  eq "F: … and window-status-current-format" "" "$(tm show-options -gqv window-status-current-format)"
  eq "F: … saving both" "#I:#W|[#I:#W]|1" "$(tm show-options -gqv @status_wsf_saved)|$(tm show-options -gqv @status_wscf_saved)|$(tm show-options -gqv @status_wlist_saved)"
  n=$(setcalls)
  bar sess=f1 win=@1 remote= acct= wsf= wscf= wsaved=1 >/dev/null
  eq "F: in hub mode with the list already blank: no tmux set-option" "$n" "$(setcalls)"
  CF='' bar sess=f1 win=@1 remote= acct= wsf= wscf= wsaved=1 >/dev/null
  eq "F: leaving hub mode restores window-status-format" '#I:#W' "$(tm show-options -gqv window-status-format)"
  eq "F: … and window-status-current-format" '[#I:#W]' "$(tm show-options -gqv window-status-current-format)"
  eq "F: … and forgets the saved pair" "||" "$(tm show-options -gqv @status_wsf_saved)|$(tm show-options -gqv @status_wscf_saved)|$(tm show-options -gqv @status_wlist_saved)"
  n=$(setcalls)
  CF='' bar sess=f1 win=@1 remote= acct= 'wsf=#I:#W' 'wscf=[#I:#W]' wsaved= >/dev/null
  eq "F: off hub mode with nothing saved: no tmux set-option" "$n" "$(setcalls)"
  tm kill-server 2>/dev/null
else
  printf 'tmux-status-selftest: no tmux — leg F skipped\n' >&2
fi

# ---- G: fleet-hub-sessions.sh writes the two summaries
HUBS="$BIN/fleet-hub-sessions.sh"
HB=$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' $(( NOW - 7 )))
# The "live install" the loop judges every machine's version against (issue
# #644): c1 → c2 → c3 on trunk, refs/tags/stable at c2, and c4 a commit off c1
# on no branch — hermetic git (no user config, a fixed identity).
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"
LIVE="$WORK/live"; git init -q "$LIVE" || fail "G: git init"
for c in c1 c2 c3; do git -C "$LIVE" commit -q --allow-empty -m "$c" || fail "G: commit $c"; done
C1=$(git -C "$LIVE" rev-parse --short HEAD~2); C2=$(git -C "$LIVE" rev-parse --short HEAD~1); C3=$(git -C "$LIVE" rev-parse --short HEAD)
git -C "$LIVE" tag stable "$C2"
C4=$(git -C "$LIVE" commit-tree -p "$C1" -m c4 "$(git -C "$LIVE" rev-parse "$C1^{tree}")"); C4=$(git -C "$LIVE" rev-parse --short "$C4")
git init -q "$WORK/nostable"; git -C "$WORK/nostable" commit -q --allow-empty -m x
cat > "$WORK/nodes.json" <<EOF
{"at":"x","machines":[
 {"hostname":"macmini","status":"online","sessions":14,"load1":5.65234375,"ncpu":15,"mem_free_bytes":29886201856,"mem_total_bytes":68719476736,"last_heartbeat":"$HB"},
 {"hostname":"mini2","status":"lost","sessions":0,"load1":0,"ncpu":10,"mem_free_bytes":0,"mem_total_bytes":0,"last_heartbeat":null},
 {"hostname":"box3","status":"online","sessions":null,"sessions_unknown":["u/f: UNAVAILABLE"],"load1":1,"ncpu":10,"mem_free_bytes":0,"mem_total_bytes":0,"last_heartbeat":"$HB"},
 {"hostname":"box4","status":"online","sessions":1,"load1":1,"ncpu":4,"mem_free_bytes":1,"mem_total_bytes":2,"last_heartbeat":"$HB"},
 {"hostname":"box5","status":"online","sessions":1,"load1":1,"ncpu":4,"mem_free_bytes":1,"mem_total_bytes":2,"last_heartbeat":"$HB"},
 {"hostname":"box6","status":"online","sessions":1,"load1":1,"ncpu":4,"mem_free_bytes":1,"mem_total_bytes":2,"last_heartbeat":"$HB"},
 {"hostname":"","status":"online"}],
 "nodes":[
 {"hostname":"macmini","os_user":"a","fleet_version":"old","last_heartbeat":"2026-10-04T13:15:20Z"},
 {"hostname":"macmini","os_user":"b","fleet_version":"$C2","last_heartbeat":"2026-10-04T13:15:25Z"},
 {"hostname":"mini2","os_user":"c","fleet_version":"","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box3","os_user":"d","fleet_version":"$C1","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box4","os_user":"e","fleet_version":"$C3","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box5","os_user":"f","fleet_version":"$C4","last_heartbeat":"2026-10-04T13:15:23Z"},
 {"hostname":"box6","os_user":"g","fleet_version":"deadbeef","last_heartbeat":"2026-10-04T13:15:23Z"}]}
EOF
cat > "$WORK/limits.json" <<'EOF'
{"per_account":[
 {"account_uuid":"7a7e6173-f07c-490f-844e-00c27c3f0844","label":"ylianghui@icloud.com","limits":{"available":true,"five_hour":{"utilization":63},"seven_day":{"utilization":65.4}}},
 {"account_uuid":"codex:ac","label":"verky.yi@gmail.com","limits":{"available":true,"source":"codex"}},
 {"account_uuid":"e69154ac","label":"verky@24helpful.com","limits":{"available":true,"five_hour":{"utilization":17},"seven_day":{"utilization":6}}},
 {"account_uuid":"5a77adb2","label":"ly297@georgetown.edu","limits":{"available":true,"five_hour":{"utilization":57.99999999999999},"seven_day":{"utilization":72}}},
 {"account_uuid":"gateway:x","label":"AI 网关 · aicall","limits":{"available":false}},
 {"account_uuid":"e58c","label":"tab\there","limits":{"available":true,"five_hour":{"utilization":1}}}]}
EOF
printf 'CCQUOTA_ACCOUNT="7a7e6173-f07c-490f-844e-00c27c3f0844"\n' > "$ACC/icloud.conf"
printf '{"sessions":[]}\n' > "$WORK/sessions.json"
hubs() { TMPDIR="$T/" FLEET_CONF_DIR="$CONF" FLEET_ACCOUNTS_DIR="$ACC" PATH="$WORK/bin:$PATH" CCQUOTA_FLEET="${CF-1}" \
         FLEET_HUB_SESSIONS_CMD="${SCMD-cat '$WORK/sessions.json'}" FLEET_HUB_NODES_CMD="${NCMD-cat '$WORK/nodes.json'}" \
         FLEET_HUB_LIMITS_CMD="${LCMD-cat '$WORK/limits.json'}" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
         FLEET_HUB_SUMMARY_EVERY="${SEVERY-0}" FLEET_LIVE_DIR="${LIVEDIR-$LIVE}" bash "$HUBS" --refresh 2>"$WORK/err"; }
rm -f "$G/hub_nodes" "$G/hub_limits" "$G/hub_ok"
CF='' hubs; [ -e "$G/hub_nodes" ] || [ -e "$G/hub_limits" ] || [ -e "$G/hub_ok" ] && fail "G: off (CCQUOTA_FLEET unset) wrote a summary or hub_ok"; CHECKS=$((CHECKS+1))
hubs || fail "G: --refresh failed" "$(cat "$WORK/err")"
OK=$(cat "$G/hub_ok" 2>/dev/null)
case "$OK" in
  [0-9]*) [ "$OK" -ge "$NOW" ] || fail "G: hub_ok is not a fresh epoch (#1483)" "$OK" ;;
  *) fail "G: a sessions round that stood must write global/hub_ok (#1483)" "$OK" ;;
esac; CHECKS=$((CHECKS+1))
SCMD=false hubs
eq "G: a failed sessions round leaves hub_ok as it was (#1483)" "$OK" "$(cat "$G/hub_ok")"
has "G: …and says how long the hub has been silent" "hub unreachable for" "$(cat "$WORK/err")"
rows=$(tr '\037' '|' < "$G/hub_nodes")
case "$rows" in "#ts|"[0-9]*) CHECKS=$((CHECKS+1)) ;; *) fail "G: hub_nodes starts with #ts" "$rows" ;; esac
row=$(printf '%s\n' "$rows" | grep '^m5|'); row=${row%|*|*|*}   # drop mem_used/mem_total/ver_state (exact below)
case "$row" in "m5|online|5.65|15|56|14|$C2|"[0-9]|"m5|online|5.65|15|56|14|$C2|"[0-9][0-9]) CHECKS=$((CHECKS+1)) ;;
  *) fail "G: m5's row: alias, mem %, the newest login's version, a small age" "$row" ;; esac
has "G: m5's memory in MB" "|37034|65536|" "$(printf '%s\n' "$rows" | grep '^m5|')"
eq "G: a lost machine with no reading: empty mem %, no version, no age, no version word" "m4|lost|0.00|10||0|||0|0|" "$(printf '%s\n' "$rows" | grep '^m4|')"
has "G: sessions null (#1465) → ? in the sessions field, never 0" "box3|online|1.00|10||?|" "$(printf '%s\n' "$rows" | grep '^box3|')"
eq "G: a machine with no hostname is not a row" "7" "$(printf '%s\n' "$rows" | grep -c .)"
# the version's word (issue #644): judged against $LIVE's refs/tags/stable (c2)
vw() { printf '%s\n' "$rows" | awk -F'|' -v n="$1" '$1 == n { print $7 "|" $11 }'; }
eq "G: at stable → ok (a short sha against the tag's commit)" "$C2|ok" "$(vw m5)"
eq "G: one commit behind stable → old:1" "$C1|old:1" "$(vw box3)"
eq "G: one commit past stable → ahead:1" "$C3|ahead:1" "$(vw box4)"
eq "G: a commit on no line through stable → off" "$C4|off" "$(vw box5)"
eq "G: a sha this checkout does not have → ? (never 0, never ok)" "deadbeef|?" "$(vw box6)"
LIVEDIR="$WORK/nolive" hubs; rows=$(tr '\037' '|' < "$G/hub_nodes")
eq "G: no live checkout → every word empty (unknown), the rows otherwise the same" 0 "$(printf '%s\n' "$rows" | awk -F'|' 'NR > 1 && $11 != ""' | grep -c .)"
eq "G: … box3 still carries its version" "$C1|" "$(vw box3)"
LIVEDIR="$WORK/nostable" hubs; rows=$(tr '\037' '|' < "$G/hub_nodes")
eq "G: a checkout with no refs/tags/stable → every word empty" 0 "$(printf '%s\n' "$rows" | awk -F'|' 'NR > 1 && $11 != ""' | grep -c .)"
hubs; rows=$(tr '\037' '|' < "$G/hub_nodes")
eq "G: … and back with the tag" "$C1|old:1" "$(vw box3)"
lrows=$(tr '\037' '|' < "$G/hub_limits")
has "G: a uuid this login has an accounts/<label>.conf for → that label; 65.4 → 65" "icloud|63|65|7a7e6173-f07c-490f-844e-00c27c3f0844|ylianghui@icloud.com" "$lrows"
has "G: an unmapped uuid → the hub's label" "verky@24helpful.com|17|6|e69154ac|verky@24helpful.com" "$lrows"
has "G: 57.999… → 58" "ly297@georgetown.edu|58|72|" "$lrows"
hasnt "G: a codex subscription (no utilization) is skipped" "codex:ac" "$lrows"
hasnt "G: an unavailable reading is skipped" "aicall" "$lrows"
has "G: a tab in a label is a space, the field count holds" "tab here|1||e58c|tab here" "$lrows"
eq "G: four rows + #ts" "5" "$(printf '%s\n' "$lrows" | grep -c .)"
cp "$G/hub_nodes" "$WORK/nodes.keep"; cp "$G/hub_limits" "$WORK/limits.keep"
NCMD='exit 1' LCMD="printf '{\"x\":1}'" hubs
cmp -s "$G/hub_nodes" "$WORK/nodes.keep" || fail "G: a failed /v1/nodes fetch must keep the last hub_nodes"
cmp -s "$G/hub_limits" "$WORK/limits.keep" || fail "G: a /v1/limits answer with no list must keep the last hub_limits"
CHECKS=$((CHECKS+2))
has "G: … and says so on stderr" "keeping the last hub_limits" "$(cat "$WORK/err")"
# their own cadence: the loop asks fleet_sessions every 2s while watched (#1481),
# the summaries keep the 10s pace — a stamp of the last attempt, hit or miss
: > "$WORK/ncalls"; rm -f "$G/hubsum.ts"
NCMD="echo n >> '$WORK/ncalls'; cat '$WORK/nodes.json'" SEVERY=10 hubs; NCMD="echo n >> '$WORK/ncalls'; cat '$WORK/nodes.json'" SEVERY=10 hubs
eq "G: two rounds inside FLEET_HUB_SUMMARY_EVERY fetch the summaries once" 1 "$(grep -c . "$WORK/ncalls")"
printf '%s\n' $(( $(date +%s) - 11 )) > "$G/hubsum.ts"
NCMD="echo n >> '$WORK/ncalls'; cat '$WORK/nodes.json'" SEVERY=10 hubs
eq "G: … and again once the stamp is older than it" 2 "$(grep -c . "$WORK/ncalls")"
# a connection-certificate identity (#1502): no seams, a hub URL, a valid
# certificate — the round asks POST /v1/fleet/summary ONCE for both summaries and
# never spends the viewer token; refused (401) → the two viewer routes with the
# token; no answer at all → nothing, the token untouched. curl / ssh-keygen are
# shims on a PATH of this leg's own; nothing reaches a network.
CB="$WORK/certbin"; mkdir -p "$CB"
for f in hub_nodes hub_limits hubsum.ts; do cp -p "$G/$f" "$WORK/$f.pre" 2>/dev/null; done   # the legs below read these
: > "$WORK/cert"; printf 'ssh-ed25519-cert-v01@openssh.com AAAA test\n' > "$WORK/cert-cert.pub"
cat > "$CB/ssh-keygen" <<'EOF'
#!/bin/sh
case "$1" in -L) printf '        Valid: forever\n' ;; -Y) cat >/dev/null; printf -- '-----BEGIN SSH SIGNATURE-----\nx\n-----END SSH SIGNATURE-----\n' ;; esac
EOF
cat > "$CB/curl" <<EOF
#!/bin/sh
out=''; url=''; auth=''; prev=''
for a in "\$@"; do
  [ "\$prev" = -o ] && out=\$a
  case "\$a" in http*) url=\$a ;; Authorization:*) auth=token ;; esac
  prev=\$a
done
printf '%s %s\n' "\${url#http://hub.test}" "\${auth:-cert}" >> '$WORK/curl.log'
case "\$url" in
  */v1/fleet/summary) code=\$(cat '$WORK/sumcode'); [ "\$code" = 200 ] && cat '$WORK/summary.json' > "\$out"; printf '%s' "\$code" ;;
  */v1/fleet/fleet_sessions*) cat '$WORK/sessions.json' > "\$out"; printf 200 ;;
  */v1/nodes) cat '$WORK/nodes.json' ;;
  */v1/limits*) cat '$WORK/limits.json' ;;
esac
EOF
chmod +x "$CB/ssh-keygen" "$CB/curl"
python3 - "$WORK/nodes.json" "$WORK/limits.json" > "$WORK/summary.json" <<'PY2'
import json, sys
n, l = (json.load(open(p)) for p in sys.argv[1:3])
print(json.dumps({"at": "x", "machines": n["machines"], "per_account": l["per_account"][:1]}))
PY2
chubs() { TMPDIR="$T/" FLEET_CONF_DIR="$CONF" FLEET_ACCOUNTS_DIR="$ACC" PATH="$CB:$WORK/bin:$PATH" CCQUOTA_FLEET=1 \
          CCQUOTA_HUB_URL=http://hub.test FLEET_CERT="$WORK/cert" CCQUOTA_VIEWER_TOKEN=tok FLEET_HUB_SUMMARY_EVERY=0 \
          FLEET_NODE_ALIASES="macmini=m5 mini2=m4" bash "$HUBS" --refresh 2>"$WORK/err"; }
rm -f "$G/hub_nodes" "$G/hub_limits" "$G/hubsum.ts"; : > "$WORK/curl.log"; echo 200 > "$WORK/sumcode"
chubs || fail "G: a certificate round failed" "$(cat "$WORK/err")"
eq "G: a certificate asks the summary door once, the token never (#1502)" "/v1/fleet/summary cert" "$(grep -v fleet_sessions "$WORK/curl.log")"
rows=$(tr '\037' '|' < "$G/hub_nodes" 2>/dev/null)
has "G: … hub_nodes from its machines: m5" "m5|online|5.65|" "$rows"
has "G: … and m4" "m4|lost|" "$rows"
has "G: … hub_limits from its per_account: the person's account" "icloud|63|65|7a7e6173" "$(tr '\037' '|' < "$G/hub_limits" 2>/dev/null)"
left=''; for f in "$G"/hubsummary.*; do [ -e "$f" ] && left=$f; done
eq "G: … and its body is not left behind" "" "$left"
rm -f "$G/hub_nodes" "$G/hub_limits"; : > "$WORK/curl.log"; echo 401 > "$WORK/sumcode"
chubs
eq "G: a refused certificate falls back to the viewer routes with the token" "/v1/fleet/summary cert
/v1/nodes token
/v1/limits?account=all token" "$(grep -v fleet_sessions "$WORK/curl.log")"
has "G: … says so" "refused the connection certificate" "$(cat "$WORK/err")"
has "G: … and writes the summaries" "m5|online" "$(tr '\037' '|' < "$G/hub_nodes" 2>/dev/null)"
rm -f "$G/hub_nodes" "$G/hub_limits"; : > "$WORK/curl.log"; echo 000 > "$WORK/sumcode"
chubs
eq "G: a hub that does not answer is no answer — the token is not spent" "/v1/fleet/summary cert" "$(grep -v fleet_sessions "$WORK/curl.log")"
[ -e "$G/hub_nodes" ] && fail "G: no answer wrote hub_nodes"; CHECKS=$((CHECKS+1))
for f in hub_nodes hub_limits hubsum.ts; do rm -f "$G/$f"; cp -p "$WORK/$f.pre" "$G/$f" 2>/dev/null; done

# ---- H: the one rule
. "$BIN/fleet-status-lib.sh"
fleet_status_node '' m5;            eq "H: no @remote → local, this machine" "local m5 " "$FSN_KIND $FSN_NODE $FSN_WID"
fleet_status_node 'm4:u/issue-9' m5; eq "H: @remote=m4:<worker_id> → remote m4, the worker" "remote m4 u/issue-9" "$FSN_KIND $FSN_NODE $FSN_WID"
fleet_status_node 'm4:' m5;          eq "H: a node with no worker still names the node" "remote m4 " "$FSN_KIND $FSN_NODE $FSN_WID"
fleet_status_node ':x' m5;           eq "H: no node → local" "local m5" "$FSN_KIND $FSN_NODE"
fleet_status_node '' '';             eq "H: no label at all → ?" "local ?" "$FSN_KIND $FSN_NODE"
fleet_status_age 59; eq "H: 59s → 0m" 0m "$FSA"; fleet_status_age 7199; eq "H: 7199s → 119m" 119m "$FSA"
fleet_status_age 7200; eq "H: 2h" 2h "$FSA"; fleet_status_age 172800; eq "H: 2d" 2d "$FSA"; fleet_status_age x; eq "H: junk → 0m" 0m "$FSA"


# ---- I: the width — narrower than 60 the label goes, the higher window stays
remote "$NOW"; nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)"; rm -f "$G/hub_ok"   # leg G rewrote all three
{ printf '#ts%s%s\n' "$US" "$NOW"; printf '%s\n' "$(j icloud 63 65 7a7e ylianghui@icloud.com)" "$(j ly297 90 72 5a77 ly297@georgetown.edu)" "$(j hot 85 92 9f9f hot@x.y)"; } > "$G/hub_limits"
HOT="sess=f1 win=@1 remote= acct=hot wsf= wscf= wsaved="
eq "I: cw=60 is wide: the label, both windows" " ${B}hot ${D}5h ${R}85% ${D}· ${D}周 ${R}92% " "$(bar $HOT cw=60)"
eq "I: cw=59 → no label, only the higher window (周 92%)" " ${D}周 ${R}92% " "$(bar $HOT cw=59)"
eq "I: cw=54, the 5h higher → only the 5h" " ${D}5h ${R}99% " "$(CF='' bar acct=icloud rl5=99 rl7=88 cw=54)"
eq "I: cw=54, one window past the line → that one, no label" " ${D}5h ${R}90% " "$(bar sess=f1 win=@1 remote= acct=ly297 wsf= wscf= wsaved= cw=54)"
eq "I: a width that is no number → wide" " ${B}hot ${D}5h ${R}85% ${D}· ${D}周 ${R}92% " "$(bar $HOT cw=x)"
eq "I: a narrow proxy window keeps its machine's name" " ${B}m4 " "$(bar $PROXY acct= cw=54)"

# ---- J: the alert counts — only when not zero, in the full order
AF="$G/alerts.ndjson"
arow() { printf '{"id":"%s","severity":"%s","subject":"s","condition":"c","value":"v","since":%s,"action":"disk","healed_at":0,"target":"","detail":"d"}\n' "$1" "$2" "$NOW"; }
plant() { : > "$AF"; for r in "$@"; do arow "${r%:*}" "${r#*:}" >> "$AF"; done; printf '%s\n' "$NOW" > "$AF.ts"; }
ALARM1='#[range=user|alarm]#[fg=#f7768e,bold]✖ 1#[nobold]#[norange]'
WARN2="#[range=user|warning]${Y}▲ 2#[norange]"
plant a1:alarm w1:warning w2:warning
eq "J: one alarm, two warnings → ✖ 1 ▲ 2, each in its range" " ${ALARM1} ${WARN2} " "$(CF='' bar)"
plant w1:warning w2:warning
eq "J: no alarm → no ✖ slot at all (#1238's fixed width is gone)" " ${WARN2} " "$(CF='' bar)"
plant a1:alarm
eq "J: an alarm alone" " ${ALARM1} " "$(CF='' bar)"
plant a1:alarm h1:healed n1:needs
eq "J: a ↻ trace and a needs row are not counted here (● N is the left side's)" " ${ALARM1} " "$(CF='' bar)"
plant a1:alarm w1:warning w2:warning
remote $(( NOW - 200 ))
eq "J: the order — machine · account · alerts · hub" \
   " ${B}m4  ${B}ly297 ${D}5h ${R}90%  ${ALARM1} ${WARN2}  ${HUBLOST} " "$(bar $PROXY acct=ly297)"
remote "$NOW"; : > "$AF"; printf '%s\n' "$NOW" > "$AF.ts"
eq "J: the counts gone → the proxy window's machine alone" " ${B}m4 " "$(bar $PROXY acct=gmail cw=54)"

# ---- K: 旧 — the machine's live install is behind the stable mark (issue #644)
remote "$NOW"; printf '%s\n' "$NOW" > "$G/hub_ok"
nodes "$NOW" "$(j m5 online 5.65 15 56 14 aaa1111 3 37035 65536 old:2)" \
             "$(j m4 online 1.57 10 25 0 bbb2222 5 4142 16384 ok)" \
             "$(j m8 online 9.00 10 90 2 ccc3333 1 14746 16384 ahead:1)" \
             "$(j m9 lost 0.00 4 10 0 ddd4444 4000 400 4096 old:9)" \
             "$(j m7 online 1.00 4 10 0 eee5555 1 400 4096 '?')" \
             "$(j m6 online 1.00 4 10 0 fff6666 1 400 4096 off)" \
             "$(j m3 online 1.00 4 10 0 ggg7777 1 400 4096)"
eq "K: this machine behind stable → its name with 旧 (the one never looked at shows it)" " ${B}m5 ${Y}旧 " "$(bar $LOCAL)"
eq "K: a proxy window onto a machine at stable → no 旧 (leg C, byte for byte)" " ${B}m4 " "$(bar $PROXY acct=)"
eq "K: ahead of stable → no 旧" " ${B}m8 " "$(px m8)"
eq "K: off stable's line → no 旧" " ${B}m6 " "$(px m6)"
eq "K: a version the checkout cannot resolve (?) → no 旧, never a guess" " ${B}m7 " "$(px m7)"
eq "K: a 10-field row (a pre-#644 cache) → no 旧" " ${B}m3 " "$(px m3)"
eq "K: a lost machine that is also old → ○ 失联 66m 旧" " ${B}m9 ${R}○ 失联 66m ${Y}旧 " "$(px m9)"
eq "K: at cw=54 旧 stays" " ${B}m5 ${Y}旧 " "$(bar $LOCAL cw=54)"
eq "K: off hub mode never" "" "$(CF='' bar $LOCAL)"
rm -f "$G/hub_ok"

# ---- L: the 54-column contract, on real clients of an isolated server
# The shipped client bar (conf/tmux-shell.conf's status lines, __BIN__ pointed at
# this tree, as fleet-shell.sh renders it) on an inner server; three OUTER isolated servers, 54 / 120 / 189 columns, each with
# one pane attached to it as a client — capture-pane on an outer pane's last line
# is the bar exactly as tmux draws it for a client that wide.
# ink <line> → the display width of what is drawn: the rstripped line less the
# fill between the left and right sides (wide characters count 2); then that
# fill's width, 0 when nothing is drawn on the right.
ink() { python3 -c '
import sys, unicodedata, re
s = sys.argv[1].rstrip()
w = lambda t: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)
gaps = [m for m in re.finditer(r" {3,}", s) if m.end() < len(s)]
g = max((m.end() - m.start() for m in gaps), default=0)
print(w(s) - g, g)' "$1"; }
if [ -z "$REAL_TMUX" ] || ! command -v python3 >/dev/null 2>&1; then
  printf 'tmux-status-selftest: no tmux / python3 — leg L skipped\n' >&2
else
  for st in normal quota alerts hublost; do
    L="$WORK/L-$st"; LG="$L/tmp/.claude-dash/global"; mkdir -p "$LG" "$L/conf/fleets/f1" "$L/acc"
    lcf=0
    printf '%s\n' "$NOW" > "$LG/hub_ok"; printf '#ts%s%s\n#me%sm5\n' "$US" "$NOW" "$US" > "$LG/remote_f1"
    : > "$LG/alerts.ndjson"
    case "$st" in
      alerts)  arow disk-low warning >> "$LG/alerts.ndjson"; arow machine-load warning >> "$LG/alerts.ndjson" ;;
      hublost) lcf=1; printf 'CCQUOTA_FLEET=1\nFLEET_SIDEBAR_SOURCE=hub\n' > "$L/conf/fleets/f1/conf"
               printf '%s\n' $(( NOW - 600 )) > "$LG/hub_ok"; printf '#ts%s%s\n#me%sm5\n' "$US" $(( NOW - 600 )) "$US" > "$LG/remote_f1" ;;
    esac
    printf '%s\n' "$NOW" > "$LG/alerts.ndjson.ts"
    sed -e "s#__BIN__#$BIN#g" -e 's#__PREFIX__#C-b#g' "$BIN/../conf/tmux-shell.conf" \
      | grep -E '^set -g (status|window-status)' > "$L/bar.conf"
    IN="$WORK/l-$st-in.sock"
    env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-}" \
      TMPDIR="$L/tmp/" FLEET_CONF_DIR="$L/conf" FLEET_ACCOUNTS_DIR="$L/acc" CCQUOTA_FLEET=$lcf \
      CCQUOTA_HUB_URL=http://127.0.0.1:9 FLEET_ALERTS_TTL=3600 FLEET_ALERTS_DISK=0 FLEET_ALERTS_MACHINE=0 \
      FLEET_CLIENT_WHERE_CMD=false FLEET_SHELL_SESSION="l-$st-none" FLEET_CLIENT_BADGE_HOST=m5 FLEET_CLIENT_BADGE_CACHE="$L/badge" \
      "$REAL_TMUX" -u -S "$IN" -f /dev/null new-session -d -s f1 -n issue-1 -x 80 -y 20 'sleep 300' \
      || fail "L: no isolated inner server"
    "$REAL_TMUX" -S "$IN" source-file "$L/bar.conf" \
      \; set -g window-status-format '' \; set -g window-status-current-format '' \
      \; set -g @login verkyyi-long \; set -g @attn_needs 2 \; set -w -t f1:issue-1 @issue 1 || fail "L: the shipped bar conf did not load"
    [ "$st" = quota ] && "$REAL_TMUX" -S "$IN" set -w -t f1:issue-1 @cc_account icloud \; set -w -t f1:issue-1 @rl5h 86 \; set -w -t f1:issue-1 @rl7d 61
    for c in 54 120 189; do
      "$REAL_TMUX" -S "$WORK/l-$st-$c.sock" -f /dev/null new-session -d -s o -x "$c" -y 12 \
        "env -u TMUX TERM=xterm-256color $REAL_TMUX -u -S '$IN' attach -t f1" || fail "L: no outer server at $c"
    done
    case "$st" in quota) tok54='5h 86%' tokw='icloud 5h 86%' ;; alerts) tok54='▲ 2' tokw='▲ 2' ;; hublost) tok54='○ 入口 10m' tokw='○ 入口 10m' ;; *) tok54='⌂ m5' tokw='⌂ m5' ;; esac
    for c in 54 120 189; do
      tok=$tokw; [ "$c" = 54 ] && tok=$tok54
      line=''
      for _ in $(seq 1 60); do
        line=$("$REAL_TMUX" -S "$WORK/l-$st-$c.sock" capture-pane -p -t o 2>/dev/null | tail -n1)
        case "$line" in *"$tok"*) case "$line" in *"⌂ m5"*) break ;; esac ;; esac   # both #() jobs drawn
        sleep 0.2
      done
      has "L: $st at $c columns — its segment" "$tok" "$line"
      # the left end is where the client runs (issue #1779): ⌂ + the machine
      has "L: $st at $c — where the client runs leads" "⌂ m5" "$line"
      hasnt "L: $st at $c — no ☰ (a node's, retired by #1714)" "☰" "$line"
      for no in 本机 负载 内存 '盘 ' '● 入口'; do hasnt "L: $st at $c — no $no" "$no" "$line"; done
      if [ "$c" = 54 ]; then
        read -r n _ <<< "$(ink "$line")"
        [ "$n" -le 30 ] || fail "L: $st at 54 columns draws $n columns of ink (> 30, the EPIC's metric)" "$line"; CHECKS=$((CHECKS+1))
        hasnt "L: $st at 54 — no 待处理" "待处理" "$line"
        [ "$st" = quota ] && hasnt "L: quota at 54 — no account label" "icloud" "$line"
        printf 'tmux-status-selftest: L %-7s 54 cols, %2s of ink: [%s]\n' "$st" "$n" "$(printf '%s' "$line" | sed 's/ *$//')"
      fi
      if [ "$st" = normal ]; then
        read -r _ g <<< "$(ink "$line")"
        [ "$g" = 0 ] || fail "L: normal at $c — something drawn on the right" "$line"; CHECKS=$((CHECKS+1))
      fi
      "$REAL_TMUX" -S "$WORK/l-$st-$c.sock" kill-server 2>/dev/null
    done
    "$REAL_TMUX" -S "$IN" kill-server 2>/dev/null
  done
fi

printf 'tmux-status-selftest: OK (%d checks) — the bar draws only what wants your hand (issue #1616): empty while all is well, ≤ 30 columns at 54 in every state\n' "$CHECKS"
