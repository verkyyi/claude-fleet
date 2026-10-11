#!/usr/bin/env bash
# fleet-status-replay-selftest.sh — the agent's state on the person's own terminal
# (issue #2539, EPIC #2535 C4). bin/fleet-status-7501.py's relay re-sends each OSC
# 7501 report as tmux passthrough (`relay --replay N`), and the node's switch /
# attach hooks (conf/tmux-attention.conf [75]: session-window-changed, client-session-changed — an
# attach fires the latter) run its `replay` onto each client's
# tty. Everything runs on isolated tmux servers (-S sockets under a short /tmp dir,
# torn down at exit — never the user's live server), a python pty standing in for
# the terminal (Ghostty).
#
#   A  unit: wrap() at depths lo..hi is what N tmux unwrap to exactly one bare
#      OSC; the relay splices the copies right after the agent's own OSC on every
#      split of the stream; depth 0 changes no byte; replay_payload() rebuilds the
#      report from @agent_status (msg kept, clear when there is none)
#   B  the chain: terminal ← shell ← stage ← node (the fleet shell's way in), each
#      server given the allow-passthrough its conf sets; the agent under
#      `relay --replay 3` asks for permission → the terminal receives the bare
#      OSC 7501, kind and words intact
#   C  why: the same chain with the shell at allow-passthrough off (before this
#      issue) → nothing reaches the terminal
#   D  replay: a terminal attached to a node with the [75] hooks from the conf —
#      attach hears its window's report, a switch to a window with no agent hears
#      clear, a switch back hears the report again; no @agent_replay ⇒ no write
#   F  thin (issue #3005): a thin client's terminal ← the home node (a session
#      there), and ← the home node ← another node (C4): with `relay --replay 3`
#      the terminal receives exactly one bare OSC 7501 at either depth
#   E  lint: the three confs set allow-passthrough on; the node conf carries the
#      [75] hooks; fleet-claude.sh passes --replay FLEET_STATUS_REPLAY_DEPTH
# Prints what the terminal received — the issue's 上线证据 for the branch.
# tmux / python3 absent → SKIP (exit 0). REPLAY_KEEP=1 keeps the work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BIN/.." && pwd)"
TMUX_BIN=$(command -v tmux) || { printf 'status-replay selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'status-replay selftest: python3 absent — SKIP\n'; exit 0; }
unset TMUX TMUX_PANE
PY="$BIN/fleet-status-7501.py"

FAIL=0; CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); printf 'ok:   %s\n' "$1"; }
bad() { CHECKS=$((CHECKS + 1)); FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# ── A. unit ─────────────────────────────────────────────────────────────────
out=$(python3 - "$PY" <<'PYEOF'
import base64, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("s7501", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
OSC = b"\x1b]7501;state=blocked:app=claude-code:kind=question:msg=" + base64.b64encode("要合并吗？".encode()) + b"\x1b\\"

def unwrap(buf):
    """One tmux with allow-passthrough on: each `ESC P tmux; … ESC \\` → its inside, ESCs halved;
    anything else that is an OSC 7501 dies there (tmux does not know it)."""
    out, i = b"", 0
    while i < len(buf):
        if buf.startswith(b"\x1bPtmux;", i):
            j, inner = i + 7, b""
            while j < len(buf):
                if buf.startswith(b"\x1b\x1b", j): inner += b"\x1b"; j += 2
                elif buf.startswith(b"\x1b\\", j): j += 2; break
                else: inner += buf[j:j + 1]; j += 1
            out += inner; i = j
        elif buf.startswith(b"\x1b]7501;", i):
            j = buf.index(b"\x1b\\", i) + 2; i = j
        else:
            out += buf[i:i + 1]; i += 1
    return out

for hops in (1, 2, 3):
    buf = OSC + m.wrap(OSC, 1, 3)          # what the relay puts on the pane
    for _ in range(hops):
        buf = unwrap(buf)
    assert buf.count(OSC) == 1, (hops, buf)
    buf = m.wrap(OSC, 0, 2)                # what replay writes to a client tty (one hop nearer)
    for _ in range(hops - 1):
        buf = unwrap(buf)
    assert buf.count(OSC) == 1, ("replay", hops, buf)

# splices land right after the agent's own OSC, on every split
stream = b"ab\x1b[1mc" + OSC + b"de\x1b]7501;?\x1b\\fg\x1b]7501;state=working:app=claude-code\x07h"
want = stream.replace(OSC, OSC + m.wrap(OSC, 1, 3)).replace(
    b"\x1b]7501;state=working:app=claude-code\x07",
    b"\x1b]7501;state=working:app=claude-code\x07" + m.wrap(b"\x1b]7501;state=working:app=claude-code\x1b\\", 1, 3))
for cut in range(len(stream) + 1):
    rd = m.Reader("", 3); got = b""
    for part in (stream[:cut], stream[cut:]):
        rd.feed(part); got += rd.spliced(part)
    rd.writer.close()
    assert got == want, (cut, got)
rd = m.Reader("", 0); rd.feed(stream); assert rd.spliced(stream) == stream; rd.writer.close()

# @agent_status → the payload again
rec = m.decode(OSC[7:-2].decode())
js = json.dumps({k: rec[k] for k in ("state", "kind", "msg", "app", "ts")}, ensure_ascii=False)
assert m.decode(m.replay_payload(js))["msg"] == "要合并吗？" and m.decode(m.replay_payload(js))["kind"] == "question"
assert m.replay_payload("") == "state=clear" and m.replay_payload('{"state":"exited","rc":0}') == "state=clear"
assert m.replay_payload('{"state":"working","app":"claude-code"}') == "state=working:app=claude-code"
print("ok")
PYEOF
) || true
[ "$out" = ok ] && ok "A wrap/unwrap at depths 1..3, splices on every split, depth 0 byte for byte, replay_payload" \
  || bad "A unit: $out"

# ── E. lint ─────────────────────────────────────────────────────────────────
passval() { awk '$1=="set" && $2=="-g" && $3=="allow-passthrough" {v=$4} END {print v}' "$1"; }
SHELL_V=$(passval "$REPO/conf/tmux-shell.conf")
STAGE_V=$(passval "$REPO/conf/tmux-shell-stage.conf")
NODE_V=$(passval "$REPO/conf/tmux-attention.conf")
for pair in "tmux-shell.conf:$SHELL_V" "tmux-shell-stage.conf:$STAGE_V" "tmux-attention.conf:$NODE_V"; do
  [ "${pair#*:}" = on ] && ok "E conf/${pair%%:*}: allow-passthrough on" || bad "E conf/${pair%%:*}: allow-passthrough '${pair#*:}', want on"
done
HOOKS=$(grep -E '^set-hook -g (session-window-changed|client-session-changed|client-attached)\[75\] .*fleet-status-7501\.py replay' "$REPO/conf/tmux-attention.conf")
[ "$(printf '%s\n' "$HOOKS" | grep -c .)" = 2 ] && ok "E node conf: the two [75] replay hooks (window and session changed)" || bad "E node conf [75] hooks: $HOOKS"
grep -q 'relay --replay "${FLEET_STATUS_REPLAY_DEPTH:-3}" --' "$BIN/fleet-claude.sh" \
  && ok "E fleet-claude.sh: relay --replay FLEET_STATUS_REPLAY_DEPTH (default 3)" || bad "E fleet-claude.sh does not pass --replay"

# ── the terminal ────────────────────────────────────────────────────────────
# Sockets under a SHORT dir: a long $TMPDIR overflows AF_UNIX's 104 bytes.
WORK="$(mktemp -d /tmp/s7r.XXXXXX)" || exit 2
cleanup() {
  for s in shell stage node one; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  [ -n "${REPLAY_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }; rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# term.py <tmux> <work> <socket> <session> <steps json> — attach a pty to <socket>,
# wait until every server in the chain has a client, then per step run its tmux
# commands, pump, and collect the BARE OSC 7501 payloads the terminal received.
cat > "$WORK/term.py" <<'PY'
import fcntl, json, os, pty, re, select, struct, subprocess, sys, termios, time
tmux, work, sock, sess, steps = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], json.loads(sys.argv[5])
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-S", work + "/" + sock, "attach", "-t", sess])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
buf = b""
def pump(secs):
    global buf
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return
            if not d: return
            buf += d
def T(s, *a):
    return subprocess.run([tmux, "-S", work + "/" + s, *a], capture_output=True, text=True).stdout
chain = steps.get("chain", [sock])
for _ in range(100):
    pump(0.1)
    if all(T(s, "list-clients").strip() for s in chain):
        break
pump(0.8)
res = {"attach": []}
RX = re.compile(rb"(?<!\x1b)\x1b\]7501;([^\x07\x1b]*)(?:\x07|\x1b\\)")
res["attach"] = [m.group(1).decode() for m in RX.finditer(buf)]
for name, cmds in steps["steps"]:
    buf = b""
    for c in cmds:
        if c[0] == "touch":
            open(c[1], "w").close()
        else:
            T(c[0], *c[1:])
    pump(steps.get("pump", 1.5))
    res[name] = [m.group(1).decode() for m in RX.finditer(buf)]
print(json.dumps(res, ensure_ascii=False))
os.kill(pid, 9)
PY
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

# The fake agent: once the test touches $WORK/go, asks for permission as 2.1.295 does.
cat > "$WORK/agent.py" <<'PY'
import base64, os, sys, time
go = sys.argv[1]
while not os.path.exists(go): time.sleep(0.05)
w = base64.b64encode("Bash: git push origin issue-2539".encode()).decode()
os.write(1, ("\x1b]7501;state=blocked:app=claude-code:kind=permission:msg=" + w + "\x1b\\").encode())
time.sleep(600)
PY
WANT="state=blocked:app=claude-code:kind=permission:msg=$(printf 'Bash: git push origin issue-2539' | base64)"

# ── B/C. the chain ──────────────────────────────────────────────────────────
chain() {  # <shell's allow-passthrough> → the terminal's JSON
  local s conf="$WORK/base.conf"
  for s in shell stage node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  rm -f "$WORK/go"
  printf 'set -g default-terminal "tmux-256color"\nset -g status off\nset -g escape-time 0\n' > "$conf"
  "$TMUX_BIN" -S "$WORK/node" -f "$conf" new-session -d -s node -x 96 -y 24 \
    "python3 '$PY' relay --replay 3 -- python3 '$WORK/agent.py' '$WORK/go'"
  "$TMUX_BIN" -S "$WORK/node" set -g allow-passthrough "$NODE_V"
  "$TMUX_BIN" -S "$WORK/stage" -f "$conf" new-session -d -s stage -x 98 -y 26 \
    "TMUX= exec $TMUX_BIN -S $WORK/node attach -t node"
  "$TMUX_BIN" -S "$WORK/stage" set -g allow-passthrough "$STAGE_V"
  "$TMUX_BIN" -S "$WORK/shell" -f "$conf" new-session -d -s shell -x 100 -y 28 \
    "TMUX= exec $TMUX_BIN -S $WORK/stage attach -t stage"
  "$TMUX_BIN" -S "$WORK/shell" set -g allow-passthrough "$1"
  python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" shell shell \
    "{\"chain\":[\"shell\",\"stage\",\"node\"],\"steps\":[[\"ask\",[[\"touch\",\"$WORK/go\"]]]]}"
}
J=$(chain "$SHELL_V")
printf 'B shell=%s stage=%s node=%s → terminal received: %s\n' "$SHELL_V" "$STAGE_V" "$NODE_V" "$J"
got=$(field "$J" '"|".join(d["ask"])')
[ "$got" = "$WANT" ] && ok "B three tmux deep: the terminal receives the bare OSC 7501, words intact" \
  || bad "B terminal got '$got', want '$WANT'"
msg=$(field "$J" '__import__("base64").b64decode(d["ask"][0].split("msg=")[1]).decode() if d["ask"] else ""')
[ "$msg" = "Bash: git push origin issue-2539" ] && ok "B decoded: '$msg'" || bad "B decoded '$msg'"

J=$(chain off)
printf 'C shell=off (before #2539) → terminal received: %s\n' "$J"
[ "$(field "$J" 'len(d["ask"])')" = 0 ] && ok "C shell at allow-passthrough off: nothing reaches the terminal (the gap)" \
  || bad "C shell off still passed it — the chain test is not measuring the shell's setting: $J"

# ── F. the thin path (issue #3005, EPIC #2999 C8) ────────────────────────────
# A thin client's terminal is the HOME machine's client: a session there is one
# tmux deep, a session on another machine two (its server in a home pane, C4).
# The relay's default depth (3) covers both, and exactly ONE bare copy arrives.
chain_thin() {  # <depth 1|2> → the terminal's JSON
  local s conf="$WORK/base.conf" outer=node
  for s in shell stage node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  rm -f "$WORK/go"
  printf 'set -g default-terminal "tmux-256color"\nset -g status off\nset -g escape-time 0\n' > "$conf"
  "$TMUX_BIN" -S "$WORK/node" -f "$conf" new-session -d -s node -x 96 -y 24 \
    "python3 '$PY' relay --replay 3 -- python3 '$WORK/agent.py' '$WORK/go'"
  "$TMUX_BIN" -S "$WORK/node" set -g allow-passthrough "$NODE_V"
  if [ "$1" = 2 ]; then   # the home machine: another node conf, the far node in its pane
    outer=shell
    "$TMUX_BIN" -S "$WORK/shell" -f "$conf" new-session -d -s shell -x 100 -y 28 \
      "TMUX= exec $TMUX_BIN -S $WORK/node attach -t node"
    "$TMUX_BIN" -S "$WORK/shell" set -g allow-passthrough "$NODE_V"
  fi
  local ch='"node"'; [ "$1" = 2 ] && ch='"shell","node"'
  python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" "$outer" "$outer" \
    "{\"chain\":[$ch],\"steps\":[[\"ask\",[[\"touch\",\"$WORK/go\"]]]]}"
}
for d in 1 2; do
  J=$(chain_thin "$d")
  printf 'F thin, %s tmux deep → terminal received: %s\n' "$d" "$J"
  got=$(field "$J" '"|".join(d["ask"])')
  [ "$got" = "$WANT" ] && ok "F thin $d deep (a session $( [ "$d" = 1 ] && echo on the home machine || echo on another machine)): exactly one bare OSC 7501, words intact" \
    || bad "F thin $d deep: terminal got '$got', want '$WANT'"
done

# ── D. replay on switch / attach ────────────────────────────────────────────
S1="$WORK/one"
"$TMUX_BIN" -S "$S1" -f "$WORK/base.conf" new-session -d -s one -n a -x 96 -y 24 "exec sleep 600"
"$TMUX_BIN" -S "$S1" set -g allow-passthrough "$NODE_V"
"$TMUX_BIN" -S "$S1" new-window -d -t one: -n b "exec sleep 600"
"$TMUX_BIN" -S "$S1" set -w -t one:a @agent_status \
  '{"state":"blocked","kind":"question","msg":"演练放在 m5 还是只在 m4？","app":"claude-code","ts":1}'
printf '%s\n' "$HOOKS" | sed "s#~/.claude/fleet/bin/#$BIN/#g" > "$WORK/hooks.conf"
"$TMUX_BIN" -S "$S1" source-file "$WORK/hooks.conf"
Q="state=blocked:app=claude-code:kind=question:msg=$(printf '演练放在 m5 还是只在 m4？' | base64)"
steps='{"chain":["one"],"steps":[["set",[["one","set","-g","@agent_replay","3"],["one","select-window","-t","one:b"],["one","select-window","-t","one:a"]]],["to-b",[["one","select-window","-t","one:b"]]],["to-a",[["one","select-window","-t","one:a"]]]]}'
# first without @agent_replay: attach + switches write nothing
J0=$(python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" one one '{"chain":["one"],"steps":[["to-b",[["one","select-window","-t","one:b"]]],["to-a",[["one","select-window","-t","one:a"]]]]}')
[ "$J0" = '{"attach": [], "to-b": [], "to-a": []}' ] && ok "D no @agent_replay (no relay with --replay ran): no write at all" \
  || bad "D without @agent_replay: $J0"
J=$(python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" one one "$steps")
printf 'D replay → terminal received: %s\n' "$J"
[ "$(field "$J" 'd["to-b"]')" = "['state=clear']" ] && ok "D a switch to a window with no agent: state=clear" \
  || bad "D to-b: $(field "$J" 'd["to-b"]')"
[ "$(field "$J" '"|".join(d["to-a"])')" = "$Q" ] && ok "D a switch back: the window's report, words intact" \
  || bad "D to-a: $(field "$J" 'd["to-a"]'), want $Q"
J=$(python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" one one '{"chain":["one"],"steps":[]}')
[ "$(field "$J" '"|".join(d["attach"])')" = "$Q" ] && ok "D a client arriving on the window hears its report, once" \
  || bad "D attach: $(field "$J" 'd["attach"]')"

printf 'status-replay selftest: %d check(s), %d failure(s)\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
