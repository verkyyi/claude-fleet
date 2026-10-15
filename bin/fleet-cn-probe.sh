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
# Prints `PASS|FAIL|INFO <layer> <detail>` lines, then `RESULT <result.json>`,
# `CLASS <class> <reason_code>` and ONE verdict line:
#   通：自动选 <route>；<route> 通 · <route> 通 …
#   不通：卡在 <layer> — <detail>
# Exit 0 通 (every layer that ran) · 1 不通 · 2 usage.
#
# One result (issue #4303): every stage is recorded with its start, end, a
# machine-readable reason_code, its evidence (redacted, under the run dir) and a
# class — `product` (the product failed the person's road), `env` (the test road
# is not there: the client box, its login, the drill identity, the pod off the
# roster) or `probe` (the probe's own machinery); only a run with no failed stage
# is 通. The run's dir, FLEET_CN_PROBE_RUNS/<run_id>/ (default
# $FLEET_CONF_DIR/global/cn-probe/runs, 0700, files 0600), holds stages.tsv,
# result.json — the verdict line above is printed FROM it
# (bin/fleet-cn-probe-result.py) — diag.json (bin/fleet-cn-probe-diag.sh, one
# read-only, redacted diagnosis of the run: versions, image digest, identity,
# admission and its readings, the credential road, the account opener;
# FLEET_CN_PROBE_DIAG=0 skips it) and ev/<stage>.txt.
#
# A Codex session's own terminal error ends its wait at once (issue #4303): the
# probe's pane holds only this round's NEW session, and a definite refusal on it
# — `unexpected status 4xx …` (403 no upstream credential, 401 …; never 408 /
# 429, and never a retrying line), a refused ssh key — fails the step with that
# reason within a poll (3 s), instead of waiting FLEET_CN_PROBE_ANSWER s. The
# prompt's own echo is never read as an answer or an error.
#
# What it leaves on the pod: one closed ticket and its task record per run; the
# Codex sessions it opened are closed — by the client's `fleet close`, else on the
# pod by their lifelong id (fleet-worker-stop.sh fid:); one that still stands is
# kept in <runs>/.left-sessions and stopped first by the next run (issue #4304). The client keeps its own connect cache
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

BIN="$(cd "$(dirname "$0")" && pwd)"
RES="$BIN/fleet-cn-probe-result.py"
RUN_ID=${FLEET_CN_PROBE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -dc 0-9a-f)}
case "$RUN_ID" in ''|*[!A-Za-z0-9_.-]*) echo "fleet-cn-probe: FLEET_CN_PROBE_RUN_ID is [A-Za-z0-9_.-]" >&2; exit 2 ;; esac
RUN_DIR=${FLEET_CN_PROBE_RUNS:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/cn-probe/runs}/$RUN_ID
umask 077
mkdir -p "$RUN_DIR/ev" || { echo "fleet-cn-probe: cannot make $RUN_DIR" >&2; exit 2; }
chmod 700 "$RUN_DIR" "$RUN_DIR/ev" 2>/dev/null
STAGES="$RUN_DIR/stages.tsv"; : > "$STAGES"
export FLEET_CN_PROBE_RUN_ID=$RUN_ID FLEET_CN_PROBE_RUN_DIR=$RUN_DIR

OKS='' T0=$(date +%s)
say() { printf '%s\n' "$*"; }
redact() { python3 "$RES" redact; }
# rec <result> <layer> <class> <reason_code> <detail> [<evidence text>] — one
# stage row; a stage runs from the previous stage's end (or the probe's start)
rec() {
  local t1 ev=''
  t1=$(date +%s)
  if [ -n "${6:-}" ]; then
    ev="ev/$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_').txt"
    printf '%s\n' "$6" | redact > "$RUN_DIR/$ev"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$T0" "$t1" "$ev" "$(printf '%s' "$5" | tr '\t\n' '  ')" >> "$STAGES"
  T0=$t1
}
# pass <layer> <detail> [<evidence>] · fail <layer> <detail> [<reason_code> [<class> [<evidence>]]]
pass() { local d; d=$(printf '%s' "$2" | redact); say "PASS $1 $d"; rec pass "$1" none ok "$d" "${3:-}"; }
fail() {
  local d; d=$(printf '%s' "$2" | redact)
  say "FAIL $1 $d"; rec fail "$1" "${4:-product}" "${3:-$(printf '%s' "${1%%:*}" | tr -c 'A-Za-z0-9' '_')_failed}" "$d" "${5:-}"
}
# verdict — the diagnosis (read-only), then the ONE result: the lines and the
# exit code come out of result.json
verdict() {
  if [ "${FLEET_CN_PROBE_DIAG:-1}" != 0 ]; then
    ${FLEET_CN_PROBE_DIAG_CMD:-bash $BIN/fleet-cn-probe-diag.sh} --run-dir "$RUN_DIR" >/dev/null 2>&1 \
      || say "INFO diag the read-only diagnosis did not finish (see $RUN_DIR)"
  fi
  python3 "$RES" render "$RUN_DIR" --oks "$OKS"
  case $? in 0) exit 0 ;; 1) exit 1 ;; esac
  say "CLASS probe result_unwritten"; say "不通：卡在 probe — the result could not be written ($RUN_DIR)"; exit 1
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
if ! out=$(ssh "${SSHO[@]}" "$CLIENT" true 2>&1); then fail client "ssh $CLIENT: $(printf '%s' "$out" | tail -1)" client_unreachable env "$out"; verdict; fi
pass client "$CLIENT"

# install
out=$(on_client 'command -v fleet && cat ~/.claude/fleet/.release 2>/dev/null | head -1; grep -h "^export FLEET_HUB_URL=" ~/.config/claude-fleet/fleet.conf')
case "$out" in */fleet*) pass install "$(printf '%s' "$out" | tr '\n' ' ')" ;; *) fail install "no fleet for $AS: $out" client_no_fleet env "$out"; verdict ;; esac
HUB=$(printf '%s\n' "$out" | sed -n 's/^export FLEET_HUB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | tail -1)
[ -n "$HUB" ] || { fail install "the client's fleet.conf names no FLEET_HUB_URL" client_no_hub_url env "$out"; verdict; }

# hub
out=$(on_client "curl -sS -m 20 -o /dev/null -w '%{http_code} %{time_total}s' $HUB/version")
case "$out" in 200*) pass hub "$HUB $out" ;; *) fail hub "$HUB $out" "$(printf '%s' "$out" | awk '{c = $1 + 0; print (c ? "hub_http_" c : "hub_unreachable")}')" product "$out"; verdict ;; esac

# cert
out=$(on_client "timeout $TMO fleet connect --cert-check")
case "$out" in PASS*) pass cert "$(printf '%s' "$out" | cut -f2-)" ;;
  # the drill identity ran out (env) or the hub refused a live certificate (product)
  *) cc=$(python3 "$RES" classify-cert "$out")
     fail cert "$(printf '%s' "$out" | tr '\t\n' '  ')" "${cc#* }" "${cc%% *}" "$out"; verdict ;; esac

# list
out=$(on_client "timeout $TMO fleet connect --pick $MACHINE")
case "$out" in *"\"machine\": \"$MACHINE\""*|*"\"hostname\": \"$MACHINE\""*) pass list "the hub lists $MACHINE for $AS" ;;
  *) fail list "the hub does not list $MACHINE for $AS: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')" machine_not_listed env "$out"; verdict ;; esac

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
  hk=$(hostkey "$out"); if [ -n "$hk" ]; then fail auto "host key: $hk" host_key product "$out"; else pass auto "picked ${picked:-?}" "$out"; OKS="自动选 ${picked:-?}"; fi
else
  fail auto "picked ${picked:-none}: $(printf '%s\n' "$out" | grep -v '^ \|^fleet connect · \|^→' | tail -3 | tr '\n' ' ')" route_auto_failed product "$out"
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
    rc_why=route_failed
    [ -z "$hk" ] || rc_why=host_key
    case "$out" in *'Permission denied (publickey'*) rc_why=key_refused ;; esac
    fail "$r" "${hk:-$(printf '%s\n' "$out" | grep -v '^rc=' | tail -3 | tr '\n' ' ')}" "$rc_why" product "$out"
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
        fail "view:$r" "drawn, then an error on screen: $(printf '%s' "$scr" | shown)" view_error product "$out"
      else
        # shellcheck disable=SC2046 # the VIEW line's words, split on purpose
        set -- $(printf '%s\n' "$out" | grep '^VIEW up ' | tail -n 1)
        pass "view:$r" "bare fleet drew the pod's view in ${3:-?}s (route ${4:-?}, first ${5:-?}ms) and stayed ${STAY}s" "$out"
      fi ;;
    'VIEW stay '*) fail "view:$r" "drawn, then gone within ${STAY}s (${st#VIEW stay }): $(printf '%s' "$scr" | shown)" view_dropped product "$out" ;;
    'VIEW noview') fail "view:$r" "bare fleet drew no view in ${VIEW_UP}s (no drawn row in thin.log): $(printf '%s' "$scr" | shown)" view_not_drawn product "$out" ;;
    'VIEW notmux'*) fail "view:$r" "no tmux for $AS on the client — cannot give fleet a terminal: ${st#VIEW notmux}" client_no_tmux probe "$out" ;;
    *) fail "view:$r" "the client step did not run: $(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')" step_not_run probe "$out" ;;
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
st=wait t0=$(date +%s) err=''
# term — a definite terminal error the NEW session itself shows (issue #4303):
# an HTTP refusal the agent gave up on, a refused key. The prompt's echo, a
# retrying line, 408 / 429 (retried by the agent) are never one.
term() {
  printf '%s\n' "$1" | grep -vF -- '只回一个词' | grep -viE 'reconnect|re-connect|retrying|retry in' | tr '\n' ' ' |
    grep -Eo 'unexpected status [0-9]{3}[^■›│]{0,220}|Permission denied \(publickey[^)]*\)|certificate (is )?(expired|revoked|not (yet )?valid)[^.]{0,80}' |
    grep -vE '^unexpected status (408|429)' | head -n 1 | sed 's/[[:space:]][[:space:]]*/ /g; s/ $//'
}
while [ $(( $(date +%s) - t0 )) -lt "$SECS" ]; do
  sleep 3
  scr=$(tmux -L $T capture-pane -p -t c 2>/dev/null)
  if printf '%s\n' "$scr" | grep -F -- "$W" | grep -vqF -- '只回一个词'; then st=answered; break; fi
  if printf '%s\n' "$scr" | grep -q '__CNP_EXIT='; then st=exited; break; fi
  err=$(term "$scr"); [ -z "$err" ] || { st=error; break; }
done
echo "CODEX $st $(( $(date +%s) - t0 ))"
[ -z "$err" ] || echo "TERM $err"
printf '%s\n' "$scr" | grep -v '^[[:space:]]*$' | tail -n 8 | sed 's/^/SCREEN /'
tmux -L $T kill-server 2>/dev/null
for k in $(comm -13 <(printf '%s\n' "$before") <(keys)); do
  if o=$(fleet close "$k" --yes 2>&1); then echo "CLOSED $k"; else echo "LEFT $k $(printf '%s' "$o" | tail -n 1 | tr '\t' ' ' | cut -c1-200)"; fi
done
fleet route "$M" auto >/dev/null 2>&1
EOS
}
codex_step() {
  local r=$1 w out st scr term why
  w=CNP$(od -An -N3 -tu4 /dev/urandom 2>/dev/null | tr -dc 0-9 | cut -c1-6)
  out=$(codex_script "$r" "$w" | on_client_s)
  st=$(printf '%s\n' "$out" | grep '^CODEX ' | tail -n 1)
  scr=$(printf '%s\n' "$out" | sed -n 's/^SCREEN //p' | grep -v "$w" | tail -n 3 | tr '\n' ' ' | shown)
  printf '%s\n' "$out" | grep '^LEFT ' | while read -r _ k why; do say "INFO codex:$r could not close the session $k it opened: ${why:-no reason given}"; done
  stop_left "codex:$r" $(printf '%s\n' "$out" | sed -n 's/^LEFT \([^ ]*\).*/\1/p')
  # shellcheck disable=SC2086 # the CODEX line's words, split on purpose
  set -- $st
  term=$(printf '%s\n' "$out" | sed -n 's/^TERM //p' | head -n 1)
  case "${2:-}" in
    answered) pass "codex:$r" "a new Codex session answered $w in ${3:-?}s" "$out" ;;
    error)    # the session's own refusal: say it at once, by what it said
      case "$term" in
        *'no upstream credential'*) why=upstream_no_credential ;;
        *'no subscription account'*) why=upstream_no_subscription ;;
        'unexpected status '*) why=upstream_http_$(printf '%s' "$term" | awk '{print $3}') ;;
        *'Permission denied'*|*certificate*) why=cert_refused ;;
        *) why=session_error ;;
      esac
      fail "codex:$r" "the new Codex session ended its turn with an error after ${3:-?}s: $term" "$why" product "$out" ;;
    exited)
      case "$scr" in
        *'REFUSED AT_CAPACITY'*) why=admit_refused ;;
        *REFUSED*) why=refused_$(printf '%s' "$scr" | sed -n 's/.*REFUSED \([A-Z_]*\).*/\1/p' | tr 'A-Z' 'a-z') ;;
        *) why=session_not_opened ;;
      esac
      fail "codex:$r" "fleet codex --new came back without a session: $scr" "$why" product "$out" ;;
    wait) fail "codex:$r" "no answer carrying $w in ${ANSWER}s: $scr" no_answer_timeout product "$out" ;;
    notmux) fail "codex:$r" "no tmux for $AS on the client — cannot give fleet a terminal: ${st#CODEX notmux}" client_no_tmux probe "$out" ;;
    *) fail "codex:$r" "the client step did not run: $(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')" step_not_run probe "$out" ;;
  esac
}

# task_script <repo> — on the pod, through `fleet connect`: a task record with
# stop_script <fleet_id…> — on the pod, through `fleet connect`: each session the
# probe opened, stopped by its lifelong id (fleet-worker-stop.sh fid:, the same
# graceful /exit the hub's worker_stop runs) — the road when the client's
# `fleet close` could not (issue #4304: eight of them piled up on the test pod,
# and its CPU gate then refused the next run's session)
stop_script() {
  printf 'M=%s TMO=%s FIDS="%s"\n' "$MACHINE" "$TMO" "$*"
  cat <<'EOS'
p=$(mktemp)
cat > "$p" <<'POD'
B=$HOME/.claude/fleet/bin
s=$(ls "$HOME/.config/claude-fleet/fleets" 2>/dev/null | head -n 1)
for f in $FIDS; do
  if [ -n "$s" ] && ${FLEET_CN_PROBE_POD_STOP:-bash $B/fleet-worker-stop.sh} "$s" "fid:$f" >/dev/null 2>&1; then echo "STOPPED $f"; else echo "STILL $f"; fi
done
POD
timeout "$TMO" fleet connect "$M" -- "FIDS='$FIDS' bash -l" < "$p" 2>&1
rm -f "$p"
EOS
}
# the probe's own leftovers: `<key> <first seen>` a line, beside the run dirs
LEFTF=$(dirname "$RUN_DIR")/.left-sessions
# stop_left <layer> <key…> — stop each on the pod; what still stands is kept in
# $LEFTF for the next run (a key is the client's `wid:<fleet>/<fleet_id>`)
stop_left() {
  local layer=$1 k f fids='' out still=''
  shift
  [ "$#" -gt 0 ] || return 0
  for k in "$@"; do f=${k##*/}; case "$f" in ''|*[!A-Za-z0-9_.:-]*) continue ;; esac; fids="$fids $f"; done
  [ -n "$fids" ] || return 0
  out=$(stop_script $fids | on_client_s)
  for k in "$@"; do
    f=${k##*/}
    if printf '%s\n' "$out" | grep -qx "STOPPED $f"; then
      say "INFO $layer stopped the session $k it opened on the pod (fleet-worker-stop.sh fid:)"
      [ ! -f "$LEFTF" ] || { grep -v "^$k " "$LEFTF" > "$LEFTF.tmp"; mv "$LEFTF.tmp" "$LEFTF"; }
    else
      still="$still $k"
      grep -q "^$k " "$LEFTF" 2>/dev/null || printf '%s %s\n' "$k" "$(date +%s)" >> "$LEFTF"
    fi
  done
  [ -z "$still" ] || say "INFO $layer left on the pod (retried next run):$still"
}
# left_sweep — an earlier run's leftovers, once a run; a key two days old is dropped
left_sweep() {
  local k t keys='' now
  [ -s "$LEFTF" ] || return 0
  now=$(date +%s)
  while read -r k t; do
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ $((now - t)) -lt 172800 ] && keys="$keys $k"
  done < "$LEFTF"
  awk -v n="$now" '$2 ~ /^[0-9]+$/ && n - $2 < 172800' "$LEFTF" > "$LEFTF.tmp"; mv "$LEFTF.tmp" "$LEFTF"
  # shellcheck disable=SC2086 # the keys, one word each
  [ -z "$keys" ] || stop_left sweep $keys
}

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
        pass task "$(printf '%s\n' "$out" | sed -n 's/^TASK repo //p') — record $t, ticket $u filed$(printf '%s\n' "$out" | grep -q '^TASK closed' && echo ' and closed again' || echo ' (NOT closed — close it by hand)')" "$out"
      else
        fail task "dispatch said 0 but printed record ${t} ticket ${u}" task_incomplete product "$out"
      fi ;;
    'TASK rc='*) why=$(printf '%s\n' "$out" | sed -n 's/^ERR //p' | tr '\n' ' '); fail task "dispatch failed (${ln#TASK }): $why" task_dispatch_failed product "$out" ;;
    *) case "$out" in
         *'TASK norepo'*) fail task "the pod's fleet hosts no repo" pod_no_repo env "$out" ;;
         *) fail task "$(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')" step_not_run probe "$out" ;;
       esac ;;
  esac
}

# the sessions an earlier run could not close (its own, by key): stopped first, so
# they never pile up on the pod and hold its CPU against this run's sessions
layer_on codex && left_sweep
for r in $ROUTES; do
  case "$r" in *[!A-Za-z0-9_.:-]*) continue ;; esac
  layer_on view && view_step "$r"
  layer_on codex && codex_step "$r"
done
layer_on task && task_step

verdict
