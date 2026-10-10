#!/bin/bash
# fleet-thin-notify-selftest.sh — notifications, opening a page and where the
# person is, for a THIN client (issue #3005, EPIC #2999 C8): its home machine
# holds the lease and writes to the 看台's terminal itself.
#
# One fleet server on an isolated socket, two thin 看台 (`fl@view-a`, `fl@view-b`)
# each with a real client — a python pty that answers XTVERSION as iTerm2 and
# records every byte it receives — and a third, `x-via-home` (another home's window
# onto this machine, C4). The hub is a seam (FLEET_THIN_LEASE_CMD) that keeps
# leases in a file and says which one is the person's primary.
#
#   A. lease   fleet_thin_lease.py beat acquires a lease for each 看台 with a client
#              (device from its row, via thin, last input = client_activity), none
#              for the -via- 看台; the book names them; a second beat inside the
#              renew interval asks nothing.
#   B. notify  the holder is the 看台 whose lease is primary: OSC 9 reaches ITS
#              pty and not the other's; @notify_jump is armed on its session; a
#              line of notify.ndjson says sent.
#   C. none    the person's primary is another client: no holder, nothing written
#              to either pty, notify.ndjson says skip no-lease.
#   D. jump    the 看台's terminal back in front (a focus-in typed into its pty)
#              takes the armed jump: the 看台 goes to the window of that worker.
#   E. beat    fleet_notify.beat hands an 在问你 row to the sender it is given.
#   F. open    fleet-open.sh with the lease via thin: no hub action, no spool —
#              OSC 1337 Custom on the newest 看台's pty; for the -via- client the
#              escape is wrapped as tmux passthrough.
#   G. where   no hub: fleet-client-where.sh answers the device off the thin row
#              (no fleet-shell server anywhere).
#   H. release a 看台 whose client left: its lease is released, the book drops it.
#   I. none    no thin 看台 ever here: beat writes no book.
#
# tmux / python3 absent → SKIP.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-thin-notify selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'fleet-thin-notify selftest: python3 absent — SKIP'; exit 0; }
case "$REAL_TMUX" in */tmux-shim/*) REAL_TMUX=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -) command -v tmux) ;; esac
unset TMUX TMUX_PANE

FAIL=0; N=0
ok()  { N=$((N + 1)); printf 'ok:   %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

W=$(mktemp -d /tmp/thn.XXXXXX) || exit 2
S="$W/s"; mkdir -p "$S" "$W/bin" "$W/conf/remote-views" "$W/g"
PIDS=''
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  "$REAL_TMUX" -S "$S/fl" kill-server 2>/dev/null
  [ -n "${THN_KEEP:-}" ] && { echo "kept $W" >&2; return; }; rm -rf "$W"
}
trap cleanup EXIT INT TERM

# tmux -L <label> → this test's own socket dir
cat > "$W/bin/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then l=\$2; shift 2; exec "$REAL_TMUX" -S "$S/\$l" "\$@"; fi
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$W/bin/tmux"
export FLEET_THIN_TMUX="$W/bin/tmux" FLEET_CONF_DIR="$W/conf" FLEET_NOTIFY_LOG="$W/notify.ndjson"
T() { "$REAL_TMUX" -S "$S/fl" "$@"; }

T -f /dev/null new-session -d -s fl -x 100 -y 30 'exec sleep 600'
T set -g focus-events on; T set -g status off
T new-window -d -t fl 'exec sleep 600'
W2=$(T list-windows -t fl -F '#{window_id}' | tail -n 1)
T set-option -w -t "$W2" @fleet_id f-two
T new-session -d -t fl -s 'fl@view-a'; T set -t 'fl@view-a' @view_thin a
T new-session -d -t fl -s 'fl@view-b'; T set -t 'fl@view-b' @view_thin b
T new-session -d -t fl -s 'fl@view-x-via-home'; T set -t 'fl@view-x-via-home' @view_thin x-via-home
T set-hook -g 'client-focus-in[79]' \
  "if -F '#{@view_thin}' { run-shell -b \"bash '$BIN/fleet-remote-view.sh' notify-jump '#{socket_path}' '#{client_session}' >/dev/null 2>&1 || :\" }"

# the person's terminal: a pty attached to one 看台; answers XTVERSION (iTerm2 or a
# given word), records every byte; $W/ctl-<n> is typed into it when it appears
cat > "$W/term_pty.py" <<'PY'
import os, pty, select, sys, time
tmux, sock, sess, name, word, work = sys.argv[1:7]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-S", sock, "attach", "-t", sess])
out = open(os.path.join(work, "out-" + name), "ab", buffering=0)
ctl = os.path.join(work, "ctl-" + name)
end = time.time() + 120
seen = b""
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        out.write(d)
        seen += d
        if b"\x1b[>q" in seen or b"\x1b[>0q" in seen:
            # a terminal's answers, in the order tmux asks: DA1, DA2, XTVERSION
            os.write(fd, b"\x1b[?62;22c\x1b[>0;95;0c\x1bP>|" + word.encode() + b"\x1b\\")
            seen = b""
        seen = seen[-8:]
    if os.path.exists(ctl):
        data = open(ctl, "rb").read()
        os.unlink(ctl)
        os.write(fd, data)
os.kill(pid, 9)
PY
attach() {  # <name> <session> <terminal word>
  python3 "$W/term_pty.py" "$REAL_TMUX" "$S/fl" "$2" "$1" "$3" "$W" & PIDS="$PIDS $!"
  LASTPID=$!
}
attach a 'fl@view-a' 'iTerm2 3.6.1'; PTY_a=$LASTPID
attach b 'fl@view-b' 'iTerm2 3.6.1'; PTY_b=$LASTPID
attach x 'fl@view-x-via-home' 'tmux 3.5a'; PTY_x=$LASTPID
for _ in $(seq 1 50); do [ "$(T list-clients | wc -l | tr -d ' ')" -ge 3 ] && break; sleep 0.1; done
sleep 0.5
TTY_A=$(T list-clients -F '#{client_session} #{client_tty}' | awk '$1 == "fl@view-a" { print $2 }')
TTY_B=$(T list-clients -F '#{client_session} #{client_tty}' | awk '$1 == "fl@view-b" { print $2 }')
TTY_X=$(T list-clients -F '#{client_session} #{client_tty}' | awk '$1 == "fl@view-x-via-home" { print $2 }')
[ -n "$TTY_A" ] && [ -n "$TTY_B" ] && [ -n "$TTY_X" ] || { bad "the three 看台 clients did not attach"; exit 1; }

spool_made() { local d; for d in "$1"/*.d; do [ -d "$d" ] && return 0; done; return 1; }
dev() { printf '{"device":"%s","os":"macOS","terminal":"iTerm2 3.6.1","via":"local","caps":["open_url"]}' "$1" | base64 | tr -d '\n'; }
row() {  # <view> <tty> <pid> <device>
  printf '%s\tfl\tthin\t%s\t%s\tcur=u/f-one\troute=-\tdevice=%s\ttoken=t\tfuid=u\tnode=home1\n' "$2" "$(date +%s)" "$3" "$(dev "$4")" \
    > "$W/conf/remote-views/$1"
}
row a "$TTY_A" "$PTY_a" MacBook-A
row b "$TTY_B" "$PTY_b" MacBook-B
row x-via-home "$TTY_X" "$PTY_x" Elsewhere

# the hub: leases in a file; PRIMARY file names the primary (default: the newest acquired)
cat > "$W/hub.py" <<'PY'
import json, os, sys
w = sys.argv[1]
req = json.load(sys.stdin)
open(os.path.join(w, "hub.log"), "a").write(json.dumps(req, sort_keys=True) + "\n")
p = os.path.join(w, "hub.json")
st = json.load(open(p)) if os.path.exists(p) else {"leases": {}}
a = req.get("action")
if a == "acquire":
    lid = "L-" + req.get("device", "?")
    st["leases"][lid] = req
elif a == "renew":
    lid = req["lease"]
    st["leases"][lid] = req
elif a == "release":
    st["leases"].pop(req["lease"], None)
    json.dump(st, open(p, "w"))
    print(json.dumps({"state": "released"}))
    sys.exit(0)
json.dump(st, open(p, "w"))
pf = os.path.join(w, "PRIMARY")
prim = open(pf).read().strip() if os.path.exists(pf) else lid
print(json.dumps({"state": "active", "lease": {"id": lid, "device": req.get("device")}, "primary": prim,
                  "clients": [{"id": k} for k in st["leases"]]}))
PY
export FLEET_THIN_LEASE_CMD="python3 $W/hub.py $W"
printf 'L-MacBook-A\n' > "$W/PRIMARY"

# --- A. lease ------------------------------------------------------------------
python3 "$BIN/fleet_thin_lease.py" beat
acq=$(grep -c '"action": "acquire"' "$W/hub.log" 2>/dev/null)
[ "$acq" = 2 ] && ok "A two 看台 with a client → two acquires" || bad "A acquires: $acq ($(cat "$W/hub.log" 2>/dev/null))"
grep -q 'Elsewhere' "$W/hub.log" && bad "A the -via- 看台 was leased" || ok "A the -via- 看台 is never leased (its home holds the lease)"
grep '"device": "MacBook-A"' "$W/hub.log" | grep -q '"via": "thin"' && grep '"device": "MacBook-A"' "$W/hub.log" | grep -q '"host": "home1"' \
  && grep '"device": "MacBook-A"' "$W/hub.log" | grep -q '"iterm2"' && grep '"device": "MacBook-A"' "$W/hub.log" | grep -q '"last_input": [1-9]' \
  && ok "A the lease says the row's device, via thin, host home1, iterm2, the client's last input" \
  || bad "A acquire body: $(grep MacBook-A "$W/hub.log" | head -n 1)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert set(d["views"])=={"a","b"} and d["primary"]=="L-MacBook-A"' "$W/conf/thin-lease.json" 2>/dev/null \
  && ok "A the book: views a, b; primary L-MacBook-A" || bad "A book: $(cat "$W/conf/thin-lease.json")"
n0=$(wc -l < "$W/hub.log"); python3 "$BIN/fleet_thin_lease.py" beat; n1=$(wc -l < "$W/hub.log")
[ "$n0" = "$n1" ] && ok "A a second beat inside the renew interval asks the hub nothing" || bad "A second beat asked $((n1 - n0))"
FLEET_THIN_LEASE_RENEW=0 python3 "$BIN/fleet_thin_lease.py" beat
[ "$(grep -c '"action": "renew"' "$W/hub.log")" = 2 ] && ok "A past the interval: each lease renewed" || bad "A renews: $(grep -c renew "$W/hub.log")"

# --- B. notify → the holder only -------------------------------------------------
h=$(python3 "$BIN/fleet_thin_lease.py" holder)
case "$h" in *'"view": "a"'*) ok "B holder = 看台 a (its lease is primary)" ;; *) bad "B holder: $h" ;; esac
# the person is in another app: the terminal said so (focus out, mode 1004)
printf '\033[O' > "$W/ctl-a"
for _ in $(seq 1 30); do T list-clients -F '#{client_session} #{client_flags}' | grep '^fl@view-a ' | grep -q focused || break; sleep 0.1; done
: > "$W/out-a"; : > "$W/out-b"
python3 "$BIN/fleet_thin_lease.py" notify --title '#3005 在问你' --body '要继续吗' --jump wid:u/f-two --log-key u/f-two --log-state ask
sleep 1.5
grep -aq $'\033]9;#3005 在问你: 要继续吗\a' "$W/out-a" && ok "B OSC 9 reached 看台 a's terminal" || bad "B a received no OSC 9: $(od -c "$W/out-a" | grep -a ']' | head -n 3)"
grep -aq $'\033]9;' "$W/out-b" && bad "B 看台 b received an OSC 9 too" || ok "B 看台 b received nothing (one person, one notification)"
j=$(T show-options -qv -t '=fl@view-a:' @notify_jump)
case "$j" in *' wid:u/f-two') ok "B @notify_jump armed on 看台 a: $j" ;; *) bad "B @notify_jump: '$j'" ;; esac
grep -q '"sent": "osc9"' "$W/notify.ndjson" && ok "B notify.ndjson: sent osc9" || bad "B log: $(cat "$W/notify.ndjson")"

# --- D. the click: focus back in → the jump ------------------------------------------
T select-window -t '=fl@view-a:^' 2>/dev/null
printf '\033[I' > "$W/ctl-a"
for _ in $(seq 1 30); do [ "$(T display-message -p -t '=fl@view-a:' '#{window_id}')" = "$W2" ] && break; sleep 0.1; done
[ "$(T display-message -p -t '=fl@view-a:' '#{window_id}')" = "$W2" ] && ok "D focus-in on 看台 a → its window for u/f-two" \
  || bad "D focus-in: 看台 a is on $(T display-message -p -t '=fl@view-a:' '#{window_id}'), want $W2"
[ -z "$(T show-options -qv -t '=fl@view-a:' @notify_jump)" ] && ok "D the jump is used once" || bad "D @notify_jump still set"
[ "$(T display-message -p -t '=fl@view-b:' '#{window_id}')" != "$W2" ] && ok "D 看台 b did not move" || bad "D 看台 b moved"

# --- C. the person is on another client: nothing ----------------------------------
printf 'L-elsewhere\n' > "$W/PRIMARY"
FLEET_THIN_LEASE_RENEW=0 python3 "$BIN/fleet_thin_lease.py" beat
python3 "$BIN/fleet_thin_lease.py" holder >/dev/null && bad "C a holder while the primary is elsewhere" || ok "C primary elsewhere → no holder here"
: > "$W/out-a"; : > "$W/out-b"
python3 "$BIN/fleet_thin_lease.py" notify --title X --body Y --jump wid:u/f-two --log-key k2 --log-state ask
sleep 1
grep -aq $'\033]9;' "$W/out-a" "$W/out-b" && bad "C an OSC 9 went out with no lease" || ok "C no lease → no OSC 9 on any 看台"
grep '"key": "k2"' "$W/notify.ndjson" | grep -q '"skip": "no-lease"' && ok "C notify.ndjson: skip no-lease" || bad "C log: $(tail -n 1 "$W/notify.ndjson")"
printf 'L-MacBook-A\n' > "$W/PRIMARY"; FLEET_THIN_LEASE_RENEW=0 python3 "$BIN/fleet_thin_lease.py" beat

# --- E. fleet_notify.beat → the sender it is given --------------------------------------
cat > "$W/send.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/sent"
EOF
chmod +x "$W/send.sh"
python3 - "$BIN" "$W" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import fleet_notify
g, w = sys.argv[2] + "/g", sys.argv[2]
row = lambda st: [{"wid": "u/f-two", "issue": "3005", "state": st, "needs": "ask" if st == "needs" else "", "node": "m4"}]
fleet_notify.beat(row("working"), g, "", sender=[w + "/send.sh"])
fleet_notify.beat(row("needs"), g, "", sender=[w + "/send.sh"])
time.sleep(1)
PY
grep -q -- '--jump wid:u/f-two' "$W/sent" 2>/dev/null && ok "E an 在问你 row → the given sender (--jump wid:u/f-two)" || bad "E sender got: $(cat "$W/sent" 2>/dev/null)"

# --- F. fleet-open to a thin 看台 -------------------------------------------------------
P0=$(T list-panes -t fl -F '#{pane_id}' | head -n 1)
WHERE="$W/where.sh"
printf '#!/bin/sh\necho %s\n' "'{\"state\":\"active\",\"source\":\"hub\",\"via\":\"thin\",\"device\":\"MacBook-A\"}'" > "$WHERE"; chmod +x "$WHERE"
cat > "$W/actions.sh" <<EOF
#!/bin/sh
echo called >> "$W/actions.called"; exit 1
EOF
chmod +x "$W/actions.sh"
openit() {
  env TMUX="$S/fl,0,0" TMUX_PANE="$P0" PATH="$W/bin:$PATH" FLEET_OPEN_WHERE_CMD="$WHERE" \
    FLEET_OPEN_ACTIONS_BIN="$W/actions.sh" FLEET_OPEN_SECRET_FILE="$W/open.secret" FLEET_OPEN_URL_BIN=/usr/bin/false \
    bash "$BIN/fleet-open.sh" https://example.com/x 2>"$W/open.err"
}
: > "$W/out-a"; : > "$W/out-b"; : > "$W/out-x"
printf 'z' > "$W/ctl-a"; sleep 0.5            # 看台 a is the newest client
r=$(openit); sleep 1
[ "$r" = sent:iterm2 ] && ok "F fleet-open → sent:iterm2" || bad "F fleet-open said '$r' ($(cat "$W/open.err"))"
[ ! -f "$W/actions.called" ] && ok "F no hub action for a thin lease (nobody polls one)" || bad "F the hub action road was taken"
grep -aq $'\033]1337;Custom=id=' "$W/out-a" && ok "F OSC 1337 Custom on 看台 a's terminal" || bad "F a got no OSC 1337"
spool_made "$W/conf/remote-views" && bad "F a spool dir was made" || ok "F no spool for a thin 看台"
: > "$W/out-x"
printf 'z' > "$W/ctl-x"; sleep 0.5            # now the -via- client is the newest
r=$(openit); sleep 1
grep -aq $'\033Ptmux;\033\033]1337;Custom=id=' "$W/out-x" && ok "F the -via- client: the escape wrapped as tmux passthrough ($r)" \
  || bad "F -via-: '$r' $(cat "$W/open.err") $(od -c "$W/out-x" | grep -a 'P' | head -n 2)"

# --- G. where, no hub, no fleet-shell -----------------------------------------------------
out=$(FLEET_CLIENT_WHERE_CMD="echo {\"state\":\"nohub\"}" FLEET_SHELL_SESSION=thn-none-$$ bash "$BIN/fleet-client-where.sh")
case "$out" in MacBook-*'（经 home1）'*) ok "G where (no hub, no fleet-shell): $out" ;; *) bad "G where: '$out'" ;; esac
js=$(FLEET_CLIENT_WHERE_CMD="echo {\"state\":\"nohub\"}" FLEET_SHELL_SESSION=thn-none-$$ bash "$BIN/fleet-client-where.sh" --json)
case "$js" in *'"via": "thin"'*'"source": "local"'*|*'"source": "local"'*'"via": "thin"'*) ok "G --json: source local, via thin" ;; *) bad "G json: $js" ;; esac

# --- H. a 看台 whose client left: released ------------------------------------------------
kill "$PTY_b" 2>/dev/null
for _ in $(seq 1 30); do T list-clients -F '#{client_session}' | grep -qx 'fl@view-b' || break; sleep 0.1; done
python3 "$BIN/fleet_thin_lease.py" beat
grep -q '"action": "release", "lease": "L-MacBook-B"' "$W/hub.log" && ok "H 看台 b's client left → its lease released" || bad "H no release: $(tail -n 2 "$W/hub.log")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert set(d["views"])=={"a"}' "$W/conf/thin-lease.json" 2>/dev/null \
  && ok "H the book keeps a only" || bad "H book: $(cat "$W/conf/thin-lease.json")"

# --- I. never a thin 看台: nothing ------------------------------------------------------------
mkdir -p "$W/conf2"
FLEET_CONF_DIR="$W/conf2" python3 "$BIN/fleet_thin_lease.py" beat
[ -z "$(ls -A "$W/conf2")" ] && ok "I no thin 看台 here → no book, nothing written" || bad "I wrote: $(ls -A "$W/conf2")"

printf 'fleet-thin-notify selftest: %d check(s), %d failure(s)\n' "$N" "$FAIL"
[ "$FAIL" -eq 0 ]
