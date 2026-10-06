#!/bin/bash
# clipboard-osc52-selftest.sh — text selected in another machine's session reaches
# the person's own clipboard (issue #1766).
#
# The chain on the person's screen: their terminal ← the shell's tmux
# (conf/tmux-shell.conf) ← its right pane, a nested client of the STAGE
# (conf/tmux-shell-stage.conf) ← the stage's pane, the machine's fleet session
# (conf/tmux-attention.conf). A selection is copied by the INNERMOST tmux, which
# writes it as OSC 52 to its terminal — a pane of the next server out. tmux's
# default `set-clipboard external` drops an OSC 52 a pane sends, so every hop
# outward must say `on`, or the copy dies there.
#
#   A. lint   each of the three confs sets `set-clipboard on`; the hub's client
#             mirror (fleetclient/) carries the shell + stage confs as they are
#             (fleet-client-mirror.sh --check).
#   B. chain  three tmux servers on isolated sockets, each given the
#             set-clipboard value its conf sets, nested shell → stage → node, a
#             python pty as the outer terminal. In the node, copy-mode selects a
#             line and copies it (what a mouse drag ends in): the pty receives
#             `\e]52;c;<base64>`, and the decoded text is exactly the selection.
#   C. why    the same chain with the shell at `external` (the value before
#             #1766): the pty receives no OSC 52 — the failure this fixes.
#   D. doctor `fleet doctor` on a client (fleet-agent-bundle.py doctor) prints a
#             `clipboard` row: PASS when iTerm2's AllowClipboardAccess is on, WARN
#             (with where to turn it on) when off or unset, nothing without iTerm2.
#
# Prints what the terminal received, decoded — the issue's 上线证据.
# tmux / python3 absent → SKIP (exit 0). CLIP_KEEP=1 keeps the work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BIN/.." && pwd)"
TMUX_BIN=$(command -v tmux) || { printf 'clipboard-osc52 selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'clipboard-osc52 selftest: python3 absent — SKIP\n'; exit 0; }
unset TMUX TMUX_PANE

FAIL=0; CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); printf 'ok:   %s\n' "$1"; }
bad() { CHECKS=$((CHECKS + 1)); FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# --- A. the confs ------------------------------------------------------------
clipval() {  # <conf> → the value its `set -g set-clipboard` line sets (last wins)
  awk '$1=="set" && $2=="-g" && $3=="set-clipboard" {v=$4} END {print v}' "$1"
}
SHELL_V=$(clipval "$REPO/conf/tmux-shell.conf")
STAGE_V=$(clipval "$REPO/conf/tmux-shell-stage.conf")
NODE_V=$(clipval "$REPO/conf/tmux-attention.conf")
[ "$SHELL_V" = on ] && ok "A conf/tmux-shell.conf: set-clipboard on" || bad "A conf/tmux-shell.conf: set-clipboard '${SHELL_V}', want on"
[ "$STAGE_V" = on ] && ok "A conf/tmux-shell-stage.conf: set-clipboard on" || bad "A conf/tmux-shell-stage.conf: set-clipboard '${STAGE_V}', want on"
[ "$NODE_V" = on ] && ok "A conf/tmux-attention.conf: set-clipboard on" || bad "A conf/tmux-attention.conf: set-clipboard '${NODE_V}', want on"
MIRROR="$REPO/tokenledger/internal/api/fleetclient/conf"
if [ -d "$MIRROR" ]; then
  for c in tmux-shell.conf tmux-shell-stage.conf; do
    [ "$(clipval "$MIRROR/$c")" = on ] && ok "A fleetclient mirror $c: set-clipboard on" || bad "A fleetclient mirror $c: not on"
  done
  if out=$(bash "$BIN/fleet-client-mirror.sh" --check 2>&1); then ok "A fleet-client-mirror.sh --check"
  else bad "A fleet-client-mirror.sh --check: $out"; fi
fi

# --- D. the client doctor's `clipboard` row (fleet-agent-bundle.py) ------------
# iTerm2 must accept the OSC 52 too; `fleet doctor` on a client says so, never fixes it.
drow() { FLEET_ITERM_CLIPBOARD="$1" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("b", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); print(m.iterm_clipboard())' "$BIN/fleet-agent-bundle.py" 2>&1; }
case "$(drow 1)" in *PASS*clipboard*) ok "D doctor: iTerm2 AllowClipboardAccess=1 → PASS clipboard" ;; *) bad "D doctor on: $(drow 1)" ;; esac
case "$(drow 0)" in *WARN*clipboard*"may access clipboard"*) ok "D doctor: AllowClipboardAccess=0 → WARN with where to turn it on" ;; *) bad "D doctor off: $(drow 0)" ;; esac
case "$(drow '')" in *WARN*clipboard*) ok "D doctor: AllowClipboardAccess unset (iTerm2 default off) → WARN" ;; *) bad "D doctor unset: $(drow '')" ;; esac
[ "$(drow none)" = None ] && ok "D doctor: no iTerm2 → no row" || bad "D doctor no iTerm2: $(drow none)"

# --- B/C. the chain ----------------------------------------------------------
# Sockets under a SHORT dir: a long $TMPDIR overflows AF_UNIX's 104 bytes.
WORK="$(mktemp -d /tmp/clip.XXXXXX)" || exit 2
cleanup() {
  for s in shell stage node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  [ -n "${CLIP_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }; rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
PAYLOAD='hello-1766 选中的字 ✓'

# The pty: attaches to the shell server, then runs the copy in the node, and
# reports every OSC 52 the terminal received (decoded) as JSON lines.
cat > "$WORK/term.py" <<'PY'
import base64, fcntl, json, os, pty, re, select, struct, subprocess, sys, termios, time
tmux, work, payload = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(tmux, [tmux, "-S", work + "/shell", "attach", "-t", "shell"])
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
def T(sock, *a):
    return subprocess.run([tmux, "-S", work + "/" + sock, *a], capture_output=True, text=True).stdout
# Wait until every hop has a client: shell (us), stage (in shell's pane), node (in stage's).
for _ in range(100):
    pump(0.1)
    if T("stage", "list-clients").strip() and T("node", "list-clients").strip() \
       and payload in T("node", "capture-pane", "-p"):
        break
pump(0.5)
buf = b""
# Select the payload line in copy-mode and copy it — where a mouse drag ends.
T("node", "copy-mode", "-t", "node")
T("node", "send", "-t", "node", "-X", "search-backward", "hello-1766")
T("node", "send", "-t", "node", "-X", "begin-selection")
T("node", "send", "-t", "node", "-X", "end-of-line")
T("node", "send", "-t", "node", "-X", "copy-selection-and-cancel")
pump(2.0)
out = []
for m in re.finditer(rb"\x1b\]52;([a-z]*);([A-Za-z0-9+/=]*)(?:\x07|\x1b\\)", buf):
    out.append({"sel": m.group(1).decode(), "text": base64.b64decode(m.group(2)).decode("utf-8", "replace")})
print(json.dumps({"osc52": out, "buffer": T("node", "show-buffer")}, ensure_ascii=False))
os.kill(pid, 9)
PY

chain() {  # <shell value> → the pty's JSON
  local s
  for s in shell stage node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  local conf="$WORK/base.conf"
  printf 'set -g default-terminal "tmux-256color"\nset -g status off\nset -g escape-time 0\nset -g mode-keys emacs\n' > "$conf"
  "$TMUX_BIN" -S "$WORK/node" -f "$conf" new-session -d -s node -x 96 -y 24 \
    "printf '%s\n' '$PAYLOAD'; exec sleep 600"
  "$TMUX_BIN" -S "$WORK/node" set -g set-clipboard "$NODE_V"
  "$TMUX_BIN" -S "$WORK/stage" -f "$conf" new-session -d -s stage -x 98 -y 26 \
    "TMUX= exec $TMUX_BIN -S $WORK/node attach -t node"
  "$TMUX_BIN" -S "$WORK/stage" set -g set-clipboard "$STAGE_V"
  "$TMUX_BIN" -S "$WORK/shell" -f "$conf" new-session -d -s shell -x 100 -y 28 \
    "TMUX= exec $TMUX_BIN -S $WORK/stage attach -t stage"
  "$TMUX_BIN" -S "$WORK/shell" set -g set-clipboard "$1"
  python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" "$PAYLOAD"
}

field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

J=$(chain "$SHELL_V")
printf 'B shell=%s stage=%s node=%s → terminal received: %s\n' "$SHELL_V" "$STAGE_V" "$NODE_V" "$J"
n=$(field "$J" 'len(d["osc52"])')
got=$(field "$J" 'd["osc52"][-1]["text"] if d["osc52"] else ""')
buf=$(field "$J" 'd["buffer"]')
[ "$buf" = "$PAYLOAD" ] && ok "B the node copied the selection: '$buf'" || bad "B node buffer '$buf', want '$PAYLOAD'"
[ "${n:-0}" -ge 1 ] && ok "B the outer terminal received OSC 52 ($n)" || bad "B the outer terminal received no OSC 52"
[ "$got" = "$PAYLOAD" ] && ok "B OSC 52 decodes to the selection: '$got'" || bad "B OSC 52 decoded '$got', want '$PAYLOAD'"

J=$(chain external)
printf 'C shell=external (before #1766) → terminal received: %s\n' "$J"
n=$(field "$J" 'len(d["osc52"])')
[ "${n:-1}" = 0 ] && ok "C shell at external: no OSC 52 reaches the terminal (the bug)" \
  || bad "C shell at external still passed OSC 52 ($n) — the chain test is not measuring the shell's setting"

printf 'clipboard-osc52 selftest: %d check(s), %d failure(s)\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
