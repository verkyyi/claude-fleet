#!/bin/bash
# fleet-orchestrator-selftest.sh — the person has ONE orchestrating session
# (issue #2117; the session is bin/fleet-orchestrator.sh, #1957).
#
# Two 承载 machines of one person (m4, m5), each its own isolated tmux server,
# conf dir and $HOME, both running `fleet-orchestrator.sh ensure` as their
# diskguard tick's home_watch does; a fake hub (FLEET_HUB_CURL) answers
# /v1/node/orchestrator from one shared holder file, like
# tokenledger/internal/api/fleet_orchestrator.go (the Go half is
# TestOrchestratorOneHolder).
#
#   A  both tick: exactly one opens it — the holder — the other says `held m5`, rc 5
#   B  the hub names m4 (home moved / m5 维护中): m5's is retired (marked, closed,
#      its conversation id kept), m4's opens; still one
#   C  the hub cannot be asked: the last answer kept stands — nothing opens, nothing closes
#   D  an old hub (404): the answer kept is forgotten, each machine decides alone (pre-#2117)
#   E  FLEET_ORCHESTRATOR=0 on the holder: it tells the hub "not here" and closes its own
#   F  no hub at all (CCQUOTA_FLEET off): opens as before — byte for byte the #1957 path
#   G  `where` prints the hub's answer
#   H  it comes back as it was (issue #2585): a closed window reopens on the same
#      conversation with the resume seed as its first turn; a Claude window on the
#      recovery page past FLEET_ORCH_REVIVE_SECS is respawned in place (same id) —
#      within the grace, or a Codex one, it is left alone
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# the real binary — never the fleet's tmux shim, which would find our own tbin/tmux again
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done
[ -n "$REAL_TMUX" ] || { echo "SKIP: no tmux"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/orch-st.XXXXXX")
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
cleanup() {
  for m in m4 m5; do "$REAL_TMUX" -S "$WORK/$m.sock" kill-server 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/tbin" "$WORK/hub"
cat > "$WORK/tbin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "\$ST_SOCK" "\$@"
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/args"\nexec sleep 600\n' "$WORK" > "$WORK/agent"
# The fake hub: mode ok | down | 404; holder sticks, "not here" moves it off.
cat > "$WORK/curl" <<'EOF'
#!/bin/bash
H="$ST_HUB"; body=''
while [ $# -gt 0 ]; do case "$1" in --data-binary) body=$2; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "$ST_ME" "$body" >> "$H/asks"
case "$(cat "$H/mode" 2>/dev/null)" in
  down) exit 7 ;;
  404) printf '{"error":"not found"}\n404'; exit 0 ;;
esac
holder=$(cat "$H/holder" 2>/dev/null)
case "$body" in
  *false*) [ "$holder" = "$ST_ME" ] && { holder=$(cat "$H/next" 2>/dev/null); printf '%s' "$holder" > "$H/holder"; } ;;
  *) [ -n "$holder" ] || { holder=$ST_ME; printf '%s' "$holder" > "$H/holder"; } ;;
esac
here=false; [ "$holder" = "$ST_ME" ] && here=true
printf '{"machine":"%s","here":%s,"rule":"holder","reason":"x"}\n200' "$holder" "$here"
EOF
chmod +x "$WORK/tbin/tmux" "$WORK/agent" "$WORK/curl"
echo ok > "$WORK/hub/mode"

for m in m4 m5; do
  mkdir -p "$WORK/$m/home" "$WORK/$m/conf"
  "$REAL_TMUX" -S "$WORK/$m.sock" -f /dev/null new-session -d -s or -n home -x 100 -y 30 'exec sh' \
    || { echo "FAIL  cannot start the isolated tmux server"; exit 1; }
done

# ens <machine> [ENV=…] — one tick of that machine's home_watch; stdout, then `rc=N`
ens() {
  local m=$1; shift
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/$m/home" FLEET_CONF_DIR="$WORK/$m/conf" FLEET_SKIP_GLOBAL_CONF=1 \
      ST_SOCK="$WORK/$m.sock" ST_ME="$m" ST_HUB="$WORK/hub" FLEET_HUB_CURL="$WORK/curl" \
      CCQUOTA_FLEET=1 CCQUOTA_TOKEN=t CCQUOTA_HUB_URL=http://hub.invalid \
      FLEET_ORCHESTRATOR=1 FLEET_AGENT=claude FLEET_ORCH_MODEL='' FLEET_WRAP_LAUNCH="$WORK/agent" \
      "$@" bash "$BIN/fleet-orchestrator.sh" ensure or 2>/dev/null
  printf 'rc=%s\n' "$?"
}
count() { "$REAL_TMUX" -S "$WORK/$1.sock" list-windows -t or -F '#{@fleet_role}' 2>/dev/null | grep -cx orchestrator; }
both()  { printf '%s+%s' "$(count m4)" "$(count m5)"; }

# A — the holder opens it, the other one does not
printf 'm5' > "$WORK/hub/holder"
o5=$(ens m5); o4=$(ens m4)
case "$o5" in @*rc=0) ;; *) bad "A: m5 (holder) did not open it: $o5" ;; esac
case "$o4" in *'held m5'*rc=5) ;; *) bad "A: m4 not told m5 holds it: $o4" ;; esac
[ "$(both)" = 0+1 ] && ok "A: two machines tick, one orchestrator (m5)" || bad "A: windows m4+m5 = $(both), want 0+1"
o5b=$(ens m5)
[ "$(both)" = 0+1 ] && [ "${o5b%%$'\n'*}" = "${o5%%$'\n'*}" ] && ok "A: the holder's next tick keeps the same window" || bad "A: second tick: $o5b / $(both)"
wid5=${o5%%$'\n'*}
fid5=$("$REAL_TMUX" -S "$WORK/m5.sock" show-options -wqv -t "$wid5" @fleet_id 2>/dev/null)

# B — the hub names m4: m5's closes, m4's opens
printf 'm4' > "$WORK/hub/holder"
o5=$(ens m5); o4=$(ens m4)
case "$o5" in *'held m4'*"retired $wid5"*rc=5) ;; *) bad "B: m5 did not retire its own: $o5" ;; esac
case "$o4" in @*rc=0) ;; *) bad "B: m4 did not open it: $o4" ;; esac
[ "$(both)" = 1+0 ] && ok "B: home moved to m4 — m5's closed, m4's opened, still one" || bad "B: windows = $(both), want 1+0"
[ -n "$fid5" ] && [ -f "$WORK/m5/conf/global/retired/$fid5" ] && ok "B: the closed one is marked retired (restore never pulls it back)" \
  || bad "B: no retired mark for m5's @fleet_id '$fid5'"
[ -s "$WORK/m5/conf/fleets/or/orchestrator.sid" ] && ok "B: m5 keeps its conversation id" || bad "B: m5's orchestrator.sid is gone"
o5=$(ens m5)
[ "$(both)" = 1+0 ] && case "$o5" in *rc=5) true ;; *) false ;; esac && ok "B: m5's next tick does not reopen it" || bad "B: m5 reopened: $o5 / $(both)"

# C — the hub cannot be asked: the kept answer stands
echo down > "$WORK/hub/mode"
o5=$(ens m5); o4=$(ens m4)
[ "$(both)" = 1+0 ] && case "$o5" in *'held m4'*rc=5) true ;; *) false ;; esac \
  && ok "C: hub silent — each machine keeps the last answer (still one)" || bad "C: $o5 / $o4 / $(both)"

# D — an old hub (404): decide alone, as before #2117
echo 404 > "$WORK/hub/mode"
o5=$(ens m5)
case "$o5" in @*rc=0) ;; *) bad "D: old hub — m5 did not decide alone: $o5" ;; esac
[ ! -e "$WORK/m5/conf/fleets/or/orchestrator.host" ] && ok "D: old hub — the kept answer is forgotten, m5 opens its own (pre-#2117)" \
  || bad "D: orchestrator.host still kept: $(cat "$WORK/m5/conf/fleets/or/orchestrator.host")"
w=$(ens m5); "$REAL_TMUX" -S "$WORK/m5.sock" kill-window -t "${w%%$'\n'*}" 2>/dev/null

# E — FLEET_ORCHESTRATOR=0 on the holder: tells the hub, closes its own
echo ok > "$WORK/hub/mode"; printf 'm4' > "$WORK/hub/holder"; printf 'm5' > "$WORK/hub/next"
o4=$(ens m4 FLEET_ORCHESTRATOR=0)
case "$o4" in *rc=3) ;; *) bad "E: off is not rc 3: $o4" ;; esac
grep -q '^m4 .*"eligible":false' "$WORK/hub/asks" && ok "E: off here — the hub is told \"not here\"" || bad "E: no eligible:false ask from m4: $(tail -3 "$WORK/hub/asks")"
o5=$(ens m5)
[ "$(both)" = 0+1 ] && ok "E: m4 closed its own, m5 took it — still one" || bad "E: windows = $(both) ($o4 / $o5)"

# F — no hub at all: the #1957 path
w=$(ens m5); "$REAL_TMUX" -S "$WORK/m5.sock" kill-window -t "${w%%$'\n'*}" 2>/dev/null
: > "$WORK/hub/asks"
o4=$(ens m4 CCQUOTA_FLEET=0)
case "$o4" in @*rc=0) ;; *) bad "F: no hub — m4 did not open it: $o4" ;; esac
[ ! -s "$WORK/hub/asks" ] && ok "F: no hub — nothing asked, opened as before" || bad "F: asked a hub that is off: $(cat "$WORK/hub/asks")"

# G — where
printf 'm4' > "$WORK/hub/holder"
w=$(env PATH="$WORK/tbin:$PATH" HOME="$WORK/m5/home" FLEET_CONF_DIR="$WORK/m5/conf" FLEET_SKIP_GLOBAL_CONF=1 \
      ST_SOCK="$WORK/m5.sock" ST_ME=m5 ST_HUB="$WORK/hub" FLEET_HUB_CURL="$WORK/curl" CCQUOTA_FLEET=1 CCQUOTA_TOKEN=t \
      CCQUOTA_HUB_URL=http://hub.invalid FLEET_ORCHESTRATOR=1 bash "$BIN/fleet-orchestrator.sh" where or 2>/dev/null)
[ "$w" = 'elsewhere m4' ] && ok "G: where — elsewhere m4" || bad "G: where = '$w'"

# H — it comes back as it was (issue #2585)
H4="$REAL_TMUX -S $WORK/m4.sock"
for x in $($H4 list-windows -t or -F '#{window_id} #{@fleet_role}' | awk '$2 == "orchestrator" { print $1 }'); do
  $H4 kill-window -t "$x"
done
: > "$WORK/args"
nargs() { wc -l < "$WORK/args" | tr -d ' '; }
waitargs() { local i=0; while [ "$(nargs)" -lt "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
o=$(ens m4 CCQUOTA_FLEET=0); wh=${o%%$'\n'*}
waitargs 1
sid=$(cat "$WORK/m4/conf/fleets/or/orchestrator.sid" 2>/dev/null)
case "$(tail -n 1 "$WORK/args")" in *"--session-id $sid"*/fleet-orchestrate*) ok "H: a new conversation starts on /fleet-orchestrate" ;;
  *) bad "H: new conversation launch = $(tail -n 1 "$WORK/args")" ;; esac
proj="$WORK/m4/home/.claude/projects/$(printf '%s' "$WORK/m4/home" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
mkdir -p "$proj"; : > "$proj/$sid.jsonl"
$H4 set-option -wq -t "$wh" @claude_state exited
$H4 set-option -wq -t "$wh" @claude_state_ts "$(date +%s)"
o=$(ens m4 CCQUOTA_FLEET=0); sleep 0.3
[ "${o%%$'\n'*}" = "$wh" ] && [ "$(nargs)" = 1 ] && ok "H: on the page within the grace — left alone" \
  || bad "H: within the grace: $o / $(nargs) launches"
$H4 set-option -wq -t "$wh" @claude_state_ts "$(( $(date +%s) - 100 ))"
$H4 set-option -wq -t "$wh" @cc_agent codex
o=$(ens m4 CCQUOTA_FLEET=0); sleep 0.3
[ "${o%%$'\n'*}" = "$wh" ] && [ "$(nargs)" = 1 ] && ok "H: a Codex orchestrator keeps its page" \
  || bad "H: codex revived: $o / $(nargs) launches"
$H4 set-option -wqu -t "$wh" @cc_agent
o=$(ens m4 CCQUOTA_FLEET=0); waitargs 2
case "$o" in "$wh"*rc=0) ;; *) bad "H: revive did not answer the same window: $o (want $wh)" ;; esac
case "$(tail -n 1 "$WORK/args")" in *"--resume $sid"*'会话刚被 fleet 接回'*) ok "H: revived in place on the same conversation, with the resume seed" ;;
  *) bad "H: revive launch = $(tail -n 1 "$WORK/args")" ;; esac
[ -z "$($H4 display-message -p -t "$wh" '#{@claude_state}')" ] || bad "H: @claude_state still exited after the revive"
[ "$(count m4)" = 1 ] || bad "H: windows = $(count m4) after the revive"
$H4 kill-window -t "$wh"
o=$(ens m4 CCQUOTA_FLEET=0); waitargs 3
case "$(tail -n 1 "$WORK/args")" in *"--resume $sid"*'会话刚被 fleet 接回'*) ok "H: a closed window reopens on the same conversation, with the resume seed" ;;
  *) bad "H: reopen launch = $(tail -n 1 "$WORK/args")" ;; esac

[ "$fails" = 0 ] && { echo "fleet-orchestrator-selftest: all passed"; exit 0; }
echo "fleet-orchestrator-selftest: $fails failed"; exit 1
