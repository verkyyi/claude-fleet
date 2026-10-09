#!/usr/bin/env bash
# fleet-status-7501-selftest.sh — the agent's own report, OSC 7501 (issue #2536,
# EPIC #2535 C1). Drives bin/fleet-status-7501.py and bin/set-claude-state.sh
# (`--via 7501`) against a REAL, isolated tmux server (its own -S socket, torn down
# at exit — never the user's live server), and bin/fleet-claude.sh's relay gate.
#
#   A  decode: the payload grammar (state/kind/id/app/progress/msg base64), a probe
#      and a malformed one; the Scanner across every split of a stream
#   B  the relay answers the probe IN the stream, ahead of the DA1 reply tmux gives
#      at once — a fake agent that probes the way Claude Code 2.1.295 does
#      (OSC 7501 ; ? then DA1, the answer must come first) reads `yes`
#   C  four reports → @agent_status (JSON, msg decoded) and @claude_state:
#      working→working, blocked/permission→needs+perm+words, blocked/question→
#      needs+ask, done→done, error→exited; a sub-task's (id=) and clear keep it
#   D  Ctrl+Z: the agent's own kill(0, SIGTSTP) does not freeze it (issue #1843)
#   E  the agent's exit code comes back through the relay, at once even with a job
#      it left behind still holding the pty; @agent_status=exited
#   F  fleet-claude.sh: relay in a tmux pane with a terminal, bare otherwise and
#      with FLEET_STATUS_7501=0
#   G  cost: CPU the relay spends per MB of agent output, and idle (printed)
# tmux absent → SKIP (exit 0).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s7501-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
T() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
PY="$BIN/fleet-status-7501.py"
FAILS=0; CHECKS=0
fail() { FAILS=$((FAILS + 1)); printf 'selftest FAIL: %s\n  %s\n' "$1" "${2:-}" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1" "want '$2', got '$3'"; }

# ── A. decode + Scanner ─────────────────────────────────────────────────────
out=$(python3 - "$PY" <<'PYEOF'
import base64, importlib.util, sys
spec = importlib.util.spec_from_file_location("s7501", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = lambda s: base64.b64encode(s.encode()).decode()
r = m.decode("state=blocked:app=claude-code:kind=permission:progress=40:msg=" + b("Bash: git push\norigin"), now=5)
assert r == {"state": "blocked", "kind": "permission", "msg": "Bash: git push origin", "app": "claude-code", "ts": 5, "progress": 40}, r
assert m.claude_verb(r) == ["needs7501", "perm", "Bash: git push origin"]
assert m.claude_verb(m.decode("state=blocked:app=claude-code:kind=question:msg=" + b("要合并吗？"))) == ["needs7501", "ask", "要合并吗？"]
assert m.claude_verb(m.decode("state=blocked:app=claude-code:kind=auth")) == ["needs7501", "", ""]
assert m.claude_verb(m.decode("state=working:app=claude-code")) == ["working"]
assert m.claude_verb(m.decode("state=idle:app=claude-code")) == ["done"]
assert m.claude_verb(m.decode("state=done:app=claude-code")) == ["done"]
assert m.claude_verb(m.decode("state=error:app=claude-code")) == ["exited"]
assert m.claude_verb(m.decode("state=clear")) is None
assert m.decode("state=working:app=claude-code:kind=permission")["kind"] == ""   # kind only when blocked
assert m.decode("state=working:id=t1:app=claude-code")["id"] == "t1"
assert m.decode("?") is None and m.decode("state=bogus") is None and m.decode("garbage") is None
assert m.decode("state=blocked:kind=permission:msg=!!notb64")["msg"] == ""
assert len(m.decode("state=blocked:kind=question:msg=" + b("x" * 900))["msg"]) == 200
stream = (b"hello\x1b]7501;state=working:app=claude-code\x1b\\mid\x1b]7501;?\x1b\\"
          b"\x1b]7501;state=blocked:kind=question:msg=" + b("问").encode() + b"\x07tail\x1b]52;c;x\x07")
want = ["state=working:app=claude-code", "?", "state=blocked:kind=question:msg=" + b("问")]
for cut in range(len(stream) + 1):
    for cut2 in (cut, min(len(stream), cut + 3)):
        sc = m.Scanner(); got = sc.feed(stream[:cut]) + sc.feed(stream[cut:cut2]) + sc.feed(stream[cut2:])
        assert got == want, (cut, cut2, got)
sc = m.Scanner(); got = []
for i in range(len(stream)):
    got += sc.feed(stream[i:i + 1])
assert got == want, got
print("ok")
PYEOF
) || true
eq "A: decode + Scanner (every split)" ok "$out"

# ── the fake agent: probes like 2.1.295, then says what the test file tells it ──
cat > "$WORK/fake.py" <<'PYEOF'
import base64, os, select, signal, sys, termios, time, tty
work = sys.argv[1]
def log(s):
    with open(work + "/fake.log", "a") as f: f.write(s + "\n")
fd = 0
old = termios.tcgetattr(fd); tty.setraw(fd)
os.write(1, b"\x1b]7501;?\x1b\\\x1b[c")       # the probe, then the DA1 sentinel
buf = b""; t0 = time.time()
while time.time() - t0 < 3 and b"c" not in buf.split(b"\x1b[?", 1)[-1][:16]:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r: buf += os.read(fd, 1024)
i7, ida = buf.find(b"\x1b]7501;?"), buf.find(b"\x1b[?")
log("probe=" + ("yes" if 0 <= i7 and (ida < 0 or i7 < ida) else "no"))
termios.tcsetattr(fd, termios.TCSANOW, old)
b = lambda s: base64.b64encode(s.encode()).decode()
seen = 0
signal.signal(signal.SIGCONT, lambda *_: log("cont"))
while True:
    try:
        lines = open(work + "/say").read().splitlines()
    except OSError:
        lines = []
    for ln in lines[seen:]:
        seen += 1
        if ln.startswith("exit "):   # leave a job behind that holds the pty open
            import subprocess; subprocess.Popen(["sleep", "20"])
            log("bye"); sys.exit(int(ln[5:]))
        if ln == "tstp":
            os.kill(0, signal.SIGTSTP); time.sleep(0.3); log("alive-after-tstp"); continue
        if ln.startswith("flood "):
            blob = b"x" * 65535 + b"\n"
            for _ in range(int(ln[6:]) * 16): os.write(1, blob)
            log("flooded"); continue
        k, _, msg = ln.partition(" ")
        os.write(1, ("\x1b]7501;" + k + (":msg=" + b(msg) if msg else "") + "\x1b\\").encode())
    time.sleep(0.05)
PYEOF
: > "$WORK/say"
say() { printf '%s\n' "$1" >> "$WORK/say"; }
waitfor() {  # <what> <cmd…>: poll until the command's output matches $want (5 s)
  for _ in $(seq 1 100); do got=$("${@:2}" 2>/dev/null); [ "$got" = "$want" ] && return 0; sleep 0.05; done
  return 1
}
st()  { T show -wv -t "=s:a" @agent_status; }
cs()  { T display-message -p -t "=s:a" '#{@claude_state}|#{@claude_needs}|#{@claude_needs_detail}'; }
asf() { st | python3 -c 'import json,sys; d=json.load(sys.stdin); print("|".join(str(d.get(k,"")) for k in sys.argv[1:]))' "$@"; }

T -f /dev/null new-session -d -s s -n a -x 120 -y 30 \
  "env -u CLAUDE_CODE_ENTRYPOINT python3 '$PY' relay -- python3 '$WORK/fake.py' '$WORK'; echo rc=\$? > '$WORK/rc'; sleep 30"

# ── B. the probe ────────────────────────────────────────────────────────────
want=probe=yes; waitfor B grep -o 'probe=[a-z]*' "$WORK/fake.log" || true
eq "B: the relay answers OSC 7501 ; ? ahead of tmux's DA1" "probe=yes" "$(grep -o 'probe=[a-z]*' "$WORK/fake.log" 2>/dev/null)"

# ── C. four reports ─────────────────────────────────────────────────────────
say "state=working:app=claude-code"
want='working|claude-code'; waitfor C asf state app || true
eq "C: working → @agent_status" "working|claude-code" "$got"
want='working||'; waitfor C cs || true
eq "C: working → @claude_state working" "working||" "$got"
[ -n "$(T show -wv -t =s:a @agent_status_ts 2>/dev/null)" ] || fail "C: no @agent_status_ts"; CHECKS=$((CHECKS + 1))
say "state=blocked:app=claude-code:kind=permission Bash: git push origin issue-1"
want='blocked|permission|Bash: git push origin issue-1'; waitfor C asf state kind msg || true
eq "C: blocked/permission → @agent_status, msg decoded" "$want" "$got"
want='needs|perm|Bash: git push origin issue-1'; waitfor C cs || true
eq "C: blocked/permission → needs · perm · its words" "$want" "$got"
say "state=working:id=sub1:app=claude-code"
say "state=clear"
sleep 0.5
eq "C: a sub-task's report and clear keep the window's state" 'needs|perm|Bash: git push origin issue-1' "$(cs)"
say "state=blocked:app=claude-code:kind=question 演练放在 m5 还是只在 m4？"
want='needs|ask|演练放在 m5 还是只在 m4？'; waitfor C cs || true
eq "C: blocked/question → needs · ask · its words" "$want" "$got"
say "state=done:app=claude-code"
want='done||'; waitfor C cs || true
eq "C: done → done (needs cleared)" "$want" "$got"
say "state=error:app=claude-code"
want='exited||'; waitfor C cs || true
eq "C: error → exited" "$want" "$got"

# ── D. Ctrl+Z ───────────────────────────────────────────────────────────────
say tstp
want=alive-after-tstp; waitfor D grep -o alive-after-tstp "$WORK/fake.log" || true
eq "D: the agent's own SIGTSTP does not freeze it" alive-after-tstp "$got"

# ── G. cost ─────────────────────────────────────────────────────────────────
rpid=$(pgrep -f "fleet-status-7501.py relay -- python3 $WORK/fake.py" | head -1)
cpu() { ps -o time= -p "$1" 2>/dev/null | awk -F'[:.]' '{ n = NF; s = $(n-1) + 60 * $(n-2) + (n > 3 ? 3600 * $(n-3) : 0); print s "." $n }'; }
if [ -n "$rpid" ]; then
  c0=$(cpu "$rpid"); sleep 3; c1=$(cpu "$rpid")
  say "flood 8"
  want=flooded; waitfor G grep -o flooded "$WORK/fake.log" || true
  sleep 1; c2=$(cpu "$rpid")
  printf 'selftest: relay cost — idle %ss CPU over 3s; %ss CPU for 8 MB of agent output\n' \
    "$(awk -v a="$c0" -v b="$c1" 'BEGIN { printf "%.2f", b - a }')" "$(awk -v a="$c1" -v b="$c2" 'BEGIN { printf "%.2f", b - a }')" >&2
  CHECKS=$((CHECKS + 1))
  awk -v a="$c0" -v b="$c1" 'BEGIN { exit !(b - a < 0.2) }' || fail "G: the idle relay burns CPU" "$c0 → $c1"
else
  fail "G: no relay process found"
fi

# ── E. exit code ────────────────────────────────────────────────────────────
say "exit 7"
want=rc=7; waitfor E cat "$WORK/rc" || true
eq "E: the agent's exit code comes back through the relay (a leftover job holds the pty)" rc=7 "$got"
want='exited|7'; waitfor E asf state rc || true
eq "E: @agent_status says exited + rc" "exited|7" "$got"

# ── F. fleet-claude.sh's gate ───────────────────────────────────────────────
mkdir -p "$WORK/fb"
cat > "$WORK/fb/claude" <<'EOF'
#!/bin/sh
ps -o command= -p "$PPID" > "$FB_OUT"; exit 0
EOF
chmod +x "$WORK/fb/claude"
fc() {  # <out> [env…]: run fleet-claude.sh in a pane of the isolated server
  T new-window -d -t "=s:" -n "f$1" "env -i HOME='$WORK' PATH='$WORK/fb:/usr/bin:/bin:$(dirname "$REAL_TMUX")' TMUX=\"\$TMUX\" TMUX_PANE=\"\$TMUX_PANE\" FLEET_CONF_DIR='$WORK/conf' FLEET_MOD=0 FLEET_AGENT_CFG=0 FLEET_MCP=0 FLEET_CLAUDE_BIN='$WORK/fb/claude' FB_OUT='$WORK/$1' ${2:-} bash '$BIN/fleet-claude.sh' --version; sleep 5"
  for _ in $(seq 1 100); do [ -s "$WORK/$1" ] && break; sleep 0.05; done
  cat "$WORK/$1" 2>/dev/null
}
case "$(fc f-on)" in *fleet-status-7501.py\ relay*) CHECKS=$((CHECKS + 1)) ;; *) fail "F: no relay in a tmux pane" "$(cat "$WORK/f-on" 2>/dev/null)" ;; esac
case "$(fc f-off FLEET_STATUS_7501=0)" in *fleet-status-7501.py*) fail "F: FLEET_STATUS_7501=0 still relays" "$(cat "$WORK/f-off")" ;; *) CHECKS=$((CHECKS + 1)) ;; esac
out=$(env -i HOME="$WORK" PATH="$WORK/fb:/usr/bin:/bin" FLEET_CONF_DIR="$WORK/conf" FLEET_MOD=0 FLEET_AGENT_CFG=0 FLEET_MCP=0 \
  FLEET_CLAUDE_BIN="$WORK/fb/claude" FB_OUT="$WORK/f-bare" bash "$BIN/fleet-claude.sh" --version </dev/null >/dev/null 2>&1; cat "$WORK/f-bare" 2>/dev/null)
case "$out" in *fleet-status-7501.py*) fail "F: relays outside tmux" "$out" ;; *) CHECKS=$((CHECKS + 1)) ;; esac

if [ "$FAILS" -eq 0 ]; then
  printf 'selftest: fleet-status-7501 OK (%d checks)\n' "$CHECKS"; exit 0
fi
printf 'selftest: fleet-status-7501 %d of %d checks FAILED\n' "$FAILS" "$CHECKS" >&2
exit 1
