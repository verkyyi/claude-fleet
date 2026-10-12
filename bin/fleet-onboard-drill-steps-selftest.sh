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
#   O  (issue #3467) B again with a thin client's list: the home's own rows (`@N`
#      keys + fleet_id) — step 10 locates and restarts by the row's @fleet_id
#   C  --home elsewhere, the session lands on remotebox: step 8 FAILs naming both
#   D  a mint the hub refuses: exit 2, nothing run
#   E  THE THIN CLIENT (issue #3445): step 8 + 8a through the REAL key path — the
#      real bin/fleet-thin.py in the drill's pane (its pty filter, its ssh argv;
#      only the ssh and the attach are stand-ins: they run the 看台's attach on a
#      local isolated socket), the real conf/tmux-view.conf key tables, the real
#      ⌘P panel (fleet-quickopen.py --view through dash-popup.sh) and its ⚡ row
#      (`do new` → go); only dash-raw-session.sh (FLEET_VIEW_NEW_CMD) and claude
#      stand in. The drill reads the panel's key off the client's own
#      dash-keymap.sh, never `prefix c`; the session turns up by its title in
#      `fleet ls --json`; claude's 「⏺ PONG」 PASSes claude-answers
#   F  the same, claude saying 「API Error: 403 …」: claude-answers FAILs quoting it
#   G  answer_state / answer_bad_line on canned screens
#   R  (issue #3458) ⚡ ↵ and the home's dash-raw-session.sh refuses (at capacity):
#      the panel says 「新会话没开起来：<its reason>」 and step 8's FAIL quotes it —
#      drill 32's FAIL ended at an empty colon
#   H  (issue #3452) ⚡ opens the session but the client's `fleet ls --json` cannot
#      be read (202937a7's spinner byte, #3444): step 8 FAILs NAMING the list, never
#      «no question, no row» — drill 30 read that as words sent to the old session
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
# ls.own (issue #3467): a thin client's list, run on its home — the home's own
# rows, a window id for a key and the identity in the fleet_id field
TMUX='' "$TMUXB" -L "$FX" list-windows -F '#{window_name}	#{@fleet_id}	#{window_id}' 2>/dev/null | python3 -c '
import json, sys
own = sys.argv[2] == "own"
print(json.dumps([dict({"name": n, "key": w if own else "wid:U/" + f, "node": sys.argv[1]}, **({"fleet_id": f} if own else {}))
                  for n, f, w in (l.rstrip("\n").split("\t") for l in sys.stdin)]))' "\$(cat "$T/client/node-name")" "\$(cat "$T/ls.own" 2>/dev/null)"
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

# --- O: the same, the list a thin client's (issue #3467): own rows of the home ----
# `@N` keys, the identity in fleet_id — step 10 locates the window by it and
# finds the session back after the restart though its window id is new
printf own > "$T/ls.own"; : > "$T/thin.args"; rm -f "$RH/restore.log"
start_client "$RH" remotebox
out=$(drill env FLEET_DRILL_INVITE_SH="$T/invite.sh" FLEET_DRILL_THIN="$T/thin.py" \
      bash "$DRILL" --login "$LOGIN" --home remotebox --name first 2>&1); rc=$?
for s in scratch attach-attachment node-restart-resume; do
  if printf '%s\n' "$out" | grep -Eq "^PASS +$s "; then ok "O: own-row keys: step $s PASS"
  else bad "O: own-row keys: step $s: $(printf '%s\n' "$out" | grep -E "^(PASS|FAIL) +$s " | head -n 1) [rc $rc]"; fi
done
[ "$rc" = 0 ] && ok 'O: exit 0' || { bad "O: exit $rc"; printf '%s\n' "$out" | tail -n 25 | sed 's/^/     │ /'; }
grep -q '^restore: ' "$RH/restore.log" 2>/dev/null && ok 'O: the home was restarted by the own row'"'"'s @fleet_id' || bad 'O: no restore ran on the home'
rm -f "$T/ls.own"

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

# --- E/F: the thin client's road, the real fleet-thin.py key path ---------------
# The home: an isolated server (-S) with the fleet `fl`, the 看台 key tables of
# conf/tmux-view.conf and the panel's environment; its first session 我的会话.
IN="$T/in.sock"
VC="$T/vconf"
LH="$T/homes/$LOGIN"
RHOME="$T/thinhome"
thin_down() {
  TMUX='' "$TMUXB" -L "$CSOCK" kill-server >/dev/null 2>&1
  TMUX='' "$TMUXB" -S "$IN" kill-server >/dev/null 2>&1
}
mkdir -p "$VC/remote-views" "$T/vg" "$T/vstate" "$RHOME/.claude/fleet/bin" "$LH/.local/share/claude-fleet/bin" "$LH/.local/bin"
# the client's own switch table, as its install carries it
ln -sf "$BIN/dash-keymap.sh" "$LH/.local/share/claude-fleet/bin/dash-keymap.sh"
# claude: its prompt, then a reply per line — PONG for pong, or the API's 403
cat > "$T/claude.sh" <<EOF
#!/bin/bash
printf '╭─ Claude Code ──────────╮\\n> '
while IFS= read -r l; do
  if [ "\$(cat "$T/claude.mode")" = apierr ]; then
    printf 'API Error: 403 {"type":"error","error":{"type":"forbidden","message":"Request not allowed"}}\\n'
  else
    case "\$l" in *pong*) printf '⏺ PONG\\n' ;; *) printf '⏺ 好的\\n' ;; esac
  fi
  printf '> '
done
EOF
# dash-raw-session.sh's stand-in (FLEET_VIEW_NEW_CMD): its argv kept, a claude
# window opened, the words its @task_line, the --print receipt back
cat > "$T/newsess.sh" <<EOF
#!/bin/sh
case " \$* " in *' --warm-only '*) exit 3 ;; esac
printf '%s\\n' "\$*" >> "$T/new.argv"
# new.mode refuse: the home's spawner says no, as the real one does (issue #3458)
if [ "\$(cat "$T/new.mode" 2>/dev/null)" = refuse ]; then
  echo 'dash-raw-session: fleet at capacity: 4/4 Claude sessions in this fleet — raise FLEET_MAX_SESSIONS or close one first' >&2
  exit 2
fi
p= prev=
for a; do [ "\$prev" = --prompt ] && p=\$a; prev=\$a; done
w=\$(TMUX= "$TMUXB" -S "$IN" new-window -d -P -F '#{window_id}' -t fl -n 我的会话 "bash '$T/claude.sh'") || exit 1
TMUX= "$TMUXB" -S "$IN" set-option -w -t "\$w" @fleet_id fnew
TMUX= "$TMUXB" -S "$IN" set-option -w -t "\$w" @task_line "\$p"
printf '%s\\t我的会话\\t\\tfnew\\n' "\$w"
EOF
# fleet-connect.py --argv's stand-in: the "ssh" below, the host at index 2
cat > "$T/argv.sh" <<EOF
#!/bin/sh
printf '{"argv": ["sh", "$T/ssh.sh", "home1"], "host": 2, "machine": "home1", "login": "$LOGIN", "route": {"kind": "direct", "name": "lan"}}\\n'
EOF
# ssh's stand-in: the remote command in the home login's HOME (its last word)
cat > "$T/ssh.sh" <<EOF
#!/bin/sh
for a; do last=\$a; done
unset TMUX TMUX_PANE
cd "$RHOME" && HOME="$RHOME" exec sh -c "\$last"
EOF
# fleet-remote-view.sh attach --thin's stand-in: the 看台 grouped onto fl with the
# fleet-view key table, its row (the token thin sent), cur, then the attach
cat > "$RHOME/.claude/fleet/bin/fleet-remote-view.sh" <<EOF
#!/bin/bash
view= token=
while [ \$# -gt 0 ]; do case \$1 in --view) view=\$2; shift ;; --token) token=\$2; shift ;; esac; shift; done
t() { TMUX= "$TMUXB" -S "$IN" "\$@"; }
t has-session -t "=fl@view-\$view" 2>/dev/null || t new-session -d -t fl -s "fl@view-\$view"
t set-option -t "fl@view-\$view" key-table fleet-view
printf '/dev/null\\tfl\\tthin\\t%s\\t%s\\tcur=U/f0\\troute=lan\\tdevice=\\ttoken=%s\\tfuid=U\\tnode=home1\\n' \\
  "\$(date +%s)" "\$\$" "\$token" > "$VC/remote-views/\$view"
printf '\\033]7502;cur;token=%s;m=home1;l=%s;w=U/f0\\007' "\$token" "\$(id -un)"
exec "$TMUXB" -S "$IN" attach -t "fl@view-\$view"
EOF
chmod +x "$T/claude.sh" "$T/newsess.sh" "$T/argv.sh" "$T/ssh.sh" "$RHOME/.claude/fleet/bin/fleet-remote-view.sh"
# the client's `fleet ls --json`: the home's windows, name + title (@task_line)
cat > "$LH/.local/bin/fleet" <<EOF
#!/bin/bash
[ "\$1 \$2" = 'ls --json' ] || exit 2
# ls.mode crash: 202937a7's list, a working row's lone spinner byte (#3444, #3452)
if [ "\$(cat "$T/ls.mode" 2>/dev/null)" = crash ]; then
  printf 'Traceback (most recent call last):\nUnicodeDecodeError: utf-8 codec cannot decode byte 0xe2 in position 812\n' >&2
  exit 1
fi
TMUX='' "$TMUXB" -S "$IN" list-windows -t fl -F '#{window_name}	#{@task_line}	#{@fleet_id}' 2>/dev/null | python3 -c '
import json, sys
print(json.dumps([{"name": n, "title": t, "key": "wid:U/" + f, "node": "home1"} for n, t, f in (l.rstrip("\\n").split("\\t") for l in sys.stdin)]))'
EOF
chmod +x "$LH/.local/bin/fleet"

# start_thin <claude mode>: the home up, the real thin client in the drill's pane
start_thin() {
  thin_down
  rm -rf "$T/new.argv" "$LH/.cache/claude-fleet/thin.log" "$VC/remote-views/"*
  printf '%s' "$1" > "$T/claude.mode"
  env -u TMUX -u TMUX_PANE HOME="$T/vhome" FLEET_CONF_DIR="$VC" FLEET_STATUS_G="$T/vg" FLEET_SWITCH_STATE="$T/vstate" \
    FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 FLEET_VIEW_NEW_CMD="sh $T/newsess.sh" \
    FLEET_VIEW_ROWS_CMD=true FLEET_DISPATCH_AGENTS_HERE=claude FLEET_AGENT=claude FLEET_VIEW_REFRESH=0 \
    "$TMUXB" -S "$IN" -f /dev/null new-session -d -s fl -x 150 -y 36 -n 我的会话 "bash '$T/claude.sh'" || return 1
  TMUX='' "$TMUXB" -S "$IN" source-file "$ROOT/conf/tmux-view.conf" || return 1
  mkdir -p "$T/vhome"
  TMUX='' "$TMUXB" -L "$CSOCK" new-session -d -s drill -x 160 -y 40 \
    "env -u XDG_CACHE_HOME -u FLEET_THIN_LOG HOME='$LH' FLEET_THIN_ARGV_CMD='sh $T/argv.sh' FLEET_THIN_UPDATE_CMD=true \
FLEET_CLIENT_XTVERSION=0 FLEET_ITERM_KEYS=0 FLEET_UI_LANG=zh FLEET_THIN_HUB_PROBE_CMD=true \
python3 '$BIN/fleet-thin.py'; sleep 600"
  local n=40
  while [ "$n" -gt 0 ]; do
    [ -s "$LH/.cache/claude-fleet/thin.log" ] && TMUX='' "$TMUXB" -L "$CSOCK" capture-pane -p -t drill | grep -q 'Claude Code' && return 0
    sleep 0.5; n=$((n - 1))
  done
  return 1
}
ROOT="$(cd "$BIN/.." && pwd)"
if command -v python3 >/dev/null 2>&1 && start_thin ok; then
  ok 'E: the real thin client is up in the drill pane, on the 看台'
  out=$(drill env FLEET_DRILL_ONLY=8 bash "$DRILL" --login "$LOGIN" --name first 2>&1); rc=$?
  for s in scratch claude-answers; do
    if printf '%s\n' "$out" | grep -Eq "^PASS +$s "; then ok "E: step $s PASS"
    else bad "E: step $s: $(printf '%s\n' "$out" | grep -E "^(PASS|FAIL|SKIP) +$s " | head -n 1) [rc $rc]"; fi
  done
  [ "$rc" = 0 ] && ok 'E: exit 0' || { bad "E: exit $rc"; printf '%s\n' "$out" | tail -n 25 | sed 's/^/     │ /'; }
  case "$(cat "$T/new.argv" 2>/dev/null)" in
    *'--no-repo'*'--prompt first'*) ok 'E: ⌘P → ⚡ ran the panel'"'"'s new session with the words (do new --prompt first)' ;;
    *) bad "E: the new-session argv: $(cat "$T/new.argv" 2>/dev/null)" ;;
  esac
  printf '%s\n' "$out" | grep -q '⌘P，敲「first」，⚡ 回车' && ok 'E: steps.md says ⌘P, never prefix c' || bad 'E: steps.md does not name ⌘P'
  # tmux's stock new-window (prefix c, drill 29) starts the default shell: no command
  TMUX='' "$TMUXB" -S "$IN" list-windows -t fl -F 'x#{pane_start_command}' | grep -qx x \
    && bad 'E: a bare shell window opened on the home (prefix c?)' || ok 'E: no stray shell window on the home'
  [ "$(TMUX='' "$TMUXB" -S "$IN" list-windows -t fl -F '#{window_name}' | grep -c 我的会话)" = 2 ] \
    && ok 'E: the panel opened a second session beside the first' || bad 'E: no second 我的会话 on the home'

  # H (issue #3452): ⚡ opened the session, but the client's `fleet ls` cannot be
  # read — the FAIL names the list, never «no question, no row»
  if start_thin ok; then
    echo crash > "$T/ls.mode"
    out=$(drill env FLEET_DRILL_ONLY=8 FLEET_DRILL_STEP_SECS=8 bash "$DRILL" --login "$LOGIN" --name first 2>&1); rc=$?
    rm -f "$T/ls.mode"
    if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -Eq '^FAIL +scratch +fleet ls --json could not be read.*UnicodeDecodeError'; then
      ok 'H: an unreadable fleet ls is named in the FAIL, not «no row»'
    else bad "H: exit $rc: $(printf '%s\n' "$out" | grep -E '^(PASS|FAIL|SKIP)' | head -n 3)"; fi
    case "$(cat "$T/new.argv" 2>/dev/null)" in
      *'--prompt first'*) ok 'H: the panel did open the new session' ;;
      *) bad "H: no new session argv: $(cat "$T/new.argv" 2>/dev/null)" ;;
    esac
  else bad 'H: the thin client did not come up'; fi

  # R (issue #3458): ⚡ ↵ and the home's spawner refuses — the panel says WHY
  # (do new's reason, not a bare 「新会话没开起来」) and the drill's FAIL quotes it
  if start_thin ok; then
    echo refuse > "$T/new.mode"
    out=$(drill env FLEET_DRILL_ONLY=8 FLEET_DRILL_STEP_SECS=20 bash "$DRILL" --login "$LOGIN" --name first 2>&1); rc=$?
    rm -f "$T/new.mode"
    if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -Eq '^FAIL +scratch +.*新会话没开起来：fleet at capacity: 4/4'; then
      ok 'R: a refused ⚡ open names its reason on the panel and in the FAIL'
    else bad "R: exit $rc: $(printf '%s\n' "$out" | grep -E '^(PASS|FAIL|SKIP)' | head -n 3)"; fi
  else bad 'R: the thin client did not come up'; fi

  if start_thin apierr; then
    out=$(drill env FLEET_DRILL_ONLY=8 bash "$DRILL" --login "$LOGIN" --name first 2>&1); rc=$?
    if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -Eq '^FAIL +claude-answers +claude cannot answer: "API Error: 403'; then
      ok 'F: an API Error is a FAIL quoting the line'
    else bad "F: exit $rc: $(printf '%s\n' "$out" | grep -E '^(PASS|FAIL|SKIP)' | head -n 3)"; fi
  else bad 'F: the thin client did not come up'; fi
  thin_down
else
  bad "E: the real thin client did not come up in the drill pane: $(TMUX='' "$TMUXB" -L "$CSOCK" capture-pane -p -t drill 2>/dev/null | sed '/^ *$/d' | tail -n 5 | tr '\n' '|')"
  thin_down
fi

# --- G: the judge on canned screens ----------------------------------------------
j() { bash "$DRILL" "$@"; }
[ "$(printf '╭─ Claude Code\n> \n⏺ PONG\n' | j --answer-state PONG)" = answered ] && ok 'G: ⏺ PONG → answered' || bad 'G: answered'
[ "$(printf '╭─ Claude Code\n> 把 pong 写成大写\n' | j --answer-state PONG)" = up ] && ok 'G: the ask alone → up' || bad 'G: up'
[ "$(printf '⏺ PONG\n  ⎿  API Error: 500 overloaded\n' | j --answer-state PONG)" = bad ] && ok 'G: API Error wins over a reply' || bad 'G: API Error'
[ "$(printf '│ Please run /login · API key\n' | j --answer-bad)" = 'Please run /login · API key' ] && ok 'G: /login quoted' || bad "G: /login: $(printf '│ Please run /login · API key\n' | j --answer-bad)"
[ "$(printf 'error: 403 Forbidden\n' | j --answer-state X)" = bad ] && ok 'G: a 403 error line → bad' || bad 'G: 403'
[ "$(printf '#403 merged · ‹ 1/2 ›\n' | j --answer-state X)" = wait ] && ok 'G: a bare 403 (an issue number) is no error' || bad 'G: bare 403'

[ "$FAILS" = 0 ] && { echo 'fleet-onboard-drill-steps-selftest: PASS'; exit 0; }
echo "fleet-onboard-drill-steps-selftest: FAIL ($FAILS)"; exit 1
