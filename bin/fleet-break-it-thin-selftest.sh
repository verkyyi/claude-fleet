#!/bin/bash
# fleet-break-it-thin-selftest.sh — docs/BREAK-IT.md rows thin-* (issue #3005,
# EPIC #2999 C8): a thin client has no loop of its own, so its home machine keeps
# its lease and writes to its 看台's terminal itself. Its own file, like the
# peerlink drills, on the cred runner (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill_* names here too.
#
#   thin-notify-two-views  bin/fleet_thin_lease.py (beat · holder · notify): two
#                          看台 on one home machine; the person moves to the other
#   thin-open-no-loop      bin/fleet-open.sh with a thin lease: no hub action, no
#                          spool — the escape on the 看台's own terminal
#
# One isolated tmux server (-S under a short /tmp dir), the person's terminals
# python ptys that answer DA / XTVERSION as iTerm2 and record every byte, the hub a
# seam (FLEET_THIN_LEASE_CMD) keeping leases in a file. tmux absent → SKIP.
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
RT=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -) command -v tmux) \
  || { printf 'fleet-break-it-thin: tmux absent — SKIP\n'; exit 0; }
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
unset TMUX TMUX_PANE

# th_box <name> — a home machine: fleet `fl`, 看台 a and b each with a terminal
# attached, their registry rows, the fake hub (PRIMARY names the primary lease).
th_box() {
  B=$(mktemp -d /tmp/thb.XXXXXX); printf '%s\n' "$B" >> "$WORK/thin-boxes"
  mkdir -p "$B/s" "$B/bin" "$B/conf/remote-views"
  cat > "$B/bin/tmux" <<EOS
#!/bin/bash
if [ "\${1:-}" = -L ]; then l=\$2; shift 2; exec "$RT" -S "$B/s/\$l" "\$@"; fi
exec "$RT" "\$@"
EOS
  chmod +x "$B/bin/tmux"
  export FLEET_THIN_TMUX="$B/bin/tmux" FLEET_CONF_DIR="$B/conf" FLEET_NOTIFY_LOG="$B/notify.ndjson" \
    FLEET_THIN_LEASE_CMD="python3 $B/hub.py $B"
  TT() { "$RT" -S "$B/s/fl" "$@"; }
  TT -f /dev/null new-session -d -s fl -x 100 -y 30 'exec sleep 600'
  TT set -g status off
  cat > "$B/hub.py" <<'PY'
import json, os, sys
w = sys.argv[1]; req = json.load(sys.stdin)
open(os.path.join(w, "hub.log"), "a").write(json.dumps(req, sort_keys=True) + "\n")
if req.get("action") == "release":
    print(json.dumps({"state": "released"})); sys.exit(0)
lid = req.get("lease") or "L-" + req.get("device", "?")
pf = os.path.join(w, "PRIMARY")
print(json.dumps({"state": "active", "lease": {"id": lid}, "primary": open(pf).read().strip() if os.path.exists(pf) else lid}))
PY
  cat > "$B/term_pty.py" <<'PY'
import os, pty, select, sys, time
tmux, sock, sess, name, work = sys.argv[1:6]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-S", sock, "attach", "-t", sess])
out = open(os.path.join(work, "out-" + name), "ab", buffering=0)
ctl, seen, end = os.path.join(work, "ctl-" + name), b"", time.time() + 60
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        out.write(d); seen += d
        if b"\x1b[>q" in seen:
            os.write(fd, b"\x1b[?62;22c\x1b[>0;95;0c\x1bP>|iTerm2 3.6.1\x1b\\"); seen = b""
        seen = seen[-8:]
    if os.path.exists(ctl):
        data = open(ctl, "rb").read(); os.unlink(ctl); os.write(fd, data)
os.kill(pid, 9)
PY
  local v t
  for v in a b; do
    TT new-session -d -t fl -s "fl@view-$v"; TT set -t "fl@view-$v" @view_thin "$v"
    python3 "$B/term_pty.py" "$RT" "$B/s/fl" "fl@view-$v" "$v" "$B" & printf '%s\n' "$!" >> "$WORK/cred-pids"
    eval "PID_$v=$!"
  done
  until_ok 5 sh -c '[ "$("$1" -S "$2" list-clients | wc -l | tr -d " ")" -ge 2 ]' _ "$RT" "$B/s/fl" || return 1
  sleep 0.5
  for v in a b; do
    t=$(TT list-clients -F '#{client_session} #{client_tty}' | awk -v s="fl@view-$v" '$1 == s { print $2 }')
    printf '%s\tfl\tthin\t%s\t%s\tcur=\troute=-\tdevice=%s\ttoken=t\tfuid=u\tnode=home\n' "$t" "$(date +%s)" \
      "$(eval "printf %s \$PID_$v")" "$(printf '{"device":"dev-%s","terminal":"iTerm2 3.6.1"}' "$v" | base64 | tr -d '\n')" \
      > "$B/conf/remote-views/$v"
  done
}
th_done() { "$RT" -S "$B/s/fl" kill-server 2>/dev/null; }
osc9_in() { grep -aq $'\033]9;' "$B/out-$1"; }

drill_thin_notify_two_views() {
  CAP=4   # the person's input → the next beat moves the primary → the next notification there
  local t0
  th_box || { WHY="the two 看台 terminals did not attach"; th_done; return 1; }
  printf 'L-dev-a\n' > "$B/PRIMARY"
  python3 "$BIN/fleet_thin_lease.py" beat
  : > "$B/out-a"; : > "$B/out-b"
  python3 "$BIN/fleet_thin_lease.py" notify --title '#1 在问你' --body x --jump wid:u/f --log-key k1 --log-state ask
  until_ok 3 osc9_in a || { WHY="the primary's 看台 (a) got no OSC 9"; th_done; return 1; }
  osc9_in b && { WHY="both 看台 were notified (one person, two copies)"; th_done; return 1; }
  # the person picks up the other device and types: the hub's primary is now b
  printf 'L-dev-b\n' > "$B/PRIMARY"; printf 'x' > "$B/ctl-b"; t0=$(now)
  sleep 0.3
  python3 "$BIN/fleet_thin_lease.py" beat
  : > "$B/out-a"; : > "$B/out-b"
  python3 "$BIN/fleet_thin_lease.py" notify --title '#2 在问你' --body y --jump wid:u/f --log-key k2 --log-state ask
  until_ok 3 osc9_in b || { WHY="after the person moved, b got no OSC 9: $(tail -n 1 "$B/notify.ndjson")"; th_done; return 1; }
  SECS=$(since "$t0")
  osc9_in a && { WHY="a still notified after the person moved to b"; th_done; return 1; }
  printf 'L-elsewhere\n' > "$B/PRIMARY"; FLEET_THIN_LEASE_RENEW=0 python3 "$BIN/fleet_thin_lease.py" beat
  : > "$B/out-a"; : > "$B/out-b"
  python3 "$BIN/fleet_thin_lease.py" notify --title '#3' --body z --jump wid:u/f --log-key k3 --log-state ask
  sleep 0.8
  { osc9_in a || osc9_in b; } && { WHY="a notification went out while no 看台 here holds the lease"; th_done; return 1; }
  th_done
  WHAT="两个看台只对租约主那个写 OSC 9；人拿起 b 打字，下一拍主换到 b，下一条只到 b；租约在别处时一条不发"
}

drill_thin_open_no_loop() {
  CAP=4
  local t0 r p0
  th_box || { WHY="the two 看台 terminals did not attach"; th_done; return 1; }
  printf '#!/bin/sh\necho %s\n' "'{\"state\":\"active\",\"source\":\"hub\",\"via\":\"thin\"}'" > "$B/where.sh"
  printf '#!/bin/sh\necho called >> "%s/actions.called"; echo "{\\"state\\":\\"queued\\"}"\n' "$B" > "$B/actions.sh"
  chmod +x "$B/where.sh" "$B/actions.sh"
  printf 'z' > "$B/ctl-a"; sleep 0.4; : > "$B/out-a"
  p0=$("$RT" -S "$B/s/fl" list-panes -t fl -F '#{pane_id}' | head -n 1); t0=$(now)
  r=$(env TMUX="$B/s/fl,0,0" TMUX_PANE="$p0" PATH="$B/bin:$PATH" FLEET_OPEN_WHERE_CMD="$B/where.sh" \
        FLEET_OPEN_ACTIONS_BIN="$B/actions.sh" FLEET_OPEN_SECRET_FILE="$B/open.secret" FLEET_OPEN_URL_BIN=/usr/bin/false \
        bash "$BIN/fleet-open.sh" https://example.com/p 2>"$B/open.err")
  until_ok 3 grep -aq $'\033]1337;Custom=id=' "$B/out-a" \
    || { WHY="no OSC 1337 on 看台 a's terminal ($r: $(cat "$B/open.err"))"; th_done; return 1; }
  SECS=$(since "$t0")
  [ -f "$B/actions.called" ] && { WHY="the page went to the hub's action queue (nobody polls it for a thin client)"; th_done; return 1; }
  ls "$B/conf/remote-views" | grep -q '\.d$' && { WHY="a spool nobody reads was made"; th_done; return 1; }
  th_done
  WHAT="租约 via=thin：fleet open 不进入口的动作队列、不建 spool，OSC 1337 直接到看台客户端的终端（${r}）"
}

trap 'th_done 2>/dev/null; [ -f "$WORK/thin-boxes" ] && while read -r b; do "$RT" -S "$b/s/fl" kill-server 2>/dev/null; [ -n "${BREAK_KEEP:-}" ] || rm -rf "$b"; done < "$WORK/thin-boxes"; cleanup' EXIT
cred_run_drills "$0"
