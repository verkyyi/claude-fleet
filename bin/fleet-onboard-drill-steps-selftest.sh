#!/bin/bash
# fleet-onboard-drill-steps-selftest.sh — steps 8–10 of bin/fleet-onboard-drill.sh
# (⑧ scratch · ⑨ attach-attachment · ⑩ node-restart-resume) run end to end in a
# sandbox (issue #3432): none of the three had ever been reached on a real
# machine, and the first real runs were going to find the drill's own bugs.
#
# What is real here: the drill script itself, every one of its keys and screen
# reads, through FLEET_DRILL_ONLY=8-10 (no login opened, none removed); tmux —
# the run's own client server (-L fleet-drill-<login>) and the "node" fleet's
# server, each on its own isolated socket, killed and restored for real.
# What stands in: the client in the pane (a small loop that draws the list the
# way the 看台 does — rows left of 「│」, the session's text right of it, the
# alternate screen, 「机器在重启」 while the node's server is down), the node's
# fleet-sessions-snapshot.sh (save pins the windows with their @fleet_id,
# restore puts them back), `fleet ls --json` (reads the node's server), sudo
# (runs as this user, HOME the target's) and, for the other-machine leg, the
# login's fleet-thin.py --run (runs the line under the remote login's HOME).
#
# Legs:
#   A  --home <this machine>: the session restarts HERE (sudo, as_sess) — 8 · 9 ·
#      10 PASS; the restart's save · kill-server · restore really happened
#   B  --home remotebox, no --invite: the drill mints its own drill person
#      (fleet-drill.sh invite --login … --home remotebox --json), and step 10
#      restarts the node over the login's client (--run --home remotebox)
#   C  --home elsewhere, the session lands on remotebox: step 8 FAILs naming both
#   D  a mint the hub refuses: exit 2, nothing run
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
DRILL="$BIN/fleet-onboard-drill.sh"
FAILS=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

# a real tmux, never the fleet's guard shim (it is a test server either way)
TMUXB=''
for d in $(printf '%s' "$PATH" | tr ':' ' '); do
  case "$d" in *tmux-shim*) continue ;; esac
  [ -x "$d/tmux" ] && { TMUXB="$d/tmux"; break; }
done
[ -n "$TMUXB" ] || { echo 'fleet-onboard-drill-steps-selftest: SKIP (no tmux)'; exit 0; }

# the drill reaches the node as its login through `env -i` (as_sess), which keeps
# no TMUX_TMPDIR: every server here lives in tmux's default dir, labels unique
unset TMUX_TMPDIR
T=$(mktemp -d "${TMPDIR:-/tmp}/odsteps.XXXXXX")
T=$(cd "$T" && pwd -P)
ID=$$
LOGIN="drill${ID}"
LOGIN=${LOGIN:0:16}
FX="odfx${ID}"                 # the node's fleet: its conf dir name = its socket label
CSOCK="fleet-drill-$LOGIN"     # the drill's own client server
cleanup() {
  TMUX='' "$TMUXB" -L "$CSOCK" kill-server >/dev/null 2>&1
  TMUX='' "$TMUXB" -L "$FX" kill-server >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
THIS=$(hostname -s 2>/dev/null || hostname)

mkdir -p "$T/shim" "$T/conf" "$T/homes/$LOGIN/.local/bin" "$T/client"
printf 'export FLEET_HUB_URL="https://hub.example"\n' > "$T/conf/fleet.conf"
for t in ssh ssh-keygen curl; do printf '#!/bin/sh\nexit 0\n' > "$T/shim/$t"; done
# sudo: as this user, HOME the target login's home under the sandbox homes
cat > "$T/shim/sudo" <<EOF
#!/bin/bash
[ "\$1" = -n ] && shift
case "\$1" in true|-v) exit 0 ;; esac
if [ "\$1" = -u ]; then u=\$2; shift 2; [ "\${1-}" = -H ] && shift
  h="$T/homes/\$u"; [ -d "\$h" ] || h="\${SHIM_REMOTE_HOME:-\$h}"
  HOME="\$h" exec "\$@"
fi
if [ "\$1" = install ]; then shift; a=(); while [ \$# -gt 0 ]; do case "\$1" in -o|-g) shift 2 ;; *) a+=("\$1"); shift ;; esac; done; exec install \${a[@]+"\${a[@]}"}; fi
exec "\$@"
EOF
chmod +x "$T/shim/"*
ln -s "$TMUXB" "$T/shim/tmux"

# node <home>: a login's fleet runtime — its conf dir, its tools' tmux, and the
# stand-in fleet-sessions-snapshot.sh (save pins name + @fleet_id, restore
# brings them back on a fresh server and says `back`)
node() {
  local h=$1
  mkdir -p "$h/.config/claude-fleet/fleets/$FX" "$h/.claude/fleet/bin" "$h/.claude/fleet/tools/bin"
  ln -sf "$TMUXB" "$h/.claude/fleet/tools/bin/tmux"
  cat > "$h/.claude/fleet/bin/fleet-sessions-snapshot.sh" <<EOF
#!/bin/bash
S=$FX
case "\$1" in
  save) tmux -L "\$S" list-windows -F '#{window_name}	#{@fleet_id}' > "\$HOME/snap.tsv" || exit 1
        echo "saved \$(grep -c . "\$HOME/snap.tsv") session(s) → \$HOME/snap.tsv" ;;
  restore)
        first=1
        while IFS='	' read -r n f; do
          if [ \$first = 1 ]; then w=\$(tmux -L "\$S" new-session -d -P -F '#{window_id}' -s "\$S" -n "\$n" 'sleep 3600'); first=0
          else w=\$(tmux -L "\$S" new-window -d -P -F '#{window_id}' -t "\$S" -n "\$n" 'sleep 3600'); fi
          tmux -L "\$S" set-option -w -t "\$w" @fleet_id "\$f"
          printf 'back\t%s\t%s\t-\n' "\$S" "\$n"
        done < "\$HOME/snap.tsv"
        echo "restore: \$(date +%s)" >> "\$HOME/restore.log" ;;
esac
EOF
  chmod +x "$h/.claude/fleet/bin/fleet-sessions-snapshot.sh"
}

# the client in the pane: the list the 看台 draws, on the alternate screen
cat > "$T/client/client.sh" <<'EOF'
#!/bin/bash
# $1 = the node's fleet socket, $2 = its machine name (for the ls stand-in), $3 = state dir
S=$1 ST=$3
unset TMUX
printf '\033[?1049h'
draw() {
  printf '\033[H\033[2J'
  if ! tmux -L "$S" has-session 2>/dev/null; then
    if [ -s "$ST/rows" ]; then echo '  机器在重启，稍等…        │'; else echo '  新任务  ⌘N              │'; fi
    return
  fi
  while IFS= read -r n; do printf '  ● %-20s │ %s\n' "$n" "$(cat "$ST/right" 2>/dev/null | head -n 1)"; done < "$ST/rows"
  [ -s "$ST/rows" ] || echo '  新任务  ⌘N              │'
  sed 1d "$ST/right" 2>/dev/null | sed 's/^/                         │ /'
}
: > "$ST/rows"
while :; do
  draw
  if IFS= read -r -t 1 line; then
    line=${line#*$'\002'c}                 # prefix c: the writing area
    [ -n "$line" ] || continue
    case "$line" in
      看图*) n=看图 f=${line##* }
             printf '%s\n' "› ${line}" > "$ST/right" ;;
      *)     n=$line f='' ; printf '› %s\n' "$line" > "$ST/right" ;;
    esac
    fid=$(printf 'f%s%s' "$RANDOM" "$RANDOM")
    if tmux -L "$S" has-session 2>/dev/null; then w=$(tmux -L "$S" new-window -d -P -F '#{window_id}' -t "$S" -n "$n" 'sleep 3600')
    else w=$(tmux -L "$S" new-session -d -P -F '#{window_id}' -s "$S" -n "$n" 'sleep 3600'); fi
    tmux -L "$S" set-option -w -t "$w" @fleet_id "$fid"
    printf '%s\n' "$n" >> "$ST/rows"
    if [ -n "$f" ]; then
      draw; sleep 1
      # the file went with the task: the session reads it at ITS machine's path
      printf '%s\n' "$(head -n 1 "$ST/right")" "收到图：$ST/node/.config/claude-fleet/attachments/a1/${f##*/}" "⏺ 红" > "$ST/right"
    fi
  fi
done
EOF
chmod +x "$T/client/client.sh"

# fleet ls --json stand-in for the login: the node's live windows, their node
fake_fleet() {
  cat > "$T/homes/$LOGIN/.local/bin/fleet" <<EOF
#!/bin/bash
[ "\$1 \$2" = 'ls --json' ] || exit 2
TMUX='' "$TMUXB" -L "$FX" list-windows -F '#{window_name}	#{@fleet_id}' 2>/dev/null | python3 -c '
import json, sys
print(json.dumps([{"name": n, "key": "wid:U/" + f, "node": sys.argv[1]} for n, f in (l.rstrip("\n").split("\t") for l in sys.stdin)]))' "\$(cat "$T/client/node-name")"
EOF
  chmod +x "$T/homes/$LOGIN/.local/bin/fleet"
}

# start_client <node home> <machine the list names>
start_client() {
  TMUX='' "$TMUXB" -L "$CSOCK" kill-server >/dev/null 2>&1
  TMUX='' "$TMUXB" -L "$FX" kill-server >/dev/null 2>&1
  rm -rf "$T/client/st"; mkdir -p "$T/client/st"
  ln -s "$1" "$T/client/st/node"
  printf '%s' "$2" > "$T/client/node-name"
  fake_fleet
  TMUX='' "$TMUXB" -L "$CSOCK" new-session -d -s drill -x 160 -y 40 \
    "PATH='$T/shim:$PATH' bash '$T/client/client.sh' '$FX' '$2' '$T/client/st'"
  sleep 1
}

# drill <args…>: the drill's steps 8–10 against that client
drill() {
  env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" TMPDIR="$T" \
    FLEET_DRILL_ONLY=8-10 FLEET_DRILL_STEP_SECS=20 FLEET_DRILL_POLL_SECS=1 FLEET_DRILL_AGENT_SECS=20 \
    FLEET_DRILL_OPENED_SECS=10 "$@"
}

# --- A: the session on THIS machine, restarted here ---------------------------
NH="$T/homes/odnode$ID"; node "$NH"
start_client "$NH" "$THIS"
out=$(drill bash "$DRILL" --login "$LOGIN" --invite fd_abcdefghijklmnopqrstuvwxyz --home "$THIS" --name first 2>&1); rc=$?
for s in scratch attach-attachment node-restart-resume; do
  if printf '%s\n' "$out" | grep -Eq "^PASS +$s "; then ok "A: step $s PASS"
  else bad "A: step $s: $(printf '%s\n' "$out" | grep -E "^(PASS|FAIL) +$s " | head -n 1) [rc $rc]"; fi
done
[ "$rc" = 0 ] && ok 'A: exit 0' || { bad "A: exit $rc"; printf '%s\n' "$out" | tail -n 25 | sed 's/^/     │ /'; }
grep -q '^restore: ' "$NH/restore.log" 2>/dev/null && ok 'A: the node server was restored for real (as_sess)' || bad 'A: no restore ran on the node'
printf '%s\n' "$out" | grep -q "on $THIS" && ok 'A: step 8 says the session is on --home' || bad 'A: no 「on <home>」 in step 8'

# --- B: --home another machine, no --invite: minted, restarted over the client --
rm -rf "$NH"                   # this machine no longer has the session's login
RH="$T/remote/$LOGIN"; node "$RH"
cat > "$T/invite.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$T/invite.args"
printf '{"person_id":"drill-ab","kind":"drill","login":"%s","host":"m4","home":"remotebox","approve_code":"fd_abcdefghijklmnopqrstuvwxyz"}\n' "$LOGIN"
EOF
cat > "$T/thin.py" <<EOF
#!/usr/bin/env python3
# fleet-thin.py --run --home <m> -- <word>… : the line, as the login on <m>
import os, subprocess, sys
a = sys.argv[1:]
assert a[0] == "--run" and a[1] == "--home", a
open("$T/thin.args", "a").write(a[2] + "\n")
env = dict(os.environ, HOME="$RH")
env.pop("FLEET_CONF_DIR", None)   # an ssh carries none of the caller's
sys.exit(subprocess.call(a[4:], env=env))
EOF
chmod +x "$T/invite.sh" "$T/thin.py"
start_client "$RH" remotebox
out=$(drill env FLEET_DRILL_INVITE_SH="$T/invite.sh" FLEET_DRILL_THIN="$T/thin.py" \
      bash "$DRILL" --login "$LOGIN" --home remotebox --name first 2>&1); rc=$?
if [ "$(cat "$T/invite.args" 2>/dev/null)" = "invite --login $LOGIN --home remotebox --json" ]; then ok 'B: the drill minted its own drill person for the home'
else bad "B: invite args: $(cat "$T/invite.args" 2>/dev/null)"; fi
for s in scratch attach-attachment node-restart-resume; do
  if printf '%s\n' "$out" | grep -Eq "^PASS +$s "; then ok "B: step $s PASS"
  else bad "B: step $s: $(printf '%s\n' "$out" | grep -E "^(PASS|FAIL) +$s " | head -n 1) [rc $rc]"; fi
done
[ "$rc" = 0 ] && ok 'B: exit 0' || { bad "B: exit $rc"; printf '%s\n' "$out" | tail -n 25 | sed 's/^/     │ /'; }
if [ "$(sort -u "$T/thin.args" 2>/dev/null)" = remotebox ] && [ "$(grep -c . "$T/thin.args")" = 2 ]; then ok 'B: save and restore went over --run --home remotebox'
else bad "B: thin calls: $(tr '\n' ' ' < "$T/thin.args" 2>/dev/null)"; fi
grep -q '^restore: ' "$RH/restore.log" 2>/dev/null && ok 'B: the remote node server was restored for real' || bad 'B: no restore ran on the remote node'
printf '%s\n' "$out" | grep -q 'restarted' && printf '%s\n' "$out" | grep -q 'on remotebox restarted' \
  && ok 'B: step 10 names the machine' || bad 'B: step 10 does not name remotebox'

# --- C: --home elsewhere, placed on remotebox: step 8 says so -------------------
start_client "$RH" remotebox
out=$(drill bash "$DRILL" --login "$LOGIN" --invite fd_abcdefghijklmnopqrstuvwxyz --home mini2 --name first 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -Eq '^FAIL +scratch +--home mini2: the session first runs on remotebox'; then ok 'C: a session off --home is a FAIL naming both (exit 1)'
else bad "C: exit $rc: $(printf '%s\n' "$out" | grep -E '^(PASS|FAIL)' | head -n 3)"; fi
printf '%s\n' "$out" | grep -Eq '^(PASS|FAIL) +attach' && bad 'C: step 9 ran after a misplaced 8' || ok 'C: nothing past step 8'

# --- D: a mint the hub refuses ---------------------------------------------------
printf '#!/bin/sh\necho "fleet-drill: the hub refused (HTTP 400): home must be a machine on the hub'"'"'s roster" >&2\nexit 1\n' > "$T/invite-no.sh"
chmod +x "$T/invite-no.sh"
out=$(drill env FLEET_DRILL_INVITE_SH="$T/invite-no.sh" bash "$DRILL" --login "$LOGIN" --home nowhere 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'did not mint a drill person for nowhere'; then ok 'D: a refused mint is exit 2, nothing run'
else bad "D: exit $rc: $(printf '%s' "$out" | head -n 3)"; fi
out=$(drill bash "$DRILL" --login drill-x1 --home m5 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'mints a drill person' && ok 'D: --home with no --invite needs a drill<x> login' || bad "D: login: exit $rc: $out"

[ "$FAILS" = 0 ] && { echo 'fleet-onboard-drill-steps-selftest: PASS'; exit 0; }
echo "fleet-onboard-drill-steps-selftest: FAIL ($FAILS)"; exit 1
