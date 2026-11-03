#!/bin/bash
# fleet-guide-region-selftest.sh — the first-login guide on a machine that cannot
# start it as it was, and a guide nobody wants any more (task FQAR).
#
# On a mainland pod (FLEET_EXEC_REGION=cn: only a DeepSeek session starts) the
# pinned `guide` window launched Claude on the fleet's default model, was refused
# by fleet-claude.sh at every start, and was reopened every three minutes; killed
# by hand after `onboarded` was written, it came straight back from its PIN row in
# restore.map. Against a REAL isolated tmux server (its own socket, never a live
# one), with dash-raw-session.sh replaced by a recorder:
#   A  the region reader: env, /etc/fleet-devnet.env (FLEET_DEVNET_ENV), nothing
#   B  on cn the tick opens the guide with --model deepseek; elsewhere without
#   C  a guide its launcher refused (@launch_refused region) stops the tick at
#      once — onboard.stuck + onboard.stuck.refused, no reopen — and the stop
#      outlives FLEET_GUIDE_STUCK_SECS (waiting changes no region)
#   D  restore of a live fleet does not reopen a pinned guide once onboarded
#      (the same row comes back while the guide is still pending)
#   E  the diskguard tick's pullback never pulls a killed pinned guide back (an
#      ordinary killed session in the same map still is)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
st_real_tmux
# never the fleet's own tmux guard (it finds `tmux` on PATH again — the shim below)
while IFS= read -r t; do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done < <(type -ap tmux)
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -)"; export PATH
export ST_MISS=1 FAIL=0   # read by selftest-lib.sh
st_sandbox "${TMPDIR:-/tmp}/guide-region.XXXXXX" physical
SOCK="$WORK/tmux.sock"
trap '"$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

st_tmux_socket "$WORK/tbin" "$SOCK" strip || st_fail "cannot write the tmux shim"
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/conf/global"
for f in "$BIN"/* "$BIN"/.[!.]*; do [ -e "$f" ] && ln -s "$f" "$WORK/bin/${f##*/}"; done
rm -f "$WORK/bin/dash-raw-session.sh"
# the recorder: one line of argv per open, and the pinned guide it would make
cat > "$WORK/bin/dash-raw-session.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/opens"
tmux new-window -d -t gr: -n guide "exec sleep 600"
tmux set-option -w -t gr:guide @pin 1
EOF
chmod +x "$WORK/bin/dash-raw-session.sh"
nt() { "$REAL_TMUX" -S "$SOCK" "$@"; }
G="$WORK/conf/global"
unset FLEET_EXEC_REGION FLEET_ONBOARD QUIET RESTORE_UNFINISHED RESTORE_KEEP_DONE RESTORE_ONLY_MAP
# gl <fn> [args] — a fleet-lib function in the sandbox (no live conf, no devnet file)
gl() {
  ( PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_DEVNET_ENV="${DEVNET:-/dev/null}" FLEET_GUIDE_COOLDOWN=0 FLEET_GUIDE_SPEAK_SECS=0
    export PATH HOME FLEET_CONF_DIR FLEET_SKIP_GLOBAL_CONF FLEET_DEVNET_ENV FLEET_GUIDE_COOLDOWN FLEET_GUIDE_SPEAK_SECS
    . "$WORK/bin/fleet-lib.sh"; "$@" ) 2>/dev/null
}
wait_open() {   # the tick's open is detached (issue #3320)
  local i=0
  while [ -e "$G/onboard.opening" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
guides() { nt list-windows -t gr -F '#{window_name} #{@pin}' 2>/dev/null | grep -c '^guide 1$'; }
opens() { grep -c . "$WORK/opens" 2>/dev/null || true; }
pending() {   # a guide the fleet should open: pending, a person here, a fresh budget
  rm -f "$G"/onboard.* "$G/onboarded"
  : > "$G/onboard.pending"; printf 'selftest\n' > "$G/onboard.person"
  printf '0\n' > "$G/onboard.tries"; printf '0\n' > "$G/onboard.retry"
}
kill_guides() {
  local w
  for w in $(nt list-windows -t gr -F '#{window_name} #{window_id}' 2>/dev/null | sed -n 's/^guide //p'); do
    nt kill-window -t "$w"
  done
}

nt -f /dev/null new-session -d -s gr -n home -x 120 -y 30 'exec sleep 600' \
  || st_fail "cannot start the isolated tmux server"

# --- A: the region reader -------------------------------------------------------
export ST_LEG=A
st_eq "cn in the env → deepseek" deepseek "$(FLEET_EXEC_REGION=cn gl fleet_region_model)"
printf 'HTTPS_PROXY=http://proxy.example.com:3128\nFLEET_EXEC_REGION=cn\n' > "$WORK/devnet.env"
st_eq "cn only in the devnet file → deepseek" deepseek "$(DEVNET="$WORK/devnet.env" gl fleet_region_model)"
st_eq "nothing → no restriction" "" "$(gl fleet_region_model)"
gl fleet_region_model >/dev/null && st_miss "no region must answer rc 1"
st_eq "an unknown value is no region" "" "$(FLEET_EXEC_REGION=mars gl fleet_exec_region)"

# --- B: the guide opens on the region's model -------------------------------------
export ST_LEG=B
pending; : > "$WORK/opens"
FLEET_EXEC_REGION=cn gl fleet_guide_tick gr; wait_open
st_eq "cn: one open" 1 "$(opens)"
st_has "cn: the guide opens on DeepSeek" "$(cat "$WORK/opens")" "--model deepseek"
st_has "cn: still a no-repo guide" "$(cat "$WORK/opens")" "--no-repo"
# a pinned guide already up on another model is reopened anew on cn, not respawned
pending; : > "$WORK/opens"
FLEET_EXEC_REGION=cn gl fleet_guide_respawn gr
st_eq "cn: a guide on the default model is replaced (one guide)" 1 "$(guides)"
st_has "cn: the replacement opens on DeepSeek" "$(cat "$WORK/opens")" "--model deepseek"
kill_guides
pending; : > "$WORK/opens"
gl fleet_guide_tick gr; wait_open
st_eq "elsewhere: one open" 1 "$(opens)"
st_hasnt "elsewhere: no model is forced" "$(cat "$WORK/opens")" "--model"
kill_guides

# --- C: a refused start stops the tick at once, and for good ----------------------
export ST_LEG=C
pending; printf '1\n' > "$G/onboard.tries"; : > "$WORK/opens"
nt new-window -d -t gr: -n guide 'exec sleep 600'; nt set-option -w -t gr:guide @pin 1
gwid=$(nt list-windows -t gr -F '#{window_name} #{window_id}' | sed -n 's/^guide //p' | head -n 1)
nt set-option -p -t "$gwid" @launch_refused region
FLEET_EXEC_REGION=cn gl fleet_guide_tick gr; wait_open
st_eq "refused: nothing reopened" 0 "$(opens)"
st_has "refused: onboard.stuck says why" "$(cat "$G/onboard.stuck" 2>/dev/null)" "启动被拒（region）"
st_eq "refused: the word is kept" region "$(cat "$G/onboard.stuck.refused" 2>/dev/null)"
st_eq "refused: the window wears it" needs "$(nt show-options -wqv -t "$gwid" @claude_state)"
printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$G/onboard.stuck.ts"   # two hours on
for _ in 1 2 3; do FLEET_EXEC_REGION=cn gl fleet_guide_tick gr; wait_open; done
st_eq "refused: a region stop is not lifted by time" 0 "$(opens)"
[ -s "$G/onboard.stuck" ] || st_miss "refused: the region stop was lifted"
# a transient refusal (a credential) lifts by time like any other stop
printf 'cred\n' > "$G/onboard.stuck.refused"
gl fleet_guide_tick gr; wait_open
[ -s "$G/onboard.stuck" ] && [ "$(cat "$G/onboard.stuck.refused" 2>/dev/null)" = region ] \
  && st_miss "refused: a credential stop must lift after FLEET_GUIDE_STUCK_SECS"
# a person's `fleet guide` (rearm) clears it
gl fleet_guide_rearm
[ -e "$G/onboard.stuck.refused" ] && st_miss "rearm: onboard.stuck.refused survived"
kill_guides

# --- D / E: fleet-restore.sh and a guide that is over -----------------------------
FID_G=0f0a0000-0000-4000-8000-00000000fa01
FID_W=0f0a0000-0000-4000-8000-00000000fa02
mkdir -p "$WORK/conf/fleets/gr" "$WORK/wt-w"
: > "$WORK/conf/fleets/gr/conf"
map() {
  { printf 'FLEET\tgr\tacme/widgets\t%s\tmain\n' "$WORK/home"
    printf 'FID\t%s\n' "$FID_G"
    printf 'WIN\tguide\t%s\t-\t-\tworking\t-\t-\t-\tclaude\t-\t-\t-\t-\t-\t-\n' "$WORK/home"
    [ "${1:-}" = with-worker ] && { printf 'FID\t%s\n' "$FID_W"
      printf 'WIN\tissue-7\t%s\t-\t7\tworking\t-\t-\t-\tclaude\t-\t-\t-\t-\t-\n' "$WORK/wt-w"; }
    printf 'PIN\t%s\n' "$FID_G"
  } > "$WORK/conf/fleets/gr/restore.map"
}
fr() {
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_DEVNET_ENV=/dev/null SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=1 FLEET_DISK_FLOOR_GB=0 \
    FLEET_WRAP_LAUNCH=/usr/bin/true bash "$WORK/bin/fleet-restore.sh" "$@" 2>&1
}

export ST_LEG=D
pending; date '+%Y-%m-%d %H:%M:%S' > "$G/onboarded"; rm -f "$G/onboard.pending"
map; out=$(fr)
st_eq "onboarded: restore does not reopen the pinned guide" 0 "$(guides)"
st_has "onboarded: restore says why" "$out" "onboarding guide is over"
pending; rm -f "$G/onboarded"; date > "$G/onboard.dismissed"
map; fr >/dev/null
st_eq "dismissed: restore does not reopen the pinned guide" 0 "$(guides)"
pending
map; fr >/dev/null
st_eq "still pending: restore brings the guide back" 1 "$(guides)"
kill_guides

export ST_LEG=E
pending; date '+%Y-%m-%d %H:%M:%S' > "$G/onboarded"; rm -f "$G/onboard.pending"
map with-worker; : > "$WORK/opens"
fr --auto >/dev/null
i=0; until nt list-windows -t gr -F '#{window_name}' 2>/dev/null | grep -qx issue-7 || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
nt list-windows -t gr -F '#{window_name}' | grep -qx issue-7 \
  || st_miss "pullback: the killed ordinary session was not pulled back (the scan did not run): $(grep pullback "$WORK/conf/restore/restore.log" 2>/dev/null | tail -n 3 | tr '\n' ' ')"
st_eq "pullback: the killed pinned guide stays closed" 0 "$(guides)"
grep -q 'pullback: gr/guide' "$WORK/conf/restore/restore.log" 2>/dev/null \
  && st_miss "pullback: the guide was queued: $(grep 'pullback: gr/guide' "$WORK/conf/restore/restore.log")"

st_done
