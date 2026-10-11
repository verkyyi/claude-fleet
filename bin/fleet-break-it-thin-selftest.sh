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
#   view-popup-wide-bleed  a session streaming wrapped CJK behind the ⌘P list
#                          (issue #3058): the 看台's popup binds say --freeze, and
#                          through the real dash-popup.sh not one of the pane's wide
#                          glyphs reaches the terminal while the popup is up
#   view-popup-far-bleed   the same over another machine's session (issue #3085): a
#                          peer window whose pane is a nested tmux streaming CJK, on
#                          a home server whose fleet-view an older release built
#                          (bare display-popup): attach's view-keys --if-stale
#                          rebuilds it, and the nested pane holds still under it
#   view-far-reaped        bin/fleet_view.py hub_fresh + bin/fleet-hub-sessions.sh
#                          (issue #3079): a worker reaped on another machine while
#                          this one's copy of the hub's list had stopped
#   view-first-frame-hub-slow  bin/fleet_view.py popup (issue #3311): hub_ok stale,
#                          no loop, a hub that takes 6 s — ⌘P's first frame drawn
#                          from the cache at once, the hub asked behind it
#   pool-prompt-nbsp       bin/scratch-pool.sh warm_input (issue #3311): Claude
#                          Code's `❯` + no-break space, read by a bash fallen back to
#                          C (a Linux node) — no warm entry ever became ready
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
  local t0 r p0 d
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
  # a spool request: <view>.d/<epoch>-<pid>.json (C2 keeps the 看台's history in that dir too)
  for d in "$B"/conf/remote-views/*.d/[0-9]*-[0-9]*.json; do [ -f "$d" ] && { WHY="a spool nobody reads was made"; th_done; return 1; }; done
  th_done
  WHAT="租约 via=thin：fleet open 不进入口的动作队列、不建 spool，OSC 1337 直接到看台客户端的终端（${r}）"
}

# view-popup-wide-bleed (issue #3058): tmux 3.7c draws a wide character a pane writes
# under a popup through the wrong cells, so wrapped CJK behind the ⌘P list lands on
# its frame and rows. The pane behind must write NOTHING while the popup is up.
drill_view_popup_wide_bleed() {
  CAP=6   # popup open → its frame on the terminal, the pane held still
  local t0 pane binds n0 n1 b
  B=$(mktemp -d /tmp/thb.XXXXXX); printf '%s\n' "$B" >> "$WORK/thin-boxes"
  mkdir -p "$B/s" "$B/bin"
  printf '#!/bin/bash\nexec "%s" -S "%s/s/fl" "$@"\n' "$RT" "$B" > "$B/bin/tmux"; chmod +x "$B/bin/tmux"
  # 龘 is the glyph to count: wrapped lines, a wide char straddling every line end
  cat > "$B/cjk.sh" <<'EOS'
#!/bin/bash
s=$(printf '龘%.0s' $(seq 66)); n=0
while :; do printf '\033[H'; for r in $(seq 0 27); do printf '%*s%s' $(( (r + n) % 4 )) '' "$s"; [ $r -lt 27 ] && printf '\r\n'; done; n=$((n+1)); sleep 0.1; done
EOS
  chmod +x "$B/cjk.sh"
  TT() { "$RT" -S "$B/s/fl" "$@"; }
  TT -f /dev/null new-session -d -s fl -x 120 -y 30 "$B/cjk.sh"
  TT set -g status off
  cat > "$B/term.py" <<'PY'
import os, pty, select, sys, time, fcntl, termios, struct
tmux, sock, out = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"; os.environ["LANG"] = "en_US.UTF-8"
    os.execvp(tmux, [tmux, "-u", "-S", sock, "attach", "-t", "fl"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
o, end = open(out, "ab", buffering=0), time.time() + 40
while time.time() < end:
    if select.select([fd], [], [], 0.05)[0]:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        o.write(d)
os.kill(pid, 9)
PY
  python3 "$B/term.py" "$RT" "$B/s/fl" "$B/out" & printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 5 sh -c '[ -n "$("$1" -S "$2" list-clients -F x)" ]' _ "$RT" "$B/s/fl" || { WHY="the terminal did not attach"; th_done; return 1; }
  until_ok 5 grep -aq '龘' "$B/out" || { WHY="the session's CJK never reached the terminal"; th_done; return 1; }
  # the 看台's own key tables, built here: every popup bind names --freeze
  env TMUX="$B/s/fl,0,0" PATH="$B/bin:$PATH" python3 "$BIN/fleet-quickopen.py" view-keys >/dev/null 2>&1
  binds=$(TT list-keys -T fleet-view 2>/dev/null | grep 'dash-popup.sh')
  [ -n "$binds" ] || { WHY="view-keys built no popup bind in fleet-view"; th_done; return 1; }
  b=$(printf '%s\n' "$binds" | grep -v -e '--freeze' | head -n 1)
  [ -z "$b" ] || { WHY="a 看台 popup bind without --freeze: $b"; th_done; return 1; }
  pane=$(TT list-panes -t fl -F '#{pane_id}')
  t0=$(now)
  ( env TMUX="$B/s/fl,0,0" PATH="$B/bin:$PATH" bash "$BIN/dash-popup.sh" --client "$(TT list-clients -F '#{client_name}' | head -n 1)" \
      --no-inline --freeze -w 90% -h 80% -- sleep 3 >/dev/null 2>&1 & )
  until_ok "$CAP" grep -aq '╭' "$B/out" || { WHY="the popup never drew its frame"; th_done; return 1; }
  SECS=$(since "$t0")
  [ "$(TT display -p -t "$pane" '#{pane_in_mode}')" = 1 ] || { WHY="the pane behind is not held while the popup is up"; th_done; return 1; }
  sleep 0.4; n0=$(grep -ao '龘' "$B/out" | wc -l); sleep 1.5; n1=$(grep -ao '龘' "$B/out" | wc -l)
  [ "$n1" = "$n0" ] || { WHY="$((n1 - n0)) of the pane's wide glyphs reached the terminal while the popup was up (tmux 3.7c draws them over it)"; th_done; return 1; }
  until_ok 4 sh -c '[ "$("$1" -S "$2" display -p -t "$3" "#{pane_in_mode}")" = 0 ]' _ "$RT" "$B/s/fl" "$pane" \
    || { WHY="the pane was left in copy-mode after the popup closed"; th_done; return 1; }
  sleep 0.5; [ "$(grep -ao '龘' "$B/out" | wc -l)" -gt "$n1" ] || { WHY="the session never drew again after the popup closed"; th_done; return 1; }
  th_done
  WHAT="会话背后一直在刷折行的中文：看台的弹窗键都带 --freeze，弹窗 ${SECS}s 内画出来，开着的 1.9s 里背后的面板一个宽字也没送到终端；关掉后面板退出 copy-mode、接着刷"
}

# view-popup-far-bleed (issue #3085): ⌘P over another machine's session. The 看台's
# window onto it is a pane running that machine's tmux (fleet-peerlink.py pane → ssh →
# its bare `-via-` 看台), so the glyphs come from a nested tmux. The home server here
# had its fleet-view built by an older release — ⌘P a bare display-popup, no --freeze —
# and nothing rebuilt it: the conf re-source watched fleet-quickopen.py, #3058 changed
# fleet_view.py. attach --thin's `view-keys --if-stale` must rebuild a table another
# version built, and the far pane must write nothing while the popup is up.
drill_view_popup_far_bleed() {
  CAP=6   # popup open → its frame on the terminal, the far pane held still
  local t0 pane binds n0 n1 b k
  B=$(mktemp -d /tmp/thb.XXXXXX); printf '%s\n' "$B" >> "$WORK/thin-boxes"
  mkdir -p "$B/s" "$B/bin"
  printf '#!/bin/bash\nexec "%s" -S "%s/s/fl" "$@"\n' "$RT" "$B" > "$B/bin/tmux"; chmod +x "$B/bin/tmux"
  cat > "$B/cjk.sh" <<'EOS'
#!/bin/bash
s=$(printf '龘%.0s' $(seq 66)); n=0
while :; do printf '\033[H'; for r in $(seq 0 27); do printf '%*s%s' $(( (r + n) % 4 )) '' "$s"; [ $r -lt 27 ] && printf '\r\n'; done; n=$((n+1)); sleep 0.1; done
EOS
  chmod +x "$B/cjk.sh"
  TT() { "$RT" -S "$B/s/fl" "$@"; }
  # the far machine: its own server, the session streaming CJK, bare (status off)
  "$RT" -S "$B/s/far" -f /dev/null new-session -d -s far -x 120 -y 30 "$B/cjk.sh"
  "$RT" -S "$B/s/far" set -g status off
  # home: the 看台's peer window, its pane that machine's tmux attached
  TT -f /dev/null new-session -d -s fl -x 120 -y 30 "env -u TMUX '$RT' -u -S '$B/s/far' attach -t far"
  TT set -g status off \; set -w @fleet_role panel \; set -w @peer far@me \; set -w @peer_node far
  cat > "$B/term.py" <<'PY'
import os, pty, select, sys, time, fcntl, termios, struct
tmux, sock, out = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"; os.environ["LANG"] = "en_US.UTF-8"
    os.execvp(tmux, [tmux, "-u", "-S", sock, "attach", "-t", "fl"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
o, end = open(out, "ab", buffering=0), time.time() + 40
while time.time() < end:
    if select.select([fd], [], [], 0.05)[0]:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        o.write(d)
os.kill(pid, 9)
PY
  python3 "$B/term.py" "$RT" "$B/s/fl" "$B/out" & printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 5 sh -c '[ -n "$("$1" -S "$2" list-clients -F x)" ]' _ "$RT" "$B/s/fl" || { WHY="the terminal did not attach"; far_done; return 1; }
  until_ok 5 grep -aq '龘' "$B/out" || { WHY="the far session's CJK never reached the terminal"; far_done; return 1; }
  # the table an older release left: built, then every popup bind the pre-#3044 bare one
  env TMUX="$B/s/fl,0,0" PATH="$B/bin:$PATH" python3 "$BIN/fleet-quickopen.py" view-keys >/dev/null 2>&1
  binds=$(TT list-keys -T fleet-view 2>/dev/null | grep 'dash-popup.sh')
  [ -n "$binds" ] || { WHY="view-keys built no popup bind in fleet-view"; far_done; return 1; }
  for k in $(printf '%s\n' "$binds" | awk '{ print $4 }'); do
    TT bind-key -T fleet-view "$k" run-shell -b "tmux display-popup -c '#{client_name}' -E 'sleep 1'"
  done
  TT set -gu @fleet_view_keys_sig
  # what attach --thin runs on every attach (fleet-remote-view.sh rv_thin_dress)
  env TMUX="$B/s/fl,0,0" PATH="$B/bin:$PATH" python3 "$BIN/fleet-quickopen.py" view-keys --if-stale >/dev/null 2>&1
  b=$(TT list-keys -T fleet-view 2>/dev/null | grep 'display-popup' | grep -v 'dash-popup.sh' | head -n 1)
  [ -z "$b" ] || { WHY="attach's view-keys --if-stale left another release's popup bind (no --freeze): $b"; far_done; return 1; }
  b=$(TT list-keys -T fleet-view 2>/dev/null | grep 'dash-popup.sh' | grep -v -e '--freeze' | head -n 1)
  [ -z "$b" ] || { WHY="a 看台 popup bind without --freeze: $b"; far_done; return 1; }
  pane=$(TT list-panes -t fl -F '#{pane_id}')
  t0=$(now)
  ( env TMUX="$B/s/fl,0,0" PATH="$B/bin:$PATH" bash "$BIN/dash-popup.sh" --client "$(TT list-clients -F '#{client_name}' | head -n 1)" \
      --no-inline --freeze -w 90% -h 80% -- sleep 3 >/dev/null 2>&1 & )
  until_ok "$CAP" grep -aq '╭' "$B/out" || { WHY="the popup never drew its frame"; far_done; return 1; }
  SECS=$(since "$t0")
  [ "$(TT display -p -t "$pane" '#{pane_in_mode}')" = 1 ] || { WHY="the peer pane behind is not held while the popup is up"; far_done; return 1; }
  sleep 0.4; n0=$(grep -ao '龘' "$B/out" | wc -l); sleep 1.5; n1=$(grep -ao '龘' "$B/out" | wc -l)
  [ "$n1" = "$n0" ] || { WHY="$((n1 - n0)) of the far session's wide glyphs reached the terminal while the popup was up"; far_done; return 1; }
  until_ok 4 sh -c '[ "$("$1" -S "$2" display -p -t "$3" "#{pane_in_mode}")" = 0 ]' _ "$RT" "$B/s/fl" "$pane" \
    || { WHY="the peer pane was left in copy-mode after the popup closed"; far_done; return 1; }
  sleep 0.5; [ "$(grep -ao '龘' "$B/out" | wc -l)" -gt "$n1" ] || { WHY="the far session never drew again after the popup closed"; far_done; return 1; }
  far_done
  WHAT="别的机器的会话（看台里的窗口是那边的 tmux）一直在刷折行的中文，家机器的看台键是旧版本建的（裸 display-popup）：attach 的 view-keys --if-stale 认出别的版本建的表、重建成带 --freeze 的；弹窗 ${SECS}s 内画出来，开着的 1.9s 里那边一个宽字也没送到终端，关掉后接着刷"
}
far_done() { "$RT" -S "$B/s/far" kill-server 2>/dev/null; th_done; }

drill_view_far_reaped() {
  CAP=10   # the issue's bound: the next ⌘P after the far reap
  local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-view-hub-fresh-selftest.sh" B 2>&1) || { WHY=$(printf '%s\n' "$out" | grep -m1 FAIL); return 1; }
  SECS=$(since "$t0")
  WHAT="家机器的远端缓存停在 16 分钟前（采集器停了、没有刷新循环），另一台机器收掉的会话：下一次打开 ⌘P 先刷一次入口的清单再列，它不在了，刷新循环也起来了"
}

drill_view_first_frame_hub_slow() {
  CAP=30
  local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-view-hub-fresh-selftest.sh" F 2>&1) || { WHY=$(printf '%s\n' "$out" | grep -m1 FAIL); return 1; }
  SECS=$(since "$t0")
  WHAT="入口清单过期、没有刷新循环、入口要 6 秒才答：⌘P 照缓存 1.5 秒内画出第一帧，入口在后台被问到"
}

drill_pool_prompt_nbsp() {
  CAP=180
  local t0 out
  t0=$(now)
  out=$(bash "$BIN/scratch-pool-live-selftest.sh" 2>&1) || { WHY=$(printf '%s\n' "$out" | grep -m1 FAIL); return 1; }
  SECS=$(since "$t0")
  WHAT="提示符是 ❯ + 不换行空格、脚本跑在退回 C 的 locale 里（Linux 节点）：暖池照样有一个就绪的条目，⌘N 拿得到"
}

th_cleanup() {
  local bx
  th_done 2>/dev/null
  if [ -f "$WORK/thin-boxes" ]; then
    while read -r bx; do "$RT" -S "$bx/s/fl" kill-server 2>/dev/null; "$RT" -S "$bx/s/far" kill-server 2>/dev/null; [ -n "${BREAK_KEEP:-}" ] || rm -rf "$bx"; done < "$WORK/thin-boxes"
  fi
  cleanup
}
trap th_cleanup EXIT
cred_run_drills "$0"
