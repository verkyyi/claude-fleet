#!/bin/bash
# fleet-cn-probe.sh — walk a China user's real road end to end from a client in
# China, and say 通 / 不通 + the layer it stopped at (issues #4150, #4180).
#
#   bin/fleet-cn-probe.sh [--client user@host] [--key FILE] [--known-hosts FILE]
#                         [--as LOGIN] [--machine NAME] [--routes "entry relay …"]
#                         [--layers "connect view codex task"] [--repo owner/name] [--jump]
#
# Segment checks (the door port answers, the hub carries the fix) once said
# "fixed" three times while a person in China still could not get in, and nine
# separate bugs each had a green unit test (#4180). This is the person's road,
# run for real: the INSTALLED client on a China machine (default the Shenzhen
# drill box, oss-drill, reached from this computer — its security group lets
# only this machine's egress in), as a signed-in test login, against a cluster
# user pod, every route forced in turn. Layers, in order:
#
#   client   this computer → the client box (ssh)
#   install  the client's `fleet` is there
#   hub      the hub answers /version from the client
#   cert     `fleet connect --cert-check` — the hub accepts its certificate
#   list     `fleet connect --pick <machine>` — the hub lists the machine
#   table    `fleet connect <machine> --verbose --retest` — every route measured
#            (TCP + SSH banner handshakes), the table printed as is
#   auto     the route `fleet connect` picks by itself runs `hostname` on the pod
#   <route>  each route forced (`--route <name>`) runs `hostname` on the pod
#   view:<route>   bare `fleet` on a terminal (a tmux pty on the client, the
#            route pinned): the pod's view drawn (the client's thin.log says
#            `drawn` on that route) and still up FLEET_CN_PROBE_STAY s later
#            (default 30) — no `end`, the client alive, no error on screen
#   codex:<route>  `fleet codex --new '<one sentence>'` on a terminal, the route
#            pinned: a NEW Codex session on the pod answers the sentence (its
#            nonce word on a line of its own) within FLEET_CN_PROBE_ANSWER s
#            (default 300); the session is closed afterwards (`fleet close`)
#   task     on the pod, through `fleet connect`: `fleet-task-record.sh dispatch
#            --repo <hosted repo>` — a hub task record T<n> AND its ticket filed
#            (file_issue's road, no spawn); the ticket is closed again
#            (not_planned) so the probe leaves no open work behind
#
#   jump     after the entry route went through: was it the door's jump account
#            (claude-fleet#4193 — `fleet connect --route entry --print` names
#            `-l fleet-jump` in its ProxyCommand) or the old per-login road?
#            INFO by default; --jump (FLEET_CN_PROBE_JUMP=1) makes the old road a FAIL
#
# door     (only when the door refuses the key, and this computer has kubectl)
#          the door's allow list, read — is the login on it?
#
# --layers picks which of view, codex, task run (default all; `connect` is the
# road every one of them stands on, client … <route>, and always runs). A route
# is pinned only for its view / codex step and put back to auto right after.
#
# Host key: a route whose ssh says the host key is unknown / changed is FAIL.
# Prints `PASS|FAIL|INFO <layer> <detail>` lines, then ONE verdict line:
#   通：自动选 <route>；<route> 通 · <route> 通 …
#   不通：卡在 <layer> — <detail>
# Exit 0 通 (every layer that ran) · 1 不通 · 2 usage.
#
# What it leaves on the pod: one closed ticket and its task record per run; the
# Codex sessions it opened are closed. The client keeps its own connect cache
# (that is the person's state). No credential is printed or passed in an argv.
set -uo pipefail

CLIENT=${FLEET_CN_PROBE_CLIENT:-root@47.119.157.4}
KEY=${FLEET_CN_PROBE_KEY:-$HOME/fleet-secrets/oss-drill/id_oss_drill}
KH=${FLEET_CN_PROBE_KNOWN_HOSTS:-$HOME/fleet-secrets/oss-drill/known_hosts}
AS=${FLEET_CN_PROBE_LOGIN:-drillcn}
MACHINE=${FLEET_CN_PROBE_MACHINE:-u-drillcn4150}
ROUTES=${FLEET_CN_PROBE_ROUTES:-}
TMO=${FLEET_CN_PROBE_TIMEOUT:-90}
KUBECTL=${FLEET_CN_PROBE_KUBECTL:-kubectl}
DOOR_NS=${FLEET_CN_PROBE_DOOR_NS:-fleet-workers}
LAYERS=${FLEET_CN_PROBE_LAYERS:-connect view codex task}
REPO=${FLEET_CN_PROBE_REPO:-}
STAY=${FLEET_CN_PROBE_STAY:-30}
VIEW_UP=${FLEET_CN_PROBE_VIEW_UP:-30}
ANSWER=${FLEET_CN_PROBE_ANSWER:-300}
JUMP=${FLEET_CN_PROBE_JUMP:-0}

while [ $# -gt 0 ]; do
  case "$1" in
    --client) CLIENT=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --known-hosts) KH=${2:-}; shift 2 ;;
    --as) AS=${2:-}; shift 2 ;;
    --machine) MACHINE=${2:-}; shift 2 ;;
    --routes) ROUTES=${2:-}; shift 2 ;;
    --layers) LAYERS=${2:-}; shift 2 ;;
    --repo) REPO=${2:-}; shift 2 ;;
    --jump) JUMP=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "fleet-cn-probe: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$AS" in ''|*[!a-z0-9_.-]*) echo "fleet-cn-probe: --as is a login name" >&2; exit 2 ;; esac
case "$MACHINE" in ''|*[!A-Za-z0-9_.-]*) echo "fleet-cn-probe: --machine is a machine name" >&2; exit 2 ;; esac
case "$REPO" in ''|*/*) ;; *) echo "fleet-cn-probe: --repo is owner/name" >&2; exit 2 ;; esac
case "$REPO" in *[!A-Za-z0-9_./-]*) echo "fleet-cn-probe: --repo is owner/name" >&2; exit 2 ;; esac
for n in "$STAY" "$VIEW_UP" "$ANSWER"; do case "$n" in ''|*[!0-9]*) echo "fleet-cn-probe: FLEET_CN_PROBE_STAY / _VIEW_UP / _ANSWER are seconds" >&2; exit 2 ;; esac; done
layer_on() { case " $LAYERS " in *" $1 "*) return 0 ;; esac; return 1; }

STUCK='' DETAIL='' OKS=''
say() { printf '%s\n' "$*"; }
pass() { say "PASS $1 $2"; }
fail() { say "FAIL $1 $2"; [ -n "$STUCK" ] || { STUCK=$1; DETAIL=$2; }; }
verdict() {
  if [ -z "$STUCK" ]; then say "通：$OKS"; exit 0; fi
  say "不通：卡在 $STUCK — $DETAIL"; exit 1
}

SSHO=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
[ -n "$KEY" ] && SSHO+=(-i "$KEY")
[ -n "$KH" ] && SSHO+=(-o "UserKnownHostsFile=$KH")
# on_client <command…> — run as the test login on the client, a login shell so
# ~/.local/bin is on PATH; the script travels on stdin, never in an argv
on_client() {
  printf '%s\n' "$*" | ssh "${SSHO[@]}" "$CLIENT" "su - $AS -s /bin/bash" 2>&1
}
# shown — a screen's last lines for a detail line, the probe's own sentinel cut
shown() { sed 's/__CNP_EXIT=[0-9]*//g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'; }
# on_client_s — a whole script on stdin, run from a file on the client so a
# command inside it (fleet, ssh) can never read the rest of the script
on_client_s() {
  ssh "${SSHO[@]}" "$CLIENT" "su - $AS -s /bin/bash -c 'f=\$(mktemp) && cat > \$f && bash \$f </dev/null; rc=\$?; rm -f \$f; exit \$rc'" 2>&1
}

# client
if ! out=$(ssh "${SSHO[@]}" "$CLIENT" true 2>&1); then fail client "ssh $CLIENT: $(printf '%s' "$out" | tail -1)"; verdict; fi
pass client "$CLIENT"

# install
out=$(on_client 'command -v fleet && cat ~/.claude/fleet/.release 2>/dev/null | head -1; grep -h "^export FLEET_HUB_URL=" ~/.config/claude-fleet/fleet.conf')
case "$out" in */fleet*) pass install "$(printf '%s' "$out" | tr '\n' ' ')" ;; *) fail install "no fleet for $AS: $out"; verdict ;; esac
HUB=$(printf '%s\n' "$out" | sed -n 's/^export FLEET_HUB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | tail -1)
[ -n "$HUB" ] || { fail install "the client's fleet.conf names no FLEET_HUB_URL"; verdict; }

# hub
out=$(on_client "curl -sS -m 20 -o /dev/null -w '%{http_code} %{time_total}s' $HUB/version")
case "$out" in 200*) pass hub "$HUB $out" ;; *) fail hub "$HUB $out"; verdict ;; esac

# cert
out=$(on_client "timeout $TMO fleet connect --cert-check")
case "$out" in PASS*) pass cert "$(printf '%s' "$out" | cut -f2-)" ;;
  *) fail cert "$(printf '%s' "$out" | tr '\t\n' '  ')"; verdict ;; esac

# list
out=$(on_client "timeout $TMO fleet connect --pick $MACHINE")
case "$out" in *"\"machine\": \"$MACHINE\""*|*"\"hostname\": \"$MACHINE\""*) pass list "the hub lists $MACHINE for $AS" ;;
  *) fail list "the hub does not list $MACHINE for $AS: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; verdict ;; esac

# table + auto: one run, measured afresh. A forced route PINS the machine
# (`--route` = `fleet route <machine> <route>`, remembered), so every run here
# starts from and leaves the person's choice at auto.
unpin() { on_client "fleet route $MACHINE auto" >/dev/null 2>&1; }
unpin
out=$(on_client "timeout $TMO fleet connect $MACHINE --verbose --retest -- hostname; echo rc=\$?")
say "INFO table"
printf '%s\n' "$out" | sed -n '/^fleet connect · /,/^→ /p' | sed 's/^/     /'
picked=$(printf '%s\n' "$out" | sed -n 's/^→ 选中 //p' | tail -1)
# a route the table marks as not for this computer (a LAN it is not on, a
# tailnet it is not in) is named, never forced: it is not a road from here
rows=$(printf '%s\n' "$out" | sed -n '/^fleet connect · /,/^→ /p' | sed -n '3,$p' | grep -v '^→')
for r in $(printf '%s\n' "$rows" | grep -E '不在这台机器的局域网|Tailscale' | cut -c3- | awk '{print $1}'); do
  say "INFO $r not a road from this client (the table says so) — not tested"
done
[ -n "$ROUTES" ] || ROUTES=$(printf '%s\n' "$rows" | grep -vE '不在这台机器的局域网|Tailscale' | cut -c3- | awk '{print $1}' | tr '\n' ' ')
hostkey() { printf '%s' "$1" | grep -E 'REMOTE HOST IDENTIFICATION|Host key verification failed|主机钥匙' | head -1; }
if printf '%s\n' "$out" | grep -q '^rc=0$' && printf '%s\n' "$out" | grep -q "^$MACHINE"; then
  hk=$(hostkey "$out"); if [ -n "$hk" ]; then fail auto "host key: $hk"; else pass auto "picked ${picked:-?}"; OKS="自动选 ${picked:-?}"; fi
else
  fail auto "picked ${picked:-none}: $(printf '%s\n' "$out" | grep -v '^ \|^fleet connect · \|^→' | tail -3 | tr '\n' ' ')"
fi

# door_why — the door refused the key: read (never write) what the door was
# told, when this computer holds the cluster. A login missing from its allow
# list is the hub's door list (the person's entry home is not on the pod).
door_why() {
  command -v "$KUBECTL" >/dev/null 2>&1 || return 0
  local p st why
  p=$("$KUBECTL" -n "$DOOR_NS" get pod -l app.kubernetes.io/name=fleet-door -o name 2>/dev/null | head -1)
  [ -n "$p" ] || return 0
  st=$("$KUBECTL" -n "$DOOR_NS" exec "$p" -- cat /var/db/fleet-node/entry/state.json 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(d.get("allow") or []), d.get("version"))' 2>/dev/null)
  # the door's sshd says why in its own log (LogLevel VERBOSE)
  why=$("$KUBECTL" -n "$DOOR_NS" exec "$p" -- grep -E "Authentication refused|user $AS |$AS not allowed|publickey for $AS " /var/log/fleet-node/entry.log 2>/dev/null | tail -3 | tr '\n' ' ')
  case "$why" in *'account is locked'*)
    say "INFO door the door account of $AS is LOCKED (/etc/shadow !) — the door's sshd (UsePAM no) refuses it whatever the key (#4161)"; return 0 ;;
  *'bad ownership or modes'*)
    say "INFO door the door's sshd refuses every key: $(printf '%s' "$why" | sed 's/.*Authentication refused: //; s/ Failed.*//') (StrictModes, #4161)"; return 0 ;;
  esac
  case " ${st% *} " in
    *" $AS "*) say "INFO door $AS is on the door's list (v${st##* }) — the door refused its key: ${why:-nothing in its log}" ;;
    *) say "INFO door $AS is NOT on the door's list (v${st##* }: ${st% *}) — the hub routes only a person whose entry home is a user pod" ;;
  esac
}

# jump_check: which road the entry route took (claude-fleet#4193)
jump_check() {
  local pargv
  pargv=$(on_client "timeout $TMO fleet connect $MACHINE --route entry --print 2>/dev/null")
  unpin
  case "$pargv" in
    *'-W %h:%p'*'-l fleet-jump'*) pass jump "entry went through the door's jump account to the pod's own sshd"; OKS="${OKS}（跳转）" ;;
    *) if [ "$JUMP" = 1 ]; then fail jump "entry still took the door's per-login road: ${pargv:-no argv}"
       else say "INFO jump entry took the door's per-login road (the hub offers no jump here yet)"; fi ;;
  esac
}

# every route, forced
for r in $ROUTES; do
  case "$r" in *[!A-Za-z0-9_.:-]*) continue ;; esac
  out=$(on_client "timeout $TMO fleet connect $MACHINE --route $r -- hostname; echo rc=\$?")
  unpin
  hk=$(hostkey "$out")
  if printf '%s\n' "$out" | grep -q "^$MACHINE" && printf '%s\n' "$out" | grep -q '^rc=0$' && [ -z "$hk" ]; then
    pass "$r" "ran hostname on $(printf '%s\n' "$out" | grep "^$MACHINE" | head -1)"; OKS="${OKS}；$r 通"
    [ "$r" = entry ] && jump_check
  else
    fail "$r" "${hk:-$(printf '%s\n' "$out" | grep -v '^rc=' | tail -3 | tr '\n' ' ')}"
    case "$r:$out" in entry:*'Permission denied (publickey)'*) door_why ;; esac
  fi
done
# ---- the person's own screens (issue #4180) ----------------------------------
# Each runs on the client as the test login, in a tmux of the probe's own
# (`tmux -L cnprobe`, a socket nobody else uses) so the client gets a real
# terminal; the server is killed when the step ends.

# view_script <route> — bare `fleet`: the thin client draws the pod's view
view_script() {
  printf 'M=%s R=%s UPS=%s STAY=%s\n' "$MACHINE" "$1" "$VIEW_UP" "$STAY"
  cat <<'EOS'
L=$HOME/.cache/claude-fleet/thin.log T=cnprobe
fleet route "$M" "$R" >/dev/null 2>&1
n0=$(cat "$L" 2>/dev/null | wc -l)
tmux -L $T kill-server 2>/dev/null
# a server still going away from the kill above answers once (#4199): one retry,
# then tmux's own words
tn() { tmux -L $T new-session -d -s v -x 160 -y 48 "env -u TMUX -u TMUX_PANE fleet; echo __CNP_EXIT=\$?; sleep 900" 2>&1; }
e=$(tn) || { sleep 1; e=$(tn); } || { echo "VIEW notmux $(printf '%s' "$e" | tr '\n' ' ' | cut -c1-160)"; exit 0; }
new() { tail -n +$((n0 + 1)) "$L" 2>/dev/null; }
up=''
for i in $(seq 1 "$UPS"); do
  sleep 1
  row=$(new | awk -F '\t' '$2 == "drawn"' | tail -n 1)
  [ -n "$row" ] && { up=$i; break; }
  tmux -L $T capture-pane -p -t v 2>/dev/null | grep -q '__CNP_EXIT=' && break
done
if [ -z "$up" ]; then
  echo "VIEW noview"
else
  echo "VIEW up $up $(printf '%s' "$row" | awk -F '\t' '{print $4, $7}')"
  sleep "$STAY"
  ended=$(new | awk -F '\t' '$2 == "end"' | tail -n 1 | cut -f2- | tr '\t' ' ')
  alive=0; pgrep -u "$(id -u)" -f fleet-thin.py >/dev/null 2>&1 && alive=1
  echo "VIEW stay alive=$alive end=${ended:-none}"
fi
tmux -L $T capture-pane -p -t v 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 6 | sed 's/^/SCREEN /'
tmux -L $T kill-server 2>/dev/null
fleet route "$M" auto >/dev/null 2>&1
EOS
}
view_step() {
  local r=$1 out st scr
  out=$(view_script "$r" | on_client_s)
  st=$(printf '%s\n' "$out" | grep '^VIEW ' | tail -n 1)
  scr=$(printf '%s\n' "$out" | sed -n 's/^SCREEN //p' | tail -n 2 | tr '\n' ' ')
  case "$st" in
    'VIEW stay alive=1 end=none')
      if printf '%s' "$scr" | grep -qE '__CNP_EXIT=|连不上|could not|REFUSED|Permission denied'; then
        fail "view:$r" "drawn, then an error on screen: $(printf '%s' "$scr" | shown)"
      else
        # shellcheck disable=SC2046 # the VIEW line's words, split on purpose
        set -- $(printf '%s\n' "$out" | grep '^VIEW up ' | tail -n 1)
        pass "view:$r" "bare fleet drew the pod's view in ${3:-?}s (route ${4:-?}, first ${5:-?}ms) and stayed ${STAY}s"
      fi ;;
    'VIEW stay '*) fail "view:$r" "drawn, then gone within ${STAY}s (${st#VIEW stay }): $(printf '%s' "$scr" | shown)" ;;
    'VIEW noview') fail "view:$r" "bare fleet drew no view in ${VIEW_UP}s (no drawn row in thin.log): $(printf '%s' "$scr" | shown)" ;;
    'VIEW notmux'*) fail "view:$r" "no tmux for $AS on the client — cannot give fleet a terminal: ${st#VIEW notmux}" ;;
    *) fail "view:$r" "the client step did not run: $(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')" ;;
  esac
}

# codex_script <route> <word> — `fleet codex --new`: a new Codex session on the
# pod answers; every session the step opened is closed again
codex_script() {
  printf 'M=%s R=%s W=%s SECS=%s\n' "$MACHINE" "$1" "$2" "$ANSWER"
  cat <<'EOS'
T=cnprobe ASK="只回一个词：$W"
keys() { fleet ls --json 2>/dev/null | python3 -c 'import json, sys
try: rows = json.load(sys.stdin)
except Exception: rows = []
for r in rows: print(r.get("key", ""))' 2>/dev/null | sort; }
fleet route "$M" "$R" >/dev/null 2>&1
before=$(keys)
tmux -L $T kill-server 2>/dev/null
# a server still going away from the kill above answers once (#4199): one retry,
# then tmux's own words
tn() { tmux -L $T new-session -d -s c -x 160 -y 48 "env -u TMUX -u TMUX_PANE fleet codex --new '$ASK'; echo __CNP_EXIT=\$?; sleep 900" 2>&1; }
e=$(tn) || { sleep 1; e=$(tn); } || { echo "CODEX notmux $(printf '%s' "$e" | tr '\n' ' ' | cut -c1-160)"; exit 0; }
st=wait t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$SECS" ]; do
  sleep 3
  scr=$(tmux -L $T capture-pane -p -t c 2>/dev/null)
  if printf '%s\n' "$scr" | grep -F -- "$W" | grep -vqF -- '只回一个词'; then st=answered; break; fi
  if printf '%s\n' "$scr" | grep -q '__CNP_EXIT='; then st=exited; break; fi
done
echo "CODEX $st $(( $(date +%s) - t0 ))"
printf '%s\n' "$scr" | grep -v '^[[:space:]]*$' | tail -n 8 | sed 's/^/SCREEN /'
tmux -L $T kill-server 2>/dev/null
for k in $(comm -13 <(printf '%s\n' "$before") <(keys)); do
  fleet close "$k" --yes >/dev/null 2>&1 && echo "CLOSED $k" || echo "LEFT $k"
done
fleet route "$M" auto >/dev/null 2>&1
EOS
}
codex_step() {
  local r=$1 w out st scr
  w=CNP$(od -An -N3 -tu4 /dev/urandom 2>/dev/null | tr -dc 0-9 | cut -c1-6)
  out=$(codex_script "$r" "$w" | on_client_s)
  st=$(printf '%s\n' "$out" | grep '^CODEX ' | tail -n 1)
  scr=$(printf '%s\n' "$out" | sed -n 's/^SCREEN //p' | grep -v "$w" | tail -n 3 | tr '\n' ' ' | shown)
  printf '%s\n' "$out" | grep '^LEFT ' | while read -r _ k; do say "INFO codex:$r could not close the session $k it opened"; done
  # shellcheck disable=SC2086 # the CODEX line's words, split on purpose
  set -- $st
  case "${2:-}" in
    answered) pass "codex:$r" "a new Codex session answered $w in ${3:-?}s" ;;
    exited) fail "codex:$r" "fleet codex --new came back without a session: $scr" ;;
    wait) fail "codex:$r" "no answer carrying $w in ${ANSWER}s: $scr" ;;
    notmux) fail "codex:$r" "no tmux for $AS on the client — cannot give fleet a terminal: ${st#CODEX notmux}" ;;
    *) fail "codex:$r" "the client step did not run: $(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')" ;;
  esac
}

# task_script <repo> — on the pod, through `fleet connect`: a task record with
# its ticket filed on a hosted repo, then the ticket closed (not_planned)
task_script() {
  printf 'M=%s REPO=%s TMO=%s\n' "$MACHINE" "$1" "$TMO"
  cat <<'EOS'
p=$(mktemp)
cat > "$p" <<'POD'
B=$HOME/.claude/fleet/bin
if [ -z "$REPO" ]; then
  REPO=$(sed -n 's/^FLEET_REPO="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$HOME"/.config/claude-fleet/fleets/*/repos/*.conf 2>/dev/null | head -n 1)
fi
[ -n "$REPO" ] || { echo "TASK norepo"; exit 0; }
echo "TASK repo $REPO"
out=$(printf 'fleet-cn-probe (#4180): the China real-user path, run by a machine. Closed by it at once.\n' |
  bash "$B/fleet-task-record.sh" dispatch --title "cn-probe $(date -u +%Y-%m-%dT%H:%MZ)" --body-file - --repo "$REPO" 2>&1); rc=$?
t=$(printf '%s\n' "$out" | grep -E '^T[0-9]+$' | head -n 1)
u=$(printf '%s\n' "$out" | grep -E '^https?://' | head -n 1)
echo "TASK rc=$rc t=${t:--} url=${u:--}"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 2 | sed 's/^/ERR /'
n=${u##*/}
case "$n" in ''|*[!0-9]*) exit 0 ;; esac
id=$(bash "$B/fleet-ticket.sh" id "$REPO" "$n" 2>/dev/null)
bash "$B/fleet-ticket.sh" state "$id" closed --reason not_planned >/dev/null 2>&1 && echo "TASK closed $id" || echo "TASK open $id"
POD
REPO=$REPO timeout "$TMO" fleet connect "$M" -- "REPO='$REPO' bash -l" < "$p" 2>&1
rm -f "$p"
EOS
}
task_step() {
  local out ln t u why
  out=$(task_script "$REPO" | on_client_s)
  ln=$(printf '%s\n' "$out" | grep '^TASK rc=' | tail -n 1)
  t=$(printf '%s' "$ln" | sed -n 's/.* t=\([^ ]*\).*/\1/p') u=$(printf '%s' "$ln" | sed -n 's/.* url=\([^ ]*\).*/\1/p')
  case "$ln" in
    'TASK rc=0 '*)
      if [ "$t" != - ] && [ "$u" != - ]; then
        pass task "$(printf '%s\n' "$out" | sed -n 's/^TASK repo //p') — record $t, ticket $u filed$(printf '%s\n' "$out" | grep -q '^TASK closed' && echo ' and closed again' || echo ' (NOT closed — close it by hand)')"
      else
        fail task "dispatch said 0 but printed record ${t} ticket ${u}"
      fi ;;
    'TASK rc='*) why=$(printf '%s\n' "$out" | sed -n 's/^ERR //p' | tr '\n' ' '); fail task "dispatch failed (${ln#TASK }): $why" ;;
    *) case "$out" in *'TASK norepo'*) why="the pod's fleet hosts no repo" ;; *) why=$(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ') ;; esac
       fail task "$why" ;;
  esac
}

for r in $ROUTES; do
  case "$r" in *[!A-Za-z0-9_.:-]*) continue ;; esac
  layer_on view && view_step "$r"
  layer_on codex && codex_step "$r"
done
layer_on task && task_step

verdict
