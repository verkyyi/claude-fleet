#!/bin/bash
# tmux-status-selftest.sh — pins issue #1482 (EPIC #1479 C3): in hub mode the
# status bar shows THE MACHINE THE CURRENT SESSION IS ON, its account's quota and
# the hub — off the caches alone — and nothing else changes; and issue #1534
# (EPIC #1529 E5): ONE layout in both modes, its two goldens below are the
# output-format contract (the EPIC's 改后 mockup):
#   local  ` 本机 · 负载 0.3 · 内存 38% · 盘 1% │ <alerts>`
#   hub    ` m5 ● · 负载 0.3 · 内存 38% │ icloud 5h 63% · 周 65% │ ● 入口 │ <alerts>`
#
#   A  degenerate: no args · args with the hub off · args with the fleet on
#      FLEET_SIDEBAR_SOURCE=local · hub on but no remote_<sess> cache
#                                   → byte for byte the plain (local) bar
#   B  a local window in hub mode   → `m5 ●` + the live 负载 · 内存,
#                                     the account chip, `● 入口`
#   C  a proxy window (@remote=m4:…) → m4's chip off hub_nodes: load per core
#                                     through the CPU bands, 内存 as %; the
#                                     account chip follows @cc_account (a local
#                                     label, the hub's label, none)
#   D  a lost machine → `○ 失联 Nm` (the hub's age + the cache's); an unknown
#      one → `?`; a bad row → `–`
#   E  the hub: a stale remote_ cache → `入口 ○ 失联 Nm`; the stale knob; and
#      global/hub_ok as THE word (issue #1483, EPIC #1479 C4): older than the knob
#      with a fresh cache → `入口 ○ 失联`, a proxy window's machine `○ 失联` too
#      (the hub's word on it is as old; a machine it already called lost keeps its
#      own, longer silence), a local window's chip untouched; fresh hub_ok over an
#      old #ts → `●`; an unreadable hub_ok → the #ts, as before the file
#   F  the window list: blank on entering hub mode (formats saved), restored on
#      leaving; no tmux call when there is nothing to do — on an ISOLATED server
#   G  fleet-hub-sessions.sh --refresh writes hub_nodes / hub_limits from the
#      seams: the alias, mem %, newest login's version, the uuid → local label
#      map, rounding, skipped rows; a failed fetch keeps the last file; off
#      (CCQUOTA_FLEET unset) writes nothing; their own cadence (FLEET_HUB_SUMMARY_EVERY);
#      hub_ok written on a sessions round that stood, left alone on a failed one (#1483)
#   H  fleet_status_node: the one rule for 「当前会话所在机器」
#   I  the width (`cw=`): < 120 drops 内存, < 100 负载 too, 盘 stays; none = all
#   J  the account chip off the window's own reading (`rl5=`/`rl7=`): local mode,
#      and hub mode when the hub's limits do not know the account
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

# bar [k=v …] — the status bar in the sandbox. CF overrides CCQUOTA_FLEET (default 1).
# Linux reads the load from /proc/loadavg (not shimmable): THIS machine's figure
# (本机 / m5) is masked to the shim's 1.20 on 4 cores, so the goldens hold on both
# OSes; another machine's comes off hub_nodes and is never masked.
bar() { local o
        o=$(FLEET_ALERTS_DISK=0 TMPDIR="$T/" FLEET_CONF_DIR="$CONF" FLEET_ACCOUNTS_DIR="$ACC" \
        CCQUOTA_HUB_URL=http://127.0.0.1:9 CCQUOTA_FLEET="${CF-1}" FLEET_NODE_ALIASES="box=m5" HOSTNAME=box.local \
        PATH="$WORK/bin:$PATH" bash "$BIN/tmux-status.sh" "$@" 2>/dev/null)
        case "${OSTYPE:-}" in darwin*) ;; *) o=$(printf '%s' "$o" | sed -E 's/(本机 |m5 #\[fg=#9ece6a\]● )(#\[fg=#565f89\]· 负载 )#\[fg=#[0-9a-f]+\]([0-9]+\.[0-9]|–)/\1\2#[fg=#9ece6a]0.3/') ;; esac
        printf '%s' "$o"; }
# the plain bar = machine segment + (no gh segment) + the alerts bar; split them
FA='#[fg=#565f89]│ #[range=user|alarm]'
plain=$(CF='' bar); machine=${plain%%"$FA"*}; tail=${plain#"$machine"}
case "$plain" in *"$FA"*) ;; *) fail "the plain bar has no alerts segment" "$plain" ;; esac
# the fields, as both goldens spell them: 1.20 / 4 cores → 0.3; 3125 of 8192 MB
# → 38%; df's Capacity column → 1%
LOAD='#[fg=#565f89]· 负载 #[fg=#9ece6a]0.3 '
MEM='#[fg=#565f89]· 内存 #[fg=#9ece6a]38% '
DSK='#[fg=#565f89]· 盘 #[fg=#9ece6a]1% '
GOLD_LOCAL=" #[fg=#7aa2f7]本机 ${LOAD}${MEM}${DSK}"
eq "golden (local): 本机 · 负载 · 内存 · 盘 — issue #1534's contract" "$GOLD_LOCAL" "$machine"

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
GOLD_HUB=" #[fg=#7aa2f7]m5 #[fg=#9ece6a]● ${LOAD}${MEM}#[fg=#565f89]│ #[fg=#7aa2f7]icloud #[fg=#565f89]5h #[fg=#9ece6a]63% #[fg=#565f89]· 周 #[fg=#9ece6a]65% #[fg=#565f89]│ #[fg=#9ece6a]● #[fg=#7aa2f7]入口 "
want="${GOLD_HUB}${tail}"
eq "golden (hub): a local window → m5 ● · 负载 · 内存 │ account │ ● 入口 — issue #1534's contract" "$want" "$(bar $LOCAL)"
eq "B: an exported, quoted conf key reads the same" "$want" "$(bar $LOCAL)"
eq "B: a legacy flat <sess>.conf is read when there is no fleets/<sess>/conf" "$want" \
   "$(mv "$CONF/fleets/f1/conf" "$CONF/f1.conf"; bar $LOCAL; mv "$CONF/f1.conf" "$CONF/fleets/f1/conf")"
out=$(rm -f "$G/remote_f1"; printf '#ts%s%s\n' "$US" "$NOW" > "$G/remote_f1"; bar $LOCAL; remote "$NOW")
has "B: no #me line → the alias of this host's first label" " #[fg=#7aa2f7]m5 #[fg=#9ece6a]● " "$out"

# ---- C: a proxy window → that machine's chip
m4=" #[fg=#7aa2f7]m4 #[fg=#9ece6a]● #[fg=#565f89]· 负载 #[fg=#9ece6a]0.2 #[fg=#565f89]· 内存 #[fg=#9ece6a]25% "
hub='#[fg=#565f89]│ #[fg=#9ece6a]● #[fg=#7aa2f7]入口 '
eq "C: @remote=m4:… → m4's load per core, memory, no account chip" "${m4}${hub}${tail}" "$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=gmail wsf= wscf= wsaved=)
eq "C: the account chip follows @cc_account (gmail)" "${m4}#[fg=#565f89]│ #[fg=#7aa2f7]gmail #[fg=#565f89]5h #[fg=#9ece6a]41% #[fg=#565f89]· 周 #[fg=#9ece6a]13% ${hub}${tail}" "$out"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=ylianghui@icloud.com wsf= wscf= wsaved=)
has "C: the hub's own label finds the row too" "#[fg=#7aa2f7]ylianghui@icloud.com #[fg=#565f89]5h #[fg=#9ece6a]63%" "$out"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=nope wsf= wscf= wsaved=)
eq "C: an account the cache does not know → no chip" "${m4}${hub}${tail}" "$out"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct=ly297 wsf= wscf= wsaved=)
has "C: quota colours: 90% red (FLEET_ACCOUNT_CEILING), 72% yellow (FLEET_ACCOUNT_WARN_PCT)" "5h #[fg=#f7768e]90% #[fg=#565f89]· 周 #[fg=#e0af68]72%" "$out"
out=$(FLEET_ACCOUNT_WARN_PCT=95 FLEET_ACCOUNT_CEILING=99 bar sess=f1 win=@2 remote=m4:u/issue-9 acct=ly297 wsf= wscf= wsaved=)
has "C: the quota bands are the account knobs" "5h #[fg=#9ece6a]90% #[fg=#565f89]· 周 #[fg=#9ece6a]72%" "$out"
out=$(bar sess=f1 win=@3 remote=m8:u/x acct= wsf= wscf= wsaved=)
has "C: a busy machine → 负载 red, 内存 red (the machine bands)" "负载 #[fg=#f7768e]0.9 #[fg=#565f89]· 内存 #[fg=#f7768e]90% " "$out"
out=$(bar sess=f1 win=@3 remote=m6:u/x acct= wsf= wscf= wsaved=)
has "C: a row with no cores / no memory → –, never a crash" "负载 #[fg=#565f89]– #[fg=#565f89]· 内存 #[fg=#565f89]– " "$out"

# ---- D: lost / unknown
out=$(bar sess=f1 win=@3 remote=m9:u/x acct= wsf= wscf= wsaved=)
eq "D: a lost machine → ○ 失联 + its age (4000s → 66m)" " #[fg=#7aa2f7]m9 #[fg=#f7768e]○ 失联 66m ${hub}${tail}" "$out"
nodes $(( NOW - 300 )) "$(j m9 lost 0.00 4 10 0 '' 300 400 4096)"
out=$(bar sess=f1 win=@3 remote=m9:u/x acct= wsf= wscf= wsaved=)
has "D: the age grows with the cache's own age (300 + 300 → 10m)" " #[fg=#7aa2f7]m9 #[fg=#f7768e]○ 失联 10m " "$out"
out=$(bar sess=f1 win=@3 remote=m7:u/x acct= wsf= wscf= wsaved=)
eq "D: a machine the cache has no row for → ?" " #[fg=#7aa2f7]m7 #[fg=#565f89]? ${hub}${tail}" "$out"
rm -f "$G/hub_nodes"
# No hub_nodes row (a certificate identity gets no /v1/nodes until #1502 — the
# shell on a colleague's computer, #1484): the hub's word from the sessions
# cache's #node line, online without the load, never a `?` for a machine it lists.
out=$(bar sess=f1 win=@3 remote=m4:u/x acct= wsf= wscf= wsaved=)
eq "D: no hub_nodes at all, a #node line says online → ● without the load" " #[fg=#7aa2f7]m4 #[fg=#9ece6a]● ${hub}${tail}" "$out"
out=$(bar sess=f1 win=@3 remote=m7:u/x acct= wsf= wscf= wsaved=)
eq "D: no hub_nodes and no #node line either → ?" " #[fg=#7aa2f7]m7 #[fg=#565f89]? ${hub}${tail}" "$out"
nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)"

# ---- E: the hub chip
remote $(( NOW - 200 ))
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)
HUBLOST='#[fg=#565f89]│ #[fg=#f7768e]○ #[fg=#7aa2f7]入口 #[fg=#f7768e]失联 3m '
eq "E: a remote_ cache older than FLEET_HUB_SESSIONS_STALE (no hub_ok: a loop from before #1483) → ○ 入口 失联 3m, and the proxy window's machine 失联 with it (#1483: nothing here hears it)" \
   " #[fg=#7aa2f7]m4 #[fg=#f7768e]○ 失联 3m ${HUBLOST}${tail}" "$out"
out=$(FLEET_HUB_SESSIONS_STALE=1000 bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)
eq "E: the stale knob is the sidebar's" "${m4}${hub}${tail}" "$out"
remote "$NOW"
# global/hub_ok (issue #1483): the loop's stamp of the last round that stood is
# the word once it exists — the cache's #ts only for a loop from before it
printf '%s\n' $(( NOW - 200 )) > "$G/hub_ok"
out=$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)
eq "E: hub_ok older than the knob, the remote_ cache FRESH → ○ 入口 失联 3m, and the proxy window's machine is 失联 3m too (hub_nodes says online — a word as old as the silence)" \
   " #[fg=#7aa2f7]m4 #[fg=#f7768e]○ 失联 3m ${HUBLOST}${tail}" "$out"
out=$(bar sess=f1 win=@3 remote=m7:u/x acct= wsf= wscf= wsaved=)
has "E: …a machine the cache has no row for is 失联 3m too, not ?" " #[fg=#7aa2f7]m7 #[fg=#f7768e]○ 失联 3m " "$out"
nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)" "$(j m9 lost 0.00 4 10 0 '' 4000 400 4096)"
out=$(bar sess=f1 win=@3 remote=m9:u/x acct= wsf= wscf= wsaved=)
has "E: …a machine the hub already called lost keeps its own, longer silence (66m)" " #[fg=#7aa2f7]m9 #[fg=#f7768e]○ 失联 66m " "$out"
nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)"
out=$(bar $LOCAL)
has "E: …a local window keeps its live readings and its account: 本机照常" " #[fg=#7aa2f7]m5 #[fg=#9ece6a]● ${LOAD}${MEM}#[fg=#565f89]│ #[fg=#7aa2f7]icloud " "$out"
has "E: …under the 失联 hub chip" "$HUBLOST" "$out"
printf '%s\n' "$NOW" > "$G/hub_ok"; remote $(( NOW - 200 ))
eq "E: a fresh hub_ok over an old #ts → ● 入口 (the file is the word, a 304 restamps both)" "${m4}${hub}${tail}" "$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)"
out=$(FLEET_HUB_SESSIONS_STALE=1000 bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)
printf '%s\n' $(( NOW - 200 )) > "$G/hub_ok"
eq "E: the knob applies to hub_ok" "${m4}${hub}${tail}" "$(FLEET_HUB_SESSIONS_STALE=1000 bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)"
printf 'junk\n' > "$G/hub_ok"
has "E: an unreadable hub_ok falls back to the cache's #ts (200s → 失联 3m)" "$HUBLOST" "$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved=)"
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
         FLEET_HUB_SESSIONS_CMD="${SCMD-cat '$WORK/sessions.json'}" FLEET_HUB_NODES_CMD="${NCMD-cat '$WORK/nodes.json'}" \
         FLEET_HUB_LIMITS_CMD="${LCMD-cat '$WORK/limits.json'}" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
         FLEET_HUB_SUMMARY_EVERY="${SEVERY-0}" bash "$HUBS" --refresh 2>"$WORK/err"; }
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

# ---- I: the width — 内存 goes first, then 负载; 盘 stays (issue #1534)
remote "$NOW"; nodes "$NOW" "$(j m4 online 1.57 10 25 0 1607453c45 5 4142 16384)"   # leg G rewrote both
eq "I: local, cw=200 → every field" "${GOLD_LOCAL}${tail}" "$(CF='' bar cw=200)"
eq "I: local, cw=120 → every field (the edge is < 120)" "${GOLD_LOCAL}${tail}" "$(CF='' bar cw=120)"
eq "I: local, cw=119 → 内存 dropped" " #[fg=#7aa2f7]本机 ${LOAD}${DSK}${tail}" "$(CF='' bar cw=119)"
eq "I: local, cw=99 → 负载 dropped too, 盘 stays" " #[fg=#7aa2f7]本机 ${DSK}${tail}" "$(CF='' bar cw=99)"
eq "I: a width that is no number → every field" "${GOLD_LOCAL}${tail}" "$(CF='' bar cw=x)"
has "I: hub, a local window at cw=110 → m5 ● · 负载, no 内存" " #[fg=#7aa2f7]m5 #[fg=#9ece6a]● ${LOAD}#[fg=#565f89]│ #[fg=#7aa2f7]icloud " "$(bar $LOCAL cw=110)"
has "I: hub, a proxy window at cw=90 → m4 ● alone" " #[fg=#7aa2f7]m4 #[fg=#9ece6a]● #[fg=#565f89]│ #[fg=#9ece6a]● #[fg=#7aa2f7]入口 " "$(bar sess=f1 win=@2 remote=m4:u/issue-9 acct= wsf= wscf= wsaved= cw=90)"

# ---- J: the account chip off the window's own reading (issue #1534)
ACHIP='#[fg=#565f89]│ #[fg=#7aa2f7]icloud #[fg=#565f89]5h #[fg=#9ece6a]1% #[fg=#565f89]· 周 #[fg=#e0af68]74% '
eq "J: local, acct + rl5/rl7 → 本机 … │ icloud 5h 1% · 周 74% (the mockup)" "${GOLD_LOCAL}${ACHIP}${tail}" "$(CF='' bar acct=icloud rl5=1 rl7=74)"
eq "J: local, one reading → the other is –" "${GOLD_LOCAL}#[fg=#565f89]│ #[fg=#7aa2f7]icloud #[fg=#565f89]5h #[fg=#9ece6a]1% #[fg=#565f89]· 周 #[fg=#565f89]–% ${tail}" "$(CF='' bar acct=icloud rl5=1 rl7=)"
eq "J: local, no reading → no chip" "${GOLD_LOCAL}${tail}" "$(CF='' bar acct=icloud rl5= rl7=)"
eq "J: local, junk readings → no chip" "${GOLD_LOCAL}${tail}" "$(CF='' bar acct=icloud rl5=x rl7=1.5)"
eq "J: local, a reading but no account → no chip" "${GOLD_LOCAL}${tail}" "$(CF='' bar acct= rl5=1 rl7=74)"
has "J: hub, the hub's limits win over the window's reading" "icloud #[fg=#565f89]5h #[fg=#9ece6a]63% " "$(bar $LOCAL rl5=1 rl7=74)"
has "J: hub, an account the hub does not know → the window's reading" "│ #[fg=#7aa2f7]nope #[fg=#565f89]5h #[fg=#f7768e]99% " \
    "$(bar sess=f1 win=@1 remote= acct=nope wsf= wscf= wsaved= rl5=99 rl7=2)"

printf 'tmux-status-selftest: OK (%d checks) — the bar shows the machine the current session is on (issue #1482), one layout in both modes (issue #1534)\n' "$CHECKS"
