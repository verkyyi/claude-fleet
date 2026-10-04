#!/bin/bash
# tmux-status-selftest.sh — pins issue #1482 (EPIC #1479 C3): in hub mode the
# status bar shows THE MACHINE THE CURRENT SESSION IS ON, its account's quota and
# the hub — off the caches alone — and nothing else changes.
#
#   A  degenerate: no args · args with the hub off · args with the fleet on
#      FLEET_SIDEBAR_SOURCE=local · hub on but no remote_<sess> cache
#                                   → byte for byte the plain bar
#   B  a local window in hub mode   → `m5 ● │` + the live machine segment,
#                                     the account chip, `入口 ●`
#   C  a proxy window (@remote=m4:…) → m4's chip off hub_nodes: load per core
#                                     through the CPU bands, MEM as G/G; the
#                                     account chip follows @cc_account (a local
#                                     label, the hub's label, none)
#   D  a lost machine → `○ 失联 Nm` (the hub's age + the cache's); an unknown
#      one → `?`; a bad row → `–`
#   E  the hub: a stale remote_ cache → `入口 ○ 失联 Nm`; the stale knob
#   F  the window list: blank on entering hub mode (formats saved), restored on
#      leaving; no tmux call when there is nothing to do — on an ISOLATED server
#   G  fleet-hub-sessions.sh --refresh writes hub_nodes / hub_limits from the
#      seams: the alias, mem %, newest login's version, the uuid → local label
#      map, rounding, skipped rows; a failed fetch keeps the last file; off
#      (CCQUOTA_FLEET unset) writes nothing; their own cadence (FLEET_HUB_SUMMARY_EVERY)
#   H  fleet_status_node: the one rule for 「当前会话所在机器」
#
# Drives bin/tmux-status.sh, bin/fleet-status-lib.sh and bin/fleet-hub-sessions.sh.
# ps / sysctl / vm_stat / free / df are shims (as tmux-status-cache-selftest.sh);
# TMPDIR, FLEET_CONF_DIR and FLEET_ACCOUNTS_DIR are a sandbox; the one tmux server
# is on a private socket behind a PATH shim.
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
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
[ -n "${KEEP:-}" ] || trap cleanup EXIT
trap 'exit 130' INT TERM HUP
US=$'\x1f'
NOW=$(date +%s)

sh_shim() { printf '#!/bin/sh\n%s\n' "$2" > "$WORK/bin/$1"; chmod +x "$WORK/bin/$1"; }
sh_shim ps      'printf "%%CPU\n12.0\n28.0\n"'
sh_shim sysctl  'printf "4\n8589934592\n16384\n"'
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

# bar [k=v …] — the status bar in the sandbox. CF overrides CCQUOTA_FLEET (default 1).
bar() { FLEET_ALERTS_DISK=0 TMPDIR="$T/" FLEET_CONF_DIR="$CONF" FLEET_ACCOUNTS_DIR="$ACC" \
        CCQUOTA_HUB_URL=http://127.0.0.1:9 CCQUOTA_FLEET="${CF-1}" FLEET_NODE_ALIASES="box=m5" HOSTNAME=box.local \
        PATH="$WORK/bin:$PATH" bash "$BIN/tmux-status.sh" "$@" 2>/dev/null; }
# the plain bar = machine segment + (no gh segment) + the alerts bar; split them
FA='#[fg=#565f89]│ #[range=user|alarm]'
plain=$(CF='' bar); machine=${plain%%"$FA"*}; tail=${plain#"$machine"}
case "$plain" in *"$FA"*) ;; *) fail "the plain bar has no alerts segment" "$plain" ;; esac
case "$machine" in ' '*'CPU '*'MEM '*'DSK '*) CHECKS=$((CHECKS+1)) ;; *) fail "the plain bar's machine segment" "$plain" ;; esac

# caches: the sidebar's (header only matters here), hub_nodes, hub_limits
remote() { printf '#ts%s%s\n#me%sm5\n#node%sm4%sonline%s1%s%s\n' "$US" "$1" "$US" "$US" "$US" "$US" "$US" "$1" > "$G/remote_f1"; }
nodes() { # nodes <ts> <row>… (each row US-joined)
  local ts="$1"; shift; { printf '#ts%s%s\n' "$US" "$ts"; printf '%s\n' "$@"; } > "$G/hub_nodes"; }
j() { local IFS="$US"; printf '%s' "$*"; }
remote "$NOW"
nodes "$NOW" "$(j m5 online 5.65 15 56 14 1607453 3 37035 65536)" \
             "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)" \
             "$(j m8 online 9.00 10 90 2 abc 1 14746 16384)" \
             "$(j m9 lost 0.00 4 10 0 '' 4000 400 4096)" \
             "$(j m6 online 1.00 0 '' 0 '' 1 '' '')"
{ printf '#ts%s%s\n' "$US" "$NOW"; printf '%s\n' "$(j icloud 63 65 7a7e ylianghui@icloud.com)" "$(j gmail 41 13 e58c verky.yi@gmail.com)" "$(j ly297 90 72 5a77 ly297@georgetown.edu)"; } > "$G/hub_limits"
printf 'FLEET_SIDEBAR_SOURCE=hub   # per fleet\n' > "$CONF/fleets/f1/conf"
LOCAL='sess=f1 win=@1 remote= acct=icloud wsf= wscf= wsaved='

# ---- A: degenerate — the plain bar, byte for byte
eq "A: no args (the pre-#1482 conf) = the plain bar" "$plain" "$(bar)"
eq "A: args, hub off = the plain bar" "$plain" "$(CF='' bar $LOCAL)"
eq "A: args, hub off, a proxy window = the plain bar" "$plain" "$(CF='' bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)"
printf 'FLEET_SIDEBAR_SOURCE=local\n' > "$CONF/fleets/f1/conf"
eq "A: the fleet on the local source = the plain bar" "$plain" "$(bar $LOCAL)"
eq "A: the local source, a proxy window = the plain bar" "$plain" "$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)"
printf 'FLEET_SIDEBAR_SOURCE=hub\n' > "$CONF/fleets/f1/conf"
eq "A: hub, but fleet.settings says local and the fleet conf has no key → local" "$plain" "$(printf '' > "$CONF/fleets/f1/conf"; bar $LOCAL)"
printf 'export FLEET_SIDEBAR_SOURCE="hub"\n' > "$CONF/fleets/f1/conf"
mv "$G/remote_f1" "$G/remote_f1.off"
eq "A: hub on, no remote_ cache yet = the plain bar" "$plain" "$(bar $LOCAL)"
mv "$G/remote_f1.off" "$G/remote_f1"
setcalls() { grep -c set-option "$WORK/tmux.log"; }   # the alerts refresh may read tmux; the bar must never SET anything on a render
eq "A: no tmux set-option on any of those" 0 "$(setcalls)"

# ---- B: a local window in hub mode
want=" #[fg=#7aa2f7]m5 #[fg=#9ece6a]● #[fg=#565f89]│${machine}#[fg=#565f89]│ #[fg=#7aa2f7]◉ icloud #[fg=#565f89]5h #[fg=#9ece6a]63% #[fg=#565f89]周 #[fg=#9ece6a]65% #[fg=#565f89]│ #[fg=#7aa2f7]入口 #[fg=#9ece6a]● ${tail}"
eq "B: local window → m5 ● + the live machine segment + account + 入口" "$want" "$(bar $LOCAL)"
eq "B: an exported, quoted conf key reads the same" "$want" "$(bar $LOCAL)"
eq "B: a legacy flat <sess>.conf is read when there is no fleets/<sess>/conf" "$want" \
   "$(mv "$CONF/fleets/f1/conf" "$CONF/f1.conf"; bar $LOCAL; mv "$CONF/f1.conf" "$CONF/fleets/f1/conf")"
out=$(rm -f "$G/remote_f1"; printf '#ts%s%s\n' "$US" "$NOW" > "$G/remote_f1"; bar $LOCAL; remote "$NOW")
has "B: no #me line → the alias of this host's first label" " #[fg=#7aa2f7]m5 #[fg=#9ece6a]● " "$out"

# ---- C: a proxy window → that machine's chip
m4=" #[fg=#7aa2f7]m4 #[fg=#9ece6a]● #[fg=#565f89]│ #[fg=#7aa2f7]CPU #[fg=#9ece6a]15% #[fg=#565f89]│ #[fg=#7aa2f7]MEM #[fg=#9ece6a]4.0G/16.0G "
hub='#[fg=#565f89]│ #[fg=#7aa2f7]入口 #[fg=#9ece6a]● '
eq "C: @remote=m4:… → m4's load per core, memory, no account chip" "${m4}${hub}${tail}" "$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=gmail wsf= wscf= wsaved=)
eq "C: the account chip follows @cc_account (gmail)" "${m4}#[fg=#565f89]│ #[fg=#7aa2f7]◉ gmail #[fg=#565f89]5h #[fg=#9ece6a]41% #[fg=#565f89]周 #[fg=#9ece6a]13% ${hub}${tail}" "$out"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=ylianghui@icloud.com wsf= wscf= wsaved=)
has "C: the hub's own label finds the row too" "◉ ylianghui@icloud.com #[fg=#565f89]5h #[fg=#9ece6a]63%" "$out"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=nope wsf= wscf= wsaved=)
eq "C: an account the cache does not know → no chip" "${m4}${hub}${tail}" "$out"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=ly297 wsf= wscf= wsaved=)
has "C: quota colours: 90% red (FLEET_ACCOUNT_CEILING), 72% yellow (FLEET_ACCOUNT_WARN_PCT)" "5h #[fg=#f7768e]90% #[fg=#565f89]周 #[fg=#e0af68]72%" "$out"
out=$(FLEET_ACCOUNT_WARN_PCT=95 FLEET_ACCOUNT_CEILING=99 bar sess=f1 win=@2 remote=m4:u/issue-9 acct=ly297 wsf= wscf= wsaved=)
has "C: the quota bands are the account knobs" "5h #[fg=#9ece6a]90% #[fg=#565f89]周 #[fg=#9ece6a]72%" "$out"
out=$(bar sess=f1 win=@3 remote=m8:u/x acct= wsf= wscf= wsaved=)
has "C: a busy machine → CPU red, MEM red (the machine bands)" "CPU #[fg=#f7768e]90% #[fg=#565f89]│ #[fg=#7aa2f7]MEM #[fg=#f7768e]14.4G/16.0G" "$out"
out=$(bar sess=f1 win=@3 remote=m6:u/x acct= wsf= wscf= wsaved=)
has "C: a row with no cores / no memory → –, never a crash" "CPU #[fg=#565f89]– #[fg=#565f89]│ #[fg=#7aa2f7]MEM #[fg=#565f89]– " "$out"

# ---- D: lost / unknown
out=$(bar sess=f1 win=@3 remote=m9:u/x acct= wsf= wscf= wsaved=)
eq "D: a lost machine → ○ 失联 + its age (4000s → 66m)" " #[fg=#7aa2f7]m9 #[fg=#f7768e]○ 失联 66m ${hub}${tail}" "$out"
nodes $(( NOW - 300 )) "$(j m9 lost 0.00 4 10 0 '' 300 400 4096)"
out=$(bar sess=f1 win=@3 remote=m9:u/x acct= wsf= wscf= wsaved=)
has "D: the age grows with the cache's own age (300 + 300 → 10m)" " #[fg=#7aa2f7]m9 #[fg=#f7768e]○ 失联 10m " "$out"
out=$(bar sess=f1 win=@3 remote=m7:u/x acct= wsf= wscf= wsaved=)
eq "D: a machine the cache has no row for → ?" " #[fg=#7aa2f7]m7 #[fg=#565f89]? ${hub}${tail}" "$out"
rm -f "$G/hub_nodes"
out=$(bar sess=f1 win=@3 remote=m4:u/x acct= wsf= wscf= wsaved=)
eq "D: no hub_nodes at all → ?" " #[fg=#7aa2f7]m4 #[fg=#565f89]? ${hub}${tail}" "$out"
nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)"

# ---- E: the hub chip
remote $(( NOW - 200 ))
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)
eq "E: a remote_ cache older than FLEET_HUB_SESSIONS_STALE → 入口 ○ 失联 3m" "${m4}#[fg=#565f89]│ #[fg=#7aa2f7]入口 #[fg=#f7768e]○ 失联 3m ${tail}" "$out"
out=$(FLEET_HUB_SESSIONS_STALE=1000 bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)
eq "E: the stale knob is the sidebar's" "${m4}${hub}${tail}" "$out"
remote "$NOW"
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
cat > "$WORK/nodes.json" <<EOF
{"at":"x","machines":[
 {"hostname":"macmini","status":"online","sessions":14,"load1":5.65234375,"ncpu":15,"mem_free_bytes":29886201856,"mem_total_bytes":68719476736,"last_heartbeat":"$HB"},
 {"hostname":"mini2","status":"lost","sessions":0,"load1":0,"ncpu":10,"mem_free_bytes":0,"mem_total_bytes":0,"last_heartbeat":null},
 {"hostname":"","status":"online"}],
 "nodes":[
 {"hostname":"macmini","os_user":"a","fleet_version":"old","last_heartbeat":"2026-10-04T13:15:20Z"},
 {"hostname":"macmini","os_user":"b","fleet_version":"1607453c45","last_heartbeat":"2026-10-04T13:15:25Z"},
 {"hostname":"mini2","os_user":"c","fleet_version":"","last_heartbeat":"2026-10-04T13:15:23Z"}]}
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
         FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_HUB_NODES_CMD="${NCMD-cat '$WORK/nodes.json'}" \
         FLEET_HUB_LIMITS_CMD="${LCMD-cat '$WORK/limits.json'}" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
         FLEET_HUB_SUMMARY_EVERY="${SEVERY-0}" bash "$HUBS" --refresh 2>"$WORK/err"; }
rm -f "$G/hub_nodes" "$G/hub_limits"
CF='' hubs; [ -e "$G/hub_nodes" ] || [ -e "$G/hub_limits" ] && fail "G: off (CCQUOTA_FLEET unset) wrote a summary"; CHECKS=$((CHECKS+1))
hubs || fail "G: --refresh failed" "$(cat "$WORK/err")"
rows=$(tr '\037' '|' < "$G/hub_nodes")
case "$rows" in "#ts|"[0-9]*) CHECKS=$((CHECKS+1)) ;; *) fail "G: hub_nodes starts with #ts" "$rows" ;; esac
row=$(printf '%s\n' "$rows" | grep '^m5|'); row=${row%|*|*}   # drop mem_used/mem_total (exact bytes below)
case "$row" in 'm5|online|5.65|15|56|14|1607453c45|'[0-9]|'m5|online|5.65|15|56|14|1607453c45|'[0-9][0-9]) CHECKS=$((CHECKS+1)) ;;
  *) fail "G: m5's row: alias, mem %, the newest login's version, a small age" "$row" ;; esac
has "G: m5's memory in MB" "|37034|65536" "$(printf '%s\n' "$rows" | grep '^m5|')"
eq "G: a lost machine with no reading: empty mem %, no version, no age" "m4|lost|0.00|10||0|||0|0" "$(printf '%s\n' "$rows" | grep '^m4|')"
eq "G: a machine with no hostname is not a row" "3" "$(printf '%s\n' "$rows" | grep -c .)"
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

# ---- H: the one rule
. "$BIN/fleet-status-lib.sh"
fleet_status_node '' m5;            eq "H: no @remote → local, this machine" "local m5 " "$FSN_KIND $FSN_NODE $FSN_WID"
fleet_status_node 'm4:u/issue-9' m5; eq "H: @remote=m4:<worker_id> → remote m4, the worker" "remote m4 u/issue-9" "$FSN_KIND $FSN_NODE $FSN_WID"
fleet_status_node 'm4:' m5;          eq "H: a node with no worker still names the node" "remote m4 " "$FSN_KIND $FSN_NODE $FSN_WID"
fleet_status_node ':x' m5;           eq "H: no node → local" "local m5" "$FSN_KIND $FSN_NODE"
fleet_status_node '' '';             eq "H: no label at all → ?" "local ?" "$FSN_KIND $FSN_NODE"
fleet_status_age 59; eq "H: 59s → 0m" 0m "$FSA"; fleet_status_age 7199; eq "H: 7199s → 119m" 119m "$FSA"
fleet_status_age 7200; eq "H: 2h" 2h "$FSA"; fleet_status_age 172800; eq "H: 2d" 2d "$FSA"; fleet_status_age x; eq "H: junk → 0m" 0m "$FSA"

printf 'tmux-status-selftest: OK (%d checks) — the bar shows the machine the current session is on (issue #1482)\n' "$CHECKS"
