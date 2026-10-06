#!/bin/bash
# fleet-host-selftest.sh — `fleet host on|off|status` (bin/fleet-host.sh, issue
# #1806, EPIC #1813 C4): the one switch for 承载, on a sandbox HOME.
#
#   A. solo         no hub: status 未开; `on` with no terminal and no --yes
#                   changes nothing (exit 2); `on --yes` → FLEET_HOST=1, the
#                   doctor's 能力 row says 承载; `off` → FLEET_HOST=0, and the
#                   conf dir holds exactly what it did after the first write
#   B. joins        a hub, no node yet: `on --yes` runs `fleet node join` then
#                   `fleet node compute on` (in that order), the agent the join
#                   started is alive; `off` runs compute off, stops that agent,
#                   puts node.env aside — processes and config as before `on`;
#                   `on` again reuses the pass (no new join token) and the
#                   agent runs again
#   C. a node       m5: node.env + compute on + FLEET_HOST=1: `on` does nothing;
#                   `off` = compute off, the agent and node.env untouched (it
#                   was not `on` that joined)
#   D. refused      the probe says no: `on` exits 1 and FLEET_HOST stays 0
#
# Hermetic: a FAKE fleet-node.sh (the hub half is its own selftests'), a sandbox
# HOME / FLEET_CONF_DIR, `sleep` as the agent. No network, no tmux, no launchctl
# (the sandbox HOME has no LaunchAgent for agent_stop to find). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet fleet-host.sh fleet-conf.sh fleet-lib.sh fleet-doctor.sh fleet-up.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-host-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
AGENTS=''
trap 'for p in $AGENTS; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT

CHECKS=0 FAILS=0
ok()  { CHECKS=$((CHECKS + 1)); }
bad() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    | /' >&2; }
is()  { if [ "$2" = "$3" ]; then ok; else bad "$1 — want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 — lacks [$3]" "$2" ;; esac; }

# mkbox <name> → INS (bin/ = symlinks + the fake fleet-node.sh), H, CD
mkbox() {
  INS="$WORK/$1/inst"; H="$WORK/$1/home"; CD="$H/.config/claude-fleet"
  mkdir -p "$INS/bin" "$CD"
  for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$INS/bin/${f##*/}"; done
  rm -f "$INS/bin/fleet-node.sh"
  cat > "$INS/bin/fleet-node.sh" <<'FAKE'
#!/bin/bash
# fake `fleet node` — records each call; join = node.env + a detached agent
CONF="$FLEET_CONF_DIR"; ENVF="$CONF/node.env"
echo "$*" >> "$CONF/node-calls"
case "$1 ${2:-}" in
  "join "*)
    [ -f "$ENVF" ] || { printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=pass-%s\nCCQUOTA_FLEET_COMPUTE=0\n' "$$" > "$ENVF"; chmod 600 "$ENVF"; }
    mkdir -p "$HOME/.ccquota"
    nohup sleep 300 >/dev/null 2>&1 < /dev/null &
    echo $! > "$HOME/.ccquota/agent.pid"
    echo "✓ 已上线（fake）" ;;
  "compute on")
    [ "${FAKE_REFUSE:-0}" = 1 ] && { echo "✗ 不打开：fake probe says no"; exit 1; }
    sed -i.x 's/^CCQUOTA_FLEET_COMPUTE=.*/CCQUOTA_FLEET_COMPUTE=1/' "$ENVF"; rm -f "$ENVF.x"
    grep -q '^CCQUOTA_FLEET_COMPUTE=' "$ENVF" || echo CCQUOTA_FLEET_COMPUTE=1 >> "$ENVF"
    echo "✓ 已打开（fake）" ;;
  "compute off")
    sed -i.x 's/^CCQUOTA_FLEET_COMPUTE=.*/CCQUOTA_FLEET_COMPUTE=0/' "$ENVF"; rm -f "$ENVF.x"
    echo "✓ 已关闭（fake）" ;;
  "compute status") echo "已打开：入口可以往这台派会话" ;;
esac
FAKE
  chmod +x "$INS/bin/fleet-node.sh"
}
run() { env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" FLEET_CONF_DIR="$CD" TMPDIR="$WORK" ${FAKE_REFUSE:+FAKE_REFUSE=$FAKE_REFUSE} "$@"; }
host() { run bash "$INS/bin/fleet" host "$@" </dev/null 2>&1; }
hostv() { run bash "$INS/bin/fleet-conf.sh" host; }
calls() { tr '\n' '|' < "$CD/node-calls" 2>/dev/null; }
agent_pid() { cat "$H/.ccquota/agent.pid" 2>/dev/null; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
snap() { (cd "$CD" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

# ---------------------------------------------------------------------------- A
mkbox a
out=$(host status)
has "A: status, no hub: 未开" "$out" "能力: 基础 · 承载 未开"
has "A: …and 不接入口" "$out" "入口: 不接"
out=$(host on); rc=$?
is "A: on with no terminal and no --yes → 2" "$rc" 2
has "A: …says what it would do" "$out" "这台的 fleet 跑会话，不接入口"
has "A: …and how to confirm" "$out" "fleet host on --yes"
[ -e "$CD/fleet.conf" ] && bad "A: an unconfirmed on wrote fleet.conf" || ok
out=$(host on --yes); rc=$?
is "A: on --yes → 0" "$rc" 0
has "A: …says 已开" "$out" "能力: 基础 · 承载 已开"
is "A: FLEET_HOST=1" "$(hostv)" 1
has "A: doctor 能力 says 承载" "$(run bash "$INS/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^ +PASS +能力')" "能力     基础 · 承载 — FLEET_HOST"
out=$(host off); rc=$?
is "A: off → 0" "$rc" 0
is "A: FLEET_HOST=0" "$(hostv)" 0
has "A: off says how to turn it back" "$out" "要在这台跑会话：fleet host on"
[ -e "$CD/node-calls" ] && bad "A: no hub, yet fleet node ran: $(calls)" || ok

# ---------------------------------------------------------------------------- B
mkbox b
run bash "$INS/bin/fleet-conf.sh" set-hub https://hub.test
before=$(snap)
out=$(host on --yes); rc=$?
is "B: on --yes → 0" "$rc" 0
is "B: join, then compute on" "$(calls)" "join|compute on|"
p1=$(agent_pid); AGENTS="$AGENTS $p1"
alive "$p1" && ok || bad "B: the agent the join started is not running"
is "B: FLEET_HOST=1" "$(hostv)" 1
[ -f "$CD/host-joined" ] && ok || bad "B: on did not note that it joined"
has "B: the hub may place here" "$(cat "$CD/node.env")" "CCQUOTA_FLEET_COMPUTE=1"
out=$(host off); rc=$?
is "B: off → 0" "$rc" 0
is "B: off ran compute off" "$(calls)" "join|compute on|compute off|"
alive "$p1" && bad "B: off left the agent running (pid $p1)" || ok
[ -e "$CD/node.env" ] && bad "B: off left node.env in place" || ok
is "B: the processes and config are what they were before on" "$(snap | grep -v -e node-calls -e node.env.host-off)" "$before"
out=$(host on --yes); rc=$?
is "B: on again → 0" "$rc" 0
has "B: …reuses the pass" "$out" "沿用上次关掉时留下的入口通行证"
p2=$(agent_pid); AGENTS="$AGENTS $p2"
alive "$p2" && ok || bad "B: on again did not start the agent"
is "B: FLEET_HOST=1 again" "$(hostv)" 1

# ---------------------------------------------------------------------------- C
mkbox c
run bash "$INS/bin/fleet-conf.sh" set-hub https://hub.test --host
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=m5\nCCQUOTA_FLEET_COMPUTE=1\n' > "$CD/node.env"; chmod 600 "$CD/node.env"
mkdir -p "$H/.ccquota"; sleep 300 >/dev/null 2>&1 < /dev/null & pc=$!; AGENTS="$AGENTS $pc"; echo "$pc" > "$H/.ccquota/agent.pid"
out=$(host on --yes)
has "C: a host already: nothing to do" "$out" "承载 已开 — 什么都不用做"
[ -e "$CD/node-calls" ] && bad "C: on ran fleet node on a host: $(calls)" || ok
out=$(host off); rc=$?
is "C: off → 0" "$rc" 0
is "C: off ran compute off only" "$(calls)" "compute off|"
alive "$pc" && ok || bad "C: off stopped an agent it did not start"
has "C: node.env kept" "$(cat "$CD/node.env" 2>/dev/null)" "CCQUOTA_TOKEN=m5"
is "C: FLEET_HOST=0" "$(hostv)" 0
out=$(host status)
has "C: status says the hub's word" "$out" "入口: "

# ---------------------------------------------------------------------------- D
mkbox d
run bash "$INS/bin/fleet-conf.sh" set-hub https://hub.test
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=x\nCCQUOTA_FLEET_COMPUTE=0\n' > "$CD/node.env"; chmod 600 "$CD/node.env"
out=$(FAKE_REFUSE=1 host on --yes); rc=$?
is "D: a refused probe → 1" "$rc" 1
has "D: …says why" "$out" "承载 没开"
is "D: FLEET_HOST stays 0" "$(hostv)" 0

printf 'fleet-host-selftest: %d checks, %d failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
