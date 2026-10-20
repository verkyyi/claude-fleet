#!/bin/bash
# clipboard-osc52-selftest.sh — text selected in another machine's session reaches
# the person's own clipboard (issue #1766).
#
# The chain on the person's screen (the thin client, issues #3005, #3008): their
# terminal ← the HOME machine's fleet server (a thin client's 看台) ← its pane —
# another machine's fleet server (conf/tmux-attention.conf both). A selection is
# copied by the INNERMOST tmux, which writes it as OSC 52 to its terminal — a pane
# of the next server out. tmux's default `set-clipboard external` drops an OSC 52
# a pane sends, so every hop outward must say `on`, or the copy dies there.
#
#   A. lint   the node conf sets `set-clipboard on`; the hub's client manifest is
#             current — the hub packs these very files at build time
#             (fleet-client-mirror.sh --check, #1803).
#   D. doctor `fleet doctor` on a client (fleet-agent-bundle.py doctor) prints a
#             `clipboard` row: PASS when iTerm2's AllowClipboardAccess is on, WARN
#             (with where to turn it on) when off or unset, nothing without iTerm2.
#   E. Ms     (issue #2758) the node conf gives every terminal `Ms` (its
#             terminal-overrides[92] row): an outer terminal tmux has no clipboard
#             feature for (TERM=screen-256color — a phone's, say) still receives
#             the copy (leg K).
#   G. binds  the node conf binds no copy-mode key (dash-keymap-selftest.sh leg 8 —
#             the node only opens capabilities).
#   K. thin   (issue #3005, EPIC #2999 C8) the two layers: another machine's fleet
#             server in a pane of the HOME machine's, the person's terminal its
#             client — both at the node conf's values: a selection copied there, a
#             real mouse drag (SGR reports typed into the outer terminal, ending in
#             tmux's stock MouseDragEnd1Pane → copy-pipe-and-cancel), and a
#             program's own OSC 52 (raw, or as passthrough — Claude Code's own
#             copy) reach the terminal; a TERM tmux has no clipboard for still does.
#   H. iTerm2 fleet-iterm-profile.py write turns AllowClipboardAccess on once (it is
#             app-wide: iTerm2 has no per-profile key) and records that it did; a
#             person who turns it off afterwards keeps it off; FLEET_ITERM_KEYS=0
#             touches nothing.
#
# Prints what the terminal received, decoded — the issue's 上线证据.
# tmux / python3 absent → SKIP (exit 0). CLIP_KEEP=1 keeps the work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REPO="$(cd "$BIN/.." && pwd)"
TMUX_BIN=$(command -v tmux) || { printf 'clipboard-osc52 selftest: tmux absent — SKIP\n'; exit 0; }
st_need python3
unset TMUX TMUX_PANE

FAIL=0; CHECKS=0
ok()  { CHECKS=$((CHECKS + 1)); printf 'ok:   %s\n' "$1"; }

# --- A. the confs ------------------------------------------------------------
clipval() {  # <conf> → the value its `set -g set-clipboard` line sets (last wins)
  awk '$1=="set" && $2=="-g" && $3=="set-clipboard" {v=$4} END {print v}' "$1"
}
NODE_V=$(clipval "$REPO/conf/tmux-attention.conf")
NODE_PT=$(awk '$1=="set" && $2=="-g" && $3=="allow-passthrough" {v=$4} END {print v}' "$REPO/conf/tmux-attention.conf")
[ "$NODE_V" = on ] && ok "A conf/tmux-attention.conf: set-clipboard on" || st_miss "A conf/tmux-attention.conf: set-clipboard '${NODE_V}', want on"
# the hub serves these very files (one copy, packed at build time — #1803)
if [ -d "$REPO/tokenledger/hub/api/fleetclient" ]; then
  if out=$(bash "$BIN/fleet-client-mirror.sh" --check 2>&1); then ok "A fleet-client-mirror.sh --check"
  else st_miss "A fleet-client-mirror.sh --check: $out"; fi
fi

# --- D. the client doctor's `clipboard` row (fleet-agent-bundle.py) ------------
# iTerm2 must accept the OSC 52 too; `fleet doctor` on a client says so, never fixes it.
drow() { FLEET_ITERM_CLIPBOARD="$1" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("b", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); print(m.iterm_clipboard())' "$BIN/fleet-agent-bundle.py" 2>&1; }
case "$(drow 1)" in *PASS*clipboard*) ok "D doctor: iTerm2 AllowClipboardAccess=1 → PASS clipboard" ;; *) st_miss "D doctor on: $(drow 1)" ;; esac
case "$(drow 0)" in *WARN*clipboard*"may access clipboard"*) ok "D doctor: AllowClipboardAccess=0 → WARN with where to turn it on" ;; *) st_miss "D doctor off: $(drow 0)" ;; esac
case "$(drow '')" in *WARN*clipboard*) ok "D doctor: AllowClipboardAccess unset (iTerm2 default off) → WARN" ;; *) st_miss "D doctor unset: $(drow '')" ;; esac
[ "$(drow none)" = None ] && ok "D doctor: no iTerm2 → no row" || st_miss "D doctor no iTerm2: $(drow none)"

# --- E (lint half). the Ms row in the node conf -------------------------------
msrow() {  # <conf> → the value its terminal-overrides[92] line sets
  awk '$1=="set" && $2=="-s" && $3=="terminal-overrides[92]" {v=$4} END {print v}' "$1" | tr -d "'"
}
# A thin client's terminal is the node's own client (issue #3005): the node says Ms too.
MS_NODE=$(msrow "$REPO/conf/tmux-attention.conf")
case "$MS_NODE" in '*:Ms=\E]52;%p1%s;%p2%s\007') ok "E conf/tmux-attention.conf: every terminal has Ms (a thin client's terminal is its client)" ;; *) st_miss "E conf/tmux-attention.conf Ms row: '$MS_NODE'" ;; esac

# --- G. no copy-mode bind on the node ------------------------------------------
grep -Eq '^[[:space:]]*bind(-key)?[[:space:]]+-T[[:space:]]+copy-mode' "$REPO/conf/tmux-attention.conf" \
  && st_miss "G the node conf binds a copy-mode key (it may only open capabilities)" || ok "G the node conf binds no copy-mode key"

# --- H. the iTerm2 permission ---------------------------------------------------
HW="$(mktemp -d /tmp/cliph.XXXXXX)" || exit 2
iprof() {  # <prefs plist state: unset|0|1> [env…] → AllowClipboardAccess after a write, + mark
  python3 - "$HW/p.plist" "$1" <<'PYH'
import plistlib, sys
d = {"New Bookmarks": []}
if sys.argv[2] != "unset": d["AllowClipboardAccess"] = sys.argv[2] == "1"
plistlib.dump(d, open(sys.argv[1], "wb"))
PYH
}
iread() { python3 -c 'import plistlib,sys; v=plistlib.load(open(sys.argv[1],"rb")).get("AllowClipboardAccess"); print("unset" if v is None else int(v))' "$HW/p.plist"; }
irun() { env FLEET_ITERM_DIR="$HW/dp" FLEET_ITERM_PREFS="$HW/p.plist" FLEET_ITERM_CLIP_MARK="$HW/mark" ITERM_PROFILE='' "$@" \
  python3 "$BIN/fleet-iterm-profile.py" write >/dev/null 2>&1; }
rm -f "$HW/mark"; iprof unset; irun
[ "$(iread)" = 1 ] && [ -f "$HW/mark" ] && ok "H unset → fleet turns it on, and marks that it did" || st_miss "H unset: AllowClipboardAccess=$(iread) mark=$([ -f "$HW/mark" ] && echo y || echo n)"
rm -f "$HW/mark"; iprof 0; irun
[ "$(iread)" = 1 ] && ok "H off, never turned on by fleet → on" || st_miss "H off before fleet: $(iread)"
iprof 0; irun
[ "$(iread)" = 0 ] && ok "H turned off by the person after fleet turned it on → stays off" || st_miss "H re-enabled after the person turned it off: $(iread)"
rm -f "$HW/mark"; iprof 1; irun
[ "$(iread)" = 1 ] && [ -f "$HW/mark" ] && ok "H already on → left on, marked" || st_miss "H already on: $(iread)"
rm -f "$HW/mark"; iprof unset; irun FLEET_ITERM_KEYS=0
[ "$(iread)" = unset ] && [ ! -f "$HW/mark" ] && ok "H FLEET_ITERM_KEYS=0 → nothing written" || st_miss "H FLEET_ITERM_KEYS=0 wrote: $(iread)"
rm -rf "$HW"

# --- K. the chain ------------------------------------------------------------
# Sockets under a SHORT dir: a long $TMPDIR overflows AF_UNIX's 104 bytes.
WORK="$(mktemp -d /tmp/clip.XXXXXX)" || exit 2
cleanup() {
  for s in shell node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  [ -n "${CLIP_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }; rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
PAYLOAD='hello-1766 选中的字 ✓'

# The pty: attaches to the home server ("shell"), then runs the copy in the node, and
# reports every OSC 52 the terminal received (decoded) as JSON lines.
cat > "$WORK/term.py" <<'PY'
import base64, fcntl, json, os, pty, re, select, struct, subprocess, sys, termios, time
tmux, work, payload, term, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = term
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
OSC52 = rb"\x1b\]52;([a-z]*);([A-Za-z0-9+/=]*)(?:\x07|\x1b\\)"
def settle(secs=8.0):
    # until the copy's OSC 52 has crossed every hop (a busy runner took more than a
    # fixed 2 s, #3906), then a breath for a second copy behind it
    end = time.time() + secs
    while time.time() < end and not re.search(OSC52, buf):
        pump(0.1)
    pump(0.3)
def T(sock, *a):
    return subprocess.run([tmux, "-S", work + "/" + sock, *a], capture_output=True, text=True).stdout
# Wait until every hop has a client: the home (us), the node (in the home's pane).
for _ in range(100):
    pump(0.1)
    if T("node", "list-clients").strip() and payload in T("node", "capture-pane", "-p"):
        break
pump(0.5)
buf = b""
if mode == "drag":
    # A person's drag: SGR mouse reports typed into the outer terminal — press on
    # the payload's first cell, move along row 1, release just past its last.
    width = sum(2 if ord(ch) > 0x2e80 else 1 for ch in payload)
    os.write(fd, b"\x1b[<0;1;1M")
    pump(0.3)
    for x in range(2, width + 2):
        os.write(fd, b"\x1b[<32;%d;1M" % x)
        pump(0.03)
    pump(0.3)
    os.write(fd, b"\x1b[<0;%d;1m" % (width + 1))
    settle()
elif mode in ("pane", "pane-pt"):
    # The program in the node's pane copies by itself (Claude Code's own copy):
    # it writes OSC 52 to its terminal — raw, or wrapped as tmux passthrough.
    b64 = base64.b64encode(payload.encode()).decode()
    seq = "\\033]52;c;%s\\007" % b64
    if mode == "pane-pt":
        seq = "\\033Ptmux;\\033\\033]52;c;%s\\007\\033\\\\" % b64
    T("node", "respawn-pane", "-k", "-t", "node", "printf '%s'; exec sleep 600" % seq)
    settle()
else:
    # Select the payload line in copy-mode and copy it — where a mouse drag ends.
    T("node", "copy-mode", "-t", "node")
    T("node", "send", "-t", "node", "-X", "search-backward", "hello-1766")
    T("node", "send", "-t", "node", "-X", "begin-selection")
    T("node", "send", "-t", "node", "-X", "end-of-line")
    T("node", "send", "-t", "node", "-X", "copy-selection-and-cancel")
    settle()
out = []
for m in re.finditer(OSC52, buf):
    out.append({"sel": m.group(1).decode(), "text": base64.b64decode(m.group(2)).decode("utf-8", "replace")})
print(json.dumps({"osc52": out, "buffer": T("node", "show-buffer")}, ensure_ascii=False))
os.kill(pid, 9)
PY

# chain_thin <outer TERM> [copy|drag|pane|pane-pt] — the thin path (issue #3005, EPIC #2999
# C8): the person's terminal ← the HOME machine's fleet server ← its pane, another
# machine's fleet server (a C4 window). Two servers, both with the node conf's own
# values (set-clipboard, allow-passthrough, the Ms row) — nothing else between.
chain_thin() {
  local s conf="$WORK/base.conf"
  for s in shell node; do "$TMUX_BIN" -S "$WORK/$s" kill-server 2>/dev/null; done
  printf 'set -g default-terminal "tmux-256color"\nset -g status off\nset -g escape-time 0\nset -g mode-keys emacs\nset -g mouse on\n' > "$conf"
  "$TMUX_BIN" -S "$WORK/node" -f "$conf" new-session -d -s node -x 96 -y 24 \
    "printf '%s\n' '$PAYLOAD'; exec sleep 600"
  "$TMUX_BIN" -S "$WORK/shell" -f "$conf" new-session -d -s shell -x 100 -y 28 \
    "TMUX= exec $TMUX_BIN -S $WORK/node attach -t node"
  for s in node shell; do
    "$TMUX_BIN" -S "$WORK/$s" set -g set-clipboard "$NODE_V"
    "$TMUX_BIN" -S "$WORK/$s" set -g allow-passthrough "$NODE_PT"
    "$TMUX_BIN" -S "$WORK/$s" set -s 'terminal-overrides[92]' "$MS_NODE"
  done
  python3 "$WORK/term.py" "$TMUX_BIN" "$WORK" "$PAYLOAD" "${1:-xterm-256color}" "${2:-copy}"
}

field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

# --- K. the thin path: another machine → the home machine → the terminal -------
# (issue #3005) a copy made in another machine's session, and a program's own OSC
# 52 there, cross the home machine's server to the person's terminal — a phone's
# terminal tmux knows no clipboard for included (the node conf's Ms row).
for m in "xterm-256color copy" "screen-256color copy" "xterm-256color drag" "xterm-256color pane" "xterm-256color pane-pt"; do
  # shellcheck disable=SC2086
  J=$(chain_thin $m)
  printf 'K thin: other machine → home → terminal (%s) → terminal received: %s\n' "$m" "$J"
  got=$(field "$J" 'd["osc52"][-1]["text"] if d["osc52"] else ""')
  [ "$got" = "$PAYLOAD" ] && ok "K thin ($m): the copy crosses two fleet servers to the terminal: '$got'" \
    || st_miss "K thin ($m): OSC 52 decoded '$got', want '$PAYLOAD'"
done

printf 'clipboard-osc52 selftest: %d check(s), %d failure(s)\n' "$CHECKS" "$FAIL"
st_done
